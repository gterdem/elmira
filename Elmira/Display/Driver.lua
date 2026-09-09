-- Elmira/Display/Driver.lua — the update loop from docs/01 §7, finally implemented.
--
--   event -> invalidate()  ->  dirty
--   OnUpdate (<=10 Hz)     ->  if Ticker says run: recompute; if the queue CHANGED: render
--
-- Everything before M3 computed a queue on demand — a slash command, a recorder mark. This is the
-- first thing in the addon that runs continuously, so it is also the first thing that can cost a
-- player framerate. Two throttles, deliberately separate:
--   * Core/Ticker decides whether to RECOMPUTE (rate cap + idle backstop).
--   * Ticker.queuesDiffer decides whether to RENDER. A rotation holds the same top suggestions for
--     seconds at a time, so most recomputes produce an identical queue and re-rendering it would
--     rebuild textures and strings ten times a second for no visible change.
--
-- Frames live here, not in Core (hard rule 3). `tick(now)` takes its time as an argument so the
-- decision path is reachable from a spec, and the OnUpdate handler feeds it `ns.now()` — the same
-- injected clock everything else uses, so Display never grows a second one.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Display = {}
local renderers = {}      -- ordered list of { name, render }
local ticker
local frame
local lastQueue           -- the queue as rendered, for the change test
local buffers = { {}, {} } -- the two queue tables the tick alternates between (see Display.tick)
local lastBuildKey
local lastError = {}      -- renderer name -> the last error text reported, so it is said once
local lastVisible         -- nil until the first tick decides; then true/false
-- AB1-D5. `watched` is the tracked set Core/Track polls -- rebuilt only when the settings version
-- or the pack changes, never per tick. `trackPrev` is Track's own memory between ticks, and
-- `lastNowKey` is what the `suggested` event compares against. One declaration for the four:
-- deleting any single `local` here would only make it a global, which no test can see.
local watched, watchedVersion, watchedPack, trackPrev, lastNowKey = {}, nil, nil, nil, nil
-- Which spells were statically live, and for which build (ADR-0015 amendment). One declaration:
-- separately, deleting either only makes it a global, which no test can see.
local gateSnapshot, gateKey

