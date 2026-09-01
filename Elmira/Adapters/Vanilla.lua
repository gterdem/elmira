-- Elmira/Adapters/Vanilla.lua — the ONLY file under Elmira/ permitted to name a WoW global at M0
-- (hard rule 3; enforced mechanically by .luacheckrc). No event registration yet — that
-- starts at M2/M3 once there is state worth invalidating a cache over.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Vanilla = {}

function Vanilla.detect()
  local build, revision, date, tocversion = GetBuildInfo()
  return {
    project = WOW_PROJECT_ID,
    isClassic = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC,
    build = build,
    revision = revision,
    date = date,
    interface = tocversion,
  }
end

function Vanilla.capabilities()
  return {
    runes = C_Engraving ~= nil,
    setAPI = false,
    swing = false, -- Adapters/Swing.lua, M3b
    inspect = false,
    nameplates = false,
    engraving = C_Engraving ~= nil,
  }
end

function Vanilla.addonVersion()
  local version
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    version = C_AddOns.GetAddOnMetadata(ADDON, "Version")
  elseif GetAddOnMetadata then
    version = GetAddOnMetadata(ADDON, "Version")
  end
  return version or "dev"
end

function Vanilla.playerClass()
  local _, class = UnitClass("player")
  return class
end

-- Scans installed addons for the one whose TOC names this class, and loads it. This is the only
-- place the docs/08 LoadOnDemand + X-Elmira-Class contract is exercised before M2 ships real data,
-- so an M0 login proves the mechanism works rather than leaving it untested until M2.
function Vanilla.loadClassPack(class)
  if not (class and C_AddOns and C_AddOns.GetNumAddOns) then return false end
  for i = 1, C_AddOns.GetNumAddOns() do
    local name = C_AddOns.GetAddOnInfo(i)
    local wantsClass = C_AddOns.GetAddOnMetadata(name, "X-Elmira-Class")
    if wantsClass == class then
      return C_AddOns.LoadAddOn(name)
    end
  end
  return false
end

-- The flat table `/elm debug state` formats. Every WoW global involved is read here; Core only
-- ever sees the result of this function.
function Vanilla.describe()
  local d = Vanilla.detect()
  return {
    project = d.project,
    version = string.format("%s/%s", d.build or "?", d.revision or "?"),
    interface = d.interface,
    caps = Vanilla.capabilities(),
    state = "null (M1)",
  }
end

Vanilla.state = ns.Interface and ns.Interface.newNullState() or nil
ns.Adapter = Vanilla
return Vanilla
