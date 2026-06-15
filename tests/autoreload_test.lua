-- Lightweight regression test for data/plugins/autoreload.lua
--
-- It stubs the minimal editor surface (system, core, config, core.doc) and then
-- loads the REAL plugin file, capturing the scan thread it registers and driving
-- it by hand. File mtimes are emulated deterministically so the test never
-- depends on filesystem timestamp granularity.
--
-- Run from the repo root:   lua tests/autoreload_test.lua
-- Exit code is non-zero if any check fails.

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then
    passed = passed + 1
    print("ok   - " .. msg)
  else
    failed = failed + 1
    print("FAIL - " .. msg)
  end
end


----------------------------------------------------------------------
-- Deterministic file layer: real bytes on disk for io.open, but mtimes
-- are tracked in a table so we control exactly when a "change" is seen.
----------------------------------------------------------------------
local mtimes = {}

local function write_file(path, content)
  local fp = assert(io.open(path, "wb"))
  fp:write(content)
  fp:close()
  mtimes[path] = (mtimes[path] or 0) + 1
end

local function delete_file(path)
  os.remove(path)
  mtimes[path] = nil
end

system = {
  get_file_info = function(path)
    local m = mtimes[path]
    if not m then return nil, "No such file or directory" end
    return { modified = m, size = 0, type = "file" }
  end,
}


----------------------------------------------------------------------
-- Fake Doc. Models just enough text/selection/dirty state for the plugin.
-- load/save must exist BEFORE the plugin is loaded so it can wrap them.
----------------------------------------------------------------------
local function normalize(text)
  return (text:gsub("\r", ""):gsub("\n$", ""))
end

local Doc = {}
Doc.__index = Doc

function Doc:load(filename)
  local fp = assert(io.open(filename, "rb"))
  local text = fp:read("*a")
  fp:close()
  self.filename = filename
  self.text = normalize(text)
  self.dirty = false
end

function Doc:save(filename)
  filename = filename or self.filename
  write_file(filename, self.text .. "\n")
  self.filename = filename
  self.dirty = false
end

function Doc:get_selection()
  local s = self.selection
  return s[1], s[2], s[3], s[4]
end

function Doc:set_selection(a, b, c, d)
  self.selection = { a, b, c or a, d or b }
end

function Doc:remove() self.text = ""; self.dirty = true end
function Doc:insert(_, _, text) self.text = (self.text or "") .. text; self.dirty = true end
function Doc:clean() self.dirty = false end
function Doc:is_dirty() return self.dirty == true end


----------------------------------------------------------------------
-- Fake core / config. Logs are recorded with their level so the test can
-- assert which of the three states (reloaded / skipped / unavailable) fired.
----------------------------------------------------------------------
local logs = {}
local function clear_logs() for i = #logs, 1, -1 do logs[i] = nil end end
local function count_logs(level, pat)
  local n = 0
  for _, e in ipairs(logs) do
    if (not level or e.level == level) and e.msg:find(pat, 1, true) then n = n + 1 end
  end
  return n
end

local captured_thread
local core = { docs = {} }
function core.log(...)       logs[#logs + 1] = { level = "log",   msg = string.format(...) } end
function core.log_quiet(...) logs[#logs + 1] = { level = "quiet", msg = string.format(...) } end
function core.error(...)     logs[#logs + 1] = { level = "error", msg = string.format(...) } end
function core.try(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then core.error("%s", err); return false, err end
  return true
end
function core.add_thread(fn) captured_thread = fn end

local config = { project_scan_rate = 0.25 }

package.loaded["core"] = core
package.loaded["core.config"] = config
package.loaded["core.doc"] = Doc


----------------------------------------------------------------------
-- Load the real plugin and grab its scan thread.
----------------------------------------------------------------------
local function script_dir()
  local s = arg and arg[0] or ""
  return s:match("^(.*)[/\\]") or "."
end
local plugin_path = script_dir() .. "/../data/plugins/autoreload.lua"

assert(loadfile(plugin_path), "could not load plugin at " .. plugin_path)()
assert(captured_thread, "plugin did not register a scan thread")

local co = coroutine.create(captured_thread)

-- Resume the thread until it finishes one full scan pass (it yields the
-- scan-rate value at the end of each pass). Asserts the thread never dies.
local function run_scan_pass()
  while true do
    local ok, val = coroutine.resume(co)
    assert(ok, "auto-reload thread crashed: " .. tostring(val))
    assert(coroutine.status(co) ~= "dead", "auto-reload thread terminated")
    if val == config.project_scan_rate then break end
  end
end

local function new_doc(filename)
  local doc = setmetatable({ selection = { 1, 1, 1, 1 }, dirty = false }, Doc)
  Doc.load(doc, filename) -- patched: also seeds the recorded mtime
  return doc
end


----------------------------------------------------------------------
-- Scenario 1: normal external modification is reloaded, selection kept.
----------------------------------------------------------------------
local fA = os.tmpname()
write_file(fA, "hello\nworld\n")
local docA = new_doc(fA)
table.insert(core.docs, docA)
docA.selection = { 1, 3, 1, 3 }

clear_logs()
write_file(fA, "HELLO\nWORLD\nNEW\n")
run_scan_pass()

check(docA.text == "HELLO\nWORLD\nNEW", "S1: external change reloaded")
check(docA.dirty == false, "S1: doc is clean after reload")
local s = docA.selection
check(s[1] == 1 and s[2] == 3 and s[3] == 1 and s[4] == 3, "S1: selection preserved")
check(count_logs("quiet", "Auto-reloaded") == 1, "S1: logged a normal auto-reload")


----------------------------------------------------------------------
-- Scenario 2: file deleted/renamed away -> thread survives, logged once,
-- buffer untouched; when it reappears it reloads again.
----------------------------------------------------------------------
clear_logs()
local before2 = docA.text
delete_file(fA)
run_scan_pass()
run_scan_pass() -- second pass proves survival + "log once"

check(docA.text == before2, "S2: buffer untouched while file missing")
check(count_logs(nil, "no longer accessible") == 1, "S2: missing file logged exactly once")

write_file(fA, "BACK\n") -- e.g. an external rename/atomic-save puts it back
run_scan_pass()

check(count_logs(nil, "accessible again") == 1, "S2: reappearance logged")
check(docA.text == "BACK", "S2: reloaded after file reappeared")


----------------------------------------------------------------------
-- Scenario 3: doc has unsaved edits and the file changes on disk ->
-- not clobbered, warned visibly, and only nagged once.
----------------------------------------------------------------------
local fB = os.tmpname()
write_file(fB, "draft\n")
local docB = new_doc(fB)
table.insert(core.docs, docB)
docB.text = "local unsaved content"
docB.dirty = true

clear_logs()
write_file(fB, "EXTERNAL CHANGE\n")
local before3 = docB.text
run_scan_pass()

check(docB.text == before3, "S3: unsaved content NOT overwritten")
check(docB.dirty == true, "S3: doc stays dirty")
check(count_logs("error", "unsaved changes") == 1, "S3: warned about the conflict (visible log)")

run_scan_pass()
check(docB.text == before3, "S3: still not overwritten on a later scan")
check(count_logs("error", "unsaved changes") == 1, "S3: conflict warned only once")


----------------------------------------------------------------------
delete_file(fA)
delete_file(fB)
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
