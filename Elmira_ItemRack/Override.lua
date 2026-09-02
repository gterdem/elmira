-- Elmira_ItemRack/Override.lua — tells Elmira which ItemRack loadout is worn, so switching gear can
-- switch the build (docs/07 §5, docs/08 "Implementation notes"). Held as a stub until M4 because a
-- hook with no consumer is pure risk on someone's live gear-swap path; Core/Profiles.lua now reacts
-- to it, so the real mechanism goes in.
--
-- **The label, and nothing else.** This callback fires ~0.5 s BEFORE the new gear is actually in the
-- equipment slots, so anything read from here about set counts, bonuses or weapons describes the
-- gear the player is leaving. Those all come from the debounced PLAYER_EQUIPMENT_CHANGED path
-- instead (docs/01 §3). The single most tempting mistake in this file is to "helpfully" read gear
-- while we are already here.
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

-- ItemRack's own bookkeeping sets are prefixed with a tilde (`~BaseGear`, `~CombatQueue`,
-- `~Unequip`). They are not loadouts the player chose and must never select a build.
local function isInternal(name)
  return type(name) ~= "string" or name == "" or name:sub(1, 1) == "~"
end

local function current()
  -- ItemRackUser is ItemRack's SavedVariables table; it exists only after ItemRack has loaded, and a
  -- hard `## Dependencies: ItemRack` does not guarantee it is populated at our file scope.
  if type(ItemRackUser) ~= "table" then return nil end
  local set = ItemRackUser.CurrentSet
  if isInternal(set) then return nil end
  return set
end

API.RegisterOverrideSource{
  name = "ItemRack",
  current = current,
  onChange = function(cb)
    if type(cb) ~= "function" then return false end
    if type(ItemRack) ~= "table" or type(ItemRack.UpdateCurrentSet) ~= "function" then
      -- Nothing to hook. Say so rather than registering a callback that can never fire: a silent
      -- no-op here is exactly the failure that cost an in-game round at M0.
      print("|cff33ff99Elmira|r: |cffff2020ItemRack.UpdateCurrentSet not found; "
            .. "gear-swap build switching is off.|r")
      return false
    end
    -- UpdateCurrentSet takes NO arguments (docs/08): reading a hook parameter here would read
    -- whatever ItemRack happened to pass, which is nothing.
    hooksecurefunc(ItemRack, "UpdateCurrentSet", function()
      cb(current())
    end)
    return true
  end,
}
