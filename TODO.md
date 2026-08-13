# TODO

**English** | [Português (Brasil)](TODO.pt-BR.md)

## Continuous integration

- [x] Restore the scheduled full Docker validation after fixing named
  PowerShell parameter forwarding for `-IgnoreDependency qt`. Manual run
  `31702395638` and the push CI run `31702377181` passed on 2026-08-13.
- [ ] Replace the top-level wrappers' raw `@args` forwarding with typed named
  parameter forwarding so hashtable splatting remains safe outside CI.
- [x] Validate PowerShell, JSON configuration, a minimal Docker build, and
  `hello.prg` on pushes and pull requests.
- [x] Provide scheduled/manual full Docker validation with optional HBDAP and
  OpenADS modes.
- [ ] Add WSL validation when a suitable self-hosted runner is available.

## HBDAP

- [x] Make HBDAP opt-in through `-WithHbdap`.
- [x] Support local checkout, repository, and revision selection.
- [x] Build the library through Harbour's native `contrib/hbdap` flow.
- [x] Record source and revision in `HBDAP_BUILD_INFO.json`.
- [x] Install `hbdap_adapter` and `hbdap_cli` into supported Windows, WSL, and
  Docker profile `bin` directories.
- [x] Run the complete HBDAP suite after Windows, WSL, and Docker builds. The
  Docker full image includes pinned PowerShell 7 and runs the canonical suite
  inside the container; the minimal public consumer remains automatic.
- [x] Generate a combined Harbour/HBDAP revision manifest with profile, runner,
  and adapter/CLI hashes.
- [ ] Package Harbour plus HBDAP for `v0.1.0-alpha`.

## Integrated optional-contrib tests

- [x] Add `scripts/Test-OptionalContribs.ps1` to test OpenADS and HBDAP only
  when requested.
- [x] Validate the request and installed artifacts before functional testing:
  `librddads`, `libace`, `libhbdap`, and build metadata.
- [ ] Compile and run a minimal Harbour program that creates, opens, and queries
  a table through `rddads` under WSL and Docker.
- [x] Compile and run a minimal Harbour consumer of the public HBDAP API under
  supported profiles. Windows, Docker, and WSL passed with the current Harbour
  revision; the WSL clean build used two jobs and excluded Qt.
- [x] Integrate HBDAP's own test suite when its checkout is available, reusing
  its canonical `test-hb_compile.ps1` entry point.
- [x] Cover `hbdap_adapter` and `hbdap_cli` after they are installed into each
  `out/<profile>/bin`.
- [x] Expose these checks through the `Test-HarbourBuilds.ps1` matrix with
  explicit `None`, `Smoke`, and `Full` levels, keeping compile/link, public
  smoke, and full-suite results distinct.

## Linux and storage

- [x] Add opt-in OpenADS support for WSL and Docker.
- [x] Validate `librddads.a` and `libace.so` in full WSL and Docker builds.
- [ ] Run a Harbour/OpenADS smoke test in both Linux runners.
- [x] Complete full WSL and Docker builds with Qt excluded.
- [x] Validate HBDAP in `linux-wsl` and `linux-docker` outputs. The WSL clean
  build, tool installation, joint manifest, and public smoke test passed on
  2026-08-13 with Harbour revision `6df4c08b98`.
- [ ] Allow logs to reside on a volume separate from the workspace.
- [ ] Detect and fail early when the workspace volume disappears.
- [ ] Document a local-workspace strategy for unreliable storage.

## Harbour 3.2.1dev compatibility

- [x] Make `-Jobs` control contrib parallelism as well, instead of allowing
  `contrib/make.hb` to raise the limit implicitly to eight.
- [x] Fix vcpkg OpenSSL and libmagic link names in Windows Zig builds.
- [x] Treat `hbmk2: Erro/Error` diagnostics as build failures even when the
  contrib make process returns exit code zero.
- [x] Supply process-local Git `safe.directory` configuration on every runner,
  without changing the user's global configuration, preserving `GIT_REVISION`.
- [x] Incrementally validate the full Zig build at Harbour `6df4c08b98` with
  two jobs, `hbssl`/`hbmagic`, and the `hello.prg` smoke test.

## Coordinated path with HBDAP and the VSCode extension

1. Make optional-contrib validation reusable, starting with artifact checks and
   a minimal HBDAP consumer under the supported `hb_compile` profiles.
2. Install and validate `hbdap_adapter` and `hbdap_cli`, then generate a joint
   Harbour/HBDAP revision manifest.
3. Feed reproducible build metadata and artifacts into the clean installation
   test shared by HBDAP and the VSCode extension.
4. Package only after the coordinated `v0.1.0-alpha.1` release candidate passes
   the core, CLI, adapter, and packaged-VSIX workflows.
