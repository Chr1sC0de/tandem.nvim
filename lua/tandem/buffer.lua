local M = {}

local function failure(code, message)
  return { ok = false, error = { code = code, message = message } }
end

-- The validation and write run in one scheduled, non-yielding editor callback.
-- No separate Rust-side check can substitute for this live-buffer check.
function M.apply(event, context)
  if context.now_ms() >= event.expires_ms then
    return failure("expired", "write expired before the editor could handle it")
  end
  local path, path_error = context.validate_path(event.path)
  if not path then return failure("invalid_path", path_error) end
  local buf = context.find_buffer(path)
  if buf and context.modified(buf) then
    context.claim(path)
    return failure("busy", "human has unsaved changes")
  end
  local current, read_error = context.disk(path)
  if not current then return failure("read_failed", read_error) end
  if current.revision ~= event.expected_revision then
    return failure("stale_revision", "file changed; reread and regenerate the edit")
  end
  local content = event.content
  if type(content) ~= "string" or #content > 1024 * 1024 or content:find("%z") or content:find("\r", 1, true) then
    return failure("unsupported_text", "expected UTF-8 text with Unix newlines, no NUL, at most 1 MiB")
  end
  local valid, why = context.valid_text(content)
  if not valid then return failure("unsupported_text", why) end
  if not buf then buf = context.load(path) end
  -- Loading can run user autocmds. Recheck after them before changing anything.
  if context.modified(buf) then
    context.claim(path)
    return failure("busy", "buffer changed while loading")
  end
  local supported, reason = context.supported(buf)
  if not supported then return failure("unsupported_buffer", reason) end
  -- BufRead autocmds may also have changed the file itself.
  current, read_error = context.disk(path)
  if not current then return failure("read_failed", read_error) end
  if current.revision ~= event.expected_revision then
    return failure("stale_revision", "file changed while loading; reread and regenerate the edit")
  end
  if not context.matches(buf, current.content) then
    return failure("buffer_out_of_sync", "clean buffer differs from disk; reload before retrying")
  end
  if context.now_ms() >= event.expires_ms then
    return failure("expired", "write expired while loading")
  end
  local ok, err = pcall(context.write, buf, content)
  if not ok then
    if context.modified(buf) then context.claim(path) end
    return failure("write_failed", tostring(err))
  end
  if context.modified(buf) then
    context.claim(path)
    return failure("write_failed", "buffer remains modified after save")
  end
  local saved, saved_error = context.disk(path)
  if not saved then return failure("outcome_unknown", saved_error) end
  if not context.matches(buf, saved.content) then
    return failure("outcome_unknown", "buffer and saved file differ; inspect before retrying")
  end
  context.saved(path)
  return { ok = true, path = event.relative_path, revision = saved.revision }
end

return M
