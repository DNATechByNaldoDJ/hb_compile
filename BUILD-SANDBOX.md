# Windows Sandbox builds

**English** | [Português (Brasil)](BUILD-SANDBOX.pt-BR.md)

`build-sandbox.ps1` runs selected Harbour profiles in a disposable Windows
Sandbox while persisting source downloads, toolchains, logs, and installation
outputs on the host.

## Purpose and intended use

The Sandbox workflow is primarily a **clean-room validation tool**. Its purpose
is to verify that a profile can prepare its tools and compile from a fresh
Windows environment without silently depending on software, environment
variables, registry entries, or configuration from the developer workstation.

It is not intended to be the main day-to-day build path. Sandbox startup,
snapshot copying, tool provisioning, dependency resolution, and a cold build are
considerably slower than using the normal local wrappers. For regular development,
prefer commands such as `build-zig.ps1` or `build-mingw64.ps1` and use incremental
builds when appropriate.

Use `build-sandbox.ps1` at meaningful validation points:

- before publishing or distributing a build;
- after changing profiles, bootstrap logic, dependencies, or build scripts;
- when investigating an undeclared host dependency;
- when confirming that setup instructions work on a clean Windows installation;
- periodically as a reproducibility check.

The persistent `scratch`, `tools`, and dependency caches improve subsequent
validation times, but they also mean that a Sandbox run is not automatically a
fully cold build. For the strongest verification, audit or clear the relevant
caches and start with an empty `out\<profile>` directory.

## Requirements

- Windows Sandbox optional feature enabled (`Containers-DisposableClientVM`).
- Hardware virtualization enabled and available to Windows.
- `WindowsSandbox.exe` available under the Windows system directory.
- Network access for the initial Harbour, toolchain, and dependency downloads.
- Enough free disk space for `scratch`, `tools`, `out`, and optional vcpkg data.

The launcher refuses to start when another Windows Sandbox instance is detected.

## Supported profiles

The initial implementation supports portable Windows-hosted toolchains:

```text
zig
zig-win64-gnu
zig-win64-msvc
zig-win32-gnu
zig-win-arm64
zig-linux-x64
zig-linux-arm64
mingw64
```

The following profiles are intentionally excluded:

- `linux-wsl` and `linux-docker`: nested virtualization/container workflows.
- `msvc64`: Visual Studio Build Tools is integrated with the host installation
  and is not treated as a portable Sandbox toolchain.
- `auto`: depends on ambient compiler detection and is not reproducible.
- `cygwin` and `msys`: require environment package provisioning that is not yet
  implemented by the Sandbox launcher.

## Basic usage

Preview the command without compiling:

```powershell
.\build-sandbox.ps1 `
  -BuildProfile zig `
  -DryRun `
  -SandboxTimeoutMinutes 10 `
  -KeepSession
```

Run a clean native Zig build:

```powershell
.\build-sandbox.ps1 `
  -BuildProfile zig `
  -Clean `
  -SandboxTimeoutMinutes 60 `
  -KeepSession
```

Run a full build without Qt:

```powershell
.\build-sandbox.ps1 `
  -BuildProfile zig `
  -Full `
  -Clean `
  -IgnoreDependency qt `
  -SandboxTimeoutMinutes 240 `
  -KeepSession
```

## Isolation and persistent directories

The launcher creates a source snapshot under:

```text
%TEMP%\hb_compile-sandbox\<timestamp>\source
```

The guest copies that snapshot to `C:\hb_compile`. The repository working tree
is therefore not directly modified by the Sandbox.

Four host directories are mapped with write access:

| Host directory | Guest directory | Purpose |
| --- | --- | --- |
| `scratch` | `C:\Persistent\scratch` | Harbour checkout and build data |
| `tools` | `C:\Persistent\tools` | Portable toolchains and dependency tools |
| `logs` | `C:\Persistent\logs` | Build and dependency logs |
| `out` | `C:\Persistent\out` | Installed artifacts by profile |

Inside the guest, junctions connect these directories to the copied project.
Their contents survive after the disposable VM closes.

## Important clean-build behavior

`-Clean` asks Harbour to clean its build products, but it does not guarantee
that `out\<profile>` is emptied before installation. Files from an older normal
or full build can remain when the current build skips a dependency or fails to
produce an optional contrib.

For an audit-quality build, start with an empty output directory:

```powershell
Rename-Item .\out\zig .\out\zig-before-sandbox
New-Item -ItemType Directory .\out\zig
```

Then run the Sandbox build. Everything in the new directory will belong to that
installation attempt. This is especially important before evaluating optional
DLLs such as `rddads`, `sddpg`, `hbpgsql`, `hbcurl`, or third-party runtime DLLs.

An old timestamp does not always prove that a build is invalid: copied source or
dependency files may preserve timestamps. Conversely, the mere presence of a
file does not prove that the current build produced it. Use the build log,
artifact hashes, and an initially empty output directory together.

## Normal versus full builds

