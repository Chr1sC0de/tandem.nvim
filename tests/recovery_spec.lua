package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local originals = {
	system = vim.system,
	select = vim.ui.select,
	notify = vim.notify,
	print = vim.print,
	jobstart = vim.fn.jobstart,
	chansend = vim.fn.chansend,
}
local root = vim.uv.fs_realpath(vim.fn.getcwd())
local fixture
local function drain()
	vim.wait(20, function()
		return false
	end, 1)
end

local function new_fixture()
	pcall(vim.api.nvim_del_augroup_by_name, "Tandem")
	fixture = {
		prompts = {},
		notifications = {},
		releases = {},
		calls = {},
		printed = {},
		status = {
			ok = true,
			protocol = 1,
			root = root,
			leases = { ["a.txt"] = { "old-a" }, ["b.txt"] = { "old-b" } },
		},
	}
	local f = fixture
	vim.fn.jobstart = function(_, callbacks)
		f.callbacks = callbacks
		return 123456
	end
	vim.fn.chansend = function(_, text)
		local message = vim.json.decode(text)
		if message.method == "hello" then
			f.status.editor = { owner = message.owner }
		end
		return #text
	end
	vim.notify = function(message)
		f.notifications[#f.notifications + 1] = message
	end
	vim.print = function(value)
		f.printed[#f.printed + 1] = value
	end
	vim.ui.select = function(items, options, callback)
		f.prompts[#f.prompts + 1] = { items = items, options = options, callback = callback }
	end
	vim.system = function(command, options, callback)
		assert(command[1] == "configured-tandem")
		assert(command[2] == "--root" and command[3] == root)
		assert(command[4] == "--state-home" and command[5] == "/test state")
		assert(options.timeout > 0 and options.timeout <= 5000)
		f.calls[#f.calls + 1] = command
		local value = vim.deepcopy(f.status)
		local result = { code = 0, stderr = "" }
		if command[6] == "release" then
			assert(command[7] == "--owner")
			local owner = command[8]
			f.releases[#f.releases + 1] = owner
			if f.release_error or owner == f.status.editor.owner then
				value = { ok = false, error = { message = f.release_error or "editor connected" } }
				result.code = 1
			else
				for path, owners in pairs(f.status.leases) do
					local kept = {}
					for _, held in ipairs(owners) do
						if held ~= owner then
							kept[#kept + 1] = held
						end
					end
					f.status.leases[path] = #kept > 0 and kept or nil
				end
				value = { ok = true }
			end
		elseif f.status_error then
			result.code, result.stderr = 1, f.status_error
		end
		result.stdout = f.malformed and "invalid json" or vim.json.encode(value)
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
	package.loaded["tandem"] = nil
	f.plugin = require("tandem")
	f.plugin.setup({ command = "configured-tandem", root = root, state_home = "/test state" })
	f.callbacks.on_stdout(123456, { '{"event":"ready","protocol":1}', "" })
	drain()
	function f.answer(index)
		local prompt = table.remove(f.prompts, 1)
		assert(prompt, "expected a recovery prompt")
		prompt.callback(index and prompt.items[index] or nil)
		drain()
	end
	function f.recover()
		assert(vim.fn.exists(":TandemRecover") == 2, "missing guided recovery command")
		vim.cmd("TandemRecover")
		drain()
	end
	return f
end

local count = 0
local function test(name, run)
	run(new_fixture())
	count = count + 1
	print("ok " .. count .. " - " .. name)
end
local ok, failure = xpcall(function()
	test("recovery cancellation leaves disconnected owners untouched", function(f)
		f.recover()
		assert(#f.prompts == 1)
		f.answer(1)
		assert(#f.releases == 0 and f.status.leases["a.txt"][1] == "old-a")
	end)

	test("confirmation releases only the selected disconnected owner", function(f)
		f.status.leases["a.txt"] = { "old-a", f.status.editor.owner }
		f.recover()
		local choices = f.prompts[1].items
		assert(#choices == 3, "connected owner must never be offered")
		assert(choices[2].owner == "old-a")
		f.answer(2)
		assert(f.prompts[1].items[1] == "Cancel")
		f.answer(2)
		assert(vim.deep_equal(f.releases, { "old-a" }))
		assert(vim.deep_equal(f.status.leases["a.txt"], { f.status.editor.owner }))
		assert(f.status.leases["b.txt"][1] == "old-b")
		assert(table.concat(f.notifications, "\n"):find("Remaining lease blockers", 1, true))
	end)
	test("cancelling confirmation or closing selection does nothing", function(f)
		f.recover()
		f.answer(2)
		f.answer(1)
		f.recover()
		f.answer(nil)
		assert(#f.releases == 0)
	end)
	test("changed file lists require fresh review", function(f)
		f.recover()
		f.answer(2)
		f.status.leases["new.txt"] = { "old-a" }
		f.answer(2)
		assert(#f.releases == 0 and #f.prompts == 1)
		assert(#f.prompts[1].items[2].files == 2)
		f.answer(1)
	end)
	test("a selected owner reconnecting cannot be released", function(f)
		f.recover()
		f.answer(2)
		f.status.editor.owner = "old-a"
		f.answer(2)
		assert(#f.releases == 0)
		for _, row in ipairs(f.prompts[1].items) do
			assert(row.owner ~= "old-a")
		end
		f.answer(1)
	end)
	test("a different holder joining the affected file requires review", function(f)
		f.recover()
		f.answer(2)
		f.status.leases["a.txt"] = { "old-a", "another-owner" }
		f.answer(2)
		assert(#f.releases == 0 and #f.prompts == 1)
		f.answer(1)
	end)
	test("CLI release failures are reported and followed by fresh status", function(f)
		f.release_error = "cannot persist leases"
		f.recover()
		f.answer(2)
		f.answer(2)
		assert(f.status.leases["a.txt"][1] == "old-a")
		assert(f.calls[#f.calls][6] == "status")
		local notices = table.concat(f.notifications, "\n")
		assert(notices:find("cannot persist leases", 1, true))
		assert(not notices:find("Released leases for", 1, true))
	end)
	test("status failures and malformed responses cannot open recovery", function(f)
		f.status_error = "daemon unavailable"
		f.recover()
		assert(#f.prompts == 0 and #f.releases == 0)
		assert(table.concat(f.notifications, "\n"):find("daemon unavailable", 1, true))
		f.status_error, f.malformed = nil, true
		f.recover()
		assert(#f.prompts == 0)
		f.malformed = false
		f.status.root = "/another-project"
		f.recover()
		assert(#f.prompts == 0 and #f.releases == 0)
	end)
	test("startup notifies once per owner and status preserves the Lua API", function(f)
		assert(#f.notifications == 2)
		f.callbacks.on_stdout(123456, { '{"event":"ready","protocol":1}', "" })
		drain()
		assert(#f.notifications == 2)
		vim.cmd("TandemStatus")
		drain()
		assert(#f.printed[1].retained == 2)
		assert(f.printed[1].connected)
		local status = f.plugin.status()
		assert(status.connected and status.retained == nil and status.daemon == nil)
	end)
	test("duplicate recovery commands share one review dialog", function(f)
		f.recover()
		f.recover()
		assert(#f.prompts == 1)
		f.answer(1)
	end)

	test("missing CLI and timeouts fail without offering release", function(f)
		vim.system = function()
			error("executable missing")
		end
		f.recover()
		assert(#f.prompts == 0 and #f.releases == 0)
		assert(table.concat(f.notifications, "\n"):find("executable missing", 1, true))
		vim.system = function(_, _, callback)
			vim.schedule(function()
				callback({ code = 124, stdout = "", stderr = "" })
			end)
			return {}
		end
		f.recover()
		assert(#f.prompts == 0 and #f.releases == 0)
		assert(table.concat(f.notifications, "\n"):find("timed out", 1, true))
	end)
	test("a review from a disconnected generation cannot release anything", function(f)
		f.recover()
		f.answer(2)
		f.callbacks.on_exit(123456, 0)
		f.answer(2)
		assert(#f.releases == 0)
	end)
end, debug.traceback)

pcall(vim.api.nvim_del_augroup_by_name, "Tandem")
vim.system, vim.ui.select, vim.notify, vim.print = originals.system, originals.select, originals.notify, originals.print
vim.fn.jobstart, vim.fn.chansend = originals.jobstart, originals.chansend
if not ok then
	error(failure)
end
print("passed " .. count .. " recovery tests")
