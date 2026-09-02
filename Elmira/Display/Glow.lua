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
local active = {}          -- frame -> style currently applied by US
local nowFrames = {}       -- frames glowing for the current now-slot

local function lib()
  return LibStub and LibStub("LibCustomGlow-1.0", true) or nil
end

local function color()
  local c = ns.Colors.HIGHLIGHT
  return { c.r, c.g, c.b, 1 }
end

function Glow.Start(frame, style)
  if not frame then return false end
  local L = lib()
  if not L then return false end
  style = style or "PIXEL"
  if active[frame] == style then return true end     -- already glowing this way; do not restart
  if active[frame] then Glow.Stop(frame) end

  if style == "BUTTON" and L.ButtonGlow_Start then
    L.ButtonGlow_Start(frame, color())
  elseif style == "AUTOCAST" and L.AutoCastGlow_Start then
    L.AutoCastGlow_Start(frame, color(), nil, nil, nil, nil, KEY)
  elseif L.PixelGlow_Start then
    L.PixelGlow_Start(frame, color(), nil, nil, nil, nil, nil, nil, nil, KEY)
  else
    return false
  end
  active[frame] = style
  return true
end

function Glow.Stop(frame)
  if not frame or not active[frame] then return false end
  local L = lib()
  local style = active[frame]
  active[frame] = nil
  if not L then return false end
  if style == "BUTTON" and L.ButtonGlow_Stop then
    L.ButtonGlow_Stop(frame)
  elseif style == "AUTOCAST" and L.AutoCastGlow_Stop then
    L.AutoCastGlow_Stop(frame, KEY)
  elseif L.PixelGlow_Stop then
    L.PixelGlow_Stop(frame, KEY)
  end
  return true
end

function Glow.StopAll()
  for frame in pairs(active) do Glow.Stop(frame) end
  nowFrames = {}
end

-- The now-slot: the queue's first icon plus every action-bar button carrying that spell. Called on
-- every render, so it must be cheap when nothing changed — it diffs the frame set and only touches
-- what actually entered or left.
function Glow.SetNowSlot(queueButton, slot)
  local p = (ns.db and ns.db.profile) or ns.DB.defaults.profile
  local wanted = {}

  if p.glow and p.glow.enabled and slot then
    if queueButton then wanted[queueButton] = true end
    if p.glow.barGlow and slot.spell and ns.BarGlow then
      for _, button in ipairs(ns.BarGlow.buttonsFor(slot.spell) or {}) do
        wanted[button] = true
      end
    end
  end

  for frame in pairs(nowFrames) do
    if not wanted[frame] then Glow.Stop(frame) end
  end
  local style = (p.glow and p.glow.style) or "PIXEL"
  for frame in pairs(wanted) do
    if not nowFrames[frame] then Glow.Start(frame, style) end
  end
  nowFrames = wanted
end

function Glow.activeCount()
  local n = 0
  for _ in pairs(active) do n = n + 1 end
  return n
end

ns.Glow = Glow
return Glow
