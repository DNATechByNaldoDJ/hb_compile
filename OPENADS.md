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

## Local compatibility adjustments

OpenADS is not identical to every historical ADS SDK release expected by
Harbour. The resolver prepares a local working copy and applies the compatibility
adjustments required by the contrib headers and linker. The upstream origin
must remain identifiable so updates can be audited and regenerated.

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
