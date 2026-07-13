# Optional dependencies

**English** | [Português (Brasil)](DEPENDENCIES.pt-BR.md)

The `-Full` mode prepares optional libraries used by Harbour contrib modules.
Windows profiles use vcpkg; Cygwin, MSYS, WSL, and Docker use libraries
installed in their own environment. `config\dependencies.json` is the source
of truth for the Windows resolver.

## Flow

1. A full wrapper calls `scripts\Invoke-HarbourBuild.ps1 -Full`.
2. The runner calls `scripts\Resolve-HarbourDeps.ps1`.
3. The resolver selects a dependency set and explicit additions.
4. Existing valid `HB_WITH_*` paths are reused.
5. Missing automated dependencies are installed unless disabled.
6. Generated environment values are loaded before Harbour make runs.

```powershell
.\build-full-zig.ps1 -Clean
.\build-full-msvc64.ps1 -DependencySet database -Clean
.\build-full-mingw64.ps1 -IgnoreDependency qt -Clean
```

## Providers by environment

### Windows

Native Windows profiles use vcpkg triplets appropriate to the compiler and
architecture. Generated `HB_WITH_*` values are written to profile-specific
configuration files under `config\`.

Useful controls include:

```powershell
-DependencyProvider vcpkg
-DependencyTriplet x64-windows
-DependencyInstallTimeoutMinutes 120
-SkipDependencyInstall
-StrictDependencies
```

### Cygwin, MSYS, and WSL

Install headers and libraries with the environment's package manager. These
profiles deliberately do not reuse Windows vcpkg binaries. Their full wrappers
enable Harbour's system-library detection.

### Docker

The full Linux Dockerfile installs supported build headers in the image. When
Qt is ignored, the wrapper also disables its Docker installation step.

## Full wrappers

Full wrappers exist for standard, MSVC, MinGW, Zig, Cygwin, MSYS, WSL, and
Docker profiles. They accept normal source, clean, jobs, and make arguments plus
dependency-selection options.

## Dependency sets

```powershell
.\build-full-zig.ps1 -DependencySet network
.\build-full-zig.ps1 -DependencySet database
.\build-full-zig.ps1 -DependencySet gui
.\build-full-zig.ps1 -DependencySet graphics
.\build-full-zig.ps1 -DependencySet full
```

Add or remove individual entries:

```powershell
.\build-full-zig.ps1 -Dependency curl -Dependency openssl
.\build-full-zig.ps1 -IgnoreDependency qt
```

Available names and Harbour variables are defined in
`config\dependencies.json`. Common automated libraries cover compression,
regular expressions, TLS, HTTP, SQL clients, image formats, and supported GUI
components.

## Automated and manual dependencies

An automated dependency has enough catalog metadata for the resolver to locate
or install it. A manual dependency requires a local SDK or override. Put
machine-specific paths in `config\external-deps.local.ps1`:

```powershell
$env:HB_WITH_SOMELIB = 'C:\SDKs\somelib'
```

Do not commit local SDK paths. ADS uses OpenADS as a fallback; see
[OPENADS.md](OPENADS.md).

## Strict mode

Without `-StrictDependencies`, unavailable optional libraries produce warnings
and the build can continue without their contrib modules. Strict mode turns
these conditions into failures and is useful for reproducible full-build CI.

## Diagnostics

- Use `-DryRun` to inspect decisions without installing or building.
- Check `config\external-deps.generated*.ps1`.
- Ensure each `HB_WITH_*` path matches the compiler architecture.
- Never mix Cygwin/MSYS libraries with native Windows toolchains.
- Ignore Qt when a quick non-GUI full build is sufficient.
- Review timestamped build and vcpkg stdout/stderr logs under `logs\`.
