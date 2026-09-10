local M = {}
local uv = vim.uv or vim.loop
local gate = require("tandem.buffer")
local state = {
	job = nil,
	ready = false,
	stopped = true,
	dirty = {},
	released = {},
	attached = {},
	buffers = {},
	applying = {},
	partial = "",
	error = nil,
	generation = 0,
}

local function normalize(path)
	return vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")
end

local function validate_path(path)
	if type(path) ~= "string" or path:find("%z") then
		return nil, "invalid path"
	end
	path = normalize(path)
	local prefix = state.root .. "/"
	if path:sub(1, #prefix) ~= prefix then
		return nil, "path is outside project"
	end
	local walked = state.root
	for part in path:sub(#prefix + 1):gmatch("[^/]+") do
		if part == ".git" or part == ".." then
			return nil, "unsupported path"
		end
		walked = walked .. "/" .. part
		local stat = uv.fs_lstat(walked)
		if stat and stat.type == "link" then
			return nil, "symlinks are unsupported"
		end
	end
	return path
end

local function send(message)
	if not state.job then
		return false
	end
	local ok, count = pcall(vim.fn.chansend, state.job, vim.json.encode(message) .. "\n")
	return ok and count > 0
end

local function emit()
	vim.schedule(function()
		pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "TandemStatus", modeline = false })
	end)
end

local function claim(path, buf)
	local record = buf and state.buffers[buf]
	if record then
		record.paths[path] = true
	end
	state.released[path] = nil
	if state.dirty[path] then
		return
	end
	state.dirty[path] = true
	send({ method = "claim", path = path })
	emit()
end

local function release(path, method)
	for _, record in pairs(state.buffers) do
		record.paths[path] = nil
	end
	state.dirty[path] = nil
	state.released[path] = method
	send({ method = method, path = path })
	emit()
end

local function buffer_path(buf)
	if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return nil
	end
	return validate_path(name)
end

local function find_buffer(path)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and buffer_path(buf) == path then
			return buf
		end
	end
end

local function disk(path)
	local fd, err, code = uv.fs_open(path, "r", 438)
	if not fd then
		if code == "ENOENT" then
			return { content = nil, revision = "missing" }
		end
		return nil, err
	end
	local stat, stat_error = uv.fs_fstat(fd)
	if not stat or stat.type ~= "file" or stat.size > 1024 * 1024 then
		uv.fs_close(fd)
		return nil, stat_error or "expected a regular text file up to 1 MiB"
	end
	local content, read_error = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	if content == nil then
		return nil, read_error
	end
	if #content ~= stat.size then
		return nil, "file changed during read"
	end
	return { content = content, revision = vim.fn.sha256(content) }
end

local function matches(buf, content)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local text = table.concat(lines, "\n")
	if (content == nil or content == "") and text == "" then
		return true
	end
	if vim.bo[buf].endofline then
		text = text .. "\n"
	end
	return text == content
end

local function held_elsewhere(buf, path)
	for other, record in pairs(state.buffers) do
		if other ~= buf and record.paths[path] and vim.api.nvim_buf_is_loaded(other) then
			return true
		end
	end
	return false
end

-- Run after the current editor callbacks, when modified and text agree.
local pending = {}
local function reconcile(buf, path)
	if state.stopped or vim.v.dying > 0 or buffer_path(buf) ~= path or not vim.api.nvim_buf_is_loaded(buf) then
		return
	end
	if vim.bo[buf].modified then
		claim(path, buf)
		return
	end
	local saved = disk(path)
	if not saved or not matches(buf, saved.content) then
		claim(path, buf)
	else
		local record = state.buffers[buf]
		if record then
			record.paths[path] = nil
		end
		if state.dirty[path] and not held_elsewhere(buf, path) then
			release(path, "saved")
		end
	end
end

local function schedule_reconcile(buf)
	local path = buffer_path(buf)
	if not path or pending[buf] == path then
		return
	end
	pending[buf] = path
	vim.schedule(function()
		if pending[buf] ~= path then
			return
		end
		pending[buf] = nil
		reconcile(buf, path)
	end)
end

