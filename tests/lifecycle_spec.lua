package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Real buffers/autocmds, with only disk and daemon process boundaries replaced.
local uv = vim.uv or vim.loop
local root = "/tandem-lifecycle-test"
local originals = {}
for _, key in ipairs({ "fs_open", "fs_fstat", "fs_read", "fs_close" }) do
	originals[key] = uv[key]
end
local jobstart, chansend, chanclose, jobwait = vim.fn.jobstart, vim.fn.chansend, vim.fn.chanclose, vim.fn.jobwait
local system = vim.system
local notify = vim.notify
local fixture
uv.fs_open = function(path, ...)
	if path:sub(1, #root + 1) == root .. "/" then
		return 900001
	end
	return originals.fs_open(path, ...)
end
uv.fs_fstat = function(fd, ...)
	if fd == 900001 then
		return { type = "file", size = #fixture.disk }
	end
	return originals.fs_fstat(fd, ...)
end
uv.fs_read = function(fd, ...)
	if fd == 900001 then
		return fixture.disk
	end
	return originals.fs_read(fd, ...)
end
uv.fs_close = function(fd, ...)
	if fd == 900001 then
		return true
	end
	return originals.fs_close(fd, ...)
end

local function drain()
	vim.wait(20, function()
		return false
	end, 1)
end

local function new_fixture()
	if fixture then
		vim.api.nvim_del_augroup_by_name("Tandem")
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_get_name(buf):sub(1, #root) == root then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
		drain()
	end
	fixture = { disk = "base\n", messages = {}, leases = {} }
	local f = fixture
	f.notifications = {}
	vim.notify = function(message)
		f.notifications[#f.notifications + 1] = message
	end
	vim.fn.jobstart = function(_, callbacks)
		f.callbacks = callbacks
		return 123456
	end
	vim.fn.chansend = function(_, text)
		local message = vim.json.decode(text)
		f.messages[#f.messages + 1] = message
		if message.method == "hello" then
			f.owner = message.owner
		end
		if message.method == "claim" then
			f.leases[message.path] = true
		end
		if message.method == "saved" or message.method == "discarded" then
			f.leases[message.path] = nil
		end
		return #text
	end
	vim.fn.chanclose = function()
		f.closed = true
		f.callbacks.on_exit(123456, 0)
		return 1
	end
	vim.fn.jobwait = function()
		return { 0 }
	end
	vim.system = function(_, _, callback)
		local leases = {}
		for path in pairs(f.leases) do
			leases[path:sub(#root + 2)] = { f.owner }
		end
		local result = {
			code = 0,
			stdout = vim.json.encode({
				ok = true,
				protocol = 1,
				root = root,
				leases = leases,
				editor = f.closed and vim.NIL or { owner = f.owner },
			}),
			stderr = "",
		}
		if callback then
			vim.schedule(function()
				callback(result)
			end)
		end
		return {
			wait = function()
				return result
			end,
			kill = function() end,
		}
	end
	f.buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(f.buf)
	vim.api.nvim_buf_set_name(f.buf, root .. "/file.txt")
	vim.bo[f.buf].swapfile = false
	vim.bo[f.buf].undolevels = -1
	vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "base" })
	vim.bo[f.buf].modified = false
	vim.bo[f.buf].undolevels = 1000
	package.loaded["tandem"] = nil
	f.plugin = require("tandem")
	f.plugin.setup({ root = root, command = "fake-tandem" })
	f.callbacks.on_stdout(123456, { '{"event":"ready","protocol":1}', "" })
	drain()
	function f.edit(text)
		vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { text })
		drain()
	end
	function f.leased()
		return f.leases[root .. "/file.txt"] == true
	end
	return f
end

-- Exercise the real exit event order in a separate Neovim, without filesystem
-- fixtures or sockets. The process/disk boundaries are the same as above.
if vim.env.TANDEM_LIFECYCLE_EXIT then
	local f = new_fixture()
	f.edit("human")
	local close = vim.fn.chanclose
	vim.fn.chanclose = function(...)
		print("TANDEM_EXIT " .. vim.json.encode({ leases = f.leases, dying = vim.v.dying }))
		return close(...)
	end
	local mode = vim.env.TANDEM_LIFECYCLE_EXIT
	if mode == "write-quit" then
		f.disk = "human\n"
		vim.bo[f.buf].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = f.buf })
		vim.cmd("quit")
	elseif mode == "hidden-quit" then
		vim.cmd("hide enew")
		vim.cmd("qall!")
	elseif mode == "signal" then
		uv.kill(vim.fn.getpid(), "sigterm")
		vim.wait(3000, function()
			return false
		end)
		error("SIGTERM did not exit Neovim")
	else
		vim.cmd("quit!")
	end
	error("expected Neovim to exit")
end

local count = 0
local function test(name, run)
	local f = new_fixture()
	run(f)
	count = count + 1
	print("ok " .. count .. " - " .. name)
end

local ok, failure = xpcall(function()
	test("undo back to saved content releases its lease", function(f)
		f.edit("human")
		assert(f.leased(), "editing must claim")
		vim.cmd("undo")
		drain()
		assert(not vim.bo[f.buf].modified, "fixture undo must restore the saved state")
		assert(not f.leased(), "undo to saved content stranded a lease")
	end)

	test("nomodified cannot release text that differs from disk", function(f)
		f.edit("human")
		vim.bo[f.buf].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = f.buf })
		drain()
		assert(f.leased())
	end)
	test("undoing an agent save into different content remains leased", function(f)
		f.edit("agent")
		f.disk = "agent\n"
		vim.bo[f.buf].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = f.buf })
		drain()
		assert(not f.leased())
		vim.cmd("undo")
		drain()
		assert(f.leased())
	end)
	test("failed save and post-save formatter edits remain protected", function(f)
		f.edit("human")
		vim.api.nvim_create_autocmd("BufWriteCmd", {
			buffer = f.buf,
			once = true,
			callback = function()
				error("save failed")
			end,
		})
		assert(not pcall(vim.cmd, "write"))
		drain()
		assert(f.leased() and vim.bo[f.buf].modified)
		f.disk = "human\n"
		vim.bo[f.buf].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = f.buf })
		vim.schedule(function()
			vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "formatter" })
		end)
		drain()
		assert(f.leased() and vim.bo[f.buf].modified)
	end)
	test("hiding or renaming a dirty buffer retains its original lease", function(f)
		f.edit("human")
		vim.cmd("hide enew")
		drain()
		assert(f.leased() and vim.api.nvim_buf_is_loaded(f.buf))
		vim.api.nvim_buf_set_name(f.buf, root .. "/renamed.txt")
		drain()
		assert(f.leased(), "rename is not a discard")
	end)
	test("forced buffer deletion releases discarded text", function(f)
		f.edit("human")
		vim.cmd("bdelete!")
		drain()
		assert(not vim.api.nvim_buf_is_loaded(f.buf))
		assert(not f.leased(), "discarded buffer stranded a lease")
	end)

	test("save immediately followed by normal exit flushes its pending release", function(f)
		f.edit("human")
		f.disk = "human\n"
		vim.bo[f.buf].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = f.buf })
		vim.api.nvim_exec_autocmds("VimLeavePre", {})
		assert(f.closed, "shutdown must close the editor bridge")
		assert(not f.leased(), "pending saved notification was lost on exit")
		assert(not f.plugin.status().connected)
	end)

	test("normal exit discards remaining tracked work", function(f)
		f.edit("human")
		vim.api.nvim_exec_autocmds("VimLeavePre", {})
		assert(not f.leased() and f.closed)
	end)
	test("abnormal exit preserves claims and never sends a discard", function(f)
		f.edit("human")
		local previous = vim.v
		vim.v = setmetatable({ dying = 1 }, { __index = previous })
		vim.api.nvim_exec_autocmds("VimLeavePre", {})
		vim.v = previous
		assert(f.leased() and f.closed)
		for _, message in ipairs(f.messages) do
			assert(message.method ~= "discarded")
		end
	end)
	test("queued applies cannot write during shutdown", function(f)
		f.callbacks.on_stdout(123456, {
			vim.json.encode({
				event = "apply",
				id = 9,
				path = root .. "/file.txt",
				relative_path = "file.txt",
				expected_revision = vim.fn.sha256(f.disk),
				content = "agent\n",
				expires_ms = 9999999999999,
			}),
			"",
		})
		vim.api.nvim_exec_autocmds("VimLeavePre", {})
		drain()
		assert(f.disk == "base\n")
		assert(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false)[1] == "base")
	end)
	test("failed shutdown delivery leaves daemon claims for recovery", function(f)
		f.edit("human")
		vim.fn.chansend = function()
			return 0
		end
		vim.system = function(_, _, callback)
			local result = { code = 1, stdout = "", stderr = "status unavailable" }
			if callback then
				vim.schedule(function()
					callback(result)
				end)
			end
			return {
				wait = function()
					return result
				end,
			}
		end
		local started = uv.hrtime()
		vim.api.nvim_exec_autocmds("VimLeavePre", {})
		assert((uv.hrtime() - started) / 1000000 < 1100)
		assert(f.leased())
		assert(f.plugin.status().error:find("status unavailable", 1, true))
	end)

	test("callbacks from an exited bridge cannot mark the editor ready", function(f)
		local old = f.callbacks
		old.on_exit(123456, 0)
		old.on_stdout(123456, { '{"event":"ready","protocol":1}', "" })
		drain()
		local connected = f.plugin.status().connected
		vim.api.nvim_exec_autocmds("VimLeavePre", {})
		assert(not connected, "an exited bridge delivered a stale ready event")
	end)

	test("real normal-exit events release saved and deliberately discarded work", function()
		for _, mode in ipairs({ "write-quit", "hidden-quit", "forced-quit" }) do
			local result = system(
				{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", "tests/lifecycle_spec.lua" },
				{ text = true, env = { TANDEM_LIFECYCLE_EXIT = mode } }
			):wait(5000)
			assert(result.code == 0, result.stderr)
			local output = (result.stdout or "") .. (result.stderr or "")
			local payload = assert(output:match("TANDEM_EXIT ([^\r\n]+)"), output)
			local status = vim.json.decode(payload)
			assert(next(status.leases) == nil and status.dying == 0, mode .. ": " .. payload)
		end
	end)
	test("real fatal-signal events retain the crashed editor's leases", function()
		local result = system(
			{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", "tests/lifecycle_spec.lua" },
			{ text = true, env = { TANDEM_LIFECYCLE_EXIT = "signal" } }
		):wait(5000)
		local output = (result.stdout or "") .. (result.stderr or "")
		local payload = assert(output:match("TANDEM_EXIT ([^\r\n]+)"), output)
		local status = vim.json.decode(payload)
		assert(next(status.leases) ~= nil and status.dying > 0, payload)
	end)

	test("reopening a renamed buffer's old path cannot release its unsaved work", function(f)
		f.edit("human")
		vim.api.nvim_buf_set_name(f.buf, root .. "/renamed.txt")
		local reopened = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(reopened)
		vim.api.nvim_buf_set_name(reopened, root .. "/file.txt")
		vim.api.nvim_buf_set_lines(reopened, 0, -1, false, { "base" })
		vim.bo[reopened].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = reopened })
		drain()
		assert(f.leased(), "clean reopened path released the renamed dirty buffer's claim")
		f.callbacks.on_stdout(123456, {
			vim.json.encode({
				event = "apply",
				id = 10,
				path = root .. "/file.txt",
				relative_path = "file.txt",
				expected_revision = vim.fn.sha256(f.disk),
				content = "agent\n",
				expires_ms = 9999999999999,
			}),
			"",
		})
		drain()
		local result
		for _, message in ipairs(f.messages) do
			if message.method == "apply_result" and message.id == 10 then
				result = message.result
			end
		end
		assert(result and result.error.code == "busy", "an in-flight apply must respect renamed unsaved work")
		assert(vim.api.nvim_buf_get_lines(reopened, 0, -1, false)[1] == "base")
		vim.api.nvim_buf_delete(f.buf, { force = true })
		drain()
		assert(not f.leased(), "a clean reopened buffer must not retain discarded work")
	end)

	test("rename and save in one callback reconcile the new path", function(f)
		f.edit("first")
		vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "second" })
		vim.api.nvim_buf_set_name(f.buf, root .. "/renamed.txt")
		f.disk = "second\n"
		vim.bo[f.buf].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = f.buf })
		drain()
		assert(not f.leases[root .. "/renamed.txt"], "old queued path swallowed the new save")
		assert(f.leased(), "renaming alone must not release the old path")
	end)
end, debug.traceback)

pcall(vim.api.nvim_del_augroup_by_name, "Tandem")
for key, value in pairs(originals) do
	uv[key] = value
end
vim.fn.jobstart, vim.fn.chansend, vim.fn.chanclose, vim.fn.jobwait = jobstart, chansend, chanclose, jobwait
vim.system = system
vim.notify = notify
if not ok then
	error(failure)
end
print("passed " .. count .. " lifecycle tests")
