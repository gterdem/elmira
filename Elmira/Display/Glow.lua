-- Elmira/Display/Glow.lua — thin wrapper over LibCustomGlow-1.0.
--
-- Two rules this file exists to enforce, both learned the hard way:
--
-- 1. **The library comes from LibStub only, never a vendored copy.** Six other addons on the author's
--    install embed LibCustomGlow (ElvUI_Libraries, WeakAuras, DBM-Core, Gargul, LootReserve,
--    ProjectAzilroka) and LibStub resolves to the highest loaded minor (docs/07 §3). Reaching for a
--    local copy would mean glowing with a different version than everything else on screen.
-- 2. **Every glow is keyed.** LibCustomGlow lets several addons glow the same button, but only if
--    each passes its own key — otherwise stopping ours stops WeakAuras' too, and the user blames the
--    wrong addon. `ButtonGlow` has no key parameter, which is exactly why it is not the default.
--
-- Glows are also idempotent here: LibCustomGlow restarts its animation if Start is called again, so
-- a display that re-glowed every tick would strobe. `active` is what prevents that.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Glow = {}
local KEY = "Elmira"
-- A second key so the dim "next" glow is a separate object on the same button: LibCustomGlow keys
-- its frames, and reusing one key would make the two overwrite each other silently.
local KEY_NEXT = "ElmiraNext"
local active = {}          -- frame -> { style, glowKey } currently applied by US
local nowFrames = {}       -- frames glowing for the current now-slot
local nextFrames = {}      -- frames glowing dimly for the slot after it (off by default)

-- LibCustomGlow-1.0's three starters take the key at a DIFFERENT position each:
--   PixelGlow_Start   (r, color, N, frequency, length, th, xOffset, yOffset, border, key, frameLevel)
--   AutoCastGlow_Start(r, color, N, frequency, scale, xOffset, yOffset, key, frameLevel)
--   ButtonGlow_Start  (r, color, frequency, frameLevel)                       -- no key at all
-- Counting nils by eye put ours in AutoCast's `yOffset`, so the library did arithmetic on the string
-- "Elmira" and the whole queue renderer died the moment anyone chose that style. Positions are
-- declared as data here and asserted in tests/spec/glow_spec.lua, because a call site written as a
-- row of nils cannot fail in any way a reader or a spec can see.
--
-- `at` is where each setting goes in that row; `default` is what the LIBRARY would use if we passed
-- nothing, which is what the options sliders show before the user has chosen anything. Storing our
-- own copy of the library's defaults is deliberate: a setting left alone passes nil, so a default
-- install renders exactly as it did before these settings existed, and the numbers here only ever
-- describe what the user is looking at.
--
-- PROC is the odd one out: ProcGlow_Start takes an options TABLE, not a positional row.
local STYLES = {
  PIXEL    = { start = "PixelGlow_Start",    stop = "PixelGlow_Stop",    keyAt = 10,
               at = { particles = 3, frequency = 4, thickness = 6 },
               default = { particles = 8, frequency = 0.25, thickness = 1 } },
  AUTOCAST = { start = "AutoCastGlow_Start", stop = "AutoCastGlow_Stop", keyAt = 8,
               at = { particles = 3, frequency = 4 },
               default = { particles = 4, frequency = 0.125 } },
  BUTTON   = { start = "ButtonGlow_Start",   stop = "ButtonGlow_Stop",   keyAt = nil,
               at = { frequency = 3 },
               default = { frequency = 0.25 } },
  PROC     = { start = "ProcGlow_Start",     stop = "ProcGlow_Stop",     options = true,
               at = { speed = "duration" },
               default = { speed = 1 } },
}
Glow.STYLES = STYLES

-- The second suggestion, when the user asks for it. Dim on purpose and OFF by default: this whole
-- ADR exists because two things were competing for one glance, and a second glow is that again.
Glow.SECONDARY_ALPHA = 0.35

-- This ability's glow settings, resolved through Core/AbilitySettings (AB1-D3/D7): its own if it
-- has any, the All abilities entry's otherwise. A nil key means the All abilities entry itself,
-- which is what the options preview and any caller with no spell in hand wants.
--
-- Guarded rather than assumed: glow_spec drives this file without the Core store, and answering
-- with the shipped defaults there is the same "a default install looks as it always did" promise
-- the `false` sentinels below make.
local function glowFor(key)
  local A = ns.AbilitySettings
  if not A then return {} end
  return A.effective(key or A.ALL, "glow") or {}
