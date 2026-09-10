# tandem.nvim

Automatically hold participating AI edits while you have unsaved changes, then
resume after a successful save. Thin Neovim client for the Rust **Tandem** daemon.

The companion Rust daemon and CLI live in [tandem](https://github.com/Chr1sC0de/tandem).

## Status

Initial implementation. All 13 Lua gateway tests pass inside Neovim 0.12.5.
The companion Rust build and five unit tests pass locally; the complete daemon
and real Neovim integration pass in GitHub Actions. The authoring workspace
blocks Unix sockets, preventing the local daemon/editor integration run.
See [VERIFICATION.md](VERIFICATION.md) for the recorded results.

Requires Neovim 0.10+, Linux/macOS, and the `tandem` executable on PATH.
The Codex launch helper and lease recovery require Tandem CLI 0.2 or newer.
Currently supports one Neovim process per project, multiple participating agents,
and ordinary UTF-8 text files up to 1 MiB with Unix newlines. Start a new Neovim
process for another project; changing cwd does not switch the daemon root.

## Install

Build/install the CLI from the companion repository with `cargo install --locked --path .`.
Use this lazy.nvim specification:

```lua
return {
  "Chr1sC0de/tandem.nvim",
  lazy = false,
  opts = {},
}
```

For local development, replace the repository string with a `dir` specification:

```lua
return {
  dir = "/absolute/path/tandem.nvim",
  lazy = false,
  opts = {},
}
```

In your dotfiles this can be a new `config/nvim/lua/plugins/tandem.lua` file.
Your existing Codex commands, chat panel, and Herdr launcher can remain in place.
They still need agent-side gateway configuration to participate.

The plugin automatically starts/reconnects the daemon. It claims a file on the
first text change and releases it after successful save, undo back to saved
content, or actual discard. There are no per-edit
commands to invoke and no proposal-acceptance flow.

## Configure

```lua
require("tandem").setup({
  command = "tandem",
  -- root = "/absolute/project", -- default: git root or cwd at setup
  -- state_home = "/short/private/state", -- override for CLI and plugin together
  reconnect_ms = 1000,
})
```

An optional lualine component:

```lua
function() return require("tandem").statusline() end
```

`User TandemStatus` is emitted when connection/lease state changes.
`:TandemStatus` displays editor state and asynchronously fetches retained leases;
`:TandemRecover` reviews disconnected owners; `:TandemReconnect` reconnects the bridge;
`:checkhealth tandem` checks the connection. `tandem status` in a terminal also
shows daemon state, retained claims and Herdr pane identity.

## Connect agents

After the plugin connects, `require("tandem").codex_args({ cwd = project })`
returns Codex arguments for a required project MCP server and a read-only native
sandbox with escalation disabled. Append these arguments to a new Codex launch.
The enabled Tandem tools receive explicit per-tool permission to reach the
daemon under that sandbox. Other tools receive no additional permission.
The routing override uses Codex's documented `developer_instructions` setting
and its app-server `config/read` API. CLI 0.154.0 is the current local target;
the credentialed smoke test below verifies behavior for your installed version.
It returns `nil, error` when the editor is disconnected, the CLI is missing,
or the requested working directory belongs to another project. Treat that as a
launch failure; do not fall back to unrestricted editing.

The helper adds developer-level guidance selecting Tandem for project edits,
including discovery of deferred tools and recovery from busy, stale, or uncertain
writes. It explicitly replaces generic native-`apply_patch` guidance for this
project. A read-only native sandbox does **not** mean Tandem editing is unavailable.

By default, the helper starts a short-lived `codex app-server` in the launch cwd
to read the effective `developer_instructions`, then appends Tandem's guidance.
It starts no model turn and changes no Codex configuration files. This lookup
has a five-second timeout and returns `nil, error` if configuration cannot be
read, rather than silently losing existing instructions.

Optional launch fields:

- `codex_command`: the Codex executable to query (default: `"codex"`). Launch
  that same executable with the returned arguments.
- `developer_instructions`: the host's already-resolved instruction string.
  When supplied, the helper appends routing guidance without querying Codex.
  Use this when the host supplies a CLI profile or instruction override; include
  its complete effective value. An empty string explicitly means none.

Append the returned arguments **after** other launch configuration overrides,
and use the same cwd and environment for the lookup and actual launch. The
automatic lookup resolves on-disk configuration, not additional CLI profiles or
overrides supplied by the host. Higher-priority host rules that prohibit Tandem
must be corrected in that host; MCP descriptions cannot override them.

Set `read_only = true` for analysis jobs. Their MCP server both hides and rejects
the writer. Normal edit jobs use Tandem's writer while native patch and shell
writes remain blocked. This can also block build commands that write artifacts
into the project; it does not restrict other MCP servers or external programs.
The helper sets arguments only for that invocation and preserves the user's
model and instruction settings. Existing agents must be restarted to use it.

Register the CLI's MCP command, `tandem --root /absolute/project mcp`, with each
agent. Route reads and writes through `tandem_read_file` and `tandem_write_file`.
The write tool waits while your buffer is dirty; after save, an old revision
requires the agent to reread and regenerate its edit.

**This does not automatically intercept native agent tools or shell writes.**
The agent needs an adapter/configuration that uses Tandem's gateway. Native
editing and shell write access must be restricted for enforceable protection.
Stock Codex jobs in the current dotfiles still bypass the gate until adapted.

Herdr can continue running Neovim and agent terminals. The plugin reports its
Herdr environment identity; it does not freeze pane processes or stop a write
midway through. Only participating file operations wait.

## Behavior and recovery

- Dirty files pause participating reads/writes; other files stay available.
- Every agent write is checked in the Neovim event loop. This also protects typing
  that happens before the daemon receives the dirty notification.
- Agent changes are applied to the buffer and saved with normal synchronous
  save hooks. Whole-buffer replacement is used initially, so precise cursor and
  extmark preservation needs further work. Normal undo remains available.
- Failed saves retain modified buffers and leases. Asynchronous formatter edits
  can create new unsaved work, which remains protected until another save.
- A buffer differing from disk is never silently overwritten, even if its
  modified flag is false. Reload or reconcile it before retrying.
- Save, reload, and undo to saved content release a lease only when the buffer
  is unmodified and its contents match disk. Setting `nomodified` alone cannot
  bypass protection.
- Actual discards such as `:bd!` release their claims once the text is unloaded.
  Closing a window or tab, hiding a dirty buffer, or renaming it preserves claims
  while the unsaved text remains loaded. Reopening a renamed buffer's old path
  does not release the renamed buffer's unsaved work.
- Normal exit flushes pending saves/discards and closes the editor bridge, with
  up to one second for delivery and verification. This includes work deliberately
  abandoned by `:q!` or `:qa!` when those commands actually exit the process.
  Abnormal exits and failed delivery leave unresolved claims for recovery.
- Disconnects preserve claims. Reconnection replays known saves/discards and
  keeps the same owner for all Codex commands sharing this Neovim process.
  A new Neovim process cannot release an earlier owner's claims by saving.
- No automatic timeout releases an unsaved-file lease.

The protocol is cooperative and limited to the configured project. It does not
protect against unrelated programs writing files behind Neovim's back. Symlinks,
BOMs, CRLF, binary files, rename/delete and multi-file operations are unsupported.

## Review retained leases

After connection, Tandem notifies once per disconnected owner that retained work
needs review. `:TandemStatus` shows those owners and their files alongside the
current editor's claims. The synchronous `require("tandem").status()` API keeps
its existing fields and does not run a CLI request.

Use `:TandemRecover` after recovering or deliberately discarding the old work:

1. Select a disconnected owner and review its affected files.
1. Confirm that the work has been recovered or deliberately discarded. Cancel is
   the default; cancelling either dialog changes nothing.
1. Tandem refreshes ownership and file lists before releasing. If they changed,
   it returns to selection for a fresh review. The CLI also refuses to release
   an owner that is currently connected.
1. Review the completion report for any remaining blockers.

Recovery clears leases; it does not restore buffer contents. CLI requests use
the configured executable, root and state directory, with a five-second timeout
per request. Failures are reported without automatically retrying a release.
The existing `tandem release --owner OWNER` command remains available for manual
recovery. Never delete `leases.json`.

The change uses CLI 0.2.0 and protocol 1 without changing persisted state.
Restart Neovim after updating the plugin to load the new lifecycle handlers.

## Tests

```sh
nvim --headless -u NONE -l tests/gate_spec.lua
nvim --headless -u NONE -i NONE -l tests/lifecycle_spec.lua
nvim --headless -u NONE -i NONE -l tests/recovery_spec.lua
nvim --headless -u NONE -l tests/codex_spec.lua
nvim --headless -u NONE -l tests/codex_config_spec.lua
# Or use standalone Lua:
lua tests/gate_spec.lua
# Or, if only TeX Lua is available:
texlua tests/gate_spec.lua

# After building the companion Rust CLI, with Neovim on PATH:
python3 tests/e2e.py ../tandem/target/debug/tandem
```

The standalone tests cover dirty-buffer races, stale revisions, save failures,
load autocmd mutations, deadlines, unsupported text and save verification. The
end-to-end test starts Neovim, verifies automatic daemon startup, and exercises
a human save while an agent edit waits. It also checks that another file remains
editable, stale proposals are rejected, fresh edits update the live buffer, undo
reclaims the file, and new UTF-8, empty, and no-EOL files save correctly.
Set `TANDEM_TEST_TMPDIR` to an existing, short writable directory when `/tmp`
is unavailable. The full test requires permission to create Unix sockets.

The lifecycle suite uses real Neovim buffers/autocmds with controlled disk and
process boundaries. Subprocess cases exercise actual forced quits, immediate
save/quit, hidden-buffer exit and fatal signals. Recovery tests cover cancellation,
selected-owner release, ownership changes, stale dialogs and CLI failures.
The end-to-end harness also covers crashes followed by new editor sessions,
guided recovery, concurrent clients, and stable ownership across reconnects.
CI builds a pinned, unchanged CLI 0.2.0 and runs these real-daemon scenarios.

The Codex launch tests cover editing/analysis guidance, preservation of existing
instructions, TOML escaping, and configuration lookup failures. Configuration
transport tests exercise initialization, fragmented JSON, errors, and timeouts
without model credentials. These checks run in CI.

To verify actual model tool selection, explicitly run the credentialed smoke
test from this checkout after `codex login`:

```sh
TANDEM_CODEX_SMOKE=1 TANDEM_CLI=/absolute/path/to/tandem \
  nvim --headless -u NONE -i NONE -l tests/codex_smoke.lua
```

It uses a temporary project and this headless Neovim as the attached editor,
sends a plain function-removal request in edit and analysis modes, and checks
Tandem tool-call events, saved content, and the live buffer. This small fixture
requires no native patch or shell calls. Each Codex turn has a 120-second limit.
The test uses the configured model and optionally `TANDEM_CODEX` for a different
Codex executable. Missing opt-in or credentials exits with status 77 (not run).
It prints the location of a local JSON evidence report and stops its isolated
daemon. It does not modify your project's source files.

A passing configuration suite alone does not establish successful model routing.
If a Codex version does not expose MCP calls in its JSON events, the smoke test
fails rather than claiming tool-selection coverage. See Codex's
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
and [app-server protocol](https://learn.chatgpt.com/docs/app-server) for the
interfaces used by the instruction lookup.
