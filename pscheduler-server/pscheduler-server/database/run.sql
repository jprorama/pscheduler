--
-- Run Table
--

DO $$
DECLARE
    t_name TEXT;            -- Name of the table being worked on
    t_version INTEGER;      -- Current version of the table
    t_version_old INTEGER;  -- Version of the table at the start
BEGIN

    --
    -- Preparation
    --

    t_name := 'run';

    t_version := table_version_find(t_name);
    t_version_old := t_version;


    --
    -- Upgrade Blocks
    --

    -- Version 0 (nonexistant) to version 1
    IF t_version = 0
    THEN

        CREATE TABLE run (

        	-- Row identifier
        	id		BIGSERIAL
        			PRIMARY KEY,

        	-- External-use identifier
        	uuid		UUID
        			UNIQUE
        			DEFAULT gen_random_uuid(),

        	-- Task this run belongs to
        	task		BIGINT
        			REFERENCES task(id)
        			ON DELETE CASCADE,

        	-- Range of times when this task will be run
        	times		TSTZRANGE
        			NOT NULL,

        	--
        	-- Information about the local system's participation in the
        	-- test
        	--

                -- Participant data for the local test
                part_data        JSONB,

        	-- State of this run
        	state	    	 INTEGER DEFAULT run_state_pending()
        			 REFERENCES run_state(id),

        	-- Any errors that prevented the run from being put on the
        	-- schedule, used when state is run_state_nonstart().  Any
        	-- test- or tool-related errors will be incorporated into the
        	-- local or merged results.
        	errors   	 TEXT,

        	-- How it went locally, i.e., what the test returned
        	-- TODO: See if this is used anywhere.
        	status           INTEGER,

        	-- Result from the local run
        	-- TODO: Change this to local_result to prevent confusion
        	result   	 JSONB,

        	--
        	-- Information about the whole test
        	--

                -- Participant data for all participants in the test.  This is
                -- an array, with each element being the part_data for
                -- each participant.
                part_data_full   JSONB,

        	-- Combined resut generated by the lead participant
        	result_full    	 JSONB,

        	-- Merged result generated by the tool that did the test
        	result_merged  	 JSONB,

        	-- Clock survey, done if the run was not successful.
        	clock_survey  	 JSONB
        );

        -- This should be used when someone looks up the external ID.  Bring
        -- the row ID a long so it can be pulled without having to consult the
        -- table.
        CREATE INDEX run_uuid ON run(uuid, id);

        -- GIST accelerates range-specific operators like &&
        CREATE INDEX run_times ON run USING GIST (times);

        -- These two indexes are used by the schedule_gap view.
        CREATE INDEX run_times_lower ON run(lower(times), state);
        CREATE INDEX run_times_upper ON run(upper(times));

	t_version := t_version + 1;

    END IF;

    -- Version 1 to version 2
    -- Adds indexes for task to aid cascading deletes
    IF t_version = 1
    THEN
        CREATE INDEX run_task ON run(task);

        t_version := t_version + 1;
    END IF;

    -- Version 2 to version 3
    -- Adds index for upcoming/current runs
    IF t_version = 2
    THEN
        CREATE INDEX run_current ON run(state)
        WHERE state in (
            run_state_pending(),
            run_state_on_deck(),
            run_state_running()
        );

        t_version := t_version + 1;
    END IF;

    -- Version 3 to version 4
    -- Rebuilds index from previous version, which didn't have
    -- IMMUTABLE versions of the run_state_* functions.
    IF t_version = 3
    THEN
        DROP INDEX IF EXISTS run_current CASCADE;
        CREATE INDEX run_current ON run(state)
        WHERE state in (
            run_state_pending(),
            run_state_on_deck(),
            run_state_running()
        );

        t_version := t_version + 1;
    END IF;

    -- Version 4 to version 5
    -- Adds state to index of upper times
    IF t_version = 4
    THEN
        DROP INDEX IF EXISTS run_times_upper;
        CREATE INDEX run_times_upper ON run(upper(times), state);

        t_version := t_version + 1;
    END IF;


    -- Version 5 to version 6
    -- Adds 'added' column
    IF t_version = 5
    THEN
        ALTER TABLE run ADD COLUMN
        added TIMESTAMP WITH TIME ZONE;

        t_version := t_version + 1;
    END IF;


    -- Version 6 to version 7
    -- Adds 'times_actual' column
    IF t_version = 6
    THEN
        ALTER TABLE run ADD COLUMN
        times_actual TSTZRANGE NULL;

        t_version := t_version + 1;
    END IF;


    -- Version 7 to version 8
    -- Adds 'priority' and 'limit_diags' columns
    IF t_version = 7
    THEN
        ALTER TABLE run ADD COLUMN
        priority INTEGER DEFAULT 0;

        ALTER TABLE run ADD COLUMN
        limit_diags TEXT;

        t_version := t_version + 1;
    END IF;


    --
    -- Cleanup
    --

    PERFORM table_version_set(t_name, t_version, t_version_old);