end

-- Is the bar glow switched on for THIS ability (AB1-D7)? The All abilities entry ships it on, and
-- the flag inherits, so a default install glows everything exactly as it did before this setting
-- existed -- but one ability can now be silenced without silencing the bars.
function Glow.enabledFor(key)
  local A = ns.AbilitySettings
  if not A then return true end
  return A.channelOn(key or A.ALL, "glow")
end

-- AT2-D1: this ability's OWN ctx read -- inCombat/targetAttackable, the same two fields
-- Display/Driver's showCtx carries -- kept here rather than threaded in from the driver because
-- every Display file already reads the state for itself (Queue.Render does the same for its
-- cooldown sweep). Unreadable/absent state answers nil, which callers below treat as "fail open":
-- the same philosophy Display.shouldShow uses, since a broken read must not silently darken every
-- bar in the game.
local function glowCtx()
  local state = ns.API and ns.API.GetState()
  if not state then return nil end
  local ctx = {}
  local ok = pcall(function()
    ctx.inCombat = state:inCombat() == true
    ctx.targetAttackable = state:targetAttackable() == true
  end)
  return ok and ctx or nil
end

-- AT2-D1: is THIS ability's glow allowed on screen right now -- its own "Show the glow" mode and
-- the same "Only in combat" guard the four cue channels already obey (Display/Driver.abilityEvent),
-- both independent of whether the strip itself is showing. `ctx` may be shared across a now/next
-- pair by the caller so one tick asks the state once, not twice.
function Glow.visibleFor(key, ctx)
  local A = ns.AbilitySettings
  if not (A and ns.Visibility) then return true end
  ctx = ctx or glowCtx()
  if not ctx then return true end
  local mode = A.effective(key or A.ALL, "glow").show or ns.Visibility.DEFAULT
  if not ns.Visibility.shouldShow(mode, ctx) then return false end
  local gen = A.effective(key or A.ALL, "general")
  if gen and gen.onlyInCombat and not ctx.inCombat then return false end
  return true
end

-- Which style to draw with -- one answer for both glows. The next-cast glow always uses the SAME
-- style as the real suggestion, dimmed; it never picks its own. PE7 (owner, 2026-09-08): each
-- ability carries its own glow style and colour, so a global override for the second glow would
-- silently replace whatever the player configured for that ability. Brightness is the one
-- difference this glow is allowed to make, which is why `secondaryAlpha` survives and a secondary
-- style does not. No `secondary` argument: a parameter nothing reads is a promise the code cannot
-- keep, and the call sites already say which glow they are starting.
function Glow.styleFor(key)
  local g = glowFor(key)
  return (g.style and STYLES[g.style]) and g.style or "PIXEL"
end

-- The user's dimness, or the shipped default. Read through here so the render path and the preview
-- cannot disagree about how dim the hint is.
function Glow.secondaryAlpha()
  local p = (ns.db and ns.db.profile) or ns.DB.defaults.profile
  local g = (p and p.glow) or {}
  local a = tonumber(g.secondaryAlpha)
  if not a then return Glow.SECONDARY_ALPHA end
  -- Clamped: 0 is an invisible hint, which is what the OFF switch is for, and above 1 is not a
  -- dimming at all.
  if a < 0.05 then return 0.05 end
  if a > 1 then return 1 end
  return a
end

local function lib()
  return LibStub and LibStub("LibCustomGlow-1.0", true) or nil
end

-- What the user has chosen. A numeric setting left alone is `false`, not a number, and a false
-- setting passes NOTHING to the library: that is what keeps a default install rendering exactly as
-- it did before any of these controls existed.
function Glow.settings(key)
  local g = glowFor(key)
  local c = g.color or ns.Colors.HIGHLIGHT
  return {
    color = { c.r, c.g, c.b, 1 },
    particles = g.particles or nil,
    frequency = g.frequency or nil,
    thickness = g.thickness or nil,
    speed = g.speed or nil,
  }
end

-- What a slider shows: the user's number, or the library's own default when they have not chosen.
-- Without this the controls would all read zero and moving one would look like turning it back on.
function Glow.effective(style, name, key)
  local def = STYLES[style] or STYLES.PIXEL
  return Glow.settings(key)[name] or (def.default and def.default[name]) or nil
