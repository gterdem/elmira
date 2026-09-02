-- Elmira/Core/Slash.lua — /elm dispatch table. Split out of Core/Init.lua specifically so it is
-- dofile-able and therefore testable: this is what turns "make test green" into a suite that
-- actually proves something, rather than an empty one that can't fail.
--
-- Slash.run(input) RETURNS a table of lines; it never prints. Core/Init.lua is the only place that
-- calls print (via NA:Print). This is also what keeps Slash.lua ignorant of the WoW API entirely.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}
-- Defensive: normally Core/API.lua sets this first, but Slash.lua stays testable in isolation too.
ns.L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
-- Core/Init.lua owns the AceDB handle and replaces this; the no-op keeps `debug dump` callable in a
-- spec (and harmless before OnInitialize) instead of erroring on a nil global.
ns.saveDump = ns.saveDump or function() end

local Slash = {}
local entries = {}

-- Builds the queue for every registered build, as data rather than text, so `/elm debug dump` can
-- persist it. Kept next to the slash command that prints it so the two can never diverge.
function ns.queueSnapshot(pack, depth)
  if not (pack and pack.builds and ns.Schema and ns.Simulation and ns.API) then return nil end
  local ctx = { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
  local state = ns.API.GetState()
  local out = {}
  for key, build in pairs(pack.builds) do
    local compiled, errors = ns.Schema.compile(build, ctx)
    if not compiled then
      out[key] = { error = ns.Schema.errorLines(errors or {}) }
    else
      local rows = {}
      for i, slot in ipairs(ns.Simulation.queue(compiled, state, depth or 5)) do
        rows[i] = { spell = slot.spell, item = slot.item, t = slot.t, cdVolatile = slot.cdVolatile }
      end
      -- The per-entry verdicts matter more than the queue itself when something looks wrong.
      local verdicts = {}
      for i, entry in ipairs(compiled.entries) do
        verdicts[i] = {
          spell = entry.spell, item = entry.item,
          passes = entry.test and entry.test(state) or false,
          usable = entry.spell and state:usable(entry.spell) or nil,
          cooldown = entry.spell and state:cooldown(entry.spell) or nil,
        }
      end
      out[key] = { queue = rows, entries = verdicts, inCombat = state:inCombat() }
    end
  end
  return out
end

-- entry = { key, args?, desc, available, milestone?, order, run = function(rest) -> {lines} }
function Slash.register(entry)
  table.insert(entries, entry)
  table.sort(entries, function(a, b) return a.order < b.order end) -- fixed order: never pairs()
end

-- Milestone labels are not all plain integers (e.g. "5c", "5a"), so this formats with %s throughout.
local function unavailableNamed(name, milestone)
  return function()
    return { string.format("%s is not available yet (M%s).", name, tostring(milestone)) }
  end
end

local function helpLines()
  local lines = { "Elmira: /elm <command>" }
  for _, e in ipairs(entries) do
    local usage = e.key
    if e.args then usage = usage .. " " .. e.args end
    lines[#lines + 1] = string.format("  %-16s %s", usage, e.desc)
  end
  return lines
end

Slash.register{ key = "help", desc = ns.L["Show this help"], order = 0, run = helpLines }

Slash.register{
  key = "debug", args = "state|bars|perf|dump|queue", desc = ns.L["Diagnostics"], order = 10,
  run = function(rest)
    local sub = rest and rest:match("^(%S+)")
    if sub == "state" then
      local d = ns.Adapter and ns.Adapter.describe and ns.Adapter.describe()
      if not d then return { "state: adapter not loaded" } end
      local caps = {}
      for k, v in pairs(d.caps or {}) do caps[#caps + 1] = k .. "=" .. tostring(v) end
      table.sort(caps)
      return {
        string.format("project=%s version=%s interface=%s", tostring(d.project), tostring(d.version), tostring(d.interface)),
        "capabilities: " .. table.concat(caps, " "),
        "state: " .. tostring(d.state),
      }
    elseif sub == "bars" then
      local providers = ns.API and ns.API.GetProviders("barProviders") or {}
      local lines = { string.format("bar providers: %d", #providers) }
      for _, p in ipairs(providers) do
        lines[#lines + 1] = string.format("  %s  priority=%d  buttons=%s", p.name, p.priority or 0,
          type(p.buttonsForSpell) == "function" and "stub" or "missing")
      end
      return lines
    elseif sub == "perf" then
      return {
        string.format("lua memory: %d KB", math.floor(collectgarbage("count"))),
        "updates: 0", -- nothing ticks before M3
        "allocations/frame: n/a (M3)",
      }
    elseif sub == "dump" then
      -- Writes a full character snapshot to SavedVariables for offline analysis (docs/01 §4a).
      -- Slash stays WoW-API-free: Collector does every client read, exactly as `state` delegates
      -- to ns.Adapter.describe().
      local Collector = ns.Collector
      if not Collector then return { "dump: collector not loaded" } end
      local packs = ns.API and ns.API.GetProviders("dataPacks") or {}
      local class = ns.Adapter and ns.Adapter.playerClass and ns.Adapter.playerClass()
      local pack = class and packs[class] or nil
      if not pack then
        return { string.format("dump: no data pack registered for %s", tostring(class)) }
      end
      local snapshot = Collector.snapshot(pack)
      -- Capture the queue into the file too. Reading it off the chat frame is unworkable in combat —
      -- it truncates, and the player has better things to do mid-fight than copy text — so the one
      -- command that matters writes everything to disk and the chat output is only a preview.
      snapshot.queues = ns.queueSnapshot and ns.queueSnapshot(pack) or nil
      local saved = ns.saveDump(snapshot)
      local lines = Collector.format(snapshot)
      local mismatches = Collector.mismatchCount(snapshot)
      lines[#lines + 1] = ""
      -- Name the actual file. WoW names a SavedVariables file after the ADDON (Elmira.lua); ElmiraDB
      -- is only the variable inside it, and looking for ElmiraDB.lua finds nothing. Chat also
      -- truncates a full dump, so the file is the real transport, not the copy buffer.
      lines[#lines + 1] = string.format("%d rune slot(s) disagree with our data.", mismatches)
      if saved then
        lines[#lines + 1] = "Chat truncates this; the full snapshot is saved to "
          .. "WTF/Account/<ACCOUNT>/SavedVariables/Elmira.lua -- /reload or log out to flush it."
      else
        lines[#lines + 1] = "WARNING: could not save the snapshot (no database yet). "
          .. "What you see above is all there is."
      end
      return lines
    elseif sub == "queue" then
      -- M2 acceptance vehicle (docs/06 M2 row: "Exodin queue prints correctly on a dummy"). There is
      -- no display until M3, so the queue has to be printable some other way; this runs the real
      -- Engine and Simulation against the LIVE adapter state, not a fixture.
      local packs = ns.API and ns.API.GetProviders("dataPacks") or {}
      local class = ns.Adapter and ns.Adapter.playerClass and ns.Adapter.playerClass()
      local pack = class and packs[class] or nil
      if not (pack and pack.builds) then
        return { string.format("queue: no builds registered for %s", tostring(class)) }
      end

      local wanted = rest and rest:match("^%S+%s+(%S+)")
      local key, build
      for k, b in pairs(pack.builds) do
        if wanted == nil or k == wanted then key, build = k, b; break end
      end
      if not build then
        local names = {}
        for k in pairs(pack.builds) do names[#names + 1] = k end
        table.sort(names)
        return { "queue: no such build. Available: " .. table.concat(names, ", ") }
      end

      local ctx = { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
      local compiled, errors = ns.Schema.compile(build, ctx)
      if not compiled then
        local lines = { string.format("queue: %s failed validation", key) }
        for _, l in ipairs(ns.Schema.errorLines(errors or {})) do lines[#lines + 1] = "  " .. l end
        return lines
      end

      local state = ns.API.GetState()
      local depth = tonumber(rest and rest:match("(%d+)%s*$")) or 5
      local q = ns.Simulation.queue(compiled, state, depth)

      local lines = { string.format("queue for %s (depth %d):", key, depth) }
      if #q == 0 then
        lines[#lines + 1] = "  (empty — nothing eligible right now)"
      end
      for i, slot in ipairs(q) do
        lines[#lines + 1] = string.format("  %d. %-26s t=%.1fs%s", i,
          tostring(slot.spell or slot.item), slot.t or 0, slot.cdVolatile and "  [volatile cd]" or "")
      end
      -- Why each entry did or did not make it. An empty queue with no explanation is the failure
      -- shape this project keeps hitting, so the reasons print alongside the answer.
      lines[#lines + 1] = "entries, in priority order:"
      for i, entry in ipairs(compiled.entries) do
        local name = tostring(entry.spell or entry.item)
        local passes = entry.test and entry.test(state)
        local usable = entry.spell and state:usable(entry.spell)
        local cd = entry.spell and state:cooldown(entry.spell) or 0
        lines[#lines + 1] = string.format("  %2d %-26s when=%s usable=%s cd=%.1f", i, name,
          passes and "pass" or "FAIL", tostring(usable), cd)
      end
      return lines
    end
    return { "Usage: /elm debug state|bars|perf|dump|queue [build] [depth]" }
  end,
}

Slash.register{
  key = "modules", desc = ns.L["List registered modules"], order = 20,
  run = function()
    local reg = ns.registry or {}
    local kinds = { "dataPacks", "barProviders", "overrideSources", "buildImporters",
                    "gearSources", "exporters", "meterProviders", "swingSources" }
    local lines = {}
    for _, kind in ipairs(kinds) do
      local count = 0
      for _ in pairs(reg[kind] or {}) do count = count + 1 end
      lines[#lines + 1] = string.format("%s %d", kind, count)
    end
    return lines
  end,
}

Slash.register{
  key = "version", desc = ns.L["Show addon and client version"], order = 30,
  run = function()
    local v = ns.Adapter and ns.Adapter.addonVersion and ns.Adapter.addonVersion() or "dev"
    local d = ns.Adapter and ns.Adapter.detect and ns.Adapter.detect()
    return { string.format("Elmira %s (interface %s)", v, d and tostring(d.interface) or "?") }
  end,
}

-- Not-yet-available verbs, in the order the project documents them, each honest about its milestone
-- so `/elm` never claims a command it can't run.
Slash.register{ key = "setup", desc = ns.L["Run the setup wizard"], order = 100, run = unavailableNamed("setup", 4) }
Slash.register{ key = "lock", desc = ns.L["Lock/unlock frames"], order = 101, run = unavailableNamed("lock", 3) }
Slash.register{ key = "profile", args = "<key>", desc = ns.L["Pin a build"], order = 102, run = unavailableNamed("profile", 4) }
Slash.register{ key = "advise", desc = ns.L["Gear advisor"], order = 103, run = unavailableNamed("advise", 4) }
Slash.register{ key = "sim", desc = ns.L["Export to WoWSims"], order = 104, run = unavailableNamed("sim", "5c") }
Slash.register{ key = "history", desc = ns.L["Encounter history"], order = 105, run = unavailableNamed("history", "5f") }
Slash.register{ key = "rotdiag", desc = ns.L["Paste-friendly diagnostic snapshot"], order = 106, run = unavailableNamed("rotdiag", "5a") }

local function find(key)
  for _, e in ipairs(entries) do
    if e.key == key then return e end
  end
end

function Slash.help()
  return helpLines()
end

-- Never throws: an unrecognised or empty command returns exactly one designed line.
function Slash.run(input)
  input = (input or ""):match("^%s*(.-)%s*$")
  if input == "" then return helpLines() end
  local verb, rest = input:match("^(%S+)%s*(.-)$")
  verb = verb:lower()
  if verb == "help" then return helpLines() end
  local entry = find(verb)
  if not entry then
    return { string.format("Unknown command '%s'. Type /elm for help.", verb) }
  end
  return entry.run(rest)
end

ns.Slash = Slash
return Slash
