-- Regression harness for data/plugins/projectsearch.lua
--
-- Reproduces the project-search concurrency bug and verifies the fix without a
-- GUI. It stubs the minimal lite runtime (Object/View class system + the
-- cooperative thread scheduler from core/init.lua) so the *real* plugin code is
-- exercised unmodified, then drives the four required regression scenarios:
--
--   A. rapid consecutive refresh (refresh while a previous scan is in flight)
--   B. different keywords searched consecutively
--   C. opening a result while a scan is running / across a refresh
--   D. refreshing again after a scan has fully completed
--
-- Scenario E is a *negative control*: it replays the legacy (buggy) search loop
-- through the very same driver and asserts that it DOES corrupt the result set,
-- proving the scenarios above are genuinely adversarial and the green checks
-- mean something.
--
-- Run from the repository root:
--     lua tests/projectsearch_concurrency_spec.lua
-- Optional arg: path to the plugin (defaults to data/plugins/projectsearch.lua).
-- Exits non-zero if any assertion fails.

local PLUGIN_PATH = arg and arg[1] or "data/plugins/projectsearch.lua"

--------------------------------------------------------------------------------
-- tiny test framework
--------------------------------------------------------------------------------
local failures, checks = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if cond then
    print(string.format("  ok   - %s", msg))
  else
    failures = failures + 1
    print(string.format("  FAIL - %s", msg))
  end
end
local function eq(a, b, msg)
  check(a == b, string.format("%s (expected %s, got %s)", msg, tostring(b), tostring(a)))
end

-- unique "file:line:col" key set; returns count and whether any duplicate seen
local function audit(results)
  local seen, dups = {}, 0
  for _, r in ipairs(results) do
    local key = string.format("%s:%d:%s", r.file, r.line, tostring(r.col))
    if seen[key] then dups = dups + 1 end
    seen[key] = true
  end
  return #results, dups
end

local function all_match(results, query)
  local q = query:lower()
  for _, r in ipairs(results) do
    if not r.text:lower():find(q, nil, true) then return false end
  end
  return true
end

--------------------------------------------------------------------------------
-- class system (verbatim from data/core/object.lua) + a minimal View stub
--------------------------------------------------------------------------------
local Object = {}
Object.__index = Object
function Object:new() end
function Object:extend()
  local cls = {}
  for k, v in pairs(self) do
    if k:find("__") == 1 then cls[k] = v end
  end
  cls.__index = cls
  cls.super = self
  setmetatable(cls, self)
  return cls
end
function Object:__call(...)
  local obj = setmetatable({}, self)
  obj:new(...)
  return obj
end

local common = {
  lerp = function(a, b, t) return a + (b - a) * t end,
  draw_text = function(_, _, _, _, x) return x end,
  fuzzy_match = function(_, _) return true end,
}

local View = Object:extend()
function View:new()
  self.position = { x = 0, y = 0 }
  self.size = { x = 100, y = 100 }
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }
  self.cursor = "arrow"
  self.scrollable = false
end
function View:move_towards(t, k, dest, rate)
  if type(t) ~= "table" then return self:move_towards(self, t, k, dest) end
  t[k] = common.lerp(t[k], dest, rate or 0.5)
end
function View:update() end
function View:on_mouse_moved() end
function View:on_mouse_pressed() return false end
function View:get_content_offset() return 0, 0 end

--------------------------------------------------------------------------------
-- cooperative scheduler mirroring data/core/init.lua run_threads/add_thread
--------------------------------------------------------------------------------
local core = {}
core.redraw = false
core.project_files = {}

