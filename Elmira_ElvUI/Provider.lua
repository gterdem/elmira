-- Elmira_ElvUI/Provider.lua — registers a bar provider stub. Deliberately does NOT call
-- LibStub("LibActionButton-1.0-ElvUI") yet: real button scanning is M3
local ADDON = ...
local API = Elmira and Elmira.API
-- `## Dependencies: Elmira` makes core's presence an invariant, so reaching this branch means the
-- load order is broken, not that the user is missing an addon. Say so out loud: a `## LoadWith:`
-- line used to hoist this file ahead of core, and the silent `return` that lived here turned that
-- into an invisible no-op that cost a full in-game verification round at M0.
if not API or API.version < 1 then
  -- Matches AceConsole's own prefix (Libs/AceConsole-3.0/AceConsole-3.0.lua:37) so core and
  -- modules speak with one identity in chat; the message body is red, not the name.
  print("|cff33ff99Elmira|r: |cffff2020" .. ADDON .. " loaded before Elmira core; bar provider not registered.|r")
  return
end

API.RegisterBarProvider{
  name = "ElvUI",
  priority = 10,
  buttonsForSpell = function() return {} end,
  keybindForSpell = function() return nil end,
  onLayoutChanged = function() end,
}
