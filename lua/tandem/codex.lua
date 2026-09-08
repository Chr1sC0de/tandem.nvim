local M = {}
local uv = vim.uv or vim.loop

-- JSON strings use TOML-compatible escapes except the optional escaped slash.
local function quote(value)
  return vim.json.encode(value):gsub("\\/", "/")
end

local function array(values)
  local encoded = {}
  for _, value in ipairs(values) do encoded[#encoded + 1] = quote(value) end
  return "[" .. table.concat(encoded, ",") .. "]"
end

local function inside(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

-- Only build launch settings after the editor is attached. Never fall back to
-- native writes when the gateway is unavailable or belongs to another project.
function M.args(connection, options)
  options = options or {}
  if not connection.connected or not connection.root then
    return nil, "Tandem is not connected. Check :TandemStatus before starting an agent."
  end
  local cwd = uv.fs_realpath(options.cwd or uv.cwd())
  if not cwd or not inside(connection.root, cwd) then
    return nil, "Agent cwd is outside Tandem's project. Open that project in another Neovim process."
  end
  if options.path then
    local path = vim.fs.normalize(vim.fn.fnamemodify(options.path, ":p"))
    if not inside(connection.root, path) then
      return nil, "The target file is outside Tandem's project."
    end
  end
  local command = vim.fn.exepath(connection.command or "tandem")
  if command == "" then return nil, "Tandem CLI is missing; install the pinned CLI and reconnect." end
  local args = { "--root", connection.root, "--state-home", connection.state_home, "mcp" }
  local enabled_tools = { "tandem_read_file", "tandem_status" }
  if options.read_only then
    args[#args + 1] = "--read-only"
  else
    enabled_tools[#enabled_tools + 1] = "tandem_write_file"
  end
  local server = "{command=" .. quote(command) .. ",args=" .. array(args)
    .. ",enabled=true,required=true,startup_timeout_sec=10,tool_timeout_sec=35,enabled_tools="
    .. array(enabled_tools) .. "}"
  return {
    "--sandbox", "read-only",
    "-c", 'approval_policy="never"',
    "-c", "mcp_servers.tandem=" .. server,
  }
end

return M
