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