local function context()
	return {
		now_ms = function()
			local sec, usec = uv.gettimeofday()
			return sec * 1000 + math.floor(usec / 1000)
		end,
		validate_path = validate_path,
		find_buffer = find_buffer,
		modified = function(buf)
			return vim.bo[buf].modified or held_elsewhere(buf, buffer_path(buf))
		end,
		claim = function(path)
			local buf = find_buffer(path)
			claim(path, buf)
			if buf then
				schedule_reconcile(buf)
			end
		end,
		saved = function(path)
			if not held_elsewhere(find_buffer(path), path) then
				release(path, "saved")
			end
		end,
		disk = disk,
		-- JSON has already been decoded from Rust's validated UTF-8 String.
		valid_text = function()
			return true
		end,
		load = function(path)
			local buf = vim.fn.bufadd(path)
			vim.fn.bufload(buf)
			return buf
		end,
		supported = function(buf)
			local b = vim.bo[buf]
			if
				b.buftype ~= ""
				or b.binary
				or b.bomb
				or b.readonly
				or not b.modifiable
				or b.fileformat ~= "unix"
				or (b.fileencoding ~= "" and b.fileencoding ~= "utf-8")
			then
				return false, "requires a writable UTF-8 buffer with Unix newlines and no BOM"
			end
			return true
		end,
		matches = matches,
		write = function(buf, content)
			state.applying[buf] = true
			local previous_fixeol = vim.bo[buf].fixendofline
			local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
				local eol = content:sub(-1) == "\n"
				local lines = vim.split(content, "\n", { plain = true })
				if eol then
					table.remove(lines)
				end
				if #lines == 0 then
					lines = { "" }
				end
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				vim.bo[buf].endofline = eol
				vim.bo[buf].fixendofline = false
				-- Preserve normal synchronous formatting and save hooks.
				vim.cmd("silent keepalt write")
			end)
			if vim.api.nvim_buf_is_valid(buf) then
				vim.bo[buf].fixendofline = previous_fixeol
			end
			state.applying[buf] = nil
			if not ok then
				error(err)
			end
		end,
	}
end

-- BufDelete/BufWipeout also run during rename. Only a completed unload
-- proves that the user abandoned the text; hidden buffers remain protected.
local unloading = {}
local function discard_unloaded(buf, record)
	if state.stopped or vim.v.dying > 0 or vim.api.nvim_buf_is_loaded(buf) then
		return
	end
	for path in pairs(record.paths) do
		if not held_elsewhere(buf, path) and state.dirty[path] then
			release(path, "discarded")
		end
	end
	if state.buffers[buf] == record then
		state.buffers[buf] = nil
	end
end

local function queue_unload(buf)
	local record = state.buffers[buf]
	if not record then
		return
	end
	unloading[buf] = record
	vim.schedule(function()
		if unloading[buf] ~= record then
			return
		end
		unloading[buf] = nil
		discard_unloaded(buf, record)
	end)
end

local function attach(buf)
	local path = buffer_path(buf)
	if not path or not vim.api.nvim_buf_is_loaded(buf) then
		return
	end
	local record = state.buffers[buf] or { paths = {} }
	state.buffers[buf] = record
	if vim.bo[buf].modified then
		claim(path, buf)
	end
	if state.attached[buf] then
		return
	end
	state.attached[buf] = true
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, b)
			if state.stopped then
				state.attached[b] = nil
				return true
			end
			if not state.applying[b] then
				-- Claim on the first text event, including insert mode, paste and LSP edits.
				-- The apply callback also checks modified, covering delayed IPC delivery.
				local p = buffer_path(b)
				if p then
					claim(p, b)
					schedule_reconcile(b)
				end
			end
		end,
		on_detach = function(_, b)
			state.attached[b] = nil
			-- BufUnload retains the path snapshot until the deferred discard check.
		end,
		on_reload = function(_, b)
			schedule_reconcile(b)
		end,
	})
end

local function cli_config()
	return { command = state.options.command, root = state.root, state_home = state.options.state_home }
end