function core.try(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then io.stderr:write("core.try caught: " .. tostring(err) .. "\n") end
  return ok, err
end

-- ordered thread list so the *older* (potentially stale) thread is always
-- resumed before the newer one - exactly the dangerous interleaving.
local scheduler = { threads = {} }
function core.add_thread(f, weak_ref)
  local wrapped = function() return core.try(f) end
  scheduler.threads[#scheduler.threads + 1] =
    { cr = coroutine.create(wrapped), key = weak_ref }
end

local function alive(e) return coroutine.status(e.cr) ~= "dead" end

-- resume every currently-alive thread exactly once (one scheduler "frame")
function scheduler.step()
  local snapshot = {}
  for i, e in ipairs(scheduler.threads) do snapshot[i] = e end
  local ran = false
  for _, e in ipairs(snapshot) do
    if alive(e) then
      assert(coroutine.resume(e.cr))
      ran = true
    end
  end
  local live = {}
  for _, e in ipairs(scheduler.threads) do
    if alive(e) then live[#live + 1] = e end
  end
  scheduler.threads = live
  return ran
end

function scheduler.run_to_idle()
  local guard = 0
  while scheduler.step() do
    guard = guard + 1
    assert(guard < 100000, "scheduler did not settle")
  end
end

function scheduler.reset() scheduler.threads = {} end

--------------------------------------------------------------------------------
-- fake filesystem + project files
--------------------------------------------------------------------------------
local file_lines = {}
io.open = function(name) -- luacheck: ignore
  local lines = file_lines[name]
  if not lines then return nil end
  local idx = 0
  return {
    lines = function()
      return function()
        idx = idx + 1
        return lines[idx]
      end
    end,
    close = function() end,
  }
end

-- 120 lines per file so each file forces a coroutine.yield (every 100 lines),
-- guaranteeing we can suspend a scan mid-file. "alpha" wins ties over "beta".
local function make_lines(n)
  local t = {}
  for i = 1, n do
    if i % 10 == 0 then
      t[i] = "alpha match at " .. i
    elseif i % 15 == 0 then
      t[i] = "beta target at " .. i
    else
      t[i] = "plain noise line " .. i
    end
  end
  return t
end

local function seed_project()
  core.project_files = {}
  file_lines = {}
  for _, name in ipairs({ "f1", "f2", "f3" }) do
    file_lines[name] = make_lines(120)
    core.project_files[#core.project_files + 1] = { filename = name, type = "file" }
  end
end

local function expected(query)
  local q = query:lower()
  local c = 0
  for _, f in ipairs(core.project_files) do
    for _, line in ipairs(file_lines[f.filename]) do
      if line:lower():find(q, nil, true) then c = c + 1 end
    end
  end
  return c
end

--------------------------------------------------------------------------------
-- remaining stub surface used by the plugin
--------------------------------------------------------------------------------
local captured_view
local opened -- records the last opened result {file,line,col}

core.command_view = {
  enter = function(self, _, submit) self._submit = submit end,
}
local function type_and_submit(text)
  assert(core.command_view._submit, "no pending command_view input")
  local cb = core.command_view._submit
  core.command_view._submit = nil
  cb(text)
  return captured_view
end

core.open_doc = function(file) return { __file = file } end
core.root_view = {
  get_active_node = function()
    return { add_view = function(_, rv) captured_view = rv end }
  end,
  open_doc = function(_, doc)
    return {
      doc = {
        set_selection = function(_, l, c) opened = { file = doc.__file, line = l, col = c } end,
      },
      scroll_to_line = function() end,
    }
  end,
  root_node = { update_layout = function() end },
}
core.error = function(...) io.stderr:write("core.error: " .. string.format(...) .. "\n") end

local commands = {}
local command = {
  add = function(_, map)
    for name, fn in pairs(map) do commands[name] = fn end
  end,
}
local keymap = { add = function() end }
local style = setmetatable({ font = { get_height = function() return 10 end } },
  { __index = function() return 0 end })

package.loaded["core"] = core
package.loaded["core.common"] = common
package.loaded["core.command"] = command
package.loaded["core.keymap"] = keymap
package.loaded["core.style"] = style
package.loaded["core.view"] = View
package.loaded["core.object"] = Object

--------------------------------------------------------------------------------
-- load the real plugin under test
--------------------------------------------------------------------------------
local chunk, err = loadfile(PLUGIN_PATH)
assert(chunk, "could not load plugin: " .. tostring(err))
chunk()

--------------------------------------------------------------------------------
-- Scenario A: rapid consecutive refresh while a scan is in flight
--------------------------------------------------------------------------------
print("Scenario A: rapid refresh does not pollute results")
do
  seed_project(); scheduler.reset(); captured_view = nil
  commands["project-search:find"]()
  local view = type_and_submit("alpha")
  eq(view.search_id, 1, "first search is generation 1")

  scheduler.step() -- gen1 thread suspends mid-file1 with partial results
  check(#view.results > 0 and view.searching, "gen1 scan is in progress when interrupted")

  view:refresh() -- gen2 starts; gen1 thread is now stale
  eq(view.search_id, 2, "refresh advances to generation 2")
  eq(#view.results, 0, "refresh resets the visible result set")

  scheduler.run_to_idle()

  local n, dups = audit(view.results)
  eq(view.search_id, 2, "current generation is 2 after settle")
  eq(view.searching, false, "search reports completed")
  eq(view.brightness, 100, "completion brightness set by the finishing query")
  eq(view.last_file_idx, #core.project_files, "progress reaches 100%")
  eq(dups, 0, "no duplicate (stale) matches leaked in")
  eq(n, expected("alpha"), "result count matches exactly one clean scan")
  check(all_match(view.results, "alpha"), "every result matches the current query")
end

--------------------------------------------------------------------------------
-- Scenario B: different keywords searched consecutively
--------------------------------------------------------------------------------
print("Scenario B: consecutive different-keyword searches stay isolated")
do
  seed_project(); scheduler.reset(); captured_view = nil
  commands["project-search:find"]()
  local view_alpha = type_and_submit("alpha")
  scheduler.step() -- leave the alpha scan running

  commands["project-search:find"]()
  local view_beta = type_and_submit("beta")
  check(view_alpha ~= view_beta, "each keyword search gets its own view")
  scheduler.run_to_idle()

  local na, da = audit(view_alpha.results)
  local nb, db = audit(view_beta.results)
  eq(da, 0, "alpha view has no duplicates")
  eq(db, 0, "beta view has no duplicates")
  eq(na, expected("alpha"), "alpha view holds exactly its own matches")
  eq(nb, expected("beta"), "beta view holds exactly its own matches")
  check(all_match(view_alpha.results, "alpha"), "alpha view free of beta results")
  check(all_match(view_beta.results, "beta"), "beta view free of alpha results")
  eq(view_beta.query, "beta", "beta view reports the beta query")
end

--------------------------------------------------------------------------------
-- Scenario C: opening a result mid-scan and across a refresh
--------------------------------------------------------------------------------
print("Scenario C: opening results stays consistent during refresh")
do
  seed_project(); scheduler.reset(); captured_view = nil
  commands["project-search:find"]()
  local view = type_and_submit("alpha")
  scheduler.step() -- partial results available
  check(#view.results >= 3, "have enough partial results to select")

  view.selected_idx = 3
  local target = view.results[3]
  opened = nil
  view:open_selected_result()
  check(opened ~= nil, "selecting a valid row opens a document")
  eq(opened.file, target.file, "opens the file of the selected row")
  eq(opened.line, target.line, "jumps to the line of the selected row")
  eq(opened.col, target.col, "jumps to the column of the selected row")

  -- a refresh rebuilds the result set; a now-dangling selection must not open
  -- a wrong file or jump to a wrong line.
  view.selected_idx = 3
  view:refresh()
  eq(view.selected_idx, 0, "refresh clears the selection")
  opened = nil
  view:open_selected_result()
  check(opened == nil, "no file is opened against a rebuilt result set")

  scheduler.run_to_idle()
  local n, dups = audit(view.results)
  eq(dups, 0, "post-refresh results have no duplicates")
  eq(n, expected("alpha"), "post-refresh results are a single clean scan")
end

--------------------------------------------------------------------------------
-- Scenario D: refresh after a completed search
--------------------------------------------------------------------------------
print("Scenario D: refresh after completion re-runs cleanly")
do
  seed_project(); scheduler.reset(); captured_view = nil
  commands["project-search:find"]()
  local view = type_and_submit("alpha")
  scheduler.run_to_idle()
  eq(view.search_id, 1, "first scan is generation 1")
  eq(view.brightness, 100, "first scan completes with full brightness")
  eq(select(1, audit(view.results)), expected("alpha"), "first scan result count correct")

  view:refresh()
  eq(view.search_id, 2, "refresh advances generation")
  eq(view.searching, true, "refresh re-enters searching state")
  scheduler.run_to_idle()

  local n, dups = audit(view.results)
  eq(view.search_id, 2, "second scan is generation 2")
  eq(view.searching, false, "second scan completes")
  eq(view.brightness, 100, "second scan completes with full brightness")
  eq(dups, 0, "refreshed results have no duplicates")
  eq(n, expected("alpha"), "refreshed result count correct")
end

--------------------------------------------------------------------------------
-- Scenario E: negative control - the legacy loop MUST corrupt under the same
-- driver, proving the scenarios above actually exercise the race.
--------------------------------------------------------------------------------
print("Scenario E: negative control reproduces the legacy corruption")
do
  seed_project(); scheduler.reset()

  -- faithful reproduction of the original begin_search thread body: the scan
  -- writes through state.results, which a "refresh" reassigns out from under
  -- the still-running thread.
  local function legacy_find(t, filename, fn)
    local fp = io.open(filename)
    if not fp then return end
    local n = 1
    for line in fp:lines() do
      local s = fn(line)
      if s then t[#t + 1] = { file = filename, text = line, line = n, col = s } end
      if n % 100 == 0 then coroutine.yield() end
      n = n + 1
    end
    fp:close()
  end

  local state = { results = {}, searching = true }
  local pred = function(line) return line:lower():find("alpha", nil, true) end
  local function legacy_begin()
    state.results = {}
    state.searching = true
    core.add_thread(function()
      for _, file in ipairs(core.project_files) do
        if file.type == "file" then legacy_find(state.results, file.filename, pred) end
      end
      state.searching = false
    end, state.results)
  end

  legacy_begin()
  scheduler.step()  -- thread1 suspends mid-scan, having written into state.results
  legacy_begin()    -- "refresh": new table, but thread1 keeps writing to state.results
  scheduler.run_to_idle()

  local n, dups = audit(state.results)
  check(n > expected("alpha") or dups > 0,
    string.format("legacy loop corrupts results (count=%d, expected=%d, dups=%d)",
      n, expected("alpha"), dups))
end

--------------------------------------------------------------------------------
print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
