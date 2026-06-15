local core = require "core"
local config = require "core.config"
local Doc = require "core.doc"


local times = setmetatable({}, { __mode = "k" })
-- docs whose file we've already reported as missing, so the "no longer
-- accessible" notice is logged once per disappearance instead of every scan
local missing = setmetatable({}, { __mode = "k" })


local function get_mtime(filename)
  if not filename then return nil end
  -- system.get_file_info returns `nil, err` when the path can't be stat'd
  -- (deleted, renamed, momentarily unreadable); never let that throw
  local info = system.get_file_info(filename)
  return info and info.modified
end


local function update_time(doc)
  -- record the on-disk mtime the in-memory contents now correspond to; a nil
  -- result (file gone) is stored as-is and simply means "nothing to compare yet"
  times[doc] = get_mtime(doc.filename)
end


local function reload_doc(doc)
  local fp = io.open(doc.filename, "r")
  if not fp then return false end
  local text = fp:read("*a")
  fp:close()
  if not text then return false end

  local sel = { doc:get_selection() }
  doc:remove(1, 1, math.huge, math.huge)
  doc:insert(1, 1, text:gsub("\r", ""):gsub("\n$", ""))
  doc:set_selection(table.unpack(sel))

  update_time(doc)
  doc:clean()
  core.log_quiet("Auto-reloaded doc \"%s\"", doc.filename)
  return true
end


local function check_doc(doc)
  local filename = doc.filename
  if not filename then return end

  local mtime = get_mtime(filename)

  -- file is gone / renamed / momentarily unreadable: report the transition once,
  -- keep the last known mtime so we re-sync if it comes back, never touch the buffer
  if not mtime then
    if not missing[doc] then
      missing[doc] = true
      core.log_quiet("File \"%s\" is no longer accessible; auto-reload paused", filename)
    end
    return
  end

  if missing[doc] then
    missing[doc] = nil
    core.log_quiet("File \"%s\" is accessible again", filename)
  end

  if times[doc] == mtime then return end

  -- external change with unsaved local edits: don't clobber the user's work.
  -- Warn visibly and acknowledge the new mtime so we only nag once per change.
  if doc:is_dirty() then
    times[doc] = mtime
    core.error("File \"%s\" changed on disk but has unsaved changes; not auto-reloaded", filename)
    return
  end

  if not reload_doc(doc) then
    core.log_quiet("File \"%s\" could not be read for auto-reload", filename)
  end
end


core.add_thread(function()
  while true do
    -- check all doc modified times; isolate each doc so a single bad file can't
    -- take the whole auto-reload thread down
    for _, doc in ipairs(core.docs) do
      core.try(check_doc, doc)
      coroutine.yield()
    end

    -- wait for next scan
    coroutine.yield(config.project_scan_rate)
  end
end)


-- patch `Doc.save|load` to store modified time
local load = Doc.load
local save = Doc.save

Doc.load = function(self, ...)
  local res = load(self, ...)
  update_time(self)
  missing[self] = nil
  return res
end

Doc.save = function(self, ...)
  local res = save(self, ...)
  update_time(self)
  missing[self] = nil
  return res
end