END;
$$ LANGUAGE plpgsql;





-- Runs which could cause conflicts

DROP VIEW IF EXISTS run_conflictable CASCADE;
CREATE OR REPLACE VIEW run_conflictable
AS
    SELECT
        run.*,
        task.duration,
        scheduling_class.anytime,
        scheduling_class.exclusive
    FROM
        run
        JOIN task ON task.id = run.task
	JOIN test ON test.id = task.test
        JOIN scheduling_class ON scheduling_class.id = test.scheduling_class
    WHERE
        run.state <> run_state_nonstart()
        AND NOT scheduling_class.anytime
;



-- Determine if a proposed run would have conflicts

DO $$ BEGIN PERFORM drop_function_all('run_has_conflicts'); END $$;

CREATE OR REPLACE FUNCTION run_has_conflicts(
    task_id BIGINT,
    proposed_start TIMESTAMP WITH TIME ZONE,
    proposed_priority INTEGER = NULL
)
RETURNS BOOLEAN
AS $$
DECLARE
    taskrec RECORD;
    proposed_times TSTZRANGE;
BEGIN

    SELECT INTO taskrec
        task.*,
        test.scheduling_class,
        scheduling_class.anytime,
        scheduling_class.exclusive
    FROM
        task
        JOIN test ON test.id = task.test
        JOIN scheduling_class ON scheduling_class.id = test.scheduling_class
    WHERE
        task.id = task_id;

    IF NOT FOUND
    THEN
        RAISE EXCEPTION 'No such task.';
    END IF;

    -- Anytime tasks don't ever count
    IF taskrec.anytime
    THEN
        RETURN FALSE;
    END IF;

    proposed_times := tstzrange(proposed_start,
        proposed_start + taskrec.duration, '[)');

    RETURN ( 
        -- Exclusive can't collide with anything
        ( taskrec.exclusive
          AND EXISTS (SELECT * FROM run_conflictable
                      WHERE
		          times && proposed_times
			  AND COALESCE(priority, 0) >= COALESCE(proposed_priority, 0)
		     )
	)
        -- Non-exclusive can't collide with exclusive
          OR ( NOT taskrec.exclusive
               AND EXISTS (SELECT * FROM run_conflictable
                           WHERE
			       exclusive
			       AND times && proposed_times
			       AND COALESCE(priority, 0) >= COALESCE(proposed_priority, 0)
		    )
	    )
        );

END;
$$ LANGUAGE plpgsql;





-- Standard message used when throwing conflict exceptions.  Used by
-- api_run_post() in a comparison.

DO $$ BEGIN PERFORM drop_function_all('run_conflict_message'); END $$;

CREATE OR REPLACE FUNCTION run_conflict_message()
RETURNS TEXT
AS $$
BEGIN
    RETURN 'Run would create a scheduling conflict.';
END;
$$ LANGUAGE plpgsql;




DROP TRIGGER IF EXISTS run_alter ON run CASCADE;

DO $$ BEGIN PERFORM drop_function_all('run_alter'); END $$;

