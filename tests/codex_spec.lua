package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local codex = require("tandem.codex")
local config_reader = require("tandem.codex_config")
local inherited = "Preserve the user's existing instructions."
config_reader.instructions = function()
	return inherited
end
local root = vim.uv.fs_realpath(vim.fn.getcwd())
local connection = {
	connected = true,
	root = root,
	command = vim.v.progpath,
	state_home = root .. '/state with "quotes" and $literal',
}
local count = 0
local function test(name, fn)
	fn()
	count = count + 1
	print("ok " .. count .. " - " .. name)
end

test("edit launches restrict native writes and require the project MCP server", function()
	local args = assert(codex.args(connection, { cwd = root }))
	assert(args[1] == "--sandbox" and args[2] == "read-only")
	assert(args[4] == 'approval_policy="never"')
	assert(args[6]:find("required=true", 1, true))
	assert(args[6]:find('"tandem_write_file"', 1, true))
	assert(args[6]:find('"--root","' .. root .. '"', 1, true))
	assert(not args[6]:find('"--read-only"', 1, true))
end)

test("read-only launches cannot expose the MCP writer", function()
	local args = assert(codex.args(connection, { cwd = root, read_only = true }))
	assert(args[6]:find('"--read-only"', 1, true))
	assert(not args[6]:find('"tandem_write_file"', 1, true))
end)

test("offline and unrelated projects cannot start a protected agent", function()
	local offline = vim.tbl_extend("force", connection, { connected = false })
	assert(codex.args(offline, { cwd = root }) == nil)
	assert(codex.args(connection, { cwd = "/" }) == nil)
	assert(codex.args(connection, { cwd = root, path = "/outside.txt" }) == nil)
end)

test("TOML survives spaces, quotes and shell metacharacters without a shell", function()
	local args = assert(codex.args(connection, { cwd = root }))
	local result = vim.system({
		"python3",
		"-c",
		[[
import json, sys, tomllib
config = tomllib.loads(sys.argv[1])["mcp_servers"]["tandem"]
assert config["args"][3] == sys.argv[2]
assert config["required"] is True
assert config["tool_timeout_sec"] == 35
assert set(config["tools"]) == set(config["enabled_tools"])
assert all(tool["approval_mode"] == "approve" for tool in config["tools"].values())
print("ok")
]],
		args[6],
		connection.state_home,
	}, { text = true }):wait(5000)
	assert(result.code == 0, result.stderr)
end)

test("edit routing replaces the native-patch rule without discarding host instructions", function()
	local custom = 'Keep "quoted" text, \\paths, $literal and Unicode λ.\nUse apply_patch to edit files.'
	local args = assert(codex.args(connection, { cwd = root, developer_instructions = custom }))
	local encoded
	for i, arg in ipairs(args) do
		if arg == "-c" and args[i + 1]:match("^developer_instructions=") then
			encoded = args[i + 1]:sub(#"developer_instructions=" + 1)
		end
	end
	assert(encoded, "editing launches need developer-level routing instructions")
	local guidance = vim.json.decode(encoded)
	assert(guidance:sub(1, #custom) == custom)
	assert(guidance:find("tandem_read_file", 1, true))
	assert(guidance:find("tandem_write_file", 1, true))
	assert(guidance:find("Discover", 1, true))
	assert(guidance:find("supersedes", 1, true))
	assert(guidance:find("stale_revision", 1, true))
	assert(guidance:find("outcome_unknown", 1, true))
	assert(guidance:find("expected_revision", 1, true))
	local parsed = vim.system({
		"python3",
		"-c",
		"import sys,tomllib; assert tomllib.loads(sys.argv[1])['developer_instructions'] == sys.argv[2]",
		"developer_instructions=" .. encoded,
		guidance,
	}, { text = true }):wait(5000)
	assert(parsed.code == 0, parsed.stderr)
end)

test("analysis routing never offers the writer as a recovery path", function()
	local args = assert(codex.args(connection, { cwd = root, read_only = true, developer_instructions = "" }))
	local config = table.concat(args, "\n")
	assert(config:find("Analysis-only Tandem session", 1, true))
	assert(config:find("Do not edit", 1, true))
	assert(not config:find("tandem_write_file", 1, true))
end)

test("effective host instructions are preserved by default", function()
	local args = assert(codex.args(connection, { cwd = root }))
	local guidance = vim.json.decode(args[8]:sub(#"developer_instructions=" + 1))
	assert(guidance:sub(1, #inherited) == inherited)
	assert(#args == 8, "do not override unrelated model or instruction settings")
end)

test("configuration failures cannot silently discard existing instructions", function()
	local previous = config_reader.instructions
	config_reader.instructions = function(cwd, command)
		assert(cwd == root and command == "custom-codex")
		return nil, "configuration unavailable"
	end
	local args, err = codex.args(connection, { cwd = root, codex_command = "custom-codex" })
	config_reader.instructions = previous
	assert(args == nil and err:find("configuration unavailable", 1, true))
	assert(codex.args(connection, { developer_instructions = false }) == nil)
end)

test("starting Neovim in a Git subdirectory selects the shared project root", function()
	local tandem = require("tandem")
	local previous = vim.fn.getcwd()
	local jobstart, chansend = vim.fn.jobstart, vim.fn.chansend
	local started
	vim.fn.jobstart = function(command)
		started = command
		return 123456
	end
	vim.fn.chansend = function()
		return 1
	end
	vim.cmd.cd(root .. "/lua")
	tandem.setup({ command = vim.v.progpath })
	local selected = tandem.status().root
	vim.cmd.cd(previous)
	vim.fn.jobstart, vim.fn.chansend = jobstart, chansend
	assert(selected == root)
	assert(started[3] == root)
end)

print("passed " .. count .. " Codex launch tests")
