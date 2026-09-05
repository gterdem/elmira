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
local lastBuildKey
local lastError = {}      -- renderer name -> the last error text reported, so it is said once
local lastVisible         -- nil until the first tick decides; then true/false
-- Which spells were statically live, and for which build (ADR-0015 amendment). One declaration:
-- separately, deleting either only makes it a global, which no test can see.
local gateSnapshot, gateKey

-- Renderers subscribe rather than the driver naming them: the queue strip, the bar glow and the
-- overlay all want the same queue and must never each run their own loop.
function Display.register(name, render)
  if type(name) ~= "string" or type(render) ~= "function" then return false end
  for _, r in ipairs(renderers) do
    if r.name == name then r.render = render; return true end   -- re-register replaces, no duplicates
  end
  renderers[#renderers + 1] = { name = name, render = render }
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
  if not (ns.API and ns.Adapter and ns.Adapter.playerClass) then return nil end
  local packs = ns.API.GetProviders("dataPacks")
  local class = ns.Adapter.playerClass()
  return class and packs and packs[class] or nil
end

-- Compiled build + key + why it was chosen. The reason is carried so `/elm debug` can answer "why
-- is it showing this build?" for a choice the user did not make.
function Display.activeBuild()
  local pack = Display.currentPack()
  if not pack then return nil, nil, "no data pack for this class" end
  local profile = ns.db and ns.db.profile
  local key, reason = ns.Profiles.resolve(pack, profile)
  if not key then return nil, nil, reason end
  local ctx = { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
  -- A pinned key may name one of the user's forks (ADR-0010); UserBuilds.find is the one lookup.
  local build = ns.UserBuilds and ns.UserBuilds.find(pack, key) or pack.builds[key]
  local compiled, errors = ns.compileBuild(build, ctx)
  if not compiled then
    return nil, key, "build '" .. key .. "' failed to compile (" .. #(errors or {}) .. " problem(s))"
  end
  return compiled, key, reason
end

-- Which rows of the active build cannot fire for this character, and why. The Builder dims these
-- (M5e) and `/elm debug gates` prints them; the announcement below is the same answer, said once,
-- at the moment it changes.
function Display.inactiveRows()
  local compiled, key = Display.activeBuild()
  if not (compiled and ns.Gates) then return {}, key end
  -- A nil state needs no guard of its own: Gates.evaluate answers with no rows for one.
  local state = ns.API and ns.API.GetState()
  local out = {}
  for _, row in ipairs(ns.Gates.evaluate(compiled, state, Display.gateContext())) do
    if not row.active then out[#out + 1] = row end
  end
  return out, key
end

-- The pack tables Core/Gates needs to turn a condition into a sentence: a set's name, a bonus's
-- note. Built here rather than in Gates because only Display knows which pack is loaded.
function Display.gateContext()
  local pack = Display.currentPack()
  local caps = ns.Adapter and ns.Adapter.capabilities and ns.Adapter.capabilities()
  if not pack then return { capabilities = caps } end
  return { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses,
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
  gateSnapshot, gateKey = now, key
  if wasKey ~= key then return nil end

  local diff = ns.Gates.diff(before, now)
  local text = ns.Gates.announcement(diff, key)
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
function Display.spellIcon(spellKey)
  local pack = Display.currentPack()
  local data = pack and pack.spells and pack.spells[spellKey]
  if not (data and data.id and GetSpellTexture) then return nil end
  return GetSpellTexture(data.id)
end

-- The texture in an inventory SLOT, for the Builder's item palette. Slot-based, not item-based,
-- because that is what a build entry binds to (`entry.item = 13`) -- the icon follows the trinket
-- you swap in without the rotation changing.
function Display.itemIcon(slot)
  if not (slot and GetInventoryItemTexture) then return nil end
  return GetInventoryItemTexture("player", slot)
end

-- The player cast something. Two things care: the strip, which pops the icon, and the
-- announcement, which says a long cooldown went out.
--
-- Both live here rather than in Queue because the strip's half is skipped when the strip is hidden
-- or still, and an announcement must not inherit that: someone who hides the queue and watches only
-- the bar glow still wants to be told a cooldown was used.
function Display.noteCast(spellID)
  local key = ns.Queue and ns.Queue.keyForSpellID and ns.Queue.keyForSpellID(spellID)
  if key then Display.announceCooldown(key) end
  if ns.Queue and ns.Queue.noteCast then ns.Queue.noteCast(spellID) end
  return key
end

-- "Avenging Wrath used." -- the only category that may reach party chat, so the bar for what counts
-- is deliberately high (Core/Announce.cooldownFloor). Nothing emitted this category at all until
-- now: it had routing, a colour and the one party toggle, and no code path that fired it.
function Display.announceCooldown(key)
  if not (ns.Announce and ns.Announce.worthAnnouncing) then return false end
  local pack = Display.currentPack()
  local data = pack and pack.spells and pack.spells[key]
  if not (data and ns.Announce.worthAnnouncing(data.cooldown)) then return false end
  local name = (data.id and ns.BarGlow and ns.BarGlow.spellName and ns.BarGlow.spellName(data.id))
    or (ns.Detect and ns.Detect.readableName and ns.Detect.readableName(key, data))
    or key
  ns.Announce.emit("cooldown", string.format("%s used.", name),
                   { icon = Display.spellIcon(key) })
  return true
end

-- Reads the live state, hands Core/Visibility booleans, returns show/hide plus the reason. The
-- reason is carried so `/elm debug perf` can say why the screen is empty — "the addon is broken" and
-- "you are standing in Ironforge with no target" look identical otherwise.
function Display.shouldShow()
  local profile = ns.db and ns.db.profile
  if profile and profile.enabled == false then return false, "display disabled" end
  local mode = (profile and profile.visibility) or ns.Visibility.DEFAULT
  local state = ns.API and ns.API.GetState()
  if not state then return true, "no state yet" end
  local ok, ctx = pcall(function()
    return { inCombat = state:inCombat() == true, hasTarget = state:targetExists() == true }
  end)
  if not ok then return true, "state unreadable" end
  return ns.Visibility.shouldShow(mode, ctx)
end

function Display.computeQueue(depth)
  local compiled, key = Display.activeBuild()
  if not compiled then return nil, key end
  local state = ns.API.GetState()
  return ns.Simulation.queue(compiled, state, depth or 5), key
end

-- Renders to every subscriber. `visible` is the third argument rather than a module flag the
-- renderers read back out of Display, so a renderer is a pure function of what it was handed.
local function renderAll(queue, key, visible)
  for _, r in ipairs(renderers) do
    -- One renderer erroring must not take the others down with it, and must not kill the OnUpdate
    -- handler — a dead OnUpdate is a display that silently stops updating, which is this codebase's
    -- characteristic failure shape.
    local ok, err = pcall(r.render, queue, key, visible)
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
          ns.log("Elmira: %s", text)
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

  -- Hidden costs one boolean read and no queue computation at all — which is the point, since for
  -- most of a session the answer is "hidden". The transition is painted once so the strip actually
  -- disappears and any bar glow is released; after that a hidden tick does nothing.
  local visible = Display.shouldShow()
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
  local queue, key = Display.computeQueue(depth)

  -- A build change must repaint even if the queue happens to look the same: the icons may be
  -- identical while the reasons behind them are not.
  local changed = (key ~= lastBuildKey) or ns.Ticker.queuesDiffer(lastQueue, queue)
  if not changed then return "unchanged" end

  lastQueue, lastBuildKey = queue, key
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