A normal build compiles the core and contribs whose requirements are already
available. Missing optional dependencies are usually warnings and their contribs
are skipped.

A full build runs `scripts\Resolve-HarbourDeps.ps1` before Harbour make. Native
Windows profiles use vcpkg and local fallbacks defined by
`config\dependencies.json`.

Full builds can take significantly longer and consume more disk space. Qt is a
particularly large dependency, so `-IgnoreDependency qt` is recommended for an
initial full validation.

Not every optional dependency is guaranteed to work with Zig. Some SDKs are
manual, architecture-specific, or provide libraries built for another compiler.
`-StrictDependencies` turns unresolved optional requirements into failures where
the resolver supports strict validation.

## Timeouts and VM lifetime

`-SandboxTimeoutMinutes` controls how long the host waits for `result.json`.
It does not currently terminate the VM or cancel the build. If the timeout is
reached while Windows Sandbox remains open, the guest may still be compiling.

Do not launch another Sandbox build while the existing instance is running.
Inspect Task Manager, the Sandbox window, session log, and build logs first.

Recommended starting values:

| Build | Suggested timeout |
| --- | ---: |
| Dry run | 10 minutes |
| Normal Zig build | 60 minutes |
| Full build without Qt | 240 minutes |
| Full build with Qt | 360 minutes or more |

Actual time depends on CPU, storage, network, cache state, and dependency set.

## Main parameters

| Parameter | Purpose |
| --- | --- |
| `-BuildProfile` | Selects one of the supported profiles |
| `-Full` | Resolves optional dependencies before building |
| `-Clean` | Requests a clean Harbour build |
| `-DryRun` | Resolves and prints commands without compiling |
| `-Jobs` | Sets make parallelism |
| `-MemoryInMB` | Configures Sandbox memory; default is 8192 MB |
| `-SandboxTimeoutMinutes` | Limits host-side result waiting |
| `-NoNetworking` | Disables guest networking |
| `-KeepSession` | Keeps session request, result, script, and transcript |
| `-KeepOpen` | Leaves the guest open after its script finishes |
| `-LocalWorkspace` | Builds on the guest disk and synchronizes persistent directories afterward |
| `-IgnoreDependency` | Excludes optional dependencies in full mode |
| `-SkipToolBootstrap` | Prevents automatic portable-tool downloads |
| `-StrictDependencies` | Fails on supported unresolved dependency cases |

`-NoNetworking` is suitable only after all required source trees, toolchains,
and dependencies have been placed in the persistent directories.

### Optional local workspace

By default, `scratch`, `tools`, `logs`, and `out` are used directly through host
mapped folders. This is fastest on reliable local storage and remains the normal
behavior.

Use `-LocalWorkspace` when the project is on slow or unreliable external/network
storage:

```powershell
.\build-sandbox.ps1 -BuildProfile zig -Full -Clean -LocalWorkspace
```

The guest copies any existing persistent content to `C:\hb_compile`, downloads
missing sources or tools normally, builds on its local virtual disk, and then
copies all four directories back to the host. No previous host build or cache is
required. Initial and final copies are validated; a synchronization error makes
the Sandbox build fail even when compilation itself succeeded. Keep the Sandbox
open and inspect `sandbox.log` if the destination storage disconnects during the
final copy.

## Results and diagnostics

With `-KeepSession`, inspect:

```text
%TEMP%\hb_compile-sandbox\<timestamp>\
  hb-compile.wsb
  request.json
  result.json
  sandbox.log
  source\
```

The Harbour log is stored separately under `logs\<timestamp>-<profile>.log`.
Check both logs because the Sandbox transcript covers provisioning and launcher
behavior, while the Harbour log contains compiler and contrib details.

After a native build, validate the installed compiler:

```powershell
.\scripts\Test-HarbourInstall.ps1 -Profile zig
```

This test proves that the installation can compile the sample, but it does not
prove that every optional artifact was produced by the current session.

## Known limitations

- Host output directories are persistent and can contain stale artifacts.
- A host timeout does not cancel the guest build.
- Optional contrib failures may not fail the overall Harbour installation.
- Full dependency resolution can install compiler-specific DLLs that require
  compatibility review for the selected Zig target.
- Windows Sandbox is interactive; this launcher is not a headless CI runner.
- Guest state outside mapped directories is discarded when the VM closes.
- Cygwin, MSYS, MSVC, WSL, Docker, and automatic compiler detection are not yet
  supported by this launcher.

## Recommended validation sequence

1. Run `-DryRun -KeepSession` to validate startup and parameter forwarding.
2. Preserve and empty `out\<profile>`.
3. Run a normal `-Clean` build.
4. Inspect `sandbox.log` and the Harbour log.
5. Confirm fresh core executables and run `Test-HarbourInstall.ps1`.
6. Run `-Full -Clean -IgnoreDependency qt` with a larger timeout.
7. Compare optional artifacts with resolver and contrib messages in the log.
8. Add Qt or stricter dependency requirements only after the base full build is
   understood.
