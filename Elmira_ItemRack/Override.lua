-- Elmira_ItemRack/Override.lua — registers an override-source stub. Deliberately does NOT install
-- the hooksecurefunc(ItemRack, "UpdateCurrentSet", ...) yet: a hook with no consumer is pure risk on
-- someone's live gear-swap path. The full mechanism (docs/07-INGAME-VERIFICATION-BASELINE.md §5,
-- docs/08-MODULE-API.md "Implementation notes") lands at M4 once Core/Profiles.lua exists to react
-- to it.
local ADDON = ...
local API = Elmira and Elmira.API
-- `## Dependencies: Elmira` makes core's presence an invariant, so reaching this branch means the
-- load order is broken, not that the user is missing an addon. Say so out loud: a `## LoadWith:`
-- line used to hoist this file ahead of core, and the silent `return` that lived here turned that
-- into an invisible no-op that cost a full in-game verification round at M0.
if not API or API.version < 1 then
  -- Matches AceConsole's own prefix (Libs/AceConsole-3.0/AceConsole-3.0.lua:37) so core and
  -- modules speak with one identity in chat; the message body is red, not the name.
  print("|cff33ff99Elmira|r: |cffff2020" .. ADDON .. " loaded before Elmira core; override source not registered.|r")
  return
end

API.RegisterOverrideSource{
  name = "ItemRack",
  current = function() return nil end,
  onChange = function() end,
}
