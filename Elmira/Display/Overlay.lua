-- Elmira/Display/Overlay.lua — peripheral cues (PRD F16, ADR-0009).
--
-- This is NOT a third rendering of "what do I press". The queue strip and the bar glow already
-- answer that for someone looking at the UI; the overlay exists for the moments they are not.
--
-- Everything here follows from that one idea:
--   * OFF by default, opted in PER CUE. There is no global "overlay on" switch, and an empty
--     `profile.overlay.cues` is a quiet install — a cue exists only because the user added it.
--   * A flare fires when the now-slot CHANGES TO an opted-in spell, never on re-evaluation. The
--     engine re-picks at up to 10 Hz, so a faithful mirror would strobe, and a strobing screen edge
--     is something people filter out within one raid night. A cue that has been habituated away is
--     worse than no cue, because the design still assumes it works.
--   * `event = "check"` cues need Core/Checks.lua (M5b) and are inert here. They are skipped
--     silently at render time and listed as unavailable by the options — never offered as an opt-in
--     that could not fire.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Overlay = {}
local frame, edges = nil, {}
local lastNow                -- the previous now-slot spell, so we can detect "changed TO"
local lastKey                -- the build the above was observed under; a switch invalidates it
local lastFired = {}         -- cue id -> when it last flared, for `/elm debug cues`

local MEDIA = "Interface\\AddOns\\Elmira\\media\\"
local EDGE_THICKNESS = 96

local function profile()
  return (ns.db and ns.db.profile) or ns.DB.defaults.profile
end

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

