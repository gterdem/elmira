-- Elmira/Display/Announcers.lua — the four things that can actually say something (PRD F37).
--
-- Core/Announce decides WHAT is said and WHERE it goes; this file is the only place that touches a
-- chat frame, a message frame, a sound or party chat. It lives under Display/ for the reason
-- Core/Init.lua:23 gives for using plain `print`: `Elmira/Core/` is declared with no WoW globals at
-- all, and widening that to let one file send a chat message would remove the check from every
-- other Core file at the same time.
--
-- The on-screen message frame follows SmartBuff-SoD's splash frame, which is the shape SoD players
-- already recognise: a MessageFrame with SetTimeVisible + a fade, an icon inlined into the text,
-- and a drag handle that only works while the options panel is open so it cannot be nudged in a
-- fight. What it does differently is colour PER CATEGORY rather than one colour for everything --
-- a warning and a rotation change should not look alike -- and holding a message back until combat
-- ends rather than dropping it in front of someone mid-pull.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Announcers = {}
local frame = nil
local moving = false

-- Every MessageFrame method this file calls is a client API with no precedent anywhere else in this
-- addon or its vendored libraries -- SetInsertMode, SetFading, SetFadeDuration, SetTimeVisible,
-- AddMessage and Clear are all first uses at interface 11509. A method that turns out not to exist
-- must degrade to "that touch did nothing", because some of these are reached from the options
-- panel's close path, and an error thrown there is an error thrown from inside a frame's OnHide.
-- Reported once per method: the calls that matter repeat several times a second.
local reported = {}
local function call(f, method, ...)
  local fn = f and f[method]
  if type(fn) ~= "function" then
    if not reported[method] then
      reported[method] = true
      ns.log("Elmira: this client's MessageFrame has no %s(); on-screen messages degrade.", method)
    end
    return
  end
  fn(f, ...)
end

local function profile()
  return (ns.db and ns.db.profile) or ns.DB.defaults.profile
end

local function settings()
  local p = profile()
  return (p and p.announce) or ns.DB.defaults.profile.announce
end

local function media()
  return LibStub and LibStub("LibSharedMedia-3.0", true) or nil
end

-- The fonts and sounds the player has, from whatever media packs they run. Without the library
-- there is exactly one font and one sound, which is still a working addon.
function Announcers.fonts()
  local lsm = media()
  if not lsm then return { ["Friz Quadrata TT"] = "Friz Quadrata TT" } end
  local out = {}
  for _, name in ipairs(lsm:List("font") or {}) do out[name] = name end
  return out
end

function Announcers.sounds()
  local out = { None = "None" }
  local lsm = media()
  for _, name in ipairs((lsm and lsm:List("sound")) or {}) do out[name] = name end
  return out
end

-- Which chat window to print into. 0 means "the default frame", which is where every Elmira message
-- went before this existed; a real index picks one of the player's own tabs, so someone who keeps a
-- separate Addons tab can have Elmira use it.
function Announcers.chatWindows()
  local out = { [0] = ns.L and ns.L["Default chat window"] or "Default chat window" }
  local count = NUM_CHAT_WINDOWS or 0
  for i = 1, count do
    local name = GetChatWindowInfo and GetChatWindowInfo(i)
    if name and name ~= "" then out[i] = name end
  end
  return out
end

local function chatFrame()
  local index = settings().chatWindow or 0
  if index and index > 0 then
    local f = _G["ChatFrame" .. index]
    if f and f.AddMessage then return f end
  end
  return DEFAULT_CHAT_FRAME
end

local function colorOf(cat)
  return (cat and ns.Colors[cat.color]) or ns.Colors.BRAND
end

function Announcers.Create()
  if frame then return frame end
  local s = settings()
  frame = CreateFrame("MessageFrame", "ElmiraToast", UIParent)
  frame:SetSize(600, 120)
  frame:SetPoint(s.screen.anchor.point or "TOP", UIParent, s.screen.anchor.relPoint or "TOP",
                 s.screen.anchor.x or 0, s.screen.anchor.y or -140)
  call(frame, "SetInsertMode", "TOP")
  call(frame, "SetJustifyH", "CENTER")
  call(frame, "SetFading", true)
  call(frame, "SetFadeDuration", 1)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  -- Mouse OFF unless the panel is open: this frame sits over the middle of the screen, and one that
  -- eats clicks there is worse than one you cannot move.
  frame:EnableMouse(false)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() if moving then frame:StartMoving() end end)
  frame:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    Announcers.SaveAnchor()
  end)
  Announcers.ApplyFont()
  return frame
