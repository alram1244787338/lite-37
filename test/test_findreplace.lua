#!/usr/bin/env lua
-- Regression tests for findreplace.lua state management.
-- Run:  lua test/test_findreplace.lua
--
-- Tests cover:
--   1. First-time previous-find without any prior find (no crash, clean error)
--   2. Same-document multiple finds then previous-find (correct LIFO order)
--   3. Switch document then previous-find (clear message, no history bleed)
--   4. repeat-find then previous-find (history chain intact)
--   5. New find session clears old history (intentional reset)
--   6. max_previous_finds cap (oldest entries evicted)

local passed, failed = 0, 0

local function assert_eq(label, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("  FAIL [%s]: got %s, want %s\n",
      label, tostring(got), tostring(want)))
  end
end

local function assert_true(label, val)
  assert_eq(label, not not val, true)
end

------------------------------------------------------------------------
-- Mock layer
------------------------------------------------------------------------

-- We track the last error message instead of printing to lite-xl's log.
local last_error = nil

-- Mock document object
local function make_doc(name)
  local d = {
    _name = name,
    _sel  = { 1, 1, 1, 1 },
  }
  function d:get_selection(...)
    return table.unpack(self._sel)
  end
  function d:set_selection(...)
    self._sel = { ... }
  end
  function d:get_text(...)
    return "mock"
  end
  function d:has_selection()
    local s = self._sel
    return s[1] ~= s[3] or s[2] ~= s[4]
  end
  function d:replace(fn)
    return 0
  end
  return d
end

-- Active view mock (DocView-like)
local active_doc = make_doc("doc_A")
local active_view = {
  doc = active_doc,
  _scroll_log = {},
}
function active_view:is(cls)
  return cls == "DocView"
end
function active_view:scroll_to_line(line, ...)
  table.insert(self._scroll_log, line)
end
function active_view:scroll_to_make_visible(...) end

-- Command view mock — captures the on_confirm / on_change / on_cancel
local command_view = {
  _text = "",
}
function command_view:set_text(t, select_all)
  self._text = t
end
function command_view:enter(label, on_confirm, on_change, on_cancel)
  self._on_confirm = on_confirm
  self._on_change  = on_change
  self._on_cancel  = on_cancel
  self._label      = label
end

-- Captured command table
local commands = {}

------------------------------------------------------------------------
-- Inject mocks via package.preload BEFORE requiring findreplace
------------------------------------------------------------------------

package.preload["core"] = function()
  return {
    active_view  = active_view,
    command_view = command_view,
    error = function(fmt, ...)
      last_error = string.format(fmt, ...)
    end,
    log = function() end,
  }
end

package.preload["core.command"] = function()
  return {
    add = function(predicate_or_name, tbl)
      for name, fn in pairs(tbl) do
        commands[name] = fn
      end
    end,
  }
end

package.preload["core.config"] = function()
  return {
    symbol_pattern = "[%a_][%w_]*",
  }
end

package.preload["core.doc.search"] = function()
  -- We control search results via this table; tests set it per-case.
  local m = { _next = nil }
  function m.find(doc, line, col, text, opt)
    if m._next then
      local r = m._next
      m._next = nil
      return table.unpack(r)
    end
    return nil
  end
  return m
end

package.preload["core.docview"] = function()
  return "DocView"   -- just a sentinel; is() checks against this string
end

------------------------------------------------------------------------
-- Load the module under test
------------------------------------------------------------------------

-- Resolve path relative to this script
local script_dir = arg[0]:match("(.*/)") or ""
package.path = script_dir .. "../data/?.lua;"
            .. script_dir .. "../data/?/init.lua;"
            .. package.path

dofile(script_dir .. "../data/core/commands/findreplace.lua")

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function reset_state()
  active_doc = make_doc("doc_A")
  active_view.doc = active_doc
  active_view._scroll_log = {}
  last_error = nil
end

-- Simulate a successful find: inject search result, drive the command_view
-- callbacks as lite-xl would.
local function simulate_find(search_result)
  local search_mod = require "core.doc.search"
  search_mod._next = search_result   -- e.g. { 5, 1, 5, 10 }

  -- Invoke the find command
  commands["find-replace:find"]()

  -- Drive on_change (incremental preview) — triggers the found flag
  command_view._on_change("mock")

  -- Drive on_confirm (user presses Enter)
  command_view._on_confirm("mock")
end

-- Simulate repeat-find
local function simulate_repeat_find(search_result)
  local search_mod = require "core.doc.search"
  search_mod._next = search_result
  commands["find-replace:repeat-find"]()
end

------------------------------------------------------------------------
-- TEST 1: First-time previous-find with no prior find
------------------------------------------------------------------------

reset_state()
print("TEST 1: previous-find with no history (cold start)")

commands["find-replace:previous-find"]()
assert_eq("1.1 error message", last_error, "No previous find results")
-- Must NOT have crashed — if we got here, that's already verified.
assert_true("1.1 no crash", true)

------------------------------------------------------------------------
-- TEST 2: Same-doc multiple finds then previous-find (LIFO)
------------------------------------------------------------------------

reset_state()
print("TEST 2: multiple finds then previous-find")

