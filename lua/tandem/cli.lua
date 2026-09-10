local M = {}

local function decode(result, config, status)
	local ok, value = pcall(vim.json.decode, result.stdout or "")
	if result.code ~= 0 then
		local message = ok and type(value) == "table" and type(value.error) == "table" and value.error.message
		return nil,
			message
				or (result.code == 124 and "Tandem CLI timed out")
				or ((result.stderr or ""):match("%S") and result.stderr)
				or ("Tandem CLI exited " .. tostring(result.code))
	end
	if not ok or type(value) ~= "table" or value.ok ~= true then
		return nil,
			(ok and type(value) == "table" and type(value.error) == "table" and value.error.message)
				or "Invalid Tandem CLI response"
	end
	if status then
		if value.protocol ~= 1 or value.root ~= config.root or type(value.leases) ~= "table" then
			return nil, "Invalid Tandem status for this project"
		end
		if
			value.editor ~= nil
			and value.editor ~= vim.NIL
			and (type(value.editor) ~= "table" or type(value.editor.owner) ~= "string")
		then
			return nil, "Invalid Tandem editor status"
		end
		for path, owners in pairs(value.leases) do
			if type(path) ~= "string" or type(owners) ~= "table" or not vim.islist(owners) then
				return nil, "Invalid Tandem lease status"
			end
			for _, owner in ipairs(owners) do
				if type(owner) ~= "string" or owner == "" then
					return nil, "Invalid Tandem lease owner"
				end
			end
		end
		if value.fault ~= nil and value.fault ~= vim.NIL then
			return nil, "Tandem state error: " .. tostring(value.fault)
		end
	end
	return value
end

-- The same configured identity is used for the editor bridge and all CLI calls.
-- With no callback, the caller supplies its remaining shutdown deadline.
function M.run(config, args, callback, timeout)
	timeout = math.max(1, timeout or 5000)
	local command = { config.command, "--root", config.root, "--state-home", config.state_home }
	vim.list_extend(command, args)
	local function finish(result)
		local value, err = decode(result, config, args[1] == "status")
		callback(value, err)
	end
	local ok, process = pcall(vim.system, command, { text = true, timeout = timeout }, callback and function(result)
		vim.schedule(function()
			finish(result)
		end)
	end or nil)
	if not ok then
		local err = "Could not start Tandem CLI: " .. tostring(process)
		if callback then
			vim.schedule(function()
				callback(nil, err)
			end)
		end
		return nil, err
	end
	if callback then
		return process
	end
	local waited, result = pcall(process.wait, process, timeout)
	if not waited then
		return nil, "Could not wait for Tandem CLI: " .. tostring(result)
	end
	return decode(result, config, args[1] == "status")
end

return M
