# OpenADS in Harbour builds

**English** | [Português (Brasil)](OPENADS.pt-BR.md)

This project uses OpenADS as a local fallback for enabling Harbour's `rddads`
contrib when the original Advantage Database Server SDK is unavailable.

## When it is used

The dependency resolver reads `config\dependencies.json`. For ADS, it first
checks an existing `HB_WITH_ADS` SDK path. During a full build with dependency
installation enabled, it can clone the configured OpenADS fallback when no SDK
is available.

The resolved include and library root is exported through `HB_WITH_ADS` before
Harbour make processes `rddads`.

WSL and Docker provide a strict opt-in path:

```powershell
.\build-full-linux-wsl.ps1 -WithOpenAds -IgnoreDependency qt
.\build-full-linux-docker.ps1 -WithOpenAds -IgnoreDependency qt
```

The runner builds the `openads_ace` CMake target, creates the Linux
`libace.so` compatibility name, exports `HB_WITH_ADS`, and adds the library
directory to `HB_USER_LIBPATHS`. Use `-OpenAdsRoot`, `-OpenAdsRepository`, and
`-OpenAdsRef` to pin the source. Without `-WithOpenAds`, Linux behavior remains
unchanged.

OpenADS itself is compiled with its concrete `UNSIGNED16 *` Unicode
signatures. A separate header copy under `out/openads-<profile>/compat` receives
the `void *` compatibility required by Harbour `rddads`, keeping the two build
contracts isolated.

## Local compatibility adjustments

OpenADS is not identical to every historical ADS SDK release expected by
Harbour. The resolver prepares a local working copy and applies the compatibility
adjustments required by the contrib headers and linker. The upstream origin
must remain identifiable so updates can be audited and regenerated.

The generated Harbour-only header adds the legacy `DOUBLE`, `WCHAR`, `VOID`,
and `ADSFIELD` definitions and applies the `void *` Unicode-buffer adaptation.
The preparation step also patches known current-GCC warnings in the local
OpenADS C++ sources: undersized `snprintf` buffers, implicit byte conversions,
and a shadowed declaration. These patches are idempotent and do not change the
produced ABI.

OpenADS is configured with `OPENADS_WARNINGS_AS_ERRORS=ON`, so a new upstream
warning fails visibly and requires an auditable compatibility update.

## Linux validation

Full `linux-wsl` and `linux-docker` builds, with Qt excluded, were validated
with OpenADS and HBDAP enabled together. Both installed `hbmk2`, `librddads.a`,
and `libhbdap.a`; OpenADS produced `libopenace64.so` and its `libace.so`
compatibility link. Functional ADS operation smoke tests remain tracked
separately in the TODO.

The `hello.prg` sample was also compiled and executed under MinGW64, MSVC64,
Cygwin, MSYS, WSL, Docker, and Zig. Select the full Docker image explicitly
when testing an installation produced by a full build:

```powershell
pwsh ./scripts/Test-HarbourBuilds.ps1 -Profile linux-docker `
  -DockerImage hb-compile/linux:full
```

The `hb-compile/linux:base` image is not expected to run binaries linked
against the full image's additional dependencies.

Do not silently substitute an unrelated ADS client. Header declarations,
calling conventions, architecture, and import-library format must match the
active Harbour compiler.

## Link libraries

- MSVC consumes Microsoft-format `.lib` files.
- MinGW and Zig GNU targets use GNU-compatible import archives when required.
- x86, x64, and ARM64 artifacts cannot be mixed.

The resolver selects or creates the appropriate local representation and points
Harbour at the prepared ADS root.

## Validation

```powershell
.\build-full-zig.ps1 -Dependency ads -Clean
.\build-full-zig.ps1 -Dependency ads -StrictDependencies -Clean
```

Check the generated dependency environment, timestamped build log, and installed
`rddads` artifacts. A `-DryRun` validates resolution only; it does not prove
that headers compiled or libraries linked successfully.

## Troubleshooting

- Old `HB_WITH_ADS`: remove or correct the local override.
- Header missing: verify the prepared include layout and generated environment.
- Unresolved symbols: check architecture, calling convention, and library format.
- Clone unavailable: enable networking or pre-populate the persistent cache.
- `rddads` skipped: inspect resolver output and do not ignore `ads`.

OpenADS is a compatibility fallback, not a replacement for validating behavior
against the official ADS runtime in production environments.
