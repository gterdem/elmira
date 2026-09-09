-- Elmira/Core/API.lua — the Elmira.API v1 registry (docs/08-MODULE-API.md).
-- Pure Lua, no WoW globals: dofile-able headlessly. Builds ns.API; Core/Init.lua publishes it as
-- the global `Elmira.API` at file scope (see Core/Init.lua for why that matters).
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local API = {}
API.version = 1 -- integer; a module checks the minimum it needs and disables itself otherwise

-- Identity-string locale shim: keeps every user-facing string routed through `ns.L[...]` (house
-- style) while staying dofile-able headlessly. A real Locale/enUS.lua (AceLocale-3.0) drops in front
-- of this at M3 with no retrofit needed.
ns.L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

-- No-op until Core/Init.lua overrides it with NA:Printf, so Core can report a rejected registration
-- without ever calling print() itself (Core never touches the WoW/Lua I/O surface directly).
ns.log = ns.log or function() end

local registry = {
  dataPacks = {}, barProviders = {}, overrideSources = {}, buildImporters = {},
  gearSources = {}, exporters = {}, meterProviders = {}, swingSources = {},
}
ns.registry = registry

-- A malformed module must never break core: every Register* validates and returns `true` or
-- `false, reason` — it never errors. This is what lets a class pack fail closed instead of taking
-- the whole addon down (hard rule 9: modules only via Elmira.API).
local function fail(label, reason)
  ns.log("rejected %s registration (%s)", label, reason)
  return false, reason
end

-- Dot-call is canonical (`API.RegisterX{...}`); a colon-call (`API:RegisterX{...}`) passes API as
-- the first argument ahead of spec. Unwrap either convention to the actual spec table.
local function unself(a, b)
  if b == nil then return a end
  return b
end

-- Explicit total order: priority descending, name ascending as a tiebreak. table.sort is not
-- guaranteed stable, so without the name tiebreak two equal-priority providers could reorder
-- between sessions; with it, the ordering is deterministic regardless of insertion order.
local function providerLess(x, y)
  if x.priority ~= y.priority then return x.priority > y.priority end
  return x.name < y.name
end

function API.RegisterDataPack(a, b)
  local spec = unself(a, b)
  if type(spec) ~= "table" or type(spec.class) ~= "string" then
    return fail("data pack", "class is required")
  end
  if type(spec.flavor) ~= "string" then
    return fail(spec.class, "flavor is required")
  end
  registry.dataPacks[spec.class] = spec
  -- AB2-D3: the one place EVERY pack arrives -- the shipped class files come through here too --
  -- so it is the one place a malformed per-ability default block can be said out loud. The pack is
  -- still registered: a bad default is inert, and refusing the pack over one would take the class's
  -- rotations with it. Silent is the one thing it must not be, because an ignored default looks
  -- exactly like a cue that was never meant to fire.
  for _, problem in ipairs(ns.Schema and ns.Schema.abilityDefaultErrors(spec.spells) or {}) do
    ns.log("data pack %s: %s", spec.class, problem)
  end
  return true
end

function API.RegisterBarProvider(a, b)
  local spec = unself(a, b)
  if type(spec) ~= "table" or type(spec.name) ~= "string" then
    return fail("bar provider", "name is required")
  end
  -- One name, one provider. Two providers claiming the same bars is not a merge, it is a coin toss:
  -- the sort below is stable only on (priority, name), so which of the two answers `buttonsForSpell`
  -- depends on registration order, and the loser's map is built and maintained for nothing. This
  -- happens for real when a retired companion addon is left installed alongside the core that
  -- absorbed it -- exactly how a stale Elmira_Paladin silently served pre-migration rotations. Refuse
  -- the second one and SAY SO, rather than letting the addon look fine and behave at random.
  for _, existing in ipairs(registry.barProviders) do
    if existing.name == spec.name then
      return fail(spec.name, "a bar provider with this name is already registered; "
                          .. "an old Elmira bar addon may still be installed")
    end
  end
  spec.priority = spec.priority or 0
  table.insert(registry.barProviders, spec)
  table.sort(registry.barProviders, providerLess)
  return true
end

function API.RegisterOverrideSource(a, b)
  local spec = unself(a, b)
  if type(spec) ~= "table" or type(spec.name) ~= "string" then
    return fail("override source", "name is required")
  end
  registry.overrideSources[spec.name] = spec
  return true
end

function API.RegisterBuildImporter(a, b)
  local spec = unself(a, b)
  if type(spec) ~= "table" or type(spec.name) ~= "string" or type(spec.prefix) ~= "string" then
    return fail("build importer", "name and prefix are required")
  end
  table.insert(registry.buildImporters, spec)
  return true
end

function API.RegisterGearSource(a, b)
  local spec = unself(a, b)
  if type(spec) ~= "table" or type(spec.name) ~= "string" then
    return fail("gear source", "name is required")
  end
  table.insert(registry.gearSources, spec)
  return true
end

function API.RegisterExporter(a, b)
  local spec = unself(a, b)
  if type(spec) ~= "table" or type(spec.name) ~= "string" then
    return fail("exporter", "name is required")
  end
  table.insert(registry.exporters, spec)
  return true
end

function API.RegisterMeterProvider(a, b)
  local spec = unself(a, b)
  if type(spec) ~= "table" or type(spec.name) ~= "string" then
    return fail("meter provider", "name is required")
  end
  table.insert(registry.meterProviders, spec)
  return true
end

function API.RegisterSwingSource(a, b)
  local spec = unself(a, b)
  if type(spec) ~= "table" or type(spec.name) ~= "string" then
    return fail("swing source", "name is required")
  end
  table.insert(registry.swingSources, spec)
  return true
end

-- M0: no consumption logic. Returns a contract-shaped null state (never nil) so a module calling
-- GetState() before M1's Engine exists still gets something Interface.validate() accepts.
function API.GetState()
  if ns.Adapter and ns.Adapter.state then return ns.Adapter.state end
  return ns.Interface and ns.Interface.newNullState() or {}
end

function API.GetActiveBuild()
  return nil -- M0: no build selection logic yet (M4)
end

function API.Advise()
  return { soul = nil, runes = {}, weapon = nil, notes = {} } -- fresh table every call
end

-- One provider by key, uncopied. The render loop resolves the player's pack on every recompute --
-- four times a second, standing still -- and copying the whole registry to read one entry was an
-- allocation on every one of them. The spec table is a shared reference, as with GetProviders.
function API.GetProvider(kind, key)
  local list = registry[kind]
  return list and key ~= nil and list[key] or nil
end

-- Shallow copy: the container is safe to mutate, but the registered spec tables themselves are
-- shared references (modules must not mutate core's registry, but they may read spec fields freely).
function API.GetProviders(kind)
  local list = registry[kind]
  if not list then return {} end
  local copy = {}
  for k, v in pairs(list) do copy[k] = v end
  return copy
end

ns.API = API
return API
