# Continuous validation

**English** | [Português (Brasil)](CI.pt-BR.md)

`hb_compile` uses two GitHub Actions workflows.

## Required CI

`hb_compile CI` runs for pushes to `main`, pull requests, and manual
dispatches. It:

- parses every versioned PowerShell script;
- validates the JSON configuration;
- resolves the Docker profile in dry-run mode;
- performs a minimal Harbour build in Linux Docker; and
- compiles and runs `samples/hello.prg` against the resulting installation.

Build logs are retained as workflow artifacts even when the build fails.
GitHub-hosted runners start from a disposable workspace, so CI builds do not
request `-Clean`; this also prevents binaries left by a different Docker image
from being executed during the clean phase.

## Full validation

`hb_compile full validation` runs a baseline full Linux Docker build every
Sunday. It can also be dispatched manually with one of these integration
modes:

- `none`;
- `hbdap`;
- `openads`; or
- `hbdap-openads`.

Qt is excluded from this validation because it is not required by HBDAP or
OpenADS and substantially increases the runner cost. The workflow verifies
`hello.prg` and the installed artifacts explicitly requested by the selected
mode.

HBDAP is private. Configure the repository Actions secret
`HBDAP_CROSS_REPO_TOKEN` with read access to the HBDAP repository before
selecting an HBDAP mode. A requested HBDAP validation fails early when that
secret is unavailable. Baseline and OpenADS validations do not require it.

WSL remains a local/manual validation target. GitHub-hosted runners do not
provide the same WSL environment used by the project; the Linux Docker build
is the reproducible CI counterpart.
