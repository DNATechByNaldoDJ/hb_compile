# Optional HBDAP integration

**English** | [Português (Brasil)](HBDAP.pt-BR.md)

`hb_compile` can opt in to building
[HBDAP](https://github.com/DNATechByNaldoDJ/hbdap) as a native Harbour contrib.
Existing builds are unchanged unless `-WithHbdap` is supplied.

When the operation includes the `install` target, `hb_compile` also builds
`hbdap_adapter` and `hbdap_cli` with that profile's hbmk2, installs them into
`out/<profile>/bin`, writes `out/<profile>/HBDAP_MANIFEST.json` with revisions
and hashes, and runs a minimal public-API consumer. Repeat the check with:

```powershell
pwsh ./scripts/Test-OptionalContribs.ps1 -Profile zig -WithHbdap
```

Run the complete HBDAP-owned core, transport, adapter, CLI, and corpus suite
through an installed profile with:

```powershell
pwsh ./scripts/Test-HarbourBuilds.ps1 -Profile zig `
  -HbdapValidation Full -HbdapRoot ../hbdap
```

`-HbdapValidation Smoke` keeps artifact, manifest, and public-consumer
validation only; `None` is the matrix default. WSL also accepts `-WslDistro`
and `-WslUser`. A Docker profile runs the full suite directly on a Linux host
with PowerShell 7; Windows hosts retain container smoke validation.

```powershell
.\build-zig.ps1 -WithHbdap
.\build-full-linux-wsl.ps1 -WithHbdap -IgnoreDependency qt
.\build-full-linux-docker.ps1 -WithHbdap -IgnoreDependency qt
```

The runner prefers a sibling `..\hbdap` checkout and otherwise clones the
default repository into `scratch\hbdap`. Use `-HbdapRoot`,
`-HbdapRepository`, and `-HbdapRef` to pin another source or revision.

Before Harbour make runs, `scripts\Install-HbdapContrib.ps1` copies the
distribution sources into `contrib\hbdap`, adds `hbdap/hbdap.hbp` to
`contrib\hbplist.txt`, and records the source revision in
`HBDAP_BUILD_INFO.json`. Harbour's own contrib build then compiles the library
consistently across Windows, WSL, and Docker runners.

The current integration covers the library, adapter, CLI, combined manifest,
public smoke, and optional full HBDAP suite. Versioned packaging remains
tracked in [TODO.md](TODO.md).

Full builds are I/O intensive. Do not use an external, encrypted, virtual, or
network-backed workspace that disconnects under load. Windows disk event 51,
BitLocker read failures, and disappearing drive letters indicate a storage
problem rather than a WSL or Docker build failure.
