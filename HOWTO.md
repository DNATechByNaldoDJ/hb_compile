# HOWTO: build workflow

**English** | [Português (Brasil)](HOWTO.pt-BR.md)

This guide describes the central Harbour build workflow, profiles,
configuration, logs, and troubleshooting.

## Overview

All wrappers call `scripts\Invoke-HarbourBuild.ps1`. The runner loads
`config\profiles.json`, prepares the source and toolchain, exports `HB_*`
variables, invokes Harbour's make entry point, and installs into
`out\<profile>`. A missing source checkout is cloned into
`scratch\harbour-core`; build logs are written to `logs\`.

## Normal and full builds

A normal build uses the selected toolchain and Harbour's bundled sources. A
full build additionally calls `scripts\Resolve-HarbourDeps.ps1` to prepare
optional contrib libraries.

```powershell
.\build-zig.ps1 -Clean
.\build-full-zig.ps1 -IgnoreDependency qt -Clean
```

Windows full builds use vcpkg. POSIX runners use packages installed inside
Cygwin, MSYS, WSL, or the Docker image.

## Available profiles

| Profile | Runner and target |
| --- | --- |
| `auto` | Windows, Harbour compiler autodetection |
| `msvc64` | Windows x64, Microsoft Visual C++ |
| `mingw64` | Windows x64, MinGW-w64 GCC |
| `cygwin` | Cygwin x64 GCC |
| `msys` | MSYS2 MSYS x64 GCC |
| `linux-wsl` | Linux x64 inside WSL |
| `linux-docker` | Linux x64 inside Docker |
| `zig` | Native Windows Zig frontend |
| `zig-win64-gnu` | Windows x64 GNU target through Zig |
| `zig-win64-msvc` | Windows x64 MSVC target through Zig |
| `zig-win32-gnu` | Windows x86 cross-build |
| `zig-win-arm64` | Windows ARM64 cross-build |
| `zig-linux-x64` | Linux x64 cross-build |
| `zig-linux-arm64` | Linux ARM64 cross-build |

```powershell
.\scripts\Invoke-HarbourBuild.ps1 -ListProfiles
```

## Main commands

```powershell
.\build-zig.ps1 -DryRun
.\build-zig.ps1 -Clean
.\build-zig.ps1 -Jobs 4
.\build-zig.ps1 -BuildParts "compiler rtl"
.\build-zig.ps1 -MakeArg "HB_BUILD_VERBOSE=yes"
```

Use `-Minimal`, `-NoContrib`, or `-Package` when the corresponding Harbour
build mode is needed.

## Toolchain lookup

Portable toolchains follow this order:

1. Explicit path such as `-ZigPath` or `-MinGwPath`.
2. Repository-local `tools\<compiler>`.
3. A valid executable in `PATH`.
4. Automatic download through `scripts\Bootstrap-Tools.ps1`.

`-SkipToolBootstrap` disables automatic downloads. The MinGW probe rejects
Cygwin GCC and validates the compiler target. MSVC uses `vswhere` to locate
Visual Studio Build Tools; pass `-NoVsDevShell` when its environment is already
loaded.

## Configuration

Profiles and default directories are defined in `config\profiles.json`.
Optional dependency metadata lives in `config\dependencies.json`. Put local
`HB_WITH_*` overrides in `config\external-deps.local.ps1`, using
`config\external-deps.example.ps1` as a template.

```powershell
.\build-zig.ps1 -HarbourRoot D:\src\harbour
.\build-zig.ps1 -HarbourRepository https://github.com/user/core.git -HarbourRef test
```

## Cygwin

Install `gcc-core`, `make`, `binutils`, and optionally `git`:

```powershell
.\build-cygwin.ps1 -Clean
.\build-full-cygwin.ps1 -InstallSystemDependencies -IgnoreDependency qt -Clean
```

Specify a nonstandard Bash with `-CygwinBash`. The x64 profile overrides the
obsolete `-march=i586` flag in Harbour's Cygwin configuration.

## MSYS2 MSYS

Install the base tools from an MSYS shell:

```bash
pacman -Syu
pacman -S --needed base-devel make binutils gcc git pkgconf
```

Specify a nonstandard shell with `-MsysBash`. Harbour has no dedicated `msys`
platform, so the profile uses `HB_PLATFORM=cygwin`, `MSYSTEM=MSYS`, and disables
dynamic core and contrib builds.

## MinGW-w64

```powershell
.\build-mingw64.ps1 -Clean
.\build-full-mingw64.ps1 -MinGwPath C:\Tools\mingw64\bin -IgnoreDependency qt -Clean
```

The bootstrap supports prefixed xPack executables such as
`x86_64-w64-mingw32-gcc.exe` and configures `HB_CCPATH`/`HB_CCPREFIX`.

## Windows Sandbox

See [BUILD-SANDBOX.md](BUILD-SANDBOX.md) for the complete launcher specification,
persistence model, clean-output procedure, timeouts, and known limitations.

The Sandbox launcher supports portable Zig and MinGW profiles:

```powershell
.\build-sandbox.ps1 -BuildProfile zig -Clean -SandboxTimeoutMinutes 60
.\build-sandbox.ps1 -BuildProfile mingw64 -Full -IgnoreDependency qt -Clean
```

It creates a temporary source snapshot, copies it to `C:\hb_compile` in the
guest, and persistently maps only `scratch`, `tools`, `logs`, and `out`. Use
`-MemoryInMB`, `-NoNetworking`, `-KeepOpen`, or `-KeepSession` as needed.

`-SandboxTimeoutMinutes` limits how long the host waits for a result. Reaching
the limit does not currently cancel the guest VM; the build may still be
running. Inspect `%TEMP%\hb_compile-sandbox\<timestamp>` and do not start a
second Sandbox while it remains active.

`-DryRun` proves that the guest started and resolved a command, but it does not
produce binaries. For a real validation, omit `-DryRun`, use `-Clean`, and
confirm that artifact and log timestamps belong to the session.

## WSL and Docker

For Debian/Ubuntu WSL environments, install at least:

```bash
sudo apt update
sudo apt install build-essential git make binutils pkg-config ca-certificates file
```

```powershell
.\build-linux-wsl.ps1 -WslDistro Ubuntu-24.04 -Clean
.\build-linux-docker.ps1 -Clean
.\build-full-linux-docker.ps1 -IgnoreDependency qt -Clean
```

Docker uses `config\docker\linux\Dockerfile` or `Dockerfile.full`. Pass
`-SkipDockerBuild` to reuse an image or `-DockerBuildArg '--no-cache'` to force
a clean image rebuild.

## Outputs and logs

Each build prints `HarbourRoot`, profile, runner, install path, log path, make
command, and exported variables. Test a successful native installation with:

```powershell
.\scripts\Test-HarbourInstall.ps1 -Profile zig
```

## Quick troubleshooting

- `win-make.exe` not found: verify `HarbourRoot` or allow the automatic clone.
- Cygwin GCC selected by `mingw64`: use the Cygwin profile or fix `PATH`.
- Cygwin/MSYS Bash missing: pass `-CygwinBash` or `-MsysBash`.
- Qt takes too long: pass `-IgnoreDependency qt`.
- Missing POSIX library: install it in that environment or ignore it.
- Sandbox timed out while active: inspect its session log and wait for or close
  the existing instance before another run.
