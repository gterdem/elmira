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

-- One recorder mark. Deliberately NOT the full dump: 41 spell rows x40 marks would blow the
-- SavedVariables budget for no benefit, since the spell table barely changes between marks. Keeps
-- what actually distinguishes one gear state from another, plus the queue and every verdict.
function ns.captureMark(pack)
  if not (pack and ns.API) then return nil end
  local state = ns.API.GetState()
  local mark = { queues = ns.queueSnapshot(pack, 5) }

  -- `ok and inCombat or nil` collapses a legitimate `false` to nil, so every mark reported
  -- combat=nil in the first recording — including the ones taken at combat start. Same defect as the
  -- collector's `known` flag and the rec label. Only ever branch explicitly on a boolean.
  local ok, inCombat = pcall(function() return state:inCombat() end)
  if ok then mark.inCombat = inCombat == true end

  local okW, weapon = pcall(function() return state:weapon(16) end)
  if okW and weapon then mark.weapon = { type = weapon.type, speed = weapon.speed, itemID = weapon.itemID } end

  local okS, soul = pcall(function() return state:enchant(3) end)
  mark.soul = okS and soul or nil

  -- Set counts are the whole point of a gear-swap test: this is what makes two marks comparable.
  mark.sets = {}
  for key in pairs(pack.sets or {}) do
    local okC, n = pcall(function() return state:setCount(key) end)
    if okC and n and n > 0 then mark.sets[key] = n end
  end

  -- Only cooldowns actually observed; nil ones say nothing and would triple the size.
  mark.cooldowns = {}
  for key in pairs(pack.spells or {}) do
    local okD, cd = pcall(function() return state:cooldown(key) end)
    if okD and cd and cd > 0 then mark.cooldowns[key] = cd end
  end
  return mark
end

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
          -- Same trap: `usable = false` must survive as false, not become nil. A verdict of nil reads
          -- as "not asked", which is exactly what it must not mean here.
          usable = entry.spell and (state:usable(entry.spell) == true) or nil,
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

-- Two commands and a reload, instead of one reload per gear state. Combat and gear changes mark
-- themselves (Core/Init.lua wires the events), so nothing needs typing mid-fight.
Slash.register{
  key = "rec", args = "start|mark [label]|stop|status|clear", desc = ns.L["Record snapshots for analysis"], order = 15,
  run = function(rest)
    local Recorder = ns.Recorder
    if not Recorder then return { "rec: recorder not loaded" } end
    -- NOT `rest and rest:match(...)`: Lua truncates the right-hand side of `and` to a single value,
    -- so the second capture would always be nil and every mark would lose its label silently.
    local sub, label
    if rest then sub, label = rest:match("^(%S+)%s*(.*)$") end
    local function pack()
      local packs = ns.API and ns.API.GetProviders("dataPacks") or {}
      local class = ns.Adapter and ns.Adapter.playerClass and ns.Adapter.playerClass()
      return class and packs[class] or nil
    end

    if sub == "start" then
      Recorder.clear()
      Recorder.start(ns.now and ns.now() or 0)
      return { "Recording. Play, swap gear, fight — combat and gear changes mark themselves.",
               "Add your own marks with: /elm rec mark <label>",
               "When done: /elm rec stop, then /reload to write the file." }
    elseif sub == "stop" then
      local n = Recorder.stop()
      return { string.format("Stopped with %d mark(s). /reload now to write them to "
        .. "WTF/Account/<ACCOUNT>/SavedVariables/Elmira.lua", n) }
    elseif sub == "status" then
      return { Recorder.status() }
    elseif sub == "clear" then
      Recorder.clear()
      return { "Cleared." }
    elseif sub == "mark" then
      local p = pack()
      if not p then return { "rec: no data pack registered" } end
      local ok, err = Recorder.mark(label ~= "" and label or "mark", ns.now and ns.now() or 0,
        function() return ns.captureMark(p) end)
      if not ok then return { "rec: " .. tostring(err) } end
      return { string.format("Marked %q (%d total).", label ~= "" and label or "mark", Recorder.count()) }
    end
    return { "Usage: /elm rec start|mark [label]|stop|status|clear" }
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
