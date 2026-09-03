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

-- Every timestamp comes from the injected clock (docs/01 §2), never GetTime() directly. Nothing ever
-- assigned `ns.now`, and all three call sites guarded it as `ns.now and ns.now() or 0` -- so every
-- recorder mark was stamped 0 and a recording had no time axis at all. The guard hid the omission
-- instead of surfacing it; giving the name a definition here is what makes those call sites mean
-- something. Falls back to 0 only when no state exists yet, which is the pre-OnInitialize case.
function ns.now()
  local state = ns.API and ns.API.GetState()
  if state and state.now then return state:now() end
  return 0
end

local Slash = {}
local entries = {}

-- Two decimals is the whole of the client's useful precision (cooldowns tick at 10 Hz), and it is
-- what turns `5.7760000000126` into `5.78`. Applied to every number that reaches SavedVariables:
-- the fourth recording spent a large share of its 99 KB on float noise nobody can read.
local function r2(x)
  if type(x) ~= "number" then return nil end
  if x < 0 then return -(math.floor(-x * 100 + 0.5) / 100) end
  return math.floor(x * 100 + 0.5) / 100
end

-- Compiling a build is not free and the cast log polls the queue once a second in combat. Builds do
-- not change at runtime, so compile once per build table and keep it. Weak keys mean a pack swap
-- (which creates new build tables) drops the old entries instead of pinning them forever.
local compileCache = setmetatable({}, { __mode = "k" })

function ns.compileBuild(build, ctx)
  local hit = compileCache[build]
  -- A hit must also have been compiled against THIS ctx. Keying on the build alone would serve a
  -- stale compilation whenever the pack's data tables are replaced but the build tables survive --
  -- silently, with the queue simply evaluating against the old spell/set data.
  if hit and hit.spells == ctx.spells and hit.sets == ctx.sets
     and hit.souls == ctx.souls and hit.bonuses == ctx.bonuses then
    return hit.compiled, hit.errors
  end
  local compiled, errors = ns.Schema.compile(build, ctx)
  compileCache[build] = { compiled = compiled, errors = errors,
                          spells = ctx.spells, sets = ctx.sets, souls = ctx.souls, bonuses = ctx.bonuses }
  return compiled, errors
end

-- Which buffs this pack's builds actually ask about, walked out of their conditions. Recording every
-- aura on the player would be huge and mostly noise; recording none is why the third and fourth
-- recordings could not explain a single verdict -- whether the seal was up had to be inferred
-- backwards from `no_seal` passing.
function ns.referencedBuffs(pack)
  local out = {}
  local function walk(when)
    for _, cond in ipairs(when or {}) do
      if type(cond) == "table" then
        local kind = cond[1]
        if kind == "buff" or kind == "no_buff" or kind == "seal" then
          if type(cond[2]) == "string" then out[cond[2]] = true end
        elseif kind == "all" or kind == "any" or kind == "not" then
          local nested = {}
          for i = 2, #cond do nested[#nested + 1] = cond[i] end
          walk(nested)
        end
      end
    end
  end
  for _, build in pairs(pack and pack.builds or {}) do
    for _, entry in ipairs(build.entries or {}) do walk(entry.when) end
  end
  return out
end

-- Reverse map spellID -> symbolic key. The cast log arrives from the client as a raw numeric id and
-- every other part of the addon speaks keys (hard rule 4). Two keys can share one id (RUNE_* mirrors
-- its ability), so collisions resolve deterministically: the non-RUNE_ name wins, then the
-- lexicographically smaller one. Left to pairs() order this map would differ between reloads.
function ns.spellKeyByID(pack)
  local map = {}
  for key, data in pairs(pack and pack.spells or {}) do
    if type(data) == "table" and data.id then
      local held = map[data.id]
      if held == nil then
        map[data.id] = key
      else
        local heldIsRune = held:sub(1, 5) == "RUNE_"
        local keyIsRune = key:sub(1, 5) == "RUNE_"
        if heldIsRune ~= keyIsRune then
          if heldIsRune then map[data.id] = key end
        elseif key < held then
          map[data.id] = key
        end
      end
    end
  end
  return map
end

