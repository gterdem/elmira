-- Elmira/Display/Overlay.lua — the screen-edge flash (PRD F16, ADR-0009 as amended 2026-09-09).
--
-- This is NOT a third rendering of "what do I press". The queue strip and the bar glow already
-- answer that for someone looking at the UI; the overlay exists for the moments they are not.
--
-- Everything here follows from that one idea:
--   * OFF by default and opted in PER ABILITY. There is no global "overlay on" switch and no
--     inherited one either: All abilities cannot switch a screen edge on for everything, because a
--     flash that fires on every suggestion is a strobe people filter out within one raid night.
--   * A class pack MAY ship one ability's flash switched on (AB2-D3) -- the amendment. That is a
--     statement about two abilities out of twenty, made by the people who wrote the rotation, not a
--     global default; the player's own setting still wins over it.
--   * It fires on EVENTS, not on a diff of its own. Core/Track decides when an ability became
--     ready and Display/Driver decides when it became the suggestion; both arrive here as one call
--     per edge, so the "did this change?" logic exists once for every channel instead of once here.
--
-- AB2-D1 replaced build-level `visuals.cues` with `Core/AbilitySettings`' `edge` channel: what
-- flashes, on which edge, in which colour and for which of the two events is now a per-character
-- setting on the ability, which is what made a cue configurable for an ability no pack ships.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Overlay = {}
local frame, edges = nil, {}
local lastFired = {}         -- ability key -> when it last flashed, for `/elm debug cues`

-- The edges a flare can use. Named here rather than in Options because Overlay is what can actually
-- draw them; Options only decides what to call them.
Overlay.EDGES = { "left", "right", "top", "bottom" }

local MEDIA = "Interface\\AddOns\\Elmira\\media\\"
local EDGE_THICKNESS = 96

-- One texture per screen edge. `flare_h` is opaque at its left edge and `flare_v` at its top, so the
-- right and bottom edges reuse them flipped through SetTexCoord rather than shipping four files.
local function makeEdge(parent, side)
  local t = parent:CreateTexture(nil, "ARTWORK")
  if side == "left" then
    t:SetTexture(MEDIA .. "flare_h")
    t:SetPoint("TOPLEFT"); t:SetPoint("BOTTOMLEFT"); t:SetWidth(EDGE_THICKNESS)
  elseif side == "right" then
    t:SetTexture(MEDIA .. "flare_h")
    t:SetTexCoord(1, 0, 0, 1)
    t:SetPoint("TOPRIGHT"); t:SetPoint("BOTTOMRIGHT"); t:SetWidth(EDGE_THICKNESS)
  elseif side == "top" then
    t:SetTexture(MEDIA .. "flare_v")
    t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(EDGE_THICKNESS)
  else
    t:SetTexture(MEDIA .. "flare_v")
    t:SetTexCoord(0, 1, 1, 0)
    t:SetPoint("BOTTOMLEFT"); t:SetPoint("BOTTOMRIGHT"); t:SetHeight(EDGE_THICKNESS)
  end
  t:SetAlpha(0)

  -- Fade-out only: the flare appears at full intensity and decays. A fade-IN would make the cue
  -- arrive late, which defeats the point of something meant to be caught in peripheral vision.
  local ag = t:CreateAnimationGroup()
  local fade = ag:CreateAnimation("Alpha")
  fade:SetFromAlpha(1); fade:SetToAlpha(0); fade:SetDuration(0.6)
  ag:SetScript("OnFinished", function() t:SetAlpha(0) end)
  t.anim, t.fade = ag, fade
  return t
end

function Overlay.Create()
  if frame then return frame end
  frame = CreateFrame("Frame", "ElmiraOverlay", UIParent)
  frame:SetAllPoints(UIParent)
  frame:SetFrameStrata("BACKGROUND")
  frame:SetFrameLevel(1)
  frame:EnableMouse(false)      -- must never eat a click; this sits over the whole screen
  for _, side in ipairs({ "left", "right", "top", "bottom" }) do
    edges[side] = makeEdge(frame, side)
  end
  return frame
