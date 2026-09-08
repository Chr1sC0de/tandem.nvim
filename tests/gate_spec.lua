package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local gate = require("tandem.buffer")
local tests = 0

local function fixture()
  local s = { modified = false, content = "base\n", revision = "v1", writes = 0, claims = 0, saves = 0, now = 10, loaded = true }
  local c = {
    now_ms = function() return s.now end,
    validate_path = function(path) return path end,
    find_buffer = function() return s.loaded and 1 or nil end,
    modified = function() return s.modified end,
    claim = function() s.claims = s.claims + 1 end,
    saved = function() s.saves = s.saves + 1 end,
    disk = function() return { content = s.content, revision = s.revision } end,
    valid_text = function() return true end,
    load = function() s.loaded = true; return 1 end,
    supported = function() return true end,
    matches = function() return true end,
    write = function(_, text)
      s.writes = s.writes + 1; s.content = text; s.revision = "v2"
    end,
  }
  local e = { path = "/project/a.rs", relative_path = "a.rs", content = "agent\n", expected_revision = "v1", expires_ms = 100 }
  return s, c, e
end

local function test(name, run)
  run(); tests = tests + 1; print("ok " .. tests .. " - " .. name)
end

test("agent edits apply and return the saved revision", function()
  local s, c, e = fixture()
  local result = gate.apply(e, c)
  assert(result.ok and result.revision == "v2")
  assert(s.writes == 1 and s.saves == 1)
end)
test("typing just before dispatch blocks without relying on a daemon lease", function()
  local s, c, e = fixture(); s.modified = true
  assert(gate.apply(e, c).error.code == "busy")
  assert(s.writes == 0 and s.claims == 1)
end)
test("human save invalidates an agent's old revision", function()
  local s, c, e = fixture(); s.revision = "human-saved"
  assert(gate.apply(e, c).error.code == "stale_revision")
  assert(s.writes == 0)
end)
test("autocmd edits during load are preserved", function()
  local s, c, e = fixture(); s.loaded = false
  c.load = function() s.modified = true; return 1 end
  assert(gate.apply(e, c).error.code == "busy")
  assert(s.writes == 0)
end)
test("autocmd disk writes during load invalidate the original revision", function()
  local s, c, e = fixture(); s.loaded = false
  c.load = function() s.revision = "saved-by-autocmd"; return 1 end
  assert(gate.apply(e, c).error.code == "stale_revision")
  assert(s.writes == 0)
end)
test("expired queued writes never run", function()
  local s, c, e = fixture(); s.now = 101
  assert(gate.apply(e, c).error.code == "expired")
  assert(s.writes == 0)
end)
test("save failures keep modified buffers leased", function()
  local s, c, e = fixture()
  c.write = function() s.modified = true; error("disk full") end
  assert(gate.apply(e, c).error.code == "write_failed")
  assert(s.claims == 1 and s.saves == 0)
end)
test("post-save formatter changes retain the lease", function()
  local s, c, e = fixture()
  c.write = function() s.modified = true end
  assert(gate.apply(e, c).error.code == "write_failed")
  assert(s.claims == 1 and s.saves == 0)
end)
test("clean buffers that differ from disk are not overwritten", function()
  local s, c, e = fixture(); c.matches = function() return false end
  assert(gate.apply(e, c).error.code == "buffer_out_of_sync")
  assert(s.writes == 0)
end)
test("unsafe paths and unsupported buffers are rejected", function()
  local s, c, e = fixture()
  c.validate_path = function() return nil, "outside project" end
  assert(gate.apply(e, c).error.code == "invalid_path")
  c.validate_path = function(p) return p end
  c.supported = function() return false, "readonly" end
  assert(gate.apply(e, c).error.code == "unsupported_buffer")
  assert(s.writes == 0)
end)
test("NUL, CRLF and oversized text do not reach the writer", function()
  local s, c, e = fixture()
  for _, content in ipairs({ "a\0b", "a\r\n", string.rep("a", 1024 * 1024 + 1) }) do
    e.content = content
    assert(gate.apply(e, c).error.code == "unsupported_text")
  end
  assert(s.writes == 0)
end)
test("empty files and non-ASCII text reach the writer intact", function()
  for _, text in ipairs({ "", "λ = 1\n", "no trailing newline" }) do
    local s, c, e = fixture(); e.content = text
    assert(gate.apply(e, c).ok and s.content == text)
  end
end)
test("saved bytes are checked after custom write handlers", function()
  local s, c, e = fixture()
  c.matches = function() return s.writes == 0 end
  assert(gate.apply(e, c).error.code == "outcome_unknown")
  assert(s.saves == 0)
end)

for _, path in ipairs({ "lua/tandem/init.lua", "lua/tandem/buffer.lua", "lua/tandem/health.lua" }) do
  assert(loadfile(path))
end
print("passed " .. tests .. " gateway tests; all plugin modules parse")
