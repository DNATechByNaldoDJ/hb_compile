# Optional HBDAP integration

**English** | [Português (Brasil)](HBDAP.pt-BR.md)

`hb_compile` can opt in to building
[HBDAP](https://github.com/DNATechByNaldoDJ/hbdap) as a native Harbour contrib.
Existing builds are unchanged unless `-WithHbdap` is supplied.

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

The current integration covers the HBDAP library. Automatic installation of
`hbdap_adapter` and `hbdap_cli`, integrated tests, and versioned packaging are
tracked in [TODO.md](TODO.md).

Full builds are I/O intensive. Do not use an external, encrypted, virtual, or
network-backed workspace that disconnects under load. Windows disk event 51,
BitLocker read failures, and disappearing drive letters indicate a storage
problem rather than a WSL or Docker build failure.