end

function Overlay.Flare(edge, color, intensity, duration)
  Overlay.Create()
  local t = edges[edge or "left"]
  if not t then return false end
  local c = color or { ns.Colors.HIGHLIGHT.r, ns.Colors.HIGHLIGHT.g, ns.Colors.HIGHLIGHT.b }
  t:SetVertexColor(c[1] or 1, c[2] or 1, c[3] or 1)
  t.anim:Stop()
  t.fade:SetFromAlpha(math.max(0.05, math.min(1, intensity or 0.5)))
  t.fade:SetDuration(duration or 0.6)
  t:SetAlpha(intensity or 0.5)
  t.anim:Play()
  return true
end

-- The two moments a screen edge can flash (AB2-D1). Deliberately NOT the five Core/Track knows
-- about: `used`, `active` and `expiring` are what the Texture tab (AB3) is for, and a full-screen
-- flash on every buff that ticks down is the strobe ADR-0009 exists to prevent. Named here because
-- Overlay is what draws them; Options/Spells only decides what to call them.
Overlay.EVENTS = { "suggested", "ready" }

-- An edge Flare cannot draw makes the flash silently never appear. The options dropdown cannot
-- produce one, but a CLASS PACK's `defaults = { edge = { edge = "middle" } }` can (AB2-D3), and so
-- can an imported settings string -- both are data written somewhere else. Falling back to a
-- drawable edge is better than a cue that is quietly dead.
local function validEdge(v)
  for _, e in ipairs(Overlay.EDGES) do if e == v then return true end end
  return false -- mutants: equivalent — nil is falsy and every caller uses this only as a condition
end

-- Settings store a colour the way every other Elmira colour is stored (`{ r =, g =, b = }`, the
-- shape an AceConfig `color` control hands back); Flare takes the positional form its texture call
-- needs. One conversion, here, rather than two shapes loose in the settings.
local function rgb(c)
  if type(c) ~= "table" then return nil end
  return { c.r, c.g, c.b }
end

-- The resolved `edge` channel, with an edge this module can actually draw. Every caller has already
-- established that Core/AbilitySettings is loaded -- a guard here would be one no test could reach.
local function settings(key)
  local e = ns.AbilitySettings.effective(key, "edge")
  if not validEdge(e.edge) then e.edge = "left" end
  return e
end

-- Overlay.Fire(key, event) -> did the screen flash
--
-- The whole renderer, now that the events come from elsewhere: Display/Driver calls this for every
-- ability event, and this decides whether THIS ability's screen edge has anything to say about it.
-- No now-slot diff of its own any more -- `suggested` already means "the now-slot became this",
-- which is why the strobe guard the old renderer carried is not repeated here.
function Overlay.Fire(key, event)
  local A = ns.AbilitySettings
  if not (A and A.channelOn(key, "edge")) then return false end
  local e = settings(key)
  -- `e[event]` is nil for `used`/`active`/`expiring`: the edge channel declares no field for them,
  -- so an event this tab does not offer cannot flash by accident.
  if not e[event] then return false end
  -- Guarding on `ns.now` existing would be theatre: Core/Slash.lua defines it unconditionally and
  -- returns 0 when no state exists yet, which is the very shape of guard that once stamped every
  -- recorder mark with 0. Test the VALUE instead: a real reading comes from GetTime() and is never
  -- 0, so 0 means "no clock yet" -- and recording it would render as "0.0s ago", a confident answer
  -- to "when did this last flash" that we do not have. Absent reads "never".
  local firedAt = ns.now and ns.now() or 0
  if firedAt > 0 then lastFired[key] = firedAt end
  return Overlay.Flare(e.edge, rgb(e.color), e.intensity)
end

