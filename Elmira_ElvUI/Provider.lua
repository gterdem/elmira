-- Elmira_ElvUI/Provider.lua — registers a bar provider stub. Deliberately does NOT call
-- LibStub("LibActionButton-1.0-ElvUI") yet: real button scanning is M3
-- (the ElvUI glow notes have the scan design).
local ADDON = ...
local API = Elmira and Elmira.API
if not API or API.version < 1 then return end

API.RegisterBarProvider{
  name = "ElvUI",
  priority = 10,
  buttonsForSpell = function() return {} end,
  keybindForSpell = function() return nil end,
  onLayoutChanged = function() end,
}
