local M = {}

-- Read Codex's effective configuration instead of reimplementing TOML, trust,
-- and config layering. No thread or model turn is started.
function M.instructions(cwd, command)
	local executable = vim.fn.exepath(command or "codex")
	if executable == "" then
		return nil, "Codex CLI is missing from PATH."
	end
	local value, failure, done, exited
	local pending = ""
	local function send(job, message)
		local ok = pcall(vim.fn.chansend, job, vim.json.encode(message) .. "\n")
		if not ok then
			failure, done = "Codex configuration connection closed.", true
		end
	end
	local function receive(job, line)
		if done or line == "" then
			return
		end
		local ok, message = pcall(vim.json.decode, line)
		if not ok or type(message) ~= "table" then
			failure, done = "Codex returned invalid configuration JSON.", true
			return
		end
		if message.id ~= 1 and message.id ~= 2 then
			return
		end
		if message.error and message.error ~= vim.NIL then
			failure, done = "Codex rejected the configuration request.", true
		elseif message.id == 1 then
			send(job, { method = "initialized", params = vim.empty_dict() })
			if not done then
				send(job, { id = 2, method = "config/read", params = { includeLayers = false, cwd = cwd } })
			end
		else
			local config = type(message.result) == "table" and message.result.config
			if type(config) ~= "table" or config == vim.NIL then
				failure = "Codex returned no effective configuration."
			elseif config.developer_instructions == nil or config.developer_instructions == vim.NIL then
				value = ""
			elseif type(config.developer_instructions) == "string" then
				value = config.developer_instructions
			else
				failure = "Codex developer_instructions must be a string."
			end
			done = true
		end
	end
	local ok, job = pcall(vim.fn.jobstart, { executable, "app-server" }, {
		cwd = cwd,
		on_stdout = function(id, data)
			pending = pending .. table.concat(data, "\n")
			while true do
				local newline = pending:find("\n", 1, true)
				if not newline then
					break
				end
				local line = pending:sub(1, newline - 1)
				pending = pending:sub(newline + 1)
				receive(id, line)
			end
		end,
		-- Do not echo a user's config or credentials in diagnostics.
		on_stderr = function() end,
		on_exit = function()
			exited = true
		end,
	})
	if not ok or job <= 0 then
		return nil, "Could not start Codex to read its configuration."
	end
	send(job, {
		id = 1,
		method = "initialize",
		params = { clientInfo = { name = "tandem_nvim", version = "0.1.0" } },
	})
	local completed = vim.wait(5000, function()
		return done or exited
	end, 10)
	pcall(vim.fn.jobstop, job)
	if not done then
		return nil,
			completed and "Codex exited before returning its configuration." or "Timed out reading Codex configuration."
	end
	return value, failure
end

return M