-- Every ability this character could configure a flash for: the class pack's spells and the ones
-- registered on this character alike (`Spells.merged`, pack wins), plus any key that has settings
-- but no entry -- an imported row for a spell this client cannot resolve still has to be able to
-- say why it is silent. Sorted, so `/elm debug cues` reads the same way twice in a row.
-- Is this a key anything knows about: the class pack's, this character's registry, or a settings
-- row imported for a spell the client cannot resolve yet.
local function known(key)
  local pack = ns.Display and ns.Display.currentPack and ns.Display.currentPack()
  local spells = (ns.Spells and ns.Spells.merged and ns.Spells.merged(pack))
    or (pack and pack.spells) or {}
  if spells[key] then return true end
  local A = ns.AbilitySettings
  return (A and A.spellInfo(key)) ~= nil or (A and A.store() and A.store()[key]) ~= nil
end

local function abilityKeys()
  local pack = ns.Display and ns.Display.currentPack and ns.Display.currentPack()
  local spells = (ns.Spells and ns.Spells.merged and ns.Spells.merged(pack))
    or (pack and pack.spells) or {}
  local seen, out = {}, {}
  for key in pairs(spells) do seen[key] = true; out[#out + 1] = key end
  local A = ns.AbilitySettings
  for _, key in ipairs((A and A.keys()) or {}) do
    if not seen[key] then out[#out + 1] = key end
  end
  table.sort(out)
  return out
end

-- What `/elm debug cues` reports. The M4 test pass could not distinguish "the flash is not switched
-- on", "the event it fires on is unticked", "the rotation never suggested that spell" and "it fired
-- and you missed it" — every one of those looks like an empty screen edge. Data, not text, so a
-- spec can assert on it.
function Overlay.describe()
  local A = ns.AbilitySettings
  local out = { abilities = {} }
  if not A then return out end
  for _, key in ipairs(abilityKeys()) do
    local e = settings(key)
    local on = A.channelOn(key, "edge")
    -- Only the abilities that have something to say: a paladin has forty keys and thirty-eight of
    -- them are off, and a chat dump nobody reads is the same as no diagnostic at all.
    if on or lastFired[key] then
      local events = {}
      for _, event in ipairs(Overlay.EVENTS) do
        if e[event] then events[#events + 1] = event end
      end
      out.abilities[#out.abilities + 1] = {
        key = key, enabled = on, edge = e.edge, color = e.color, intensity = e.intensity,
        -- The pair that separates "wired wrong" from "you never triggered it": switched on, with
        -- events ticked, and never fired.
        events = events, firedAt = lastFired[key],
      }
    end
  end
  return out
end

-- Manual test-fire, so a silent flash can be told apart from a silent TRACKER without a target
-- dummy — and the Preview button on the Screen-edge tab, which asks the same question.
-- Deliberately ignores whether the channel is on: what it answers is "can this edge flash at all",
-- and refusing a switched-off ability would make the diagnostic useless in the one case it is for.
function Overlay.TestFire(key)
  local A = ns.AbilitySettings
  -- Not "default to the first ability", and not "flash whatever you typed" either: a flash
  -- attributed to a key that names nothing answers a question the user did not ask, in the one
  -- command whose job is to stop flashes being misattributed. The All abilities row is allowed
  -- through by name -- it is what the Screen-edge tab's own Preview button previews.
  if not (A and type(key) == "string" and key ~= "") then
    return false, "not an ability key: " .. tostring(key)
  end
  if key ~= A.ALL and not known(key) then
    return false, "no ability " .. key .. " on this character"
  end
  local e = settings(key)
  Overlay.Flare(e.edge, rgb(e.color), e.intensity)
  local label = (ns.Display and ns.Display.spellName and ns.Display.spellName(key)) or key
  -- A switched-off ability still flashes -- that is the question this answers -- but it must SAY
  -- so, or a bare success line reads as a promise that it will fire in play.
  if not A.channelOn(key, "edge") then
    label = label .. " (screen edge is off for it — it will not fire in play)"
  end
  return true, label
end

ns.Overlay = Overlay
return Overlay