-- One recorder mark. Deliberately NOT the full dump: 41 spell rows x120 marks would blow the
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
  -- The LEARNED cooldown duration, which is a different question from how much is left and the one
  -- the shipped data table can be wrong about. GetSpellBaseCooldown reported 15000 for Exorcism in
  -- every gear state while the real cooldown was 6 s (docs/07 §9.1), so the adapter observes and
  -- caches instead — but that cache was session-local and never reached a recording, leaving "does
  -- Exorcism settle at 6, not the shipped 15?" unanswerable from four runs of evidence.
  mark.baseCooldowns = {}
  for key in pairs(pack.spells or {}) do
    local okD, cd = pcall(function() return state:cooldown(key) end)
    if okD and cd and cd > 0 then mark.cooldowns[key] = r2(cd) end
    local okB, base = pcall(function() return state:baseCooldown(key) end)
    if okB and base and base > 0 then mark.baseCooldowns[key] = r2(base) end
  end

  -- Timing. `gcd` is how much of a global is LEFT, `gcdDuration` is how long one lasts; conflating
  -- them stalled the whole simulated queue at t=0 once already, so a recording states both.
  local okG, gcd = pcall(function() return state:gcd() end)
  if okG then mark.gcd = r2(gcd) end
  local okGD, gcdDur = pcall(function() return state:gcdDuration() end)
  if okGD then mark.gcdDuration = r2(gcdDur) end

  -- Every buff the builds actually gate on, with stacks and remaining. Without this, a verdict of
  -- "passes = false" on a buff condition is unfalsifiable.
  mark.buffs = {}
  for key in pairs(ns.referencedBuffs(pack)) do
    local okA, stacks, remaining = pcall(function() return state:buff(key) end)
    if okA and stacks then mark.buffs[key] = { stacks = stacks, remaining = r2(remaining) } end
  end

  local okSeal, seal = pcall(function() return state:seal() end)
  mark.seal = okSeal and seal or nil

  local okP, mana = pcall(function() return state:power("MANA") end)
  if okP and mana then mark.mana = r2(mana) end

  -- What each spell COSTS, read from the client rather than the data table (GetSpellPowerCost tracks
  -- the rank and the runes; Data/Spells.lua cannot). Without this, "the seal reported usable at 86
  -- mana" is an argument rather than a check: cost next to mana settles whether `usable` is wrong or
  -- the seal is simply cheap. SEAL_OF_MARTYRDOM carries no `cost` in Data/Spells.lua at all, so the
  -- client is the only source for it.
  mark.powerCosts = {}
  for key in pairs(pack.spells or {}) do
    local okC, cost = pcall(function() return state:powerCost(key) end)
    if okC and cost and cost > 0 then mark.powerCosts[key] = r2(cost) end
  end

  -- A queue computed with no target is not the queue the player was looking at.
  local okT, exists = pcall(function() return state:targetExists() end)
  if okT then
    mark.target = { exists = exists == true }
    local okTT, ttype = pcall(function() return state:targetType() end)
    if okTT then mark.target.type = ttype end
    local okHP, hp = pcall(function() return state:targetHPPct() end)
    if okHP then mark.target.hpPct = r2(hp) end
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
    local compiled, errors = ns.compileBuild(build, ctx)
    if not compiled then
      out[key] = { error = ns.Schema.errorLines(errors or {}) }
    else
      local rows = {}
      for i, slot in ipairs(ns.Simulation.queue(compiled, state, depth or 5)) do
        rows[i] = { spell = slot.spell, item = slot.item, t = r2(slot.t), cdVolatile = slot.cdVolatile }
      end
      -- The per-entry verdicts matter more than the queue itself when something looks wrong.
      local verdicts = {}
      for i, entry in ipairs(compiled.entries) do
        -- `usable = false` must survive as false, not become nil: a verdict of nil reads as "not
        -- asked", which is exactly what it must not mean here. The previous one-liner was
        -- `entry.spell and (state:usable(entry.spell) == true) or nil`, and `false or nil` is nil --
        -- committing the very collapse the comment above it warned against. Only an explicit `if`
        -- keeps a boolean a boolean; there is no and/or spelling of this that does.
        local usable, cooldown = nil, nil
        if entry.spell then
          usable = state:usable(entry.spell) == true
          cooldown = r2(state:cooldown(entry.spell))
        end
        -- WHICH condition rejected the entry. Only failures are stored: a passing condition carries
        -- no information and every byte here is multiplied by entries x marks.
        local failed = nil
        for _, cond in ipairs(entry.conditions or {}) do
          if cond.test and not cond.test(state) then
            failed = failed or {}
            failed[#failed + 1] = cond.label
          end
        end
        verdicts[i] = {
          spell = entry.spell, item = entry.item,
          passes = entry.test and entry.test(state) or false,
          usable = usable,
          cooldown = cooldown,
          failed = failed,
        }
      end
      out[key] = { queue = rows, entries = verdicts, inCombat = state:inCombat() }
    end
  end
  return out
end

-- PURE. One row of the cast log. This lives here rather than in Core/Init.lua because no spec can
-- load Init.lua (it needs AceAddon) -- the same reason breaking the dedupe fingerprint changed no
-- test until it was moved out. `suggestion` is the poll's {at, top} or nil.
--
-- `age` is how stale the suggestion was when the cast landed. It is recorded rather than filtered
-- because the right cutoff is an analysis decision, not a capture one: a row with age 0.9 next to a
-- 1.5 s global is weaker evidence than one at 0.1, and discarding it here would hide that.
function ns.castRow(now, spellID, keyMap, suggestion)
  if type(spellID) ~= "number" then return nil end
  local row = { at = r2(now), id = spellID, spell = keyMap and keyMap[spellID] or nil }
  if suggestion and suggestion.at then
    row.suggested = suggestion.top
    row.age = r2(now - suggestion.at)
  end
  return row
end

-- Just the top suggestion per build, for the cast log's "what was Elmira saying?" column. Depth 1
-- and no verdicts: this runs once a second in combat, unlike queueSnapshot which runs per mark.
function ns.topSuggestions(pack)
  if not (pack and pack.builds and ns.Schema and ns.Simulation and ns.API) then return nil end
  local ctx = { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
  local state = ns.API.GetState()
  local out = {}
  for key, build in pairs(pack.builds) do
    local compiled = ns.compileBuild(build, ctx)
    if compiled then
      local slot = ns.Simulation.queue(compiled, state, 1)[1]
      if slot then out[key] = slot.spell or (slot.item and ("item:" .. tostring(slot.item))) end
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
  key = "debug", args = "state|bars|swing|cues|perf|dump|queue", desc = ns.L["Diagnostics"], order = 10,
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
      -- Walks the WHOLE chain, because "the bar glow does not work" has four independent causes and
      -- the old version of this command could only report the first. Counting registered providers
      -- says nothing about whether one found a button, and a provider that silently returns nothing
      -- looks identical to a provider that is not there.
      local p = ns.db and ns.db.profile
      local lines = {}
      if p and p.glow then
        lines[#lines + 1] = string.format("glow: enabled=%s barGlow=%s style=%s active=%d",
          tostring(p.glow.enabled), tostring(p.glow.barGlow), tostring(p.glow.style),
          ns.Glow and ns.Glow.activeCount() or 0)
        if p.glow.enabled == false then lines[#lines + 1] = "  -> glow is OFF in the options" end
        if p.glow.barGlow == false then lines[#lines + 1] = "  -> bar glow is OFF in the options" end
      end

      local keys = {}
      local queue = ns.Display and select(1, ns.Display.computeQueue(3))
      for _, slot in ipairs(queue or {}) do
        if slot.spell then keys[#keys + 1] = slot.spell end
      end

      -- Degrades rather than refusing: without Display loaded this still answers the Core half of
      -- the question (which providers registered), which is the half a headless spec can reach.
      local d = ns.BarGlow and ns.BarGlow.describe(keys)
      if not d then
        local registered = ns.API and ns.API.GetProviders("barProviders") or {}
        lines[#lines + 1] = string.format("bar providers: %d", #registered)
        for _, prov in ipairs(registered) do
          lines[#lines + 1] = string.format("  %s  priority=%d", prov.name or "?", prov.priority or 0)
        end
        lines[#lines + 1] = "display not loaded, so no buttons were looked up"
        return lines
      end

      lines[#lines + 1] = string.format("bar providers: %d", #d.providers)
      for _, prov in ipairs(d.providers) do
        lines[#lines + 1] = string.format("  %s  priority=%d  buttonsForSpell=%s keybindForSpell=%s",
          prov.name, prov.priority, tostring(prov.buttonsForSpell), tostring(prov.keybindForSpell))
        if prov.info then
          lines[#lines + 1] = string.format("    %s: present=%s  %d button(s) registered, %d spell(s) mapped",
            tostring(prov.info.library), tostring(prov.info.present),
            prov.info.buttons or 0, prov.info.mapped or 0)
        end
      end
      if #d.providers == 0 then
        lines[#lines + 1] = "  none — is Elmira_ElvUI enabled in the AddOns list?"
      end
      lines[#lines + 1] = string.format("blizzard fallback: %d spell(s) mapped", d.blizzard or 0)

      if #d.rows == 0 then
        lines[#lines + 1] = "queue is empty, so there is nothing to look for on the bars"
      end
      for i, row in ipairs(d.rows) do
        lines[#lines + 1] = string.format("%d. %s id=%s -> %s", i, row.key, tostring(row.id),
          row.count > 0
            and string.format("%d button(s) via %s (%s)%s", row.count, tostring(row.source),
                  row.button or "unnamed", row.bind and (" key=" .. row.bind) or "")
            or "NO VISIBLE BUTTON")
      end
      return lines
    elseif sub == "swing" then
      -- M3b has no UI of its own until M5d's twist readout, so this command IS the feature's only
      -- visible surface. It names why there is no number rather than printing a blank, because
      -- "no swing timer" and "swing timer that has not seen a swing" need different fixes.
      if not ns.Swing then return { "swing: adapter not loaded" } end
      local state = ns.API and ns.API.GetState()
      local latency = 0
      if state and state.latency then
        local ok, ms = pcall(function() return state:latency() end)
        if ok then latency = ms or 0 end
      end
      local d = ns.Swing.describe(ns.now(), latency)
      local caps = ns.Adapter and ns.Adapter.capabilities and ns.Adapter.capabilities() or {}
      local lines = {
        string.format("%s: available=%s  capability swing=%s", d.library, tostring(d.available),
          tostring(caps.swing)),
        string.format("latency: %d ms (world)", latency),
      }
      if d.why then
        lines[#lines + 1] = "no reading: " .. d.why
      else
        lines[#lines + 1] = string.format("swing: %.2fs speed, %.2fs remaining (latency-adjusted)",
          d.speed or 0, d.remaining or 0)
      end
      -- The seal side of M3b. A window of nil is the shipped state until the twist research lands,
      -- and saying so is the point: otherwise `seal_linger` reads false forever with no explanation.
      local pack = ns.Display and ns.Display.currentPack()
      local window = pack and pack.sealLingerWindow
      if window then
        lines[#lines + 1] = string.format("seal linger window: %.2fs (from the data pack)", window)
        local linger = state and state.sealLinger and state:sealLinger()
        lines[#lines + 1] = "lingering seal: " .. tostring(linger)
      else
        lines[#lines + 1] = "seal linger window: not set — the pack ships no sourced value, so every"
        lines[#lines + 1] = "  seal_linger condition reads false (docs/02, deliberate)"
      end
      return lines
    elseif sub == "cues" then
      -- Four independent reasons a screen-edge cue stays silent, and they are indistinguishable by
      -- looking at the screen: not opted in, cannot fire yet, the rotation never put that spell in
      -- the now-slot, or it fired while you were looking at the boss. Says which.
      -- `/elm debug cues <n>` test-fires one, which separates a silent cue from a broken renderer.
      if not ns.Overlay then return { "cues: overlay not loaded" } end
      local which = rest and rest:match("^%S+%s+(%S+)")
      if which then
        local ok, what = ns.Overlay.TestFire(which)
        return { ok and ("test-fired: " .. tostring(what)) or ("cannot test-fire: " .. tostring(what)) }
      end

      local d = ns.Overlay.describe()
      local lines = {
        string.format("build=%s  now-slot=%s", tostring(d.buildKey), tostring(d.nowSlot)),
      }
      if #d.cues == 0 then
        lines[#lines + 1] = "this build suggests no cues"
      end
      for _, c in ipairs(d.cues) do
        lines[#lines + 1] = string.format("%d. %s [%s]", c.index, tostring(c.reason or c.id), c.id)
        if c.unavailable then
          lines[#lines + 1] = "   UNAVAILABLE: " .. c.unavailable
        elseif not c.enabled then
          lines[#lines + 1] = "   off — enable it in /elm config → Peripheral cues"
        else
          lines[#lines + 1] = string.format("   on  edge=%s intensity=%s", tostring(c.edge),
            tostring(c.intensity))
          -- "never" here with matchesNow=true is the actionable pair: the cue is on, its spell IS
          -- the current suggestion, and nothing has flared. That is a bug, not a quiet rotation.
          lines[#lines + 1] = string.format("   matches now-slot=%s  last fired=%s",
            tostring(c.matchesNow),
            c.firedAt and string.format("%.1fs ago", math.max(0, ns.now() - c.firedAt)) or "never")
        end
      end
      lines[#lines + 1] = "/elm debug cues <n> test-fires one"
      return lines
    elseif sub == "perf" then
      local lines = { string.format("lua memory: %d KB", math.floor(collectgarbage("count"))) }
      if not ns.Display then
        lines[#lines + 1] = "display: not loaded"
        return lines
      end
      local s = ns.Display.stats()
      local total = (s.runs or 0) + (s.skipped or 0)
      lines[#lines + 1] = string.format("display: %s, build=%s, renderers=%d",
        ns.Display.isEnabled() and "running" or "stopped", tostring(s.build), s.renderers or 0)
      -- Recomputes vs ticks: at 10 Hz against a 60 fps client this should sit near 83% skipped.
      -- A low number here means the throttle is not doing its job, which is the failure this
      -- command exists to make visible rather than something a player discovers as frame drops.
      lines[#lines + 1] = string.format("ticks: %d recomputed, %d skipped (%.0f%% skipped)",
        s.runs or 0, s.skipped or 0, total > 0 and (s.skipped or 0) / total * 100 or 0)
      if ns.BarGlow then
        local b = ns.BarGlow.stats()
        lines[#lines + 1] = string.format("bar map: %d spells, %d provider(s), built=%s",
          b.mapped or 0, b.providers or 0, tostring(b.built))
      end
      lines[#lines + 1] = string.format("visible: %s (%s), mode=%s",
        tostring(s.visible), tostring(s.visibleReason), tostring(s.mode))
      if ns.Glow then
        lines[#lines + 1] = string.format("active glows: %d", ns.Glow.activeCount())
      end
      lines[#lines + 1] = "/elm debug perf again after a fight to compare"
      return lines
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
    return { "Usage: /elm debug state|bars|swing|cues|perf|dump|queue [build] [depth]" }
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
      -- The first real recording was started mid-combat, so its baseline mark was a combat snapshot
      -- and the first gear state was never captured cleanly. Refuse rather than silently record a
      -- run whose first mark means something different from every later one.
      local st = ns.API and ns.API.GetState()
      local inCombat = st and st.inCombat and st:inCombat()
      if inCombat then
        return { "Not started: you are in combat.",
                 "The first mark is the baseline for everything after it, so it has to be taken at rest.",
                 "Step away, let combat drop, then /elm rec start again." }
      end
      Recorder.clear()
      Recorder.start(ns.now())
      -- Print the plan here rather than relying on a document on another machine.
      return {
        "Recording started. Combat, gear swaps and your own casts all record themselves.",
        "Nothing needs typing during a fight — you cannot, and you do not have to.",
        "  1) /elm rec mark baseline",
        "  2) fight something for 30s+ and PLAY NORMALLY   (auto)",
        "     A duel or a real mob. Longer fights beat more fights.",
        "  3) let combat drop, then fight again using cooldowns  (auto)",
        "Gear test, if you want one — after each swap wait a second, then label it:",
        "  remove ONE tier-3 piece -> /elm rec mark t3-minus-one, then put it back",
        "Then: /elm rec stop, then /reload. /elm rec status shows progress.",
      }
    elseif sub == "stop" then
      local n = Recorder.stop()
      local lines = { string.format("Stopped with %d mark(s).", n) }
      if n == 0 then
        lines[#lines + 1] = "Nothing was captured — did you swap any gear or enter combat?"
      end
      lines[#lines + 1] = "/reload NOW to write them out. Without it nothing is saved."
      return lines
    elseif sub == "status" then
      return { Recorder.status() }
    elseif sub == "clear" then
      Recorder.clear()
      return { "Cleared." }
    elseif sub == "mark" then
      local p = pack()
      if not p then return { "rec: no data pack registered" } end
      -- No dedupe key: a mark the player asked for is always recorded, even if nothing changed.
      local ok, err = Recorder.mark(label ~= "" and label or "mark", ns.now(),
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
Slash.register{
  key = "config", args = "", desc = ns.L["Open the options"], order = 99,
  run = function()
    if ns.Options and ns.Options.Open() then return { "Opening options." } end
    return { "config: options are not loaded" }
  end,
}
Slash.register{
  key = "setup", desc = ns.L["Run the setup wizard"], order = 100,
  run = function()
    if not ns.Wizard then return { "setup: the wizard is not loaded" } end
    if ns.Wizard.Open() then return {} end   -- the window IS the output
    return { "setup: could not open the window (AceGUI-3.0 missing?)" }
  end,
}
Slash.register{
  key = "lock", desc = ns.L["Lock/unlock frames"], order = 101,
  run = function()
    if not ns.Queue then return { "lock: display not loaded" } end
    local locked = ns.Queue.SetLocked(not ns.Queue.isLocked())
    if locked then
      return { "Frames locked." }
    end
    -- Say where it is, because an unlocked frame with nothing in it is invisible: before a build is
    -- active the strip has no icons, and "drag it" is unhelpful advice about an empty rectangle.
    return { "Frames unlocked — drag the queue to move it. /elm lock again to lock." }
  end,
}
Slash.register{
  key = "profile", args = "<key>", desc = ns.L["Pin a build"], order = 102,
  run = function(rest)
    local pack = ns.Display and ns.Display.currentPack()
    if not (pack and pack.builds) then return { "profile: no data pack for your class" } end
    local keys = {}
    for key in pairs(pack.builds) do keys[#keys + 1] = key end
    table.sort(keys)

    local wanted = rest and rest:match("^(%S+)")
    if not wanted then
      -- Naming the current one matters as much as listing them: `activeBuild` may have been chosen
      -- by a rule the user never saw, and "which am I on" is otherwise unanswerable.
      local _, active, why = nil, nil, nil
      if ns.Display then _, active, why = ns.Display.activeBuild() end
      local lines = { "Builds: " .. table.concat(keys, ", ") }
      lines[#lines + 1] = string.format("Active: %s (%s)", tostring(active), tostring(why))
      lines[#lines + 1] = "Usage: /elm profile <key>, or /elm profile auto to unpin."
      return lines
    end

    local profile = ns.db and ns.db.profile
    if not profile then return { "profile: no profile loaded" } end
    if wanted == "auto" then
      profile.activeBuild = false          -- the DB's documented "unset" sentinel, never nil
      if ns.Display then ns.Display.refresh() end
      return { "Unpinned. Elmira will choose a build for you again." }
    end
    if not pack.builds[wanted] then
      return { string.format("No build %q. Available: %s", wanted, table.concat(keys, ", ")) }
    end
    profile.activeBuild = wanted
    if ns.Display then ns.Display.refresh() end
    return { "Pinned to " .. wanted .. ". /elm profile auto to undo." }
  end,
}
Slash.register{
  key = "advise", desc = ns.L["Gear advisor"], order = 103,
  run = function()
    if not (ns.Advisor and ns.Detect and ns.API) then return { "advise: the advisor is not loaded" } end
    local pack = ns.Display and ns.Display.currentPack()
    if not pack then return { "advise: no data pack for your class" } end
    local _, buildKey = ns.Display.activeBuild()
    if not buildKey then return { "advise: no active build" } end

    local advice = pack.advice and pack.class and pack.advice[pack.class]
      and pack.advice[pack.class][buildKey]
    if not advice then
      -- A build with no advice entry is a data gap, not an error, and saying which build it is
      -- makes it actionable instead of mysterious.
      return { string.format("No gear advice has been written for %s yet.", buildKey) }
    end

    local state = ns.API.GetState()
    local detection = ns.Detect.gather(state, ns.Adapter, pack)
    local rec = ns.Advisor.recommend(advice, state,
      { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses },
      { soul = detection.soul, weapon = detection.weapon, build = buildKey })
    local lines = { "Gear advice for " .. buildKey .. ":" }
    for _, line in ipairs(ns.Advisor.lines(rec, ns.L)) do lines[#lines + 1] = "  " .. line end
    if #lines == 1 then lines[#lines + 1] = "  Nothing to change." end
    return lines
  end,
}
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
