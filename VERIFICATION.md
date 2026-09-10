# Verification — 2026-09-08

Local environment: Linux x86_64, Neovim 0.12.5, companion Rust CLI built with
Rust/Cargo 1.98.1.

- `nvim --headless -u NONE -l tests/gate_spec.lua`: all 13 tests passed.
- All three plugin Lua modules parse successfully.
- Companion `cargo test --locked`: five tests passed; `cargo build --locked` passed.
- The real Neovim/daemon integration and six daemon protocol tests passed in
  [the companion CI run](https://github.com/Chr1sC0de/tandem/actions/runs/34231032123).
- Standalone Lua tests also passed in
  [this repository's CI run](https://github.com/Chr1sC0de/tandem.nvim/actions/runs/34230865330).

The initial full integration used CLI `d9b03abb71c6f56fa269903695212d61b30a12b0`
and plugin `2742eb16f5ab09d977e60c5761536876cf52bed8`. It verified save waiting,
stale rejection, live buffer updates, undo leases, file creation, UTF-8, empty
files, and files without a final newline. The current harness also checks
automatic daemon startup and edits to another file while a buffer is unsaved.
Subsequent integration results appear in the
[companion CI workflow](https://github.com/Chr1sC0de/tandem/actions/workflows/ci.yml).

## Local integration limitation

The local real-editor harness was attempted, but the workspace rejects Unix
socket creation with `Operation not permitted`. The daemon cannot start its
listener there. The 13 local gate tests run inside real Neovim with controlled
gate dependencies; they do not substitute for transport integration. The full
transport was verified separately on GitHub's Linux runner with Neovim 0.12.5.

macOS, a full Herdr session, and interception of native agent tools have not been
verified. Participating agents must use Tandem's gateway; native edit and shell
write tools still require adapters.

## Codex edit routing — 2026-09-10

- Reproduced the missing launch-guidance failure with a regression test before
  adding the fix.
- Nine Codex launch tests pass, including instruction preservation, edit versus
  analysis behavior, escaping, configuration failures, and project-root selection.
- Seven configuration tests pass, including a real subprocess-pipe handshake,
  fragmented responses, missing configuration, transport errors, and timeouts.
- All 13 existing gateway tests pass. `git diff --check` passes.
- The opt-in smoke test correctly reports not run with exit status 77 by default.
  The opt-in run with the installed Tandem executable reached fixture setup, then
  failed with EROFS creating its temporary project. Its credentialed edit/analysis
  cases have not been verified in this environment.
- Installed Codex CLI: 0.154.0. A real `codex app-server` configuration probe
  cannot start here because SQLite initialization requires writes outside the
  native read-only sandbox. Therefore the passing transport fixture is not
  evidence that the installed Codex configuration API or model routing passed.
- Repository edits were successfully applied through the connected Tandem writer.
  Rust daemon, lease, and protocol code did not change.
