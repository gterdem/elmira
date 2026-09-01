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

return helper