-- Renderers subscribe rather than the driver naming them: the queue strip, the bar glow and the
-- overlay all want the same queue and must never each run their own loop.
--
-- `tick` is optional and is what a renderer registers when part of what it draws is a function of
-- TIME rather than of the queue (PE9-D1: the strip's "in 3.4s" countdown). Renders happen only when
-- the queue changes, which can be seconds apart, so anything counting down would freeze between
-- them -- a number that looks alive and is not. It is emphatically not a second loop: same
-- OnUpdate, same Ticker cap, and it only runs on ticks that were going to happen anyway.
function Display.register(name, render, tick)
  if type(name) ~= "string" or type(render) ~= "function" then return false end
  for _, r in ipairs(renderers) do
    -- re-register replaces, no duplicates. `tick` is written unconditionally, so a re-register
    -- with no tick clears a stale one rather than leaving the old closure running.
    if r.name == name then r.render, r.tick = render, tick; return true end
  end
  renderers[#renderers + 1] = { name = name, render = render, tick = tick, phase = "render:" .. name }
  return true
end

function Display.renderers() return renderers end

function Display.invalidate()
  if ticker then ticker:markDirty() end
end

function Display.ticker()
  if not ticker then ticker = ns.Ticker.new() end
  return ticker
end

-- The pack for the player's class, or nil. Guarded because a class with no shipped pack is a normal
-- state (only Paladin ships at M2), not an error.
function Display.currentPack()
  if not (ns.API and ns.API.GetProvider and ns.Adapter and ns.Adapter.playerClass) then return nil end
  local class = ns.Adapter.playerClass()
  return class and ns.API.GetProvider("dataPacks", class) or nil
end

-- The compile context for a pack, built once per pack rather than once per tick. Core/Slash's
-- compile cache compares the ctx's four tables by identity to decide whether a hit is still good,
-- so the ctx must carry the pack's CURRENT tables: a pack whose tables were swapped underneath it
-- gets a fresh ctx, and with it a fresh compile. Weak keys let a replaced pack go.
local ctxByPack = setmetatable({}, { __mode = "k" })
-- R2b (D76): `spells` widens to the merged registry+pack view (`Spells.merged`, pack wins on a
-- collision) so the ACTIVE build compiles a registry-key entry's `data` (cooldown seconds, cost,
-- cdVolatile) exactly as it would a pack one -- without this, a saved rotation naming a registered
-- spell validated (Core/UserBuilds.ctxFor) but rendered nothing, because THIS ctx, not that one,
-- compiles the build the render loop actually runs. `Spells.merged` returns the SAME table object
-- for this pack on every call, so `held.spells == spells` below still holds across ticks exactly as
-- it did comparing `pack.spells` to itself -- the cache still serves one ctx per pack, not a fresh
-- one every tick.
local function packContext(pack)
  local held = ctxByPack[pack]
  local spells = ns.Spells and ns.Spells.merged and ns.Spells.merged(pack) or pack.spells
  if held and held.spells == spells and held.sets == pack.sets
     and held.souls == pack.souls and held.bonuses == pack.bonuses then
    return held
  end
  local ctx = { spells = spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
  ctxByPack[pack] = ctx
  return ctx
end

-- Compiled build + key + why it was chosen. The reason is carried so `/elm debug` can answer "why
-- is it showing this build?" for a choice the user did not make.
function Display.activeBuild()
  local pack = Display.currentPack()
  if not pack then return nil, nil, "no data pack for this class" end
  local profile = ns.db and ns.db.profile
  local key, reason = ns.Profiles.resolve(pack, profile)
  if not key then return nil, nil, reason end
  local ctx = packContext(pack)
  -- A pinned key may name one of the user's forks (ADR-0010); UserBuilds.find is the one lookup.
  local build = ns.UserBuilds and ns.UserBuilds.find(pack, key) or pack.builds[key]
  local compiled, errors = ns.compileBuild(build, ctx)
  if not compiled then
    return nil, key, "build '" .. key .. "' failed to compile (" .. #(errors or {}) .. " problem(s))"
  end
  return compiled, key, reason
end

-- Display.gateRows() -> compiled, rows, key
--
-- ALL the rows, active and not, in the compiled build's own order. The Builder needs the whole list
-- because its per-row status has to distinguish "this row cannot fire for you" from "this row is
-- fine and simply is not first right now", and only the second half of that is in `inactiveRows`.
--
-- Row i belongs to SAVED entry `compiled.entries[i].index`, not to saved entry i: `Schema.compile`
-- skips disabled entries and records the position it came from. A caller that maps by ordinal puts
-- every status one row out as soon as a line is switched off.
function Display.gateRows()
  local compiled, key = Display.activeBuild()
  if not (compiled and ns.Gates) then return nil, {}, key end
  -- A nil state needs no guard of its own: Gates.evaluate answers with no rows for one.
  local state = ns.API and ns.API.GetState()
  return compiled, ns.Gates.evaluate(compiled, state, Display.gateContext()), key
end

-- Which rows of the active build cannot fire for this character, and why. `/elm debug gates` prints
-- these and Display.checkGates announces the moment the set changes; the Builder wants gateRows
-- instead, because it draws the active ones too.
function Display.inactiveRows()
  local _, rows, key = Display.gateRows()
  local out = {}
  for _, row in ipairs(rows) do
    if not row.active then out[#out + 1] = row end
  end
  return out, key
end

-- The queue exactly as it is on screen, or nil while the display is hidden -- which is most of a
-- session, and is a real answer rather than a missing one ("no target, out of combat").
--
-- Only valid for the CURRENT render. `Display.tick` alternates between two buffers, so the table
-- this returns is refilled two queue changes from now; a caller reads it fresh each time it draws
-- and never keeps it.
function Display.currentQueue()
  return lastQueue
end

-- The pack tables Core/Gates needs to turn a condition into a sentence: a set's name, a bonus's
-- note. Built here rather than in Gates because only Display knows which pack is loaded.
function Display.gateContext()
  local pack = Display.currentPack()
  local caps = ns.Adapter and ns.Adapter.capabilities and ns.Adapter.capabilities()
  if not pack then return { capabilities = caps } end
  -- R2b (D76): same merge as packContext, so a gate naming a registry key ("this row needs X")
  -- resolves it rather than reporting it as absent from the pack.
  local spells = ns.Spells and ns.Spells.merged and ns.Spells.merged(pack) or pack.spells
  return { spells = spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses,
           capabilities = caps }
end

-- Has this character's gear, runes or level just changed which rows of the build can fire? Called
-- from Core/Init on the events that can move a STATIC gate -- never from the render loop, because
-- the answer cannot change between two frames.
--
-- The first call after a build change records silently. There is nothing to announce about a
-- rotation the player has only just switched to, and saying "Divine Storm is now active" because
-- they changed profile would be a message about nothing.
function Display.checkGates()
  local compiled, key = Display.activeBuild()
  local state = ns.API and ns.API.GetState()
  if not (compiled and state and ns.Gates) then return nil end

  local now = ns.Gates.snapshot(ns.Gates.evaluate(compiled, state, Display.gateContext()))
  local before, wasKey = gateSnapshot, gateKey

  -- PE15: uncertainty is not information -- it must be neither announced NOR REMEMBERED.
  --
  -- This is the load-bearing half. Suppressing the announcement alone still lets an uncertain
  -- verdict overwrite the remembered one, and then the next reading the client DOES give looks
  -- like a real change and announces anyway: the symptom moves one call later and the fix looks
  -- like it is in place. So a spell whose new verdict rests on something unreadable keeps exactly
  -- what was last known about it, and a spell nothing was ever known about is not recorded at all
  -- -- its first readable verdict is then a first sighting, which Gates.diff already says nothing
  -- about. Assigning nil to the key `pairs` is currently on is the one mutation Lua allows.
  for spell, entry in pairs(now) do
    if entry.certain == false then
      local remembered
      if wasKey == key and before then remembered = before[spell] end
      now[spell] = remembered
    end
  end

  gateSnapshot, gateKey = now, key
  if wasKey ~= key then return nil end

  local diff = ns.Gates.diff(before, now)
  -- D40: `key` is the raw storage key -- a shipped build's own name, or a fork's `USER_...` slug --
  -- never something a player has seen. `UserBuilds.displayName` is the one place that turns either
  -- into the name shown everywhere else on screen; without it this announcement was the one place
  -- in the addon a `USER_` key leaked into a sentence a player reads. Core's copy, not the Options
  -- panel's: Display does not reach up a layer, and the panel is not loaded in every spec that
  -- reaches this line -- which is exactly how the first version of this fix came to be untestable.
  local name = (ns.UserBuilds and ns.UserBuilds.displayName
                and ns.UserBuilds.displayName(Display.currentPack(), key)) or key
  local text = ns.Gates.announcement(diff, name)
  if not text then return nil end
  -- The icon of the spell the message is about, so a glance at the toast says which ability
  -- changed before the sentence has been read.
  local first = diff.activated[1] or diff.deactivated[1]
  if ns.Announce then ns.Announce.emit("rotation", text, { icon = Display.spellIcon(first.spell) }) end
  return text
end

-- Presentation, so it lives here rather than on the State contract: nothing in the rotation depends
-- on what a spell looks like. Display/Queue draws its icons through this too -- two copies of the
-- same lookup is one that can go stale.
--
-- D81 (review finding on R2b): this used to read `pack.spells` alone, so a spell added by id,
-- by name or from the spellbook -- resolvable everywhere else after D75/D79/D80 -- still had no
-- icon anywhere it was drawn, including U1's rows. `ns.Spells.merged` is the same per-character
-- merge every other consumer widened to; a spell that genuinely has none (an item line, or an
-- unresolved key) still falls through to the nil the caller already treats as "no icon".
function Display.spellIcon(spellKey)
  local pack = Display.currentPack()
  local spells = (pack and ns.Spells and ns.Spells.merged and ns.Spells.merged(pack))
    or (pack and pack.spells)
  local data = spells and spells[spellKey]
  if not (data and data.id and GetSpellTexture) then return nil end
  return GetSpellTexture(data.id)
end

-- I1c: the Abilities page's "from your spellbook" picker lists spells that may not be registered
-- under any key yet -- that is the whole point of the picker -- so it has no `spellKey` to hand
-- `Display.spellIcon` above; it only has the raw spell id the adapter's `spellbookEntries()`
-- already carries. Same guard, same source (`GetSpellTexture`), just keyed by id instead of by the
-- merged-registry lookup: the "by id" sibling of `spellIcon`, the way `itemIcon` is its "by slot" one.
function Display.spellIconByID(id)
  if not (type(id) == "number" and id > 0 and GetSpellTexture) then return nil end
  return GetSpellTexture(id)
end

-- The texture in an inventory SLOT, for the Builder's item palette. Slot-based, not item-based,
-- because that is what a build entry binds to (`entry.item = 13`) -- the icon follows the trinket
-- you swap in without the rotation changing.
function Display.itemIcon(slot)
  if not (slot and GetInventoryItemTexture) then return nil end
  return GetInventoryItemTexture("player", slot)
end

-- The player cast something. Two things care: the strip, which pops the icon, and everything the
-- ability's own settings say happens when it is used (AB1-D5's `used` event).
--
-- Both live here rather than in Queue because the strip's half is skipped when the strip is hidden
-- or still, and a sound or an announcement must not inherit that: someone who hides the queue and
-- watches only the bar glow still wants to be told a cooldown was used.
function Display.noteCast(spellID)
  local key = ns.Queue and ns.Queue.keyForSpellID and ns.Queue.keyForSpellID(spellID)
  if key then Display.abilityEvent(key, "used") end
  if ns.Queue and ns.Queue.noteCast then ns.Queue.noteCast(spellID) end
  return key
end

-- Display.spellName(key) -> what a player calls it
--
-- The client's own name for the id the merged registry holds, falling back to the readable form of
-- the key. Both halves already existed inside announceCooldown; they are named here because the
-- announcement is no longer the only sentence an ability's key has to appear in.
function Display.spellName(key)
  local pack = Display.currentPack()
  local spells = (pack and ns.Spells and ns.Spells.merged and ns.Spells.merged(pack))
    or (pack and pack.spells)
  local data = (spells and spells[key]) or {}
  return (data.id and ns.BarGlow and ns.BarGlow.spellName and ns.BarGlow.spellName(data.id))
    or (ns.Detect and ns.Detect.readableName and ns.Detect.readableName(key, data))
    or key
end

-- "Divine Protection used -- 10s." (AB1-D10.)
--
-- No cooldown floor any more: a number of seconds cannot tell a tank's defensive save from a burst
-- cooldown, and that is exactly the distinction that decides whether a line belongs in a group's
-- chat. The ability's own Announcement tab decides, and it ships OFF for every ability including
-- the long ones. Routing (chat / screen / party / raid) is still Core/Announce's.
function Display.announceCooldown(key)
  local A = ns.AbilitySettings
  if not (ns.Announce and A) then return false end
  local settings = A.effective(key, "announce")
  if not settings.enabled then return false end
  local name = Display.spellName(key)
  local text = string.format("%s used.", name)
  if settings.duration then
    -- The buff's FULL length, State's third return -- not what is left of it, which at the instant
    -- of the cast is the same number only by luck.
    local state = ns.API and ns.API.GetState()
    local full = state and select(3, state:buff(key)) or nil
    -- Omitted when unknown, never guessed: "used -- 0s" reads as a fact we do not have.
    if full and full > 0 then text = string.format("%s used -- %ds.", name, full) end
  end
  ns.Announce.emit("cooldown", text, { icon = Display.spellIcon(key) })
  return true
end

-- Display.watchedKeys() -> [{ key =, expiring = }]
--
-- The tracked set (AB1-D5): every registry key whose settings ask for something Core/Track has to
-- watch the state for. Rebuilt only when Core/AbilitySettings' version counter moves or the pack
-- changes -- a fresh walk of the whole registry on every tick would be the aura scan this addon
-- spent M5 removing. Sorted, so two ticks report the same events in the same order.
function Display.watchedKeys()
  local A = ns.AbilitySettings
  if not A then return watched end
  local pack = Display.currentPack()
  local v = A.version()
  if watchedVersion == v and watchedPack == pack then return watched end
  watchedVersion, watchedPack = v, pack
  for i = #watched, 1, -1 do watched[i] = nil end
  local spells = (ns.Spells and ns.Spells.merged and ns.Spells.merged(pack)) or (pack and pack.spells) or {}
  for key in pairs(spells) do
    if A.tracked(key) then
      watched[#watched + 1] = { key = key, expiring = A.effective(key, "general").expiringSeconds }
    end
  end
  table.sort(watched, function(a, b) return a.key < b.key end)
  return watched
end

-- Display.abilityEvent(key, event) -> did anything happen
--
-- The one place one of AB1-D5's five events turns into something the player notices. Every channel
-- that can answer for an event answers here, so "Only in combat" is asked once rather than once per
-- channel -- a guard applied in four places is a guard that will be forgotten in one of them.
function Display.abilityEvent(key, event)
  local A = ns.AbilitySettings
  if not A then return false end
  if A.effective(key, "general").onlyInCombat then
    local state = ns.API and ns.API.GetState()
    if not (state and state:inCombat()) then return false end
  end
  local acted = false
  if ns.Sounds and ns.Sounds.abilitySoundsOn() and A.channelOn(key, "sound") then
    if ns.Sounds.play(A.effective(key, "sound")[event]) then acted = true end
  end
  -- AB2-D1: the screen edge is a channel like any other now. Overlay decides whether THIS ability's
  -- edge cares about THIS event; the driver only has to reach it, which is the half that used to be
  -- a renderer with a now-slot diff of its own.
  if ns.Overlay and ns.Overlay.Fire(key, event) then acted = true end
  if event == "used" and Display.announceCooldown(key) then acted = true end
  return acted
end

-- Reads the live state, hands Core/Visibility booleans, returns show/hide plus the reason. The
-- reason is carried so `/elm debug perf` can say why the screen is empty — "the addon is broken" and
-- "you are standing in Ironforge with no target" look identical otherwise.
--
-- One context table for the life of the module, refilled per tick, and a named reader rather than
-- a closure: this runs on every tick the display is not hidden, and a closure plus a table per
-- call was the visibility phase's entire cost in `/elm debug memory`.
local showCtx = {}
local function readShowCtx(state)
  showCtx.inCombat = state:inCombat() == true
  -- PE9-D6: attackable, not merely present. The hostility half of the reading lives in the adapter
  -- (hard rule 3); this is the one place the display asks for it.
  showCtx.targetAttackable = state:targetAttackable() == true
  return showCtx
end

function Display.shouldShow()
  local profile = ns.db and ns.db.profile
  if profile and profile.enabled == false then return false, "display disabled" end
  local mode = (profile and profile.visibility) or ns.Visibility.DEFAULT
  local state = ns.API and ns.API.GetState()
  if not state then return true, "no state yet" end
  local ok, ctx = pcall(readShowCtx, state)
  if not ok then return true, "state unreadable" end
  return ns.Visibility.shouldShow(mode, ctx)
end

-- The two halves are measured separately (Core/MemProbe) because they fail for different reasons:
-- resolving the build is a cache lookup that should cost nothing, while simulating the queue is
-- hundreds of client calls. A single "computeQueue" number cannot tell those apart, and which one
-- holds the memory decides what gets rewritten. `M.enter()` answers nil unless `/elm debug memory`
-- is running, so an ordinary tick pays one comparison.
--
-- `into` is the buffer to refill (see Simulation.queue). Only the tick passes one; a slash command
-- or the recorder asking for a queue gets fresh tables it may keep.
function Display.computeQueue(depth, into)
  local M = ns.MemProbe
  local mark = M and M.enter()
  local compiled, key = Display.activeBuild()
  if mark then M.leave("build", mark) end
  if not compiled then return nil, key end
  local state = ns.API.GetState()
  mark = M and M.enter()
  local queue = ns.Simulation.queue(compiled, state, depth or 5, into)
  if mark then M.leave("simulate", mark) end
  return queue, key
end

-- Renders to every subscriber. `visible` is the third argument rather than a module flag the
-- renderers read back out of Display, so a renderer is a pure function of what it was handed.
local function renderAll(queue, key, visible)
  for _, r in ipairs(renderers) do
    -- One renderer erroring must not take the others down with it, and must not kill the OnUpdate
    -- handler — a dead OnUpdate is a display that silently stops updating, which is this codebase's
    -- characteristic failure shape.
    local M = ns.MemProbe
    local mark = M and M.enter()
    local ok, err = pcall(r.render, queue, key, visible)
    -- `r.phase` is built once at registration, not concatenated here: a string built inside the
    -- measured span would be charging the renderer for the diagnostic watching it.
    if mark then M.leave(r.phase, mark) end
    if not ok then
      -- Once per distinct message. A renderer that errors does so on every queue change, which in
      -- combat is several times a second: the first report is a bug, the next two hundred are noise
      -- that buries it and the fight both.
      err = tostring(err)
      if lastError[r.name] ~= err then
        lastError[r.name] = err
        local text = string.format("Display renderer '%s' errored: %s", r.name, err)
        if ns.Announce then
          ns.Announce.emit("warning", text)
        else
          ns.log("%s", text)
        end
      end
    else
      lastError[r.name] = nil
    end
  end
end

-- One tick. Returns "rendered", "unchanged", "hidden" or "skipped", which is what makes
-- `/elm debug perf` able to report work avoided rather than merely assert that some was.
function Display.tick(now)
  local t = Display.ticker()
  if not t:shouldRun(now) then return "skipped" end

  -- AB1-D5: the tracker rides the loop that already exists -- same OnUpdate, same 10 Hz cap, no
  -- second timer. Before the visibility branch on purpose: a screen flash or a sound for a spell
  -- coming off cooldown is exactly what someone who has hidden the strip is relying on.
  if ns.Track then
    local fired, memory = ns.Track.tick(ns.API and ns.API.GetState(), Display.watchedKeys(), trackPrev)
    trackPrev = memory
    for _, e in ipairs(fired) do Display.abilityEvent(e.key, e.event) end
  end

  -- Hidden costs one boolean read and no queue computation at all — which is the point, since for
  -- most of a session the answer is "hidden". The transition is painted once so the strip actually
  -- disappears and any bar glow is released; after that a hidden tick does nothing.
  local M = ns.MemProbe
  local mark = M and M.enter()
  local visible = Display.shouldShow()
  if mark then M.leave("visibility", mark) end
  if not visible then
    if lastVisible ~= false then
      lastVisible = false
      lastQueue, lastBuildKey = nil, nil
      renderAll(nil, nil, false)
    end
    return "hidden"
  end
  lastVisible = true

  local profile = ns.db and ns.db.profile
  local depth = (profile and profile.depth) or 3
  -- Two buffers: the queue on screen and the one being computed. Most recomputes come back
  -- "unchanged", and the one on screen must survive them untouched, so the fresh queue always lands
  -- in whichever buffer is NOT being shown. A recompute that changes nothing therefore allocates
  -- nothing; one that does swaps the two.
  local spare = (lastQueue == buffers[1]) and buffers[2] or buffers[1]
  local queue, key = Display.computeQueue(depth, spare)

  -- A build change must repaint even if the queue happens to look the same: the icons may be
  -- identical while the reasons behind them are not.
  local changed = (key ~= lastBuildKey) or ns.Ticker.queuesDiffer(lastQueue, queue)
  if not changed then
    -- The queue is the same, but a countdown drawn on it is not (PE9-D1). pcall for the same reason
    -- renderAll uses one: a throwing tick must not kill the OnUpdate handler. Not reported here --
    -- anything that can break the tick breaks the render too, and that path already says so once.
    for _, r in ipairs(renderers) do
      if r.tick then pcall(r.tick, now) end
    end
    return "unchanged"
  end

  lastQueue, lastBuildKey = queue, key
  -- The `suggested` event (AB1-D5): the now-slot became THIS ability. Compared separately from
  -- `changed` above, which is true for any movement anywhere in the queue -- firing a cue because
  -- the third icon changed is the strobe ADR-0009 is about.
  local nowKey = queue[1] and queue[1].spell or nil
  if nowKey ~= lastNowKey then
    lastNowKey = nowKey
    if nowKey then Display.abilityEvent(nowKey, "suggested") end
  end
  renderAll(queue, key, true)
  return "rendered"
end

function Display.Enable()
  if not frame then
    frame = CreateFrame("Frame", nil, UIParent)   -- plain frame, never a secure template (rule 1)
    -- ns.now(), not GetTime: all time comes from the injected clock (house style), which
    -- is what lets tick() be driven from a spec.
    frame:SetScript("OnUpdate", function()
      Display.tick(ns.now())
    end)
  end
  frame:Show()
  Display.invalidate()
  return true
end

function Display.Disable()
  if frame then frame:Hide() end
  return true
end

function Display.isEnabled()
  return frame ~= nil and frame:IsShown()
end

-- Forces the next tick to recompute AND repaint, regardless of whether the queue changed. Used by
-- anything that alters how the queue is drawn rather than what it contains (scale, depth, a colour).
function Display.resetGates()
  gateSnapshot, gateKey = nil, nil
end

-- Forget everything painted AND everything known about the gates. The gate half matters because a
-- build can change WITHOUT its key changing -- an import over the same fork, a profile copy, the
-- M5e editor -- and the next look would then diff the new rows against the old build's and announce
-- a gear change for an edit the player made themselves. The cost is one silent re-record.
function Display.refresh()
  lastQueue, lastBuildKey, lastVisible = nil, nil, nil
  Display.resetGates()
  Display.invalidate()
end

function Display.stats()
  local s = Display.ticker():stats()
  s.renderers = #renderers
  -- lastBuildKey is only ever set by a RENDER, so it is nil whenever the display is hidden -- which
  -- is most of a session, and precisely when someone runs `/elm debug perf` to ask why the screen is
  -- empty. Printing `build=nil` there answered "I have no idea" to a question that has a cheap,
  -- deterministic answer. Resolving costs a compile and this is a slash command, not the tick.
  s.build = lastBuildKey
  if not s.build then
    local _, key, reason = Display.activeBuild()
    s.build, s.buildReason = key, reason
  end
  s.visible, s.visibleReason = Display.shouldShow()
  s.mode = (ns.db and ns.db.profile and ns.db.profile.visibility) or ns.Visibility.DEFAULT
  return s
end

ns.Display = Display
return Display
