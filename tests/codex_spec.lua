package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local codex = require("tandem.codex")
local root = vim.uv.fs_realpath(vim.fn.getcwd())
local connection = {
  connected = true, root = root, command = vim.v.progpath,
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
  local result = vim.system({ "python3", "-c", [[
import json, sys, tomllib
config = tomllib.loads(sys.argv[1])["mcp_servers"]["tandem"]
assert config["args"][3] == sys.argv[2]
assert config["required"] is True
assert config["tool_timeout_sec"] == 35
print("ok")
]], args[6], connection.state_home }, { text = true }):wait(5000)
  assert(result.code == 0, result.stderr)
end)

test("starting Neovim in a Git subdirectory selects the shared project root", function()
  local tandem = require("tandem")
  local temporary = vim.fn.tempname()
  vim.fn.mkdir(temporary .. "/.git", "p")
  vim.fn.mkdir(temporary .. "/nested", "p")
  local previous = vim.fn.getcwd()
  local jobstart, chansend = vim.fn.jobstart, vim.fn.chansend
  local started
  vim.fn.jobstart = function(command) started = command; return 123456 end
  vim.fn.chansend = function() return 1 end
  vim.cmd.cd(temporary .. "/nested")
  tandem.setup({ command = vim.v.progpath })
  local selected = tandem.status().root
  vim.cmd.cd(previous)
  vim.fn.jobstart, vim.fn.chansend = jobstart, chansend
  assert(selected == vim.uv.fs_realpath(temporary))
  assert(started[3] == selected)
  vim.fn.delete(temporary, "rf")
end)

print("passed " .. count .. " Codex launch tests")