end

function Announcers.frame() return frame end

function Announcers.ApplyFont()
  if not frame then return false end
  local s = settings()
  local lsm = media()
  local path = lsm and lsm:Fetch("font", s.screen.font)
  -- No media library, or a font pack the player has since uninstalled: keep the frame's own font
  -- rather than passing nil, which blanks every message with no error anywhere.
  if path then call(frame, "SetFont", path, s.screen.size or 18, "OUTLINE") end
  call(frame, "SetTimeVisible", s.screen.duration or 4)
  return path ~= nil
end

function Announcers.SaveAnchor()
  if not frame then return false end
  local point, _, relPoint, x, y = frame:GetPoint()
  local anchor = settings().screen.anchor
  anchor.point, anchor.relPoint, anchor.x, anchor.y = point, relPoint, x, y
  return true
end

-- Move mode. Shows one sample per category while it is on, because a frame you position while it is
-- empty is a frame you position wrongly: the samples are how tall it really gets.
function Announcers.SetMoving(on)
  moving = on and true or false
  if not frame then return moving end
  frame:EnableMouse(moving)
  if moving then
    call(frame, "SetTimeVisible", 3600)
    for _, cat in ipairs(ns.Announce.CATEGORIES) do
      local c = colorOf(cat)
      call(frame, "AddMessage", cat.label, c.r, c.g, c.b, 1)
    end
  else
    call(frame, "Clear")
    call(frame, "SetTimeVisible", settings().screen.duration or 4)
  end
  return moving
end

function Announcers.isMoving() return moving end

-- Move mode must not outlive the panel that turned it on. Two exits, because the one that matters
-- most is the one nobody remembers to use: closing the options window, and entering combat -- a
-- mouse-enabled frame across the middle of the screen is worst exactly when you are fighting.
function Announcers.StopMoving()
  if not moving then return false end
  Announcers.SetMoving(false)
  return true
end

-- The sinks. Each is registered by name, and Core/Announce calls the ones a category is routed to.
-- `|Tpath:size|t` inlines a texture into a font string. Size 0 means "match the line height",
-- which is what we want and is why no number is computed here.
function Announcers.screen(cat, row)
  if not frame then return false end
  local c = colorOf(cat)
  local text = row.text
  if row.icon then text = "|T" .. tostring(row.icon) .. ":0|t " .. text end
  call(frame, "AddMessage", text, c.r, c.g, c.b, 1)
  return true
end

function Announcers.chat(cat, row)
  local f = chatFrame()
  if not (f and f.AddMessage) then return false end
  f:AddMessage(ns.Colors.prefix() .. ": " .. ns.Colors.wrap(colorOf(cat), row.text))
  return true
end

function Announcers.sound()
  local name = settings().sound
  if not name or name == "None" then return false end
  local lsm = media()
  local path = lsm and lsm:Fetch("sound", name)
  if not (path and PlaySoundFile) then return false end
  PlaySoundFile(path)
  return true
end

-- The only channel other people see. Two gates, and both matter: the CATEGORY has to be one a group
-- could act on (Core/Announce decides that, in code, not in a checkbox), and there has to be a group
-- to say it to -- SendChatMessage to PARTY while solo is an error in the client, not a no-op.
function Announcers.party(cat, row)
  if not (cat and cat.shareable) then return false end
  if not (IsInGroup and IsInGroup()) then return false end
  if not SendChatMessage then return false end
  local channel = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
  SendChatMessage(ns.Announce.plain(row.text), channel)
  return true
end

function Announcers.Register()
  ns.Announce.registerSink("screen", Announcers.screen)
  ns.Announce.registerSink("chat", Announcers.chat)
  ns.Announce.registerSink("sound", Announcers.sound)
  ns.Announce.registerSink("party", Announcers.party)
  return true
end

ns.Announcers = Announcers
return Announcers