-- The cues this build suggests, as data. Builds SUGGEST; they never enable anything themselves
-- (ADR-0009) — the options surface these as one-click "recommended peripheral cues".
function Overlay.availableCues()
  local compiled = ns.Display and select(1, ns.Display.activeBuild())
  local list = compiled and compiled.visuals and compiled.visuals.cues or {}
  local out = {}
  for i, cue in ipairs(list) do
    local entry = { index = i, event = cue.event, spell = cue.spell, key = cue.key,
                    color = cue.color, edge = cue.edge, reason = cue.reason,
                    requiresBonus = cue.requiresBonus }
    -- Two separate reasons a cue may be unofferable, and they are not the same thing: one waits on
    -- a milestone, the other on the player's gear. Saying which is the difference between "not yet"
    -- and "not for you".
    if cue.event == "check" then
      entry.unavailable = "needs readiness checks (M5b)"
    elseif cue.requiresBonus then
      local state = ns.API and ns.API.GetState()
      local ok = state and state.bonus and state:bonus(cue.requiresBonus)
      if not ok then entry.unavailable = "needs " .. cue.requiresBonus end
    end
    out[#out + 1] = entry
  end
  return out
end

local function cueID(cue)
  return (cue.event or "?") .. ":" .. tostring(cue.spell or cue.key or cue.index)
end

function Overlay.isEnabled(cue)
  local cues = profile().overlay and profile().overlay.cues or {}
  local setting = cues[cueID(cue)]
  return setting ~= nil and setting.enabled == true, setting
end

function Overlay.SetEnabled(cue, enabled, opts)
  local p = profile()
  p.overlay = p.overlay or { cues = {} }
  p.overlay.cues = p.overlay.cues or {}
  local id = cueID(cue)
  -- A cue enabled while its spell is ALREADY the top suggestion -- the normal case, since you turn a
  -- cue on during the fight that made you want it -- would otherwise count as "already shown" and
  -- stay silent until the rotation moved off that spell and back. That reads as "the cue does not
  -- work". This lives inside SetEnabled rather than at the call site because a caller that forgets it
  -- produces a silent cue, which is exactly how the bug shipped.
  -- Conditional on purpose: forgetting the now-slot unconditionally would also re-arm every OTHER
  -- enabled cue, so toggling one cue in the options flashes a second, unrelated screen edge.
  if cue.event == "now_slot" and cue.spell ~= nil and cue.spell == lastNow then
    Overlay.Reset()
  end
  if not enabled then
    p.overlay.cues[id] = nil          -- opting out removes it: absent means "never asked for"
    return false
  end
  local setting = p.overlay.cues[id] or {}
  setting.enabled = true
  setting.color = (opts and opts.color) or setting.color or cue.color
  setting.edge = (opts and opts.edge) or setting.edge or cue.edge or "left"
  setting.intensity = (opts and opts.intensity) or setting.intensity or 0.5
  setting.sound = (opts and opts.sound) or setting.sound
  p.overlay.cues[id] = setting
  return true
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

-- Renderer. Fires only on a CHANGE of the now-slot, which is why `lastNow` is compared before
-- anything else happens: this function runs on every render, and the whole design rests on it doing
-- nothing the vast majority of the time.
-- The renderer contract is (queue, key, visible) since M3's visibility gating. This one works out
-- correctly on the hidden path either way — Driver passes a nil queue, which already means "clear" —
-- but naming `visible` here is deliberate: relying on nil-by-coincidence is how the next renderer
-- fires a screen flare at someone whose display is switched off.
function Overlay.Render(queue, key, visible)
  -- A build or profile switch means the previous now-slot was another rotation's suggestion. Carrying
  -- it across swallows the first cue of the new build. The key is already an argument, so the module
  -- can notice this itself rather than depending on someone remembering to call Reset(). Only a real
  -- key counts: the hidden path passes nil, which is not a build change.
  if key ~= nil and key ~= lastKey then
    lastKey, lastNow = key, nil
  end

  local now = (visible ~= false) and queue and queue[1] and queue[1].spell or nil
  if now == lastNow then return end
  lastNow = now
  if not now then return end

  for _, cue in ipairs(Overlay.availableCues()) do
    if cue.event == "now_slot" and cue.spell == now and not cue.unavailable then
      local on, setting = Overlay.isEnabled(cue)
      if on then
        -- Guarding on `ns.now` existing would be theatre: Core/Slash.lua defines it unconditionally
        -- and returns 0 when no state exists yet, which is the very shape of guard that once stamped
        -- every recorder mark with 0. Test the VALUE instead. A real reading comes from GetTime() and
        -- is never 0, so 0 means "no clock yet" -- and recording it would render as "0.0s ago", a
        -- confident answer to "when did this last fire" that we do not have. Absent reads "never".
        local firedAt = ns.now and ns.now() or 0
        if firedAt > 0 then lastFired[cueID(cue)] = firedAt end
        Overlay.Flare(setting.edge, setting.color, setting.intensity)
        local sounds = profile().sounds
        if sounds and sounds.enabled and setting.sound and PlaySoundFile then
          PlaySoundFile(setting.sound)
        end
      end
    end
  end
end

-- What `/elm debug cues` reports. The M4 test pass could not distinguish "the cue is not enabled",
-- "the cue cannot fire", "the now-slot never reached it" and "it fired and you missed it" — every
-- one of those looks like an empty screen edge. Data, not text, so a spec can assert on it.
function Overlay.describe()
  local out = { nowSlot = lastNow, buildKey = lastKey, cues = {} }
  for i, cue in ipairs(Overlay.availableCues()) do
    local on, setting = Overlay.isEnabled(cue)
    out.cues[i] = {
      index = i, id = cueID(cue), event = cue.event, reason = cue.reason,
      unavailable = cue.unavailable, enabled = on,
      edge = (setting and setting.edge) or cue.edge or "left",
      color = (setting and setting.color) or cue.color,
      intensity = setting and setting.intensity,
      firedAt = lastFired[cueID(cue)],
      -- The one fact that separates "wired wrong" from "the rotation never asked for it".
      matchesNow = cue.event == "now_slot" and cue.spell ~= nil and cue.spell == lastNow,
    }
  end
  return out
end

-- Manual test-fire, so a silent cue can be told apart from a silent RENDERER without a target dummy.
-- Deliberately ignores `enabled`: the question it answers is "can this edge flare at all", and
-- refusing to fire a disabled cue would make the diagnostic useless in exactly the case it is for.
function Overlay.TestFire(index)
  -- Not `tonumber(index) or 1`: defaulting garbage to the first cue answers a question the user did
  -- not ask and attributes the flare to the wrong cue -- in the one command whose job is to stop
  -- flares being misattributed.
  local n = tonumber(index)
  if not n then return false, "not a cue number: " .. tostring(index) end
  local cue = Overlay.availableCues()[n]
  if not cue then return false, "no cue " .. tostring(n) end
  local _, setting = Overlay.isEnabled(cue)
  Overlay.Flare((setting and setting.edge) or cue.edge,
                (setting and setting.color) or cue.color,
                setting and setting.intensity)
  local label = cue.reason or cue.spell or cue.key or ("cue " .. tostring(cue.index))
  -- An unavailable cue still flares -- the question this answers is "can this edge flare at all" --
  -- but it must SAY so. The options list this cue greyed out as unable to fire (ADR-0009: check cues
  -- stay inert until M5b), and a bare success line here would be read as that promise being wrong.
  if cue.unavailable then
    label = label .. " (" .. cue.unavailable .. " — will not fire in play)"
  end
  return true, label
end

-- A build or profile switch must not leave a stale "we were already showing this" memory, or the
-- first cue after the switch is silently swallowed.
function Overlay.Reset()
  lastNow, lastKey = nil, nil
end

ns.Overlay = Overlay
return Overlay
