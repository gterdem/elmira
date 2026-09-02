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
function Overlay.Render(queue)
  local now = queue and queue[1] and queue[1].spell or nil
  if now == lastNow then return end
  lastNow = now
  if not now then return end

  for _, cue in ipairs(Overlay.availableCues()) do
    if cue.event == "now_slot" and cue.spell == now and not cue.unavailable then
      local on, setting = Overlay.isEnabled(cue)
      if on then
        Overlay.Flare(setting.edge, setting.color, setting.intensity)
        local sounds = profile().sounds
        if sounds and sounds.enabled and setting.sound and PlaySoundFile then
          PlaySoundFile(setting.sound)
        end
      end
    end
  end
end

-- A build or profile switch must not leave a stale "we were already showing this" memory, or the
-- first cue after the switch is silently swallowed.
function Overlay.Reset()
  lastNow = nil
end

ns.Overlay = Overlay
return Overlay
