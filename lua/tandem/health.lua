local M = {}
function M.check()
  vim.health.start("tandem.nvim")
  if vim.fn.has("nvim-0.10") == 1 then vim.health.ok("Neovim 0.10+")
  else vim.health.error("Neovim 0.10 or newer is required") end
  local status = require("tandem").status()
  if status.connected then vim.health.ok("daemon connected for " .. status.root)
  else vim.health.error(status.error or "not connected; call setup() and install tandem") end
  vim.health.info("One Neovim process per project; multiple participating agents supported")
  vim.health.info("Agent editing must use Tandem's CLI or MCP write gateway")
end
return M
