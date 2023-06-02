#
# RPM Spec for Ethr
#

%define short ethr
Name:		%{short}
Version:	0.2.1
Release:	1%{?dist}
Summary:	A cross-platform network performance measurement tool
BuildArch:	%(uname -m)
License:	MIT
Group:		Applications/System

Provides:	%{name} = %{version}-%{release}
Prefix:		%{_prefix}

Vendor:		Microsoft Corporation
URL:		https://github.com/microsoft/ethr

Source:		%{short}-%{version}.tar.gz

BuildRequires:  golang


%description
Ethr is a cross platform network performance measurement tool written
in golang. The goal of this project is to provide a native tool for
comprehensive network performance measurements of bandwidth,
connections/s, packets/s, latency, loss & jitter, across multiple
protocols such as TCP, UDP, HTTP, HTTPS, and across multiple platforms
such as Windows, Linux and other Unix systems.

%global debug_package %{nil}


%define godir $(pwd)/GOPATH
%define gopath %{godir}:/usr/lib/golang/src/vendor:/usr/lib/golang/pkg/linux_amd64/vendor
%define gobin %{godir}/bin
%define gocache %{godir}/.cache

%prep
%setup -q


%build
export GOPATH="%{gopath}"
export GOBIN="%{gobin}"
export GOCACHE="%{gocache}"

mkdir -p "%{godir}" "%{gobin}"

# Go leaves a bunch of directories read-only, which makes cleaning out
# the workspace difficult.  Make sure that's cleaned up no matter
# what.

mkdir -p "%{godir}"
cleanup()
{
    find "%{godir}" -type d | xargs chmod +w
}
trap cleanup EXIT

%if 0%{?el7}
## EL7 has problems with its git that cause module fetches not to work.
## Use Golang's proxy to do it instead.
#export GO111MODULE=on
#export GOPROXY="https://proxy.golang.org"
%endif

go mod init microsoft.com/ethr
go mod tidy -e
go get ./...

go build


%install
%{__mkdir_p} %{buildroot}/%{_bindir}
install %{name} %{buildroot}/%{_bindir}/%{name}



%clean
rm -rf %{buildroot}


%files
%defattr(-,root,root)
%license LICENSE
%{_bindir}/*
