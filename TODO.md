# TODO

**English** | [Português (Brasil)](TODO.pt-BR.md)

## HBDAP

- [x] Make HBDAP opt-in through `-WithHbdap`.
- [x] Support local checkout, repository, and revision selection.
- [x] Build the library through Harbour's native `contrib/hbdap` flow.
- [x] Record source and revision in `HBDAP_BUILD_INFO.json`.
- [ ] Install `hbdap_adapter` and `hbdap_cli` into each profile's `bin`.
- [ ] Run HBDAP tests after Windows, WSL, and Docker builds.
- [ ] Generate a combined Harbour/HBDAP revision manifest.
- [ ] Package Harbour plus HBDAP for `v0.1.0-alpha`.

## Linux and storage

- [x] Add opt-in OpenADS support for WSL and Docker.
- [x] Validate `librddads.a` and `libace.so` in full WSL and Docker builds.
- [ ] Run a Harbour/OpenADS smoke test in both Linux runners.
- [x] Complete full WSL and Docker builds with Qt excluded.
- [x] Validate HBDAP in `linux-wsl` and `linux-docker` outputs.
- [ ] Allow logs to reside on a volume separate from the workspace.
- [ ] Detect and fail early when the workspace volume disappears.
- [ ] Document a local-workspace strategy for unreliable storage.
