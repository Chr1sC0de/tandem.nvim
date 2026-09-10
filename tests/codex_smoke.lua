-- Opt-in, credentialed integration test. Run from the plugin checkout:
-- TANDEM_CODEX_SMOKE=1 TANDEM_CLI=/path/to/tandem nvim --headless -u NONE -i NONE -l tests/codex_smoke.lua
if vim.env.TANDEM_CODEX_SMOKE ~= "1" then
	print("NOT RUN: set TANDEM_CODEX_SMOKE=1 to run the credentialed Codex smoke test")
	vim.cmd("cquit 77")
end
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local codex = vim.fn.exepath(vim.env.TANDEM_CODEX or "codex")
local binary = vim.fn.exepath(vim.env.TANDEM_CLI or "tandem")
assert(codex ~= "" and binary ~= "", "Codex and Tandem must be installed")
local login = vim.system({ codex, "login", "status" }, { text = true }):wait(10000)
if login.code ~= 0 then
	print("NOT RUN: Codex credentials unavailable; run codex login first")
	vim.cmd("cquit 77")
end
local base, temporary_error = (vim.uv or vim.loop).fs_mkdtemp(
	(vim.env.TANDEM_TEST_TMPDIR or "/tmp") .. "/td-codex-XXXXXX"
)
assert(base, "a writable temporary directory is required: " .. tostring(temporary_error))
local root = base .. "/repo"
vim.fn.mkdir(root, "p")
local source = { "def remove_me():", "    return 1", "", "", "def sentinel():", '    return "keep"' }
local expected = { "def sentinel():", '    return "keep"' }
local file = root .. "/example.py"
vim.fn.writefile(source, file)
vim.opt.swapfile = false
vim.cmd.edit(file)
local buffer = vim.api.nvim_get_current_buf()
local tandem = require("tandem")
local daemon_pid, active_process
local report = {
	plugin_worktree_dirty = vim.system({ "git", "diff", "--quiet" }):wait(5000).code ~= 0,
	codex_version = vim.trim(vim.system({ codex, "--version" }, { text = true }):wait(10000).stdout),
	tandem_version = vim.trim(vim.system({ binary, "--version" }, { text = true }):wait(10000).stdout),
	plugin_revision = vim.trim(vim.system({ "git", "rev-parse", "HEAD" }, { text = true }):wait(5000).stdout),
	cases = {},
}
local function run(read_only)
	vim.api.nvim_buf_set_lines(buffer, 0, -1, false, source)
	vim.cmd.write()
	assert(vim.wait(5000, function()
		return #tandem.status().dirty == 0
	end, 10))
	local protected = assert(tandem.codex_args({ cwd = root, read_only = read_only, codex_command = codex }))
	local command = { codex, "exec", "--json", "--ephemeral", "--skip-git-repo-check", "-C", root }
	vim.list_extend(command, protected)
	command[#command + 1] = "Remove the remove_me function from example.py. Preserve the sentinel function exactly."
	local result
	active_process = vim.system(
		command,
		{ text = true },
		vim.schedule_wrap(function(value)
			result = value
		end)
	)
	assert(
		vim.wait(120000, function()
			return result ~= nil
		end, 10),
		"Codex smoke timed out after 120 seconds"
	)
	active_process = nil
	assert(result.code == 0, "Codex smoke failed (exit " .. tostring(result.code) .. ")")
	local case = { mode = read_only and "analysis" or "edit", tools = {}, native_changes = 0, commands = 0 }
	report.cases[#report.cases + 1] = case
	local read, wrote = false, false
	for line in result.stdout:gmatch("[^\n]+") do
		local event = vim.json.decode(line)
		local item = event.item
		if event.type == "item.completed" and item then
			if item.type == "mcp_tool_call" then
				case.tools[#case.tools + 1] = { server = item.server, tool = item.tool, status = item.status }
				if item.server == "tandem" then
					if item.tool == "tandem_read_file" then
						read = true
					end
					if item.tool == "tandem_write_file" then
						assert(read, "writer called without a preceding Tandem read")
						wrote = true
					end
				end
			elseif item.type == "file_change" then
				case.native_changes = case.native_changes + 1
			elseif item.type == "command_execution" then
				case.commands = case.commands + 1
			end
		end
	end
	local disk = vim.fn.readfile(file)
	local live = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
	case.saved_content, case.buffer_content = disk, live
	assert(vim.deep_equal(disk, live), "saved file and attached buffer differ")
	assert(case.native_changes == 0, "native patch tool was used")
	-- This tiny fixture needs no shell commands; make write-route evidence unambiguous.
	assert(case.commands == 0, "smoke fixture must use Tandem tools without native shell commands")
	if read_only then
		assert(not wrote and vim.deep_equal(disk, source), "analysis session modified the fixture")
	else
		assert(read and wrote, "missing Tandem read/write tool events; tool selection was not verified")
		-- Allow only harmless leading/trailing blank lines after deleting the function.
		assert(vim.trim(table.concat(disk, "\n")) == table.concat(expected, "\n"), "unexpected function-removal result")
	end
	case.passed = true
end
local ok, failure = xpcall(function()
	tandem.setup({ command = binary, root = root, state_home = base .. "/state" })
	assert(
		vim.wait(10000, function()
			return tandem.status().connected
		end, 10),
		"Tandem editor did not connect"
	)
	local status = vim.system({ binary, "--root", root, "--state-home", base .. "/state", "status" }, { text = true })
		:wait(5000)
	daemon_pid = vim.json.decode(status.stdout).pid
	assert(type(daemon_pid) == "number" and daemon_pid > 1)
	run(false)
	run(true)
end, debug.traceback)
if active_process then
	active_process:kill(15)
	active_process:wait(5000)
end
-- Close this test's bridge before terminating its isolated daemon.
vim.api.nvim_exec_autocmds("VimLeavePre", {})
if not daemon_pid then
	local status = vim.system({ binary, "--root", root, "--state-home", base .. "/state", "status" }, { text = true })
		:wait(5000)
	local decoded, value = pcall(vim.json.decode, status.stdout or "")
	if decoded and value.ok and type(value.pid) == "number" and value.pid > 1 then
		daemon_pid = value.pid
	end
end
if daemon_pid then
	(vim.uv or vim.loop).kill(daemon_pid, 15)
end
report.passed = ok
if not ok then
	report.failure = failure
end
local evidence = base .. "/report.json"
vim.fn.writefile({ vim.json.encode(report) }, evidence)
print("Codex smoke evidence: " .. evidence)
if not ok then
	error(failure)
end
print("passed: real Codex edit and analysis routing, saved file and attached Neovim buffer")