CREATE OR REPLACE FUNCTION run_alter()
RETURNS TRIGGER
AS $$
DECLARE
    horizon INTERVAL;
    taskrec RECORD;
    tool_name TEXT;
    run_result external_program_result;
    pdata_out JSONB;
    result_merge_input JSONB;
BEGIN

    -- TODO: What changes to a run don't we allow?

    SELECT INTO taskrec
        task.*,
        test.scheduling_class,
        scheduling_class.anytime,
        scheduling_class.exclusive
    FROM
        task
        JOIN test ON test.id = task.test
        JOIN scheduling_class ON scheduling_class.id = test.scheduling_class
    WHERE
        task.id = NEW.task;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No task % exists.', NEW.task;
    END IF;


    IF TG_OP = 'INSERT' THEN
        NEW.added := now();
    ELSIF TG_OP = 'UPDATE' AND NEW.added <> OLD.added THEN
        RAISE EXCEPTION 'Insertion time cannot be updated.';
    END IF;



    -- Non-background gets bounced if trying to schedule beyond the
    -- scheduling horizon.

    SELECT INTO horizon schedule_horizon FROM configurables;
    IF taskrec.scheduling_class <> scheduling_class_background_multi()
       AND (upper(NEW.times) - normalized_now()) > horizon THEN
        RAISE EXCEPTION 'Cannot schedule runs more than % in advance (% is % outside the range %)',
            horizon, NEW.times, (upper(NEW.times) - normalized_now() - horizon),
	    tstzrange(normalized_now(), normalized_now()+horizon);
    END IF;

    -- Only allow time changes that shorten the run
    IF (TG_OP = 'UPDATE')
        AND ( (lower(NEW.times) <> lower(OLD.times))
              OR ( upper(NEW.times) > upper(OLD.times) ) )
    THEN
        RAISE EXCEPTION 'Runs cannot be rescheduled, only shortened.';
    END IF;

    -- Make sure UUID assignment follows a sane pattern.

    IF (TG_OP = 'INSERT') THEN

        IF taskrec.participant = 0 THEN
	    -- Lead participant should be assigning a UUID
            IF NEW.uuid IS NOT NULL THEN
                RAISE EXCEPTION 'Lead participant should not be given a run UUID.';
            END IF;
            NEW.uuid := gen_random_uuid();
        ELSE
            -- Non-leads should be given a UUID.
            IF NEW.uuid IS NULL THEN
                RAISE EXCEPTION 'Non-lead participant should not be assigning a run UUID.';
            END IF;
        END IF;

    ELSEIF (TG_OP = 'UPDATE') THEN

        IF NEW.uuid <> OLD.uuid THEN
            RAISE EXCEPTION 'UUID cannot be changed';
        END IF;

        IF NEW.state <> OLD.state AND NEW.state = run_state_canceled() THEN
	    PERFORM pg_notify('run_canceled', NEW.id::TEXT);
        END IF;

        IF NEW.state <> OLD.state AND NEW.state = run_state_running() THEN
	    UPDATE task
	    SET runs_started = runs_started + 1
	    WHERE id = NEW.task;
        END IF;

	-- TODO: Make sure part_data_full, result_ful and
	-- result_merged happen in the right order.

	NOTIFY run_change;

    END IF;


    -- TODO: When there's resource management, assign the resources to this run.

    SELECT INTO tool_name name FROM tool WHERE id = taskrec.tool; 

    -- Finished runs are what get inserted for background tasks.
    -- TODO: Should be anything that's not a "finished" state
    IF TG_OP = 'INSERT' AND NEW.state <> run_state_finished() THEN

        pdata_out := row_to_json(t) FROM ( SELECT taskrec.participant AS participant,
                                           cast ( taskrec.json #>> '{test, spec}' AS json ) AS test ) t;

        run_result := pscheduler_command(ARRAY['internal', 'invoke', 'tool', tool_name, 'participant-data'], pdata_out::TEXT );
        IF run_result.status <> 0 THEN
	    RAISE EXCEPTION 'Unable to get participant data: %', run_result.stderr;
	END IF;
        NEW.part_data := regexp_replace(run_result.stdout, '\s+$', '')::JSONB;

    END IF;

    IF (TG_OP = 'UPDATE') THEN
               
	IF NEW.priority <> OLD.priority THEN
	    RAISE EXCEPTION 'Priority cannot be changed after scheduling.';
	END IF;

	-- Runs that are canceled stay that way.
	IF NEW.state <> OLD.state AND OLD.state = run_state_canceled() THEN
	    NEW.state := OLD.state;
	END IF;

	IF NOT run_state_transition_is_valid(OLD.state, NEW.state) THEN
            RAISE EXCEPTION 'Invalid transition between states (% to %).',
                OLD.state, NEW.state;
        END IF;


        -- Handle changes in status

        IF NEW.status IS NOT NULL
           AND ( (OLD.status IS NULL) OR (NEW.status <> OLD.status) )
           AND lower(NEW.times) > normalized_now()
        THEN
            RAISE EXCEPTION 'Cannot set state on future runs. % / %', lower(NEW.times), normalized_now();
        END IF;


	-- Handle times for runs reaching a state where they may have
	-- been running to one where they've stopped.

	IF NEW.state <> OLD.state
            AND NEW.state IN ( run_state_finished(), run_state_overdue(),
                 run_state_missed(), run_state_failed(), run_state_preempted() )
        THEN

	    -- Adjust the end times only if there's a sane case for
	    -- doing so.  If the clock is out of whack, the current
	    -- time could be less than the start time, which would
	    -- make for an invalid range.

	    IF normalized_now() >= lower(OLD.times)
            THEN
	        -- Record the actual times the run ran
	    	NEW.times_actual = tstzrange(lower(OLD.times), normalized_now(), '[]');

	    	-- If the run took less than the scheduled time, return
	    	-- the remainder to the timeline.
	    	IF upper(OLD.times) > normalized_now() THEN
	           NEW.times = tstzrange(lower(OLD.times), normalized_now(), '[]');
	    	END IF;
            END IF;

        END IF;

	-- If there's now a merged result, notify anyone watching for those.

       IF OLD.result_merged IS NULL AND NEW.result_merged IS NOT NULL
       THEN
	      PERFORM pg_notify('result_available', NEW.id::TEXT);
       END IF;


    ELSIF (TG_OP = 'INSERT') THEN

        -- Make a note that this run was put on the schedule and
        -- update the start time if we don't have one.

        UPDATE task t
        SET
            runs = runs + 1,
            -- TODO: This skews future runs when the first run slips.
            first_start = coalesce(t.first_start, t.start, lower(NEW.times))
        WHERE t.id = taskrec.id;


        -- Reject new runs that overlap with anything that isn't a
        -- finished run or where this insert would cause a conflict.
        -- This is done as the absolute last step because the entire
        -- table has to be locked.  We want that to happen for as
        -- little time as possible and only if there's potential for
        -- the run to have conflicts.  The table update above will be
        -- rolled back if this bombs out.

        IF (NOT taskrec.anytime)                       -- Test can have conflicts
           AND (NOT run_state_is_finished(NEW.state))  -- Tasks that will run

        THEN

            IF run_has_conflicts(taskrec.id, lower(NEW.times), NEW.priority)
            THEN
               RAISE EXCEPTION '%', run_conflict_message();
            END IF;

        END IF;

        PERFORM pg_notify('run_new', NEW.uuid::TEXT);

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER run_alter BEFORE INSERT OR UPDATE ON run
       FOR EACH ROW EXECUTE PROCEDURE run_alter();



-- If a task becomes disabled, remove all future runs.

DROP TRIGGER IF EXISTS run_task_disabled ON task CASCADE;

DO $$ BEGIN PERFORM drop_function_all('run_task_disabled'); END $$;

CREATE OR REPLACE FUNCTION run_task_disabled()
RETURNS TRIGGER
AS $$
BEGIN
    IF NEW.enabled <> OLD.enabled AND NOT NEW.enabled THEN

        -- Chuck future runs
        DELETE FROM run
        WHERE
            task = NEW.id
            AND lower(times) > normalized_now();

        -- Mark anything current as canceled.
	UPDATE run SET state = run_state_canceled()
	WHERE
	    run.task = NEW.id
	    AND times @> normalized_now()
	    AND state <> run_state_nonstart();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER run_task_disabled BEFORE UPDATE ON task
   FOR EACH ROW EXECUTE PROCEDURE run_task_disabled();


-- If the scheduling horizon changes and becomes smaller, remove runs
-- that go beyond it.

DROP TRIGGER IF EXISTS run_horizon_change ON configurables CASCADE;

DO $$ BEGIN PERFORM drop_function_all('run_horizon_change'); END $$;

CREATE OR REPLACE FUNCTION run_horizon_change()
RETURNS TRIGGER
AS $$
BEGIN

    IF NEW.schedule_horizon < OLD.schedule_horizon THEN
        DELETE FROM run
        WHERE upper(times) > (normalized_now() + NEW.schedule_horizon);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER run_horizon_change AFTER UPDATE ON configurables
    FOR EACH ROW EXECUTE PROCEDURE run_horizon_change();



-- Determine if a run can proceed or is pre-empted by other runs

DO $$ BEGIN PERFORM drop_function_all('run_can_proceed'); END $$;

CREATE OR REPLACE FUNCTION run_can_proceed(
    run_id BIGINT
)
RETURNS BOOLEAN
AS $$
DECLARE
    runrec RECORD;
BEGIN
    SELECT INTO runrec
        run.*,
        test.scheduling_class,
        scheduling_class.anytime,
        scheduling_class.exclusive
    FROM
        run
        JOIN task ON task.id = run.task
        JOIN test ON test.id = task.test
        JOIN scheduling_class ON scheduling_class.id = test.scheduling_class
    WHERE run.id = run_id;


    IF NOT FOUND
    THEN
        RAISE EXCEPTION 'No such run.';
    END IF;

    -- Anytime tasks don't ever count, so they're good to go.                                                                       
    IF runrec.anytime
    THEN
        RETURN TRUE;
    END IF;

    RETURN NOT (
        -- Exclusive can't collide with anything                                                                                    
        ( runrec.exclusive
          AND EXISTS (SELECT * FROM run_conflictable
                      WHERE
                          times && runrec.times
                          AND COALESCE(priority, 0) >= COALESCE(runrec.priority, 0)
                          AND id <> run_id
                     )
        )
        -- Non-exclusive can't collide with exclusive          
          OR ( NOT runrec.exclusive
               AND EXISTS (SELECT * FROM run_conflictable
                           WHERE
                               exclusive
                               AND times && runrec.times
                               AND COALESCE(priority, 0) >= COALESCE(runrec.priority, 0)
                               AND id <> run_id
                    )
            )
        );

END;
$$ LANGUAGE plpgsql;



DO $$ BEGIN PERFORM drop_function_all('run_start'); END $$;



-- Get a run marked as started.  Return NULL if successful and an
-- error message if not.  This is used by the runner.

CREATE OR REPLACE FUNCTION run_start(run_id BIGINT)
RETURNS TEXT
AS $$
BEGIN

    IF control_is_paused()
    THEN
        UPDATE run SET
            state = run_state_missed(),
            status = 1,
            result = '{ "succeeded": false, "diags": "System was paused." }'
        WHERE id = run_id;
        RETURN 'System was paused at run time.';
    END IF;

    IF NOT run_can_proceed(run_id)
    THEN
        UPDATE run SET
            state = run_state_preempted(),
            status = 1,
            result = '{ "succeeded": false, "diags": "Run was preempted." }'
        WHERE id = run_id;
        RETURN 'Run was preempted.';
    END IF;

    UPDATE run SET state = run_state_running() WHERE id = run_id;
    RETURN NULL;

END;
$$ LANGUAGE plpgsql;


-- Maintenance functions

DO $$ BEGIN PERFORM drop_function_all('run_handle_stragglers'); END $$;

CREATE OR REPLACE FUNCTION run_handle_stragglers()
RETURNS VOID
AS $$
DECLARE
    straggle_time TIMESTAMP WITH TIME ZONE;
    straggle_time_bg_multi TIMESTAMP WITH TIME ZONE;
BEGIN

    -- When non-background-multi tasks are considered tardy
    SELECT INTO straggle_time
        normalized_now() - run_straggle FROM configurables;

    -- When non-background-multi tasks are considered tardy
    SELECT INTO straggle_time_bg_multi
        normalized_now() - run_straggle FROM configurables;

    -- Runs that failed to start
    UPDATE run
    SET state = run_state_missed()
    WHERE id IN (
        SELECT
            run.id
        FROM
            run
            JOIN task ON task.id = run.task
            JOIN test ON test.id = task.test
        WHERE

            -- Non-background-multi runs pending on deck after start times
            -- were missed
            ( test.scheduling_class <> scheduling_class_background_multi()
              AND lower(times) < straggle_time
              AND run.state IN ( run_state_pending(), run_state_on_deck() )
            )

            OR

            -- Background-multi runs that passed their end time
            ( test.scheduling_class = scheduling_class_background_multi()
              AND upper(times) < straggle_time_bg_multi
              AND run.state IN ( run_state_pending(), run_state_on_deck() )
            )
    );


    -- Runs that started and didn't report back in a timely manner
    UPDATE run
    SET state = run_state_overdue()
    WHERE
        upper(times) < straggle_time
        AND state = run_state_running();

END;
$$ LANGUAGE plpgsql;


DO $$ BEGIN PERFORM drop_function_all('run_purge'); END $$;

CREATE OR REPLACE FUNCTION run_purge()
RETURNS VOID
AS $$
DECLARE
    purge_before TIMESTAMP WITH TIME ZONE;
BEGIN

    -- Most runs
    SELECT INTO purge_before now() - keep_runs_tasks FROM configurables;
    DELETE FROM run
    WHERE
        upper(times) < purge_before
        AND state NOT IN (run_state_pending(),
                          run_state_on_deck(),
                          run_state_running());

    -- Extra margin for anything that might actually be running
    purge_before := purge_before - 'PT1H'::INTERVAL;
    DELETE FROM run
    WHERE
        upper(times) < purge_before
        AND state IN (run_state_pending(),
                      run_state_on_deck(),
                      run_state_running());

END;
$$ LANGUAGE plpgsql;



-- Maintenance that happens four times a minute.

DO $$ BEGIN PERFORM drop_function_all('run_main_fifteen'); END $$;

CREATE OR REPLACE FUNCTION run_maint_fifteen()
RETURNS VOID
AS $$
BEGIN
    PERFORM run_handle_stragglers();
    PERFORM run_purge();
END;
$$ LANGUAGE plpgsql;



-- Convenient ways to see the goings on

CREATE OR REPLACE VIEW run_status
AS
    SELECT
        run.id AS run,
	run.uuid AS run_uuid,
	task.id AS task,
	task.uuid AS task_uuid,
	test.name AS test,
	tool.name AS tool,
	run.times,
	run_state.display AS state
    FROM
        run
	JOIN run_state ON run_state.id = run.state
	JOIN task ON task.id = task
	JOIN test ON test.id = task.test
	JOIN tool ON tool.id = task.tool
    WHERE
        run.state <> run_state_pending()
	OR (run.state = run_state_pending()
            AND lower(run.times) < (now() + 'PT2M'::interval))
    ORDER BY run.times;


CREATE OR REPLACE VIEW run_status_short
AS
    SELECT run, task, times, state
    FROM  run_status
;




--
-- JSON Representation
--

DO $$ BEGIN PERFORM drop_function_all('run_json'); END $$;

-- Return a JSON record suitable for returning by the REST API

CREATE OR REPLACE FUNCTION run_json(run_id BIGINT)
RETURNS JSONB
AS $$
DECLARE
    rec RECORD;
    result JSONB;
BEGIN
    SELECT INTO rec
        run.*,
        run_state.*,
	task.*,
	archiving_json(run.id) AS archivings
    FROM
        run
        JOIN run_state ON run_state.id = run.state
        JOIN task ON task.id = run.task
    WHERE run.id = run_id;
    IF NOT FOUND
    THEN
        RAISE EXCEPTION 'No such run.';
    END IF;

    result := json_build_object(
        'start-time', timestamp_with_time_zone_to_iso8601(lower(rec.times)),
        'end-time', timestamp_with_time_zone_to_iso8601(upper(rec.times)),
        'duration', interval_to_iso8601(upper(rec.times) - lower(rec.times)),
	'participant', rec.participant,
	'participants', rec.participants,
	'participant-data', rec.part_data,
	'participant-data-full', rec.part_data_full,
	'result', rec.result,
	'result-full', rec.result_full,
	'result-merged', rec.result_merged,
	'state', rec.enum,
	'state-display', rec.display,
	'errors', rec.errors,
	-- clock-survey is conditional; see below.
	-- archivings is conditional; see below.
        'added', timestamp_with_time_zone_to_iso8601(rec.added),
	'priority', rec.priority,
	'limit-diags', rec.limit_diags
	-- task-href has to be added by the caller
	-- result-href has to be added by the caller
    );

    IF rec.clock_survey IS NOT NULL THEN
        result := jsonb_set(result, '{clock-survey}', rec.clock_survey::JSONB, TRUE);
    END IF;

    IF rec.archivings IS NOT NULL THEN
        result := jsonb_set(result, '{archivings}', rec.archivings::JSONB, TRUE);
    END IF;

    RETURN result;
END
$$ language plpgsql;




--
-- API
--

-- Put a run of a task on the schedule.

-- NOTE: This is for scheduled runs only, not background-multi results.

DO $$ BEGIN PERFORM drop_function_all('api_run_post'); END $$;

CREATE OR REPLACE FUNCTION api_run_post(
    task_uuid UUID,
    start_time TIMESTAMP WITH TIME ZONE,
    run_uuid UUID,  -- NULL to assign one
    nonstart_reason TEXT = NULL,
    priority INTEGER = NULL,
    limit_diags TEXT = NULL
)
RETURNS TABLE (
    succeeded BOOLEAN,  -- True if the post was successful
    new_uuid UUID,      -- UUID of run, NULL if post failed
    conflict BOOLEAN,   -- True of failed because of a conflict
    error TEXT          -- Error text if post failed
)
AS $$
DECLARE
    task RECORD;
    time_range TSTZRANGE;
    initial_state INTEGER;
    initial_status INTEGER;
    exception_text TEXT;
BEGIN

    SELECT INTO task * FROM task WHERE uuid = task_uuid;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, FALSE,
            'Task does not exist'::TEXT;
        RETURN;
    END IF;

    IF run_uuid IS NULL AND task.participant <> 0 THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, FALSE,
            'Cannot set run UUID as non-lead participant'::TEXT;
        RETURN;
    END IF;

    IF nonstart_reason IS NULL THEN
        initial_state := run_state_pending();
        initial_status := NULL;
    ELSE
        initial_state := run_state_nonstart();
        initial_status := 1;  -- Nonzero means failure.
    END IF;
    
    start_time := normalized_time(start_time);
    time_range := tstzrange(start_time, start_time + task.duration, '[)');

    BEGIN

        WITH inserted_row AS (
            INSERT INTO run (uuid, task, times, state,
                errors, priority, limit_diags)
            VALUES (run_uuid, task.id, time_range, initial_state,
	        nonstart_reason, priority, limit_diags)
            RETURNING *
        ) SELECT INTO run_uuid uuid FROM inserted_row;

        RETURN QUERY SELECT TRUE, run_uuid, FALSE, ''::TEXT;

    EXCEPTION

        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS exception_text = MESSAGE_TEXT;
            IF exception_text <> run_conflict_message()
            THEN
                RAISE;  -- Re-reaise the original exception
            END IF;

            RETURN QUERY SELECT FALSE, NULL::UUID, TRUE, exception_text;

    END;

    RETURN;


END;
$$ LANGUAGE plpgsql;
