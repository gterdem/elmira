-- tests/helper.lua — shared loader for headless specs. Every Core/Adapters module follows the
-- pattern in tests/README.md: `local ADDON, ns = ...; ns = ns or _G.__ELM_NS or {}` at the top,
-- `return Module` at the bottom. Plain `dofile` doesn't pass varargs, so modules fall back to the
-- shared `_G.__ELM_NS` table — this is what lets the same `ns` persist across dofile calls within
-- one spec, mirroring how the WoW client hands every file of one addon the same `ns` table.
local helper = {}

-- Fresh ns per spec. Without this, registry state (barProviders, dataPacks, ...) leaks between
-- specs and produces order-dependent failures.
function helper.reset()
  _G.__ELM_NS = {}
  return _G.__ELM_NS
end

function helper.load(path)
  local chunk, err = loadfile(path)
  if not chunk then error(err, 2) end
  return chunk("Elmira", _G.__ELM_NS)
end

function helper.ns()
  return _G.__ELM_NS
end

-- Shipped class data lives in Elmira/Classes/<Class>.lua and registers a THUNK, not a table
-- (ADR-0011). These three helpers are the only place a spec has to know that.

-- Discovers the shipped class files. A spec that globs for itself and finds nothing turns every
-- assertion downstream into a vacuous pass, so callers get the list and check it is non-empty.
function helper.classFiles()
  local pipe = assert(io.popen("ls Elmira/Classes/*.lua 2>/dev/null"), "cannot enumerate Elmira/Classes")
  local files = {}
  for line in pipe:lines() do files[#files + 1] = line end
  pipe:close()
  table.sort(files)
  return files
end

-- Loads one class file with its OWN private ns -- the way the client hands one addon one namespace --
-- and returns every RegisterBuiltinPack call it made, unevaluated. Returning the raw registered
-- VALUE rather than calling it is the point: it is what lets a spec assert the file registered a
-- function, which is the ADR-0011 property a file building tables at load would silently break.
function helper.classRegistrations(path)
  local captured = {}
  local ns = {
    RegisterBuiltinPack = function(class, value)
      captured[#captured + 1] = { class = class, value = value }
    end,
  }
  assert(loadfile(path), path .. " does not load")("Elmira", ns)
  return captured
end

-- The pack table exactly as Core/Init.lua sees it: lowercase keys, one call of the thunk.
function helper.classPack(class)
  local path = "Elmira/Classes/" .. class .. ".lua"
  local captured = helper.classRegistrations(path)
  assert(#captured == 1, path .. " must register exactly one pack, got " .. #captured)
  assert(type(captured[1].value) == "function", path .. " registered a table, not a thunk")
  return captured[1].value(), captured[1].class
end

return helper
