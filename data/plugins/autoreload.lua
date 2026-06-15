local core = require "core"
local config = require "core.config"
local Doc = require "core.doc"


local times = setmetatable({}, { __mode = "k" })
local dirty_warned = setmetatable({}, { __mode = "k" })


local function update_time(doc)
  if not doc.filename then return end
  local ok, info = pcall(system.get_file_info, doc.filename)
  if ok and info then
    times[doc] = info.modified
  end
end


local function file_readable(filename)
  if not filename then return false end
  local fp = io.open(filename, "rb")
  if fp then
    fp:close()
    return true
  end
  return false
end


local function reload_doc(doc)
  -- Do not overwrite unsaved changes
  if doc:is_dirty() then
    if not dirty_warned[doc] then
      core.log_quiet(
        "Auto-reload skipped for \"%s\": unsaved changes", doc.filename
      )
      dirty_warned[doc] = true
    end
    -- Keep tracking external mtime so reload triggers after user saves
    update_time(doc)
    return
  end

  dirty_warned[doc] = nil

  -- File may have been deleted or become unreadable
  if not file_readable(doc.filename) then
    core.log_quiet(
      "Auto-reload skipped for \"%s\": file not readable", doc.filename
    )
    return
  end

  local fp, err = io.open(doc.filename, "rb")
  if not fp then
    core.log_quiet(
      "Auto-reload skipped for \"%s\": %s", doc.filename, err or "open failed"
    )
    return
  end

  local text = fp:read("*a")
  fp:close()

  if not text then
    core.log_quiet(
      "Auto-reload skipped for \"%s\": read failed", doc.filename
    )
    return
  end

  -- Preserve cursor/selection across reload
  local sel = { doc:get_selection() }

  doc:remove(1, 1, math.huge, math.huge)
  doc:insert(1, 1, text:gsub("\r", ""):gsub("\n$", ""))
  doc:set_selection(table.unpack(sel))

  update_time(doc)
  doc:clean()
  core.log_quiet("Auto-reloaded doc \"%s\"", doc.filename)
end


core.add_thread(function()
  while true do
    for _, doc in ipairs(core.docs) do
      if doc.filename then
        local ok, err = pcall(function()
          local ok2, info = pcall(system.get_file_info, doc.filename)
          if ok2 and info and times[doc] ~= info.modified then
            reload_doc(doc)
          end
        end)
        if not ok then
          core.log_quiet("Auto-reload error for \"%s\": %s", doc.filename, err)
        end
      end
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
  dirty_warned[self] = nil
  return res
end

Doc.save = function(self, ...)
  local res = save(self, ...)
  update_time(self)
  dirty_warned[self] = nil
  return res
end
