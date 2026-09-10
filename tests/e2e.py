"""Real editor test: python3 tests/e2e.py /path/to/tandem.

Requires Neovim >= 0.10 and a built CLI. No third-party Python dependencies.
"""

import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    nvim = shutil.which("nvim")
    if not nvim:
        raise SystemExit("Neovim 0.10+ is required")
    plugin = str(pathlib.Path(__file__).resolve().parents[1])
    processes = []
    # Keep Unix socket paths short, while allowing restricted workspaces.
    with tempfile.TemporaryDirectory(
        prefix="td-e2e-", dir=os.environ.get("TANDEM_TEST_TMPDIR", "/tmp")
    ) as temporary:
        base = pathlib.Path(temporary)
        root = base / "repo"
        root.mkdir()
        file = root / "a.txt"
        file.write_text("base\n")
        socket_path = str(base / "editor.sock")
        argv = [binary, "--root", str(root), "--state-home", str(base / "s")]
        config = base / "init.lua"
        # json.dumps safely quotes these test-generated ASCII paths for Lua.
        config.write_text(
            "\n".join(
                [
                    "vim.opt.runtimepath:append(" + json.dumps(plugin) + ")",
                    "vim.opt.swapfile = false",
                    "_G.tandem_test_notices = {}",
                    "vim.notify = function(message) table.insert(_G.tandem_test_notices, message) end",
                    "vim.ui.select = function(items, options, callback) "
                    "_G.tandem_test_prompt = {items = items, callback = callback} end",
                    "vim.cmd.edit(" + json.dumps(str(file)) + ")",
                    "require('tandem').setup({ command = "
                    + json.dumps(binary)
                    + ", root = "
                    + json.dumps(str(root))
                    + ", state_home = "
                    + json.dumps(str(base / "s"))
                    + " })",
                ]
            )
        )

        def run_cli(*args, check=True):
            result = subprocess.run(
                argv + list(args), capture_output=True, text=True, timeout=8
            )
            if check and result.returncode:
                raise AssertionError(result.stderr or result.stdout)
            return json.loads(result.stdout)

        def expr(lua):
            return subprocess.check_output(
                [
                    nvim,
                    "--server",
                    socket_path,
                    "--remote-expr",
                    "luaeval(" + json.dumps(lua) + ")",
                ],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=5,
            ).strip()

        def until(predicate):
            for _ in range(200):
                try:
                    if predicate():
                        return
                except (
                    OSError,
                    subprocess.SubprocessError,
                    ValueError,
                    AssertionError,
                ):
                    pass
                time.sleep(0.025)
            raise AssertionError("timed out waiting for condition")

        daemon_pid = None
        log = (base / "process.log").open("wb")
        try:
            # Exercise the normal setup path: Neovim must start the daemon.
            editor = subprocess.Popen(
                [
                    nvim,
                    "--headless",
                    "-i",
                    "NONE",
                    "-n",
                    "--listen",
                    socket_path,
                    "-u",
                    str(config),
                ],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
            )
            processes.append(editor)
            until(lambda: run_cli("status")["ok"])
            daemon_pid = run_cli("status")["pid"]
            assert isinstance(daemon_pid, int) and daemon_pid > 1
            until(
                lambda: json.loads(expr("vim.json.encode(require('tandem').status())"))[
                    "connected"
                ]
            )

            old = run_cli("read", "a.txt")["revision"]
            expr("vim.api.nvim_buf_set_lines(0, 0, -1, false, {'human'})")
            proposal = base / "proposal.txt"
            proposal.write_text("agent\n")
            pending = subprocess.Popen(
                argv
                + [
                    "write",
                    "a.txt",
                    "--expect",
                    old,
                    "--content-file",
                    str(proposal),
                    "--timeout-ms",
                    "5000",
                ],
                stdout=subprocess.PIPE,
                stderr=log,
            )
            processes.append(pending)
            until(lambda: run_cli("status")["waiting"] == 1)
            assert pending.poll() is None
            assert file.read_text() == "base\n"
            # Only a.txt is leased: another agent can still edit another file.
            other = run_cli(
                "write",
                "other.txt",
                "--expect",
                "missing",
                "--content-file",
                str(proposal),
            )
            assert other["ok"] and (root / "other.txt").read_text() == "agent\n"
            assert pending.poll() is None
            assert json.loads(expr("vim.json.encode(vim.bo.modified)")) is True
            expr("vim.cmd('write')")
            output, _ = pending.communicate(timeout=8)
            assert json.loads(output)["error"]["code"] == "stale_revision", output
            assert file.read_text() == "human\n"

            fresh = run_cli("read", "a.txt")["revision"]
            result = run_cli(
                "write", "a.txt", "--expect", fresh, "--content-file", str(proposal)
            )
            assert result["ok"] and file.read_text() == "agent\n"
            assert json.loads(
                expr("vim.json.encode(vim.api.nvim_buf_get_lines(0, 0, -1, false))")
            ) == ["agent"]
            expr("vim.cmd('undo')")
            until(lambda: bool(run_cli("status")["leases"]))
            assert file.read_text() == "agent\n", "undo must remain unsaved"
            expr("vim.cmd('write')")
            until(lambda: not run_cli("status")["leases"])

            for name, text in [
                ("empty.txt", ""),
                ("unicode.txt", "λ = 1\n"),
                ("no-eol.txt", "hello"),
            ]:
                proposal.write_text(text)
                result = run_cli(
                    "write",
                    name,
                    "--expect",
                    "missing",
                    "--content-file",
                    str(proposal),
                )
                assert result["ok"], result
                assert (root / name).read_bytes() == text.encode()
                assert result["revision"] == hashlib.sha256(text.encode()).hexdigest()

            # Lifecycle scenarios use the real editor, daemon and UI commands.
            def lua(code):
                return expr("(function() " + code + " end)()")

            def local_status():
                return json.loads(expr("vim.json.encode(require('tandem').status())"))

            def assert_blocked(path):
                result = run_cli("read", path, "--timeout-ms", "100", check=False)
                assert result["error"]["code"] == "busy", result

            def edit(text):
                expr(
                    "vim.api.nvim_buf_set_lines(0, 0, -1, false, {"
                    + json.dumps(text)
                    + "})"
                )
                path = (
                    pathlib.Path(expr("vim.api.nvim_buf_get_name(0)"))
                    .relative_to(root)
                    .as_posix()
                )
                owner = local_status()["owner"]
                until(lambda: owner in run_cli("status")["leases"].get(path, []))

            def reload_file():
                expr("vim.cmd('edit!')")
                until(lambda: not run_cli("status")["leases"])

            def start_editor():
                # A killed editor cannot remove its Unix socket pathname.
                pathlib.Path(socket_path).unlink(missing_ok=True)
                process = subprocess.Popen(
                    [
                        nvim,
                        "--headless",
                        "-i",
                        "NONE",
                        "-n",
                        "--listen",
                        socket_path,
                        "-u",
                        str(config),
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=log,
                    stderr=log,
                )
                processes.append(process)
                until(lambda: local_status()["connected"])
                return process

            def quit_editor(process, command):
                # Schedule exit after the remote request, without allowing the
                # save's scheduled release to run between :write and :quit.
                try:
                    expr(
                        "vim.schedule(function() vim.cmd("
                        + json.dumps(command)
                        + ") end)"
                    )
                except subprocess.CalledProcessError:
                    # Neovim may close the RPC connection before sending a reply.
                    pass
                assert process.wait(timeout=3) == 0
                until(lambda: run_cli("status")["editor"] is None)

            def crash_editor(process):
                owner = local_status()["owner"]
                process.kill()
                process.wait(timeout=3)
                until(lambda: run_cli("status")["editor"] is None)
                return owner

            def answer_recovery(owner=None, confirm=False, cancel=False):
                until(
                    lambda: json.loads(
                        expr("vim.json.encode(_G.tandem_test_prompt ~= nil)")
                    )
                )
                if cancel:
                    selection = "p.items[1]"
                elif confirm:
                    selection = "p.items[2]"
                else:
                    selection = (
                        "(function() for _, row in ipairs(p.items) do "
                        "if row.owner == "
                        + json.dumps(owner)
                        + " then return row end end "
                        "error('owner absent from recovery selection') end)()"
                    )
                lua(
                    "local p = _G.tandem_test_prompt; _G.tandem_test_prompt = nil; p.callback("
                    + selection
                    + ")"
                )

            # Undo to the saved bytes must unblock multiple independent clients.
            owner = local_status()["owner"]
            for _ in range(2):
                args = json.loads(
                    expr(
                        "vim.json.encode(assert(require('tandem').codex_args({cwd = "
                        + json.dumps(str(root))
                        + ", developer_instructions = ''})))"
                    )
                )
                assert "--sandbox" in args
                assert local_status()["owner"] == owner
            edit("temporary")
            clients = [
                subprocess.Popen(
                    argv + ["read", "a.txt", "--timeout-ms", "5000"],
                    stdout=subprocess.PIPE,
                    stderr=log,
                )
                for _ in range(2)
            ]
            processes.extend(clients)
            until(lambda: run_cli("status")["waiting"] == 2)
            assert all(client.poll() is None for client in clients)
            expr("vim.cmd('undo')")
            for client in clients:
                output, _ = client.communicate(timeout=8)
                assert json.loads(output)["ok"], output
            until(lambda: not run_cli("status")["leases"])

            edit("still unsaved")
            expr("vim.bo.modified = false")
            assert_blocked("a.txt")
            reload_file()

            edit("save failure")
            lua(
                "vim.api.nvim_create_autocmd('BufWriteCmd', {buffer = 0, once = true, "
                "callback = function() error('fixture save failure') end})"
            )
            assert not json.loads(expr("vim.json.encode((pcall(vim.cmd, 'write')))"))
            assert_blocked("a.txt")
            reload_file()

            edit("before formatter")
            lua(
                "vim.api.nvim_create_autocmd('BufWritePost', {buffer = 0, once = true, "
                "callback = function() vim.schedule(function() "
                "vim.api.nvim_buf_set_lines(0, 0, -1, false, {'formatter'}) end) end})"
            )
            expr("vim.cmd('write')")
            until(lambda: json.loads(expr("vim.json.encode(vim.bo.modified)")))
            assert_blocked("a.txt")
            reload_file()

            edit("hidden work")
            expr("vim.cmd('split | quit!')")
            assert_blocked("a.txt")
            expr("vim.cmd('tab split | tabclose!')")
            assert_blocked("a.txt")
            expr("vim.cmd('hide enew')")
            assert_blocked("a.txt")
            expr("vim.cmd.buffer(" + json.dumps(str(file)) + ")")
            expr(
                "vim.api.nvim_buf_set_name(0, "
                + json.dumps(str(root / "renamed.txt"))
                + ")"
            )
            assert_blocked("a.txt")
            expr("vim.cmd('bdelete!')")
            until(lambda: not run_cli("status")["leases"])
            expr("vim.cmd.edit(" + json.dumps(str(file)) + ")")

            edit("forced quit")
            quit_editor(editor, "quit!")
            assert not run_cli("status")["leases"]

            editor = start_editor()
            edit("hidden quit")
            expr("vim.cmd('hide enew')")
            quit_editor(editor, "qall!")
            assert not run_cli("status")["leases"]

            editor = start_editor()
            edit("saved at exit")
            quit_editor(editor, "write | quit")
            assert file.read_text() == "saved at exit\n"
            assert not run_cli("status")["leases"]

            # Two crashes leave two distinct owners; a third editor may recover
            # exactly one after review, without weakening its own live lease.
            editor = start_editor()
            edit("crashed a")
            old_a = crash_editor(editor)
            assert old_a in run_cli("status")["leases"]["a.txt"]
            editor = start_editor()
            assert local_status()["owner"] != old_a
            expr("vim.cmd('write')")
            assert old_a in run_cli("status")["leases"]["a.txt"], (
                "a new owner cannot save away old claims"
            )
            expr("vim.cmd.edit(" + json.dumps(str(root / "b.txt")) + ")")
            edit("crashed b")
            old_b = crash_editor(editor)
            editor = start_editor()
            current = local_status()["owner"]
            assert len({old_a, old_b, current}) == 3
            until(
                lambda: (
                    old_a in expr("table.concat(_G.tandem_test_notices, '\\n')")
                    and old_b in expr("table.concat(_G.tandem_test_notices, '\\n')")
                )
            )
            expr("vim.cmd('TandemReconnect')")
            until(lambda: run_cli("status")["editor"] is None)
            until(lambda: local_status()["connected"])
            assert local_status()["owner"] == current

            expr("vim.cmd('TandemRecover')")
            answer_recovery(cancel=True)
            assert old_a in run_cli("status")["leases"]["a.txt"]
            expr("vim.cmd('TandemRecover')")
            answer_recovery(owner=old_a)
            answer_recovery(cancel=True)
            assert old_a in run_cli("status")["leases"]["a.txt"]

            # Keep a genuine current-owner edit on the same file during recovery.
            edit("current editor work")
            expr("vim.cmd('TandemRecover')")
            answer_recovery(owner=old_a)
            answer_recovery(confirm=True)
            until(lambda: old_a not in run_cli("status")["leases"].get("a.txt", []))
            status = run_cli("status")
            assert current in status["leases"]["a.txt"]
            assert old_b in status["leases"]["b.txt"]
            assert_blocked("a.txt")
            until(
                lambda: (
                    "Remaining lease blockers"
                    in expr("table.concat(_G.tandem_test_notices, '\\n')")
                )
            )
            # Wait for the completion report before opening the next recovery.
            expr("vim.cmd('TandemRecover')")
            answer_recovery(owner=old_b)
            answer_recovery(confirm=True)
            until(lambda: "b.txt" not in run_cli("status")["leases"])
            expr("vim.cmd('write')")
            until(lambda: not run_cli("status")["leases"])
            assert run_cli("read", "a.txt")["content"] == "current editor work\n"
            quit_editor(editor, "quit")

            print(
                "passed: gateway operations, clean reconciliation, actual discards, hidden/renamed buffers, "
                "save/formatter failures, shutdown flush, crash recovery, selected-owner release, "
                "stable reconnect identity and concurrent protected clients"
            )

        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=5)
            # This daemon belongs to the fresh temporary project above.
            if daemon_pid is not None:
                try:
                    os.kill(daemon_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            log.close()
            if sys.exc_info()[0] is not None:
                print(
                    (base / "process.log").read_text(errors="replace"), file=sys.stderr
                )


if __name__ == "__main__":
    main()