local function shutdown()
	if state.stopped then
		return
	end
	local deadline = uv.hrtime() / 1000000 + 1000
	-- VimLeavePre means exit is committed. QuitPre/ExitPre can still be cancelled.
	state.ready = false
	if vim.v.dying == 0 then
		for buf, path in pairs(pending) do
			reconcile(buf, path)
		end
		for buf, record in pairs(unloading) do
			discard_unloaded(buf, record)
		end
		-- Normal process exit abandons the remaining tracked text, including hidden
		-- buffers. Claims with no known buffer are left for explicit recovery.
		for buf, record in pairs(state.buffers) do
			local path = buffer_path(buf)
			if path then
				reconcile(buf, path)
			end
			for held in pairs(record.paths) do
				if state.dirty[held] then
					release(held, "discarded")
				end
			end
		end
		for path, method in pairs(state.released) do
			if not state.dirty[path] then
				send({ method = method, path = path })
			end
		end
	end
	state.stopped = true
	state.generation = state.generation + 1
	pending, unloading = {}, {}
	local job = state.job
	state.job = nil
	if job then
		pcall(vim.fn.chanclose, job, "stdin")
	end
	if vim.v.dying > 0 then
		return
	end
	local function remaining()
		return math.max(0, math.floor(deadline - uv.hrtime() / 1000000))
	end
	if job and remaining() > 0 then
		pcall(vim.fn.jobwait, { job }, remaining())
	end
	local verified, failure = false, "Shutdown delivery could not be verified"
	while remaining() > 0 do
		local status, err = require("tandem.cli").run(cli_config(), { "status" }, nil, remaining())
		if not status then
			failure = err
			break
		end
		local editor = status.editor ~= vim.NIL and status.editor or nil
		verified = not editor or editor.owner ~= state.owner
		for path in pairs(state.released) do
			if not state.dirty[path] then
				for _, owner in ipairs(status.leases[path:sub(#state.root + 2)] or {}) do
					if owner == state.owner then
						verified = false
					end
				end
			end
		end
		if verified then
			break
		end
		if remaining() > 0 then
			vim.wait(math.min(10, remaining()), function()
				return false
			end, 1)
		end
	end
	if not verified then
		state.error = failure
		vim.notify(
			"Tandem: " .. failure .. ". Retained leases can be reviewed with :TandemRecover.",
			vim.log.levels.WARN
		)
	end
end

local connect
local function handle(event)
	if event.event == "ready" then
		if event.protocol ~= 1 then
			error("unsupported daemon protocol")
		end
		state.ready, state.error = true, nil
		state.recovery.ready()
		-- A previous save acknowledgment may have been lost during disconnect.
		for path, method in pairs(state.released) do
			if not state.dirty[path] then
				send({ method = method, path = path })
			end
		end
		emit()
	elseif event.event == "apply" then
		local ok, result = pcall(gate.apply, event, context())
		if not ok then
			local path = validate_path(event.path)
			local buf = path and find_buffer(path)
			if buf and vim.bo[buf].modified then
				claim(path, buf)
			end
			result = { ok = false, error = { code = "outcome_unknown", message = tostring(result) } }
		end
		send({ method = "apply_result", id = event.id, result = result })
	elseif event.ok == false then
		state.error = event.error and event.error.message or "daemon error"
		emit()
	end
end

connect = function()
	if state.stopped or state.job then
		return
	end
	state.partial = ""
	state.generation = state.generation + 1
	local generation = state.generation
	local command = { state.options.command, "--root", state.root }
	if state.options.state_home then
		vim.list_extend(command, { "--state-home", state.options.state_home })
	end
	table.insert(command, "editor")
	local job = vim.fn.jobstart(command, {
		stdin = "pipe",
		on_stdout = function(_, data)
			if generation ~= state.generation then
				return
			end
			state.partial = state.partial .. table.concat(data, "\n")
			while true do
				local newline = state.partial:find("\n", 1, true)
				if not newline then
					break
				end
				local line = state.partial:sub(1, newline - 1)
				state.partial = state.partial:sub(newline + 1)
				if line ~= "" then
					local ok, event = pcall(vim.json.decode, line)
					if ok then
						vim.schedule(function()
							if generation ~= state.generation or state.stopped then
								return
							end
							local handled, why = pcall(handle, event)
							if not handled then
								state.error = tostring(why)
								emit()
							end
						end)
					else
						state.error = "invalid daemon response"
					end
				end
			end
		end,
		on_stderr = function(_, data)
			if generation ~= state.generation or state.stopped then
				return
			end
			local text = table.concat(data, "\n"):gsub("%s+$", "")
			if text ~= "" then
				state.error = text
				emit()
			end
		end,
		on_exit = function()
			if generation ~= state.generation then
				return
			end
			state.generation = state.generation + 1
			state.job, state.ready = nil, false
			emit()
			if not state.stopped then
				vim.defer_fn(connect, state.options.reconnect_ms)
			end
		end,
	})
	if job <= 0 then
		state.error = "could not start tandem; install the CLI or set command"
		emit()
		vim.defer_fn(connect, state.options.reconnect_ms)
		return
	end
	state.job = job
	local dirty = {}
	for path in pairs(state.dirty) do
		table.insert(dirty, path)
	end
	-- Neovim encodes an ordinary empty Lua table as JSON [].
	send({
		method = "hello",
		protocol = 1,
		owner = state.owner,
		dirty = dirty,
		herdr = {
			socket = vim.env.HERDR_SOCKET_PATH,
			workspace = vim.env.HERDR_WORKSPACE_ID,
			tab = vim.env.HERDR_TAB_ID,
			pane = vim.env.HERDR_PANE_ID,
		},
	})
end

function M.status()
	local files = {}
	for path in pairs(state.dirty) do
		table.insert(files, path)
	end
	table.sort(files)
	return { connected = state.ready, owner = state.owner, root = state.root, dirty = files, error = state.error }
end

function M.statusline()
	if not state.ready then
		return "tandem: offline"
	end
	local count = #M.status().dirty
	return count > 0 and ("tandem: editing " .. count) or "tandem: ready"
end

function M.codex_args(options)
	return require("tandem.codex").args({
		connected = state.ready,
		root = state.root,
		command = state.options and state.options.command,
		state_home = state.options and state.options.state_home,
	}, options)
end

function M.setup(options)
	if not state.stopped then
		return
	end
	state.options = vim.tbl_extend("force", { command = "tandem", reconnect_ms = 1000 }, options or {})
	local argument = vim.fn.argv(0)
	local argument_root = type(argument) == "string" and argument ~= "" and vim.fs.root(argument, ".git") or nil
	local root = state.options.root
		or vim.fs.root(0, ".git")
		or argument_root
		or vim.fs.root(uv.cwd(), ".git")
		or uv.cwd()
	state.root = normalize(uv.fs_realpath(root) or root)
	state.options.state_home = normalize(
		state.options.state_home
			or vim.env.XDG_STATE_HOME
			or ((vim.env.HOME or error("Set HOME or XDG_STATE_HOME")) .. "/.local/state")
	)
	state.owner = state.owner or ("nvim-" .. vim.fn.getpid() .. "-" .. tostring(uv.hrtime()))
	state.stopped = false
	state.recovery = require("tandem.recovery").new(cli_config(), function()
		if not state.stopped then
			return state.generation
		end
	end)
	local group = vim.api.nvim_create_augroup("Tandem", { clear = true })
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "BufNewFile", "BufFilePost" }, {
		group = group,
		callback = function(event)
			attach(event.buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufUnload", {
		group = group,
		callback = function(event)
			queue_unload(event.buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = group,
		callback = function(event)
			local path = buffer_path(event.buf)
			if path and not state.applying[event.buf] then
				claim(path, event.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWritePost", "BufModifiedSet" }, {
		group = group,
		callback = function(event)
			schedule_reconcile(event.buf)
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = shutdown,
	})
	vim.api.nvim_create_user_command("TandemStatus", function()
		state.recovery.status(M.status)
	end, {})
	vim.api.nvim_create_user_command("TandemRecover", function()
		state.recovery.recover()
	end, {})
	vim.api.nvim_create_user_command("TandemReconnect", function()
		if state.job then
			vim.fn.jobstop(state.job)
		else
			connect()
		end
	end, {})
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		attach(buf)
	end
	connect()
end

return M
