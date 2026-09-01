-- Elmira_ItemRack/Override.lua — registers an override-source stub. Deliberately does NOT install
-- the hooksecurefunc(ItemRack, "UpdateCurrentSet", ...) yet: a hook with no consumer is pure risk on
-- someone's live gear-swap path. The full mechanism (docs/07-INGAME-VERIFICATION-BASELINE.md §5,
-- docs/08-MODULE-API.md "Implementation notes") lands at M4 once Core/Profiles.lua exists to react
-- to it.
local ADDON = ...
local API = Elmira and Elmira.API
if not API or API.version < 1 then return end

API.RegisterOverrideSource{
  name = "ItemRack",
  current = function() return nil end,
  onChange = function() end,
}
