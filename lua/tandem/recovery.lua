local cli = require("tandem.cli")
local M = {}

local function connected(status)
	return type(status.editor) == "table" and status.editor.owner or nil
end

local function retained(status)
	local by_owner = {}
	for path, owners in pairs(status.leases) do
		for _, owner in ipairs(owners) do
			if owner ~= connected(status) then
				by_owner[owner] = by_owner[owner] or {}
				table.insert(by_owner[owner], path)
			end
		end
	end
	local rows = {}
	for owner, files in pairs(by_owner) do
		table.sort(files)
		rows[#rows + 1] = { owner = owner, files = files }
	end
	table.sort(rows, function(a, b)
		return a.owner < b.owner
	end)
	return rows
end

-- Include every holder of each affected file, not just the selected owner.
local function snapshot(status, owner)
	local result = { editor = connected(status), files = {} }
	for path, owners in pairs(status.leases) do
		if vim.tbl_contains(owners, owner) then
			result.files[path] = vim.deepcopy(owners)
			table.sort(result.files[path])
		end
	end
	return result
end

function M.new(config, generation)
	local seen, running = {}, nil
	local function notify(message, level)
		vim.notify("Tandem: " .. message, level or vim.log.levels.INFO)
	end
	local function current(token)
		return token ~= nil and generation() == token
	end
	local function request(args, token, callback)
		cli.run(config, args, function(value, err)
			if current(token) then
				callback(value, err)
			end
		end)
	end
	local function announce(status)
		for _, row in ipairs(retained(status)) do
			if not seen[row.owner] then
				seen[row.owner] = true
				notify(
					"Retained leases from "
						.. row.owner
						.. ": "
						.. table.concat(row.files, ", ")
						.. ". Recover or discard that work, then use :TandemRecover.",
					vim.log.levels.WARN
				)
			end
		end
	end

	local api = {}
	function api.ready()
		local token = generation()
		request({ "status" }, token, function(status, err)
			if status then
				announce(status)
			else
				notify(err, vim.log.levels.WARN)
			end
		end)
	end

	function api.status(local_status)
		local token = generation()
		request({ "status" }, token, function(status, err)
			local report = local_status()
			if status then
				report.retained = retained(status)
				report.daemon = status
			else
				report.daemon_error = err
				notify(err, vim.log.levels.ERROR)
			end
			vim.print(report)
		end)
	end

	function api.recover()
		local token = generation()
		if not token then
			return
		end
		if running and current(running.token) then
			notify("Recovery is already open.")
			return
		end
		local operation = { token = token }
		running = operation
		local function active()
			return running == operation and current(token)
		end
		local function finish()
			if running == operation then
				running = nil
			end
		end
		local function fail(err)
			finish()
			notify(err, vim.log.levels.ERROR)
		end
		local choose
		choose = function(status)
			if not active() then
				finish()
				return
			end
			local rows = retained(status)
			if #rows == 0 then
				finish()
				notify("No disconnected owners have retained leases.")
				return
			end
			local choices = { { cancel = true } }
			vim.list_extend(choices, rows)
			vim.ui.select(choices, {
				prompt = "Recover retained leases (buffer contents are not restored):",
				format_item = function(row)
					return row.cancel and "Cancel" or (row.owner .. ": " .. table.concat(row.files, ", "))
				end,
			}, function(row)
				if not active() or not row or row.cancel then
					finish()
					return
				end
				local before = snapshot(status, row.owner)
				vim.ui.select({ "Cancel", "Release leases" }, {
					prompt = "Confirm work from "
						.. row.owner
						.. " has been recovered or deliberately discarded: "
						.. table.concat(row.files, ", "),
				}, function(answer)
					if not active() or answer ~= "Release leases" then
						finish()
						return
					end
					request({ "status" }, token, function(fresh, err)
						if not active() then
							return
						end
						if not fresh then
							fail(err)
							return
						end
						if connected(fresh) == row.owner or not vim.deep_equal(before, snapshot(fresh, row.owner)) then
							notify(
								"Lease ownership or affected files changed. Review the refreshed selection.",
								vim.log.levels.WARN
							)
							choose(fresh)
							return
						end
						request({ "release", "--owner", row.owner }, token, function(result, release_error)
							if not active() then
								return
							end
							request({ "status" }, token, function(after, status_error)
								if not active() then
									return
								end
								finish()
								if not result then
									notify(release_error, vim.log.levels.ERROR)
								end
								if not after then
									notify(status_error, vim.log.levels.ERROR)
									return
								end
								local blockers = {}
								for path, owners in pairs(after.leases) do
									if #owners > 0 then
										blockers[#blockers + 1] = path .. " (" .. table.concat(owners, ", ") .. ")"
									end
								end
								table.sort(blockers)
								if result then
									notify(
										"Released leases for " .. row.owner .. ". Buffer contents were not restored."
									)
								end
								notify(
									#blockers == 0 and "No remaining lease blockers."
										or ("Remaining lease blockers: " .. table.concat(blockers, "; "))
								)
							end)
						end)
					end)
				end)
			end)
		end
		request({ "status" }, token, function(status, err)
			if not active() then
				return
			end
			if status then
				choose(status)
			else
				fail(err)
			end
		end)
	end

	return api
end

return M