end

-- Does this style have anything to do with this setting? Pixel is the only one with a thickness,
-- Proc the only one with a duration. Rows that do nothing are worse than absent rows: the user
-- moves the slider, nothing changes, and the panel has lied.
function Glow.applies(style, name)
  local def = STYLES[style]
  return (def and def.at and def.at[name]) ~= nil
end

-- Holes in the arg row are nils, and every one of those parameters defaults sensibly inside the
-- library. Positions are declared as data above and asserted in tests/spec/glow_spec.lua, because
-- a call site written as a row of nils cannot fail in any way a reader or a spec can see.
local function startArgs(styleDef, frame, s, glowKey)
  if styleDef.options then
    return { frame, { color = s.color, duration = s.speed, key = glowKey } }, 2
  end
  local args = { frame, s.color }
  local n = 2
  for name, pos in pairs(styleDef.at) do
    if s[name] then
      args[pos] = s[name]
      if pos > n then n = pos end
    end
  end
  if styleDef.keyAt then
    args[styleDef.keyAt] = glowKey
    if styleDef.keyAt > n then n = styleDef.keyAt end
  end
  return args, n
end
Glow.startArgs = startArgs

function Glow.Start(frame, style, secondary, key)
  if not frame then return false end
  local L = lib()
  if not L then return false end
  style = (style and STYLES[style]) and style or "PIXEL"
  local glowKey = secondary and KEY_NEXT or KEY
  local held = active[frame]
  -- Already glowing this exact way; do not restart. Restarting is visible: the animation jumps
  -- back to its first frame every render, ten times a second.
  if held and held.style == style and held.glowKey == glowKey then return true end
  if held then Glow.Stop(frame) end

  local def = STYLES[style]
  local fn = L[def.start]
  if not fn then return false end
  local s = Glow.settings(key)
  if secondary then
    s.color = { s.color[1], s.color[2], s.color[3], Glow.secondaryAlpha() }
  end
  local args, n = startArgs(def, frame, s, glowKey)
  fn(unpack(args, 1, n))
  active[frame] = { style = style, glowKey = glowKey }
  return true
end

function Glow.Stop(frame)
  if not frame or not active[frame] then return false end
  local L = lib()
  local held = active[frame]
  active[frame] = nil
  if not L then return false end
  local def = STYLES[held.style] or STYLES.PIXEL
  local fn = L[def.stop]
  if not fn then return false end
  -- Every _Stop that takes a key takes it second; ButtonGlow_Stop takes none. Passing OUR key back
  -- is what stops us tearing down a glow some other addon put on the same button.
  if def.keyAt or def.options then fn(frame, held.glowKey) else fn(frame) end
  return true
end

function Glow.StopAll()
  for frame in pairs(active) do Glow.Stop(frame) end
  nowFrames, nextFrames = {}, {}
end

