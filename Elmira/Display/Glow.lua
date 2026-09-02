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

-- LibCustomGlow-1.0's three starters take the key at a DIFFERENT position each:
--   PixelGlow_Start   (r, color, N, frequency, length, th, xOffset, yOffset, border, key, frameLevel)
--   AutoCastGlow_Start(r, color, N, frequency, scale, xOffset, yOffset, key, frameLevel)
--   ButtonGlow_Start  (r, color, frequency, frameLevel)                       -- no key at all
-- Counting nils by eye put ours in AutoCast's `yOffset`, so the library did arithmetic on the string
-- "Elmira" and the whole queue renderer died the moment anyone chose that style. Positions are
-- declared as data here and asserted in tests/spec/glow_spec.lua, because a call site written as a
-- row of nils cannot fail in any way a reader or a spec can see.
local STYLES = {
  PIXEL    = { start = "PixelGlow_Start",    stop = "PixelGlow_Stop",    keyAt = 10 },
  AUTOCAST = { start = "AutoCastGlow_Start", stop = "AutoCastGlow_Stop", keyAt = 8 },
  BUTTON   = { start = "ButtonGlow_Start",   stop = "ButtonGlow_Stop",   keyAt = nil },
}
Glow.STYLES = STYLES

local function lib()
  return LibStub and LibStub("LibCustomGlow-1.0", true) or nil
end

local function color()
  local c = ns.Colors.HIGHLIGHT
  return { c.r, c.g, c.b, 1 }
end

-- Everything between the frame and the key is left at the library's own defaults: a hole in the
-- arg list is a nil, and every one of those parameters defaults sensibly inside the library.
local function startArgs(styleDef, frame)
  local args = { frame, color() }
  local n = 2
  if styleDef.keyAt then
    args[styleDef.keyAt] = KEY
    n = styleDef.keyAt
  end
  return args, n
end
Glow.startArgs = startArgs

function Glow.Start(frame, style)
  if not frame then return false end
  local L = lib()
  if not L then return false end
  style = (style and STYLES[style]) and style or "PIXEL"
  if active[frame] == style then return true end     -- already glowing this way; do not restart
  if active[frame] then Glow.Stop(frame) end

  local def = STYLES[style]
  local fn = L[def.start]
  if not fn then return false end
  local args, n = startArgs(def, frame)
  fn(unpack(args, 1, n))
  active[frame] = style
  return true
end

function Glow.Stop(frame)
  if not frame or not active[frame] then return false end
  local L = lib()
  local style = active[frame]
  active[frame] = nil
  if not L then return false end
  local def = STYLES[style] or STYLES.PIXEL
  local fn = L[def.stop]
  if not fn then return false end
  -- Every _Stop that takes a key takes it second; ButtonGlow_Stop takes none.
  if def.keyAt then fn(frame, KEY) else fn(frame) end
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
