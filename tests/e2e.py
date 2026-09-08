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
        config.write_text("\n".join([
            "vim.opt.runtimepath:append(" + json.dumps(plugin) + ")",
            "vim.opt.swapfile = false",
            "vim.cmd.edit(" + json.dumps(str(file)) + ")",
            "require('tandem').setup({ command = " + json.dumps(binary)
            + ", root = " + json.dumps(str(root)) + ", state_home = "
            + json.dumps(str(base / "s")) + " })",
        ]))

        def run_cli(*args, check=True):
            result = subprocess.run(argv + list(args), capture_output=True, text=True, timeout=8)
            if check and result.returncode:
                raise AssertionError(result.stderr or result.stdout)
            return json.loads(result.stdout)

        def expr(lua):
            return subprocess.check_output(
                [nvim, "--server", socket_path, "--remote-expr", "luaeval(" + json.dumps(lua) + ")"],
                text=True, stderr=subprocess.DEVNULL, timeout=5,
            ).strip()

        def until(predicate):
            for _ in range(200):
                try:
                    if predicate():
                        return
                except (OSError, subprocess.SubprocessError, ValueError, AssertionError):
                    pass
                time.sleep(0.025)
            raise AssertionError("timed out waiting for condition")

        daemon_pid = None
        log = (base / "process.log").open("wb")
        try:
            # Exercise the normal setup path: Neovim must start the daemon.
            editor = subprocess.Popen([nvim, "--headless", "--listen", socket_path, "-u", str(config)],
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            processes.append(editor)
            until(lambda: run_cli("status")["ok"])
            daemon_pid = run_cli("status")["pid"]
            assert isinstance(daemon_pid, int) and daemon_pid > 1
            until(lambda: json.loads(expr("vim.json.encode(require('tandem').status())"))["connected"])

            old = run_cli("read", "a.txt")["revision"]
            expr("vim.api.nvim_buf_set_lines(0, 0, -1, false, {'human'})")
            proposal = base / "proposal.txt"
            proposal.write_text("agent\n")
            pending = subprocess.Popen(argv + ["write", "a.txt", "--expect", old, "--content-file", str(proposal),
                                               "--timeout-ms", "5000"], stdout=subprocess.PIPE, stderr=log)
            processes.append(pending)
            until(lambda: run_cli("status")["waiting"] == 1)
            assert pending.poll() is None
            assert file.read_text() == "base\n"
            # Only a.txt is leased: another agent can still edit another file.
            other = run_cli("write", "other.txt", "--expect", "missing", "--content-file", str(proposal))
            assert other["ok"] and (root / "other.txt").read_text() == "agent\n"
            assert pending.poll() is None
            assert json.loads(expr("vim.json.encode(vim.bo.modified)")) is True
            expr("vim.cmd('write')")
            output, _ = pending.communicate(timeout=8)
            assert json.loads(output)["error"]["code"] == "stale_revision", output
            assert file.read_text() == "human\n"

            fresh = run_cli("read", "a.txt")["revision"]
            result = run_cli("write", "a.txt", "--expect", fresh, "--content-file", str(proposal))
            assert result["ok"] and file.read_text() == "agent\n"
            assert json.loads(expr("vim.json.encode(vim.api.nvim_buf_get_lines(0, 0, -1, false))")) == ["agent"]
            expr("vim.cmd('undo')")
            until(lambda: bool(run_cli("status")["leases"]))
            assert file.read_text() == "agent\n", "undo must remain unsaved"
            expr("vim.cmd('write')")
            until(lambda: not run_cli("status")["leases"])

            for name, text in [("empty.txt", ""), ("unicode.txt", "λ = 1\n"), ("no-eol.txt", "hello")]:
                proposal.write_text(text)
                result = run_cli("write", name, "--expect", "missing", "--content-file", str(proposal))
                assert result["ok"], result
                assert (root / name).read_bytes() == text.encode()
                assert result["revision"] == hashlib.sha256(text.encode()).hexdigest()

            print("passed: automatic daemon startup, save waiting, independent-file edits, stale rejection, live buffer writes, undo leases, creation, UTF-8, empty/no-EOL files")
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
                print((base / "process.log").read_text(errors="replace"), file=sys.stderr)


if __name__ == "__main__":
    main()