-- The now-slot: every action-bar button carrying the suggested spell. Called on every render, so it
-- must be cheap when nothing changed — it diffs the frame set and only touches what entered or left.
--
-- The queue's own icon used to be in this set. ADR-0015 took it out: the strip and the bar were
-- lighting up for the same spell at the same instant, and the strip's half is the one you cannot
-- press. The glow is the action bar's by default, and the strip speaks in size and motion; AT2-D3's
-- amendment puts the strip's first icon back into this same `wantNow` set, opt-in, when the player
-- asks for it -- the one button that can never be missing the way a bar button can.
function Glow.SetNowSlot(slot, nextSlot)
  local p = (ns.db and ns.db.profile) or ns.DB.defaults.profile
  local g = p.glow or {}
  local q = p.queue or {}
  local wantNow, wantNext = {}, {}

  local nowKey = slot and slot.spell or nil
  local nextKey = nextSlot and nextSlot.spell or nil
  -- One ctx for the whole call: now and next answer the same "is it in combat / is there a target"
  -- question, so there is no reason to read the state twice for one tick.
  local ctx = glowCtx()
  local nowOn = nowKey and Glow.enabledFor(nowKey) and Glow.visibleFor(nowKey, ctx)
  if g.barGlow and ns.BarGlow then
    if nowOn then
      local buttons = ns.BarGlow.buttonsFor(nowKey)
      for _, button in ipairs(buttons or {}) do
        wantNow[button] = true
      end
      -- Say so when there is nothing to glow. A suggestion the player cannot see on their bars is
      -- the whole display failing in the way least likely to be noticed.
      if #(buttons or {}) == 0 and ns.BarGlow.noteMissing then
        ns.BarGlow.noteMissing(nowKey)
      end
    end
    -- The cast after this one, dim, only if asked for. A spell that is both now and next gets the
    -- bright glow alone: two glows on one button is not "more information", it is a flicker.
    if g.secondary and nextKey and Glow.enabledFor(nextKey) and Glow.visibleFor(nextKey, ctx) then
      for _, button in ipairs(ns.BarGlow.buttonsFor(nextKey) or {}) do
        if not wantNow[button] then wantNext[button] = true end
      end
    end
  end

  -- AT2-D3: the strip's own switch, independent of `barGlow` above in both directions -- an
  -- action-bar glow that is off must not silence this, and this being off must not silence the
  -- bars. Slot 1 only, and never through BarGlow.buttonsFor/noteMissing: the strip is not an action
  -- bar, and it is never the button the player "could not find".
  if q.stripGlow and nowOn then
    local stripButton = ns.Queue and ns.Queue.firstSlotFrame and ns.Queue.firstSlotFrame()
    if stripButton then wantNow[stripButton] = true end
  end

  for frame in pairs(nowFrames) do
    if not wantNow[frame] then Glow.Stop(frame) end
  end
  for frame in pairs(nextFrames) do
    -- A frame promoted from next to now is left alone here: Glow.Start replaces a glow held under
    -- the other key, so stopping it twice would only be noise.
    if not wantNext[frame] then Glow.Stop(frame) end
  end
  for frame in pairs(wantNow) do
    if not nowFrames[frame] then Glow.Start(frame, Glow.styleFor(nowKey), false, nowKey) end
  end
  for frame in pairs(wantNext) do
    if not nextFrames[frame] then Glow.Start(frame, Glow.styleFor(nextKey), true, nextKey) end
  end
  nowFrames, nextFrames = wantNow, wantNext
end

-- Renderer, registered with Display/Driver in its own right rather than being called from the
-- strip's renderer. That is what lets a player hide the strip and keep the glow: with the two
-- joined, turning the queue off silently turned off the half of the display they were using.
--
-- AT2-D1: `visible` -- the STRIP's own visibility -- is no longer read here at all. The glow
-- answers to its own mode (`Glow.visibleFor`, inside `SetNowSlot`), so a hidden strip with the glow
-- set to "Always" still lights the bars; only an actually empty queue (the driver truly has
-- nothing, or nothing at all could want the glow either) releases everything.
function Glow.Render(queue, _key, _visible)
  local slot, nextSlot = nil, nil
  if queue then slot, nextSlot = queue[1], queue[2] end
  Glow.SetNowSlot(slot, nextSlot)
end

-- Is this frame currently lit for the REAL suggestion? The options panel's preview needs to know
-- before it stops a glow it started: between lighting a button and its timer firing, the rotation
-- can move on and the render loop can take that same frame for the actual now-slot. Stopping it
-- then puts the button dark AND leaves SetNowSlot believing it is already lit, so it is not relit
-- until the suggestion changes away and back.
function Glow.isNowFrame(frame)
  return frame ~= nil and nowFrames[frame] == true
end

-- The same question, widened to the dim "next" glow. The preview's timer must not tear down a
-- button the RENDER LOOP owns under either key: stopping it darkens a button that should be lit,
-- and the loop still believes it is lit, so it stays dark until that suggestion changes away and
-- back. `isNowFrame` alone was that bug with the second key added underneath it.
function Glow.isRendererFrame(frame)
  return frame ~= nil and (nowFrames[frame] == true or nextFrames[frame] == true)
end

-- Which styles the LOADED library can actually draw. Proc arrived in LibCustomGlow minor 25; an
-- older copy winning LibStub would leave the dropdown offering a style that silently draws nothing.
function Glow.available()
  local L = lib()
  local out = {}
  for key, def in pairs(STYLES) do
    if L and L[def.start] then out[key] = true end
  end
  return out
end

function Glow.activeCount()
  local n = 0
  for _ in pairs(active) do n = n + 1 end
  return n
end

ns.Glow = Glow
return Glow