-- Find #1: result at line 5
simulate_find({ 5, 1, 5, 10 })
-- After find: previous_finds has [{1,1,1,1}] (initial sel), cursor at line 5

-- Move cursor to result and do repeat-find #2: result at line 10
active_doc._sel = { 5, 10, 5, 10 }
simulate_repeat_find({ 10, 1, 10, 8 })
-- previous_finds now: [{1,1,1,1}, {5,10,5,10}]

-- repeat-find #3: result at line 20
active_doc._sel = { 10, 8, 10, 8 }
simulate_repeat_find({ 20, 1, 20, 5 })
-- previous_finds now: [{1,1,1,1}, {5,10,5,10}, {10,8,10,8}]

-- Now previous-find should walk back in LIFO order
last_error = nil
commands["find-replace:previous-find"]()
assert_eq("2.1 no error", last_error, nil)
assert_eq("2.2 jumped to line 10", active_doc._sel[1], 10)

last_error = nil
commands["find-replace:previous-find"]()
assert_eq("2.3 no error", last_error, nil)
assert_eq("2.4 jumped to line 5", active_doc._sel[1], 5)

last_error = nil
commands["find-replace:previous-find"]()
assert_eq("2.5 no error", last_error, nil)
assert_eq("2.6 jumped to line 1 (origin)", active_doc._sel[1], 1)

-- History should now be empty
commands["find-replace:previous-find"]()
assert_eq("2.7 exhausted history gives error", last_error, "No previous find results")

------------------------------------------------------------------------
-- TEST 3: Switch document then previous-find
------------------------------------------------------------------------

reset_state()
print("TEST 3: switch document then previous-find")

-- Build up history in doc_A
simulate_find({ 5, 1, 5, 10 })
active_doc._sel = { 5, 10, 5, 10 }
simulate_repeat_find({ 10, 1, 10, 8 })

-- Switch to doc_B
local doc_b = make_doc("doc_B")
active_view.doc = doc_b

last_error = nil
commands["find-replace:previous-find"]()
assert_eq("3.1 doc-switch error", last_error, "No previous find results in this document")
-- History of doc_A should NOT have been popped
assert_eq("3.2 still on doc_B", active_view.doc._name, "doc_B")

-- Switch back to doc_A — history should still be intact
active_view.doc = active_doc
last_error = nil
commands["find-replace:previous-find"]()
assert_eq("3.3 no error after switching back", last_error, nil)
assert_eq("3.4 history preserved at line 5", active_doc._sel[1], 5)

------------------------------------------------------------------------
-- TEST 4: repeat-find then previous-find chain
------------------------------------------------------------------------

reset_state()
print("TEST 4: repeat-find then previous-find chain")

simulate_find({ 3, 1, 3, 5 })
active_doc._sel = { 3, 5, 3, 5 }
simulate_repeat_find({ 7, 1, 7, 5 })
active_doc._sel = { 7, 5, 7, 5 }
simulate_repeat_find({ 12, 1, 12, 5 })

-- Previous should go 12 -> 7 -> 3 -> 1
commands["find-replace:previous-find"]()
assert_eq("4.1 back to line 7", active_doc._sel[1], 7)

commands["find-replace:previous-find"]()
assert_eq("4.2 back to line 3", active_doc._sel[1], 3)

commands["find-replace:previous-find"]()
assert_eq("4.3 back to origin line 1", active_doc._sel[1], 1)

commands["find-replace:previous-find"]()
assert_eq("4.4 exhausted", last_error, "No previous find results")

------------------------------------------------------------------------
-- TEST 5: New find session clears old history
------------------------------------------------------------------------

reset_state()
print("TEST 5: new find clears old history")

-- Build history
simulate_find({ 5, 1, 5, 10 })
active_doc._sel = { 5, 10, 5, 10 }
simulate_repeat_find({ 10, 1, 10, 8 })

-- Start a brand new find — should wipe history
simulate_find({ 30, 1, 30, 5 })

-- Old positions (line 5, 10) should be gone; only origin of new find remains
last_error = nil
commands["find-replace:previous-find"]()
-- The new find saves the starting sel (which was {5,10,5,10} from before the new find)
-- but the old repeat-find history is gone.
assert_eq("5.1 no error (origin saved)", last_error, nil)

-- Second previous-find should fail (only 1 entry from new find)
commands["find-replace:previous-find"]()
assert_eq("5.2 old history cleared", last_error, "No previous find results")

------------------------------------------------------------------------
-- TEST 6: max_previous_finds cap
------------------------------------------------------------------------

reset_state()
print("TEST 6: history cap at 50")

simulate_find({ 1, 1, 1, 5 })
-- Push 60 entries via repeat-find
for i = 2, 61 do
  active_doc._sel = { i, 1, i, 1 }
  simulate_repeat_find({ i + 1, 1, i + 1, 5 })
end

-- Count how many previous-finds succeed before exhaustion
local count = 0
last_error = nil
while true do
  commands["find-replace:previous-find"]()
  if last_error then break end
  count = count + 1
  last_error = nil
end
-- Should be capped at 50
assert_eq("6.1 cap at 50", count, 50)

------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
else
  print("All tests passed.")
end
