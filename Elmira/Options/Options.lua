-- Elmira/Options/Options.lua — the settings UI (AceConfig-3.0).
--
-- Every user-facing string goes through AceLocale (`ns.L[...]`), enUS only in v1, so a translation
-- is a data file rather than a rewrite.
--
-- The overlay section is the interesting one. ADR-0009 forbids a global "overlay on" switch, so
-- there isn't one: the section lists the cues the ACTIVE BUILD suggests, each individually
-- opt-in-able, and a cue that cannot fire is shown disabled WITH ITS REASON rather than hidden.
-- Hiding it would leave the user wondering why a documented cue is missing; offering it would let
-- them enable something that can never fire.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Options = {}
local L = ns.L

local function profile()
  return ns.db and ns.db.profile
end

-- Anything that changes HOW the queue is drawn rather than WHAT it contains has to force a repaint:
-- the driver skips rendering when the queue is unchanged, so a scale or depth change would
-- otherwise not appear until the rotation happened to move on.
local function redraw()
  if ns.Queue then ns.Queue.Layout() end
  if ns.Display then ns.Display.refresh() end
end

local function overlayGroup()
  local args = {}
  local cues = ns.Overlay and ns.Overlay.availableCues() or {}
  if #cues == 0 then
    args.none = {
      type = "description", order = 1,
      name = L["This build suggests no peripheral cues."],
    }
    return args
  end

  args.header = {
    type = "description", order = 0,
    name = L["Screen-edge flares for the moments you are not looking at the UI. Off unless you turn one on."],
  }

  for i, cue in ipairs(cues) do
    local label = cue.reason or cue.spell or cue.key or ("cue " .. i)
    if cue.unavailable then
      args["cue" .. i] = {
        type = "toggle", order = i, width = "full",
        name = label .. "  |cff9AA0A6(" .. cue.unavailable .. ")|r",
        desc = L["This cue cannot fire yet, so it cannot be enabled."],
        disabled = true,
        get = function() return false end,
        set = function() end,
      }
    else
      args["cue" .. i] = {
        type = "toggle", order = i, width = "full",
        name = label,
        desc = (cue.edge and (L["Edge: "] .. cue.edge)) or nil,
        get = function() return (ns.Overlay.isEnabled(cue)) end,
        set = function(_, v)
          ns.Overlay.SetEnabled(cue, v)
          -- Show it once on enable. A cue the user just turned on and cannot picture is a cue they
          -- turn straight back off.
          if v then
            local _, setting = ns.Overlay.isEnabled(cue)
            ns.Overlay.Flare(setting and setting.edge, setting and setting.color,
                             setting and setting.intensity)
          end
        end,
      }
    end
  end
  return args
end

function Options.table()
  return {
    type = "group",
    name = ns.Colors.wrap(ns.Colors.BRAND, "Elmira"),
    args = {
      queue = {
        type = "group", order = 1, name = L["Queue"], inline = false,
        args = {
          enabled = {
            type = "toggle", order = 1, name = L["Show the queue"],
            get = function() return profile().enabled end,
            set = function(_, v)
              profile().enabled = v
              if v then ns.Display.Enable() else ns.Display.Disable() end
              redraw()
            end,
          },
          depth = {
            type = "range", order = 2, name = L["Icons"], min = 1, max = 5, step = 1,
            desc = L["How many casts ahead to show. Slot 1 is what to press now."],
            get = function() return profile().depth end,
            set = function(_, v) profile().depth = v; redraw() end,
          },
          scale = {
            type = "range", order = 3, name = L["Scale"], min = 0.5, max = 2.0, step = 0.05,
            isPercent = true,
            get = function() return profile().scale end,
            set = function(_, v) profile().scale = v; redraw() end,
          },
          locked = {
            type = "toggle", order = 4, name = L["Lock position"],
            desc = L["Unlock to drag the queue. Same as /elm lock."],
            get = function() return ns.Queue.isLocked() end,
            set = function(_, v) ns.Queue.SetLocked(v) end,
          },
        },
      },
      glow = {
        type = "group", order = 2, name = L["Glow"],
        args = {
          enabled = {
            type = "toggle", order = 1, name = L["Glow the next cast"],
            get = function() return profile().glow.enabled end,
            set = function(_, v) profile().glow.enabled = v; redraw() end,
          },
          barGlow = {
            type = "toggle", order = 2, name = L["Also glow your action bar"],
            desc = L["Highlights the button on your bars, not just the queue icon."],
            get = function() return profile().glow.barGlow end,
            set = function(_, v)
              profile().glow.barGlow = v
              if ns.Glow then ns.Glow.StopAll() end   -- drop glows we will no longer be refreshing
              redraw()
            end,
          },
          style = {
            type = "select", order = 3, name = L["Style"],
            values = { PIXEL = L["Pixel"], BUTTON = L["Button"], AUTOCAST = L["Autocast"] },
            get = function() return profile().glow.style end,
            set = function(_, v)
              profile().glow.style = v
              if ns.Glow then ns.Glow.StopAll() end   -- restart in the new style, don't layer them
              redraw()
            end,
          },
        },
      },
      overlay = {
        type = "group", order = 3, name = L["Peripheral cues"],
        args = overlayGroup(),
      },
      sounds = {
        type = "group", order = 4, name = L["Sounds"],
        args = {
          enabled = {
            type = "toggle", order = 1, name = L["Play cue sounds"],
            desc = L["Sounds use the same per-cue opt-in as flares."],
            get = function() return profile().sounds.enabled end,
            set = function(_, v) profile().sounds.enabled = v end,
          },
        },
      },
    },
  }
end

function Options.Register()
  local AceConfig = LibStub and LibStub("AceConfig-3.0", true)
  local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
  if not (AceConfig and AceConfigDialog) then return false end

  -- Built fresh on open rather than once at load: the overlay section is derived from the ACTIVE
  -- build's suggested cues, and both the build and the character's gear can change in a session.
  AceConfig:RegisterOptionsTable("Elmira", Options.table)
  Options.frame = AceConfigDialog:AddToBlizOptions("Elmira", "Elmira")

  local AceDBOptions = LibStub("AceDBOptions-3.0", true)
  if AceDBOptions and ns.db then
    AceConfig:RegisterOptionsTable("Elmira-Profiles", AceDBOptions:GetOptionsTable(ns.db))
    AceConfigDialog:AddToBlizOptions("Elmira-Profiles", L["Profiles"], "Elmira")
  end
  Options.dialog = AceConfigDialog
  return true
end

function Options.Open()
  if not Options.dialog then Options.Register() end
  if Options.dialog then
    Options.dialog:Open("Elmira")
    return true
  end
  return false
end

ns.Options = Options
return Options
