package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local reader = require("tandem.codex_config")
local count = 0
local function test(name, fn)
	fn()
	count = count + 1
	print("ok " .. count .. " - " .. name)
end

-- Exercise the actual framing/handshake/cleanup code, with only process I/O
-- replaced. No Codex account, user config, writable directory or network needed.
local function simulate(scenario)
	scenario = scenario or {}
	local original = {
		jobstart = vim.fn.jobstart,
		chansend = vim.fn.chansend,
		jobstop = vim.fn.jobstop,
		exepath = vim.fn.exepath,
		wait = vim.wait,
	}
	local callbacks, stopped, requests = nil, false, {}
	local function stdout(message)
		local wire = vim.json.encode(message)
		-- Split both within a JSON token and at the trailing newline.
		callbacks.on_stdout(42, { wire:sub(1, 7) })
		callbacks.on_stdout(42, { wire:sub(8), "" })
	end
	vim.fn.exepath = function(command)
		assert(command == "selected-codex")
		return scenario.missing and "" or "/bin/selected-codex"
	end
	vim.fn.jobstart = function(command, options)
		assert(vim.deep_equal(command, { "/bin/selected-codex", "app-server" }))
		assert(options.cwd == "/project")
		callbacks = options
		return scenario.start_failure and -1 or 42
	end
	vim.fn.jobstop = function(job)
		assert(job == 42)
		stopped = true
	end
	vim.fn.chansend = function(job, data)
		assert(job == 42 and data:sub(-1) == "\n")
		local request = vim.json.decode(data)
		requests[#requests + 1] = request
		if request.method == "initialize" then
			assert(request.params.clientInfo.name == "tandem_nvim")
			if scenario.closed then
				error("closed pipe")
			end
			if scenario.exit then
				callbacks.on_exit(42, 1)
				return 1
			end
			if scenario.timeout then
				return 1
			end
			if scenario.invalid_json then
				callbacks.on_stdout(42, { "invalid json", "" })
				return 1
			end
			if scenario.rpc_error then
				stdout({ id = 1, error = { message = "private configuration detail" } })
			else
				stdout({ id = 1, result = {} })
			end
		elseif request.method == "config/read" then
			assert(request.params.cwd == "/project" and request.params.includeLayers == false)
			assert(requests[2].method == "initialized")
			stdout({ method = "notice", params = {} })
			stdout({ id = 2, result = scenario.result or { config = { developer_instructions = "host\nλ" } } })
		end
		return #data
	end
	vim.wait = function(timeout, predicate)
		assert(timeout == 5000)
		return predicate() or false
	end
	local ok, value, err = pcall(reader.instructions, "/project", "selected-codex")
	vim.fn.jobstart, vim.fn.chansend = original.jobstart, original.chansend
	vim.fn.jobstop, vim.fn.exepath, vim.wait = original.jobstop, original.exepath, original.wait
	assert(ok, value)
	assert(stopped == not (scenario.missing or scenario.start_failure))
	return value, err, requests
end

test("effective instructions survive fragmented JSON and initialization", function()
	local value, err, requests = simulate()
	assert(value == "host\nλ" and err == nil)
	assert(#requests == 3)
end)
test("absent and null instructions mean an empty configured value", function()
	assert(simulate({ result = { config = {} } }) == "")
	assert(simulate({ result = { config = { developer_instructions = vim.NIL } } }) == "")
end)
test("malformed configuration is rejected", function()
	for _, result in ipairs({ {}, { config = vim.NIL }, { config = { developer_instructions = 123 } } }) do
		local value, err = simulate({ result = result })
		assert(value == nil and type(err) == "string")
	end
end)
test("missing executable and failed startup return actionable errors", function()
	for _, scenario in ipairs({ { missing = true }, { start_failure = true } }) do
		local value, err = simulate(scenario)
		assert(value == nil and err:find("Codex", 1, true))
	end
end)
test("RPC and transport failures fail closed without echoing configuration", function()
	for _, scenario in ipairs({ { rpc_error = true }, { invalid_json = true }, { closed = true }, { exit = true } }) do
		local value, err = simulate(scenario)
		assert(value == nil and type(err) == "string")
		assert(not err:find("private", 1, true))
	end
end)
test("a timeout stops the configuration process", function()
	local value, err = simulate({ timeout = true })
	assert(value == nil and err:find("Timed out", 1, true))
end)

test("the configuration handshake works over real process pipes", function()
	local original = vim.fn.jobstart
	vim.fn.jobstart = function(command, options)
		assert(command[2] == "app-server")
		return original({
			"python3",
			"-u",
			"-c",
			[[
import json, sys
def receive():
    return json.loads(sys.stdin.readline())
def send(value):
    print(json.dumps(value), flush=True)
initial = receive()
assert initial["method"] == "initialize"
send({"id": initial["id"], "result": {}})
assert receive()["method"] == "initialized"
request = receive()
assert request["method"] == "config/read"
assert request["params"]["includeLayers"] is False
send({"id": request["id"], "result": {"config": {"developer_instructions": "process-host"}}})
# Keep the pipe open until the caller stops this isolated process.
sys.stdin.read()
]],
		}, options)
	end
	local ok, value, err = pcall(reader.instructions, vim.fn.getcwd(), vim.v.progpath)
	vim.fn.jobstart = original
	assert(ok and value == "process-host" and err == nil, err or value)
end)

print("passed " .. count .. " Codex configuration tests")
