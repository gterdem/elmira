-- Elmira/Adapters/ItemRack.lua — tells Elmira which ItemRack loadout is worn, so switching gear can
-- switch the build (docs/07 §5, docs/08 "Implementation notes").
--
-- KNOWN GAP, not fixed by the move: nothing reads `overrideSources` yet. Core/API.lua stores the
-- registration and Core/Slash.lua counts it for `/elm modules`; Display/Driver.lua calls
-- Profiles.resolve() with no override context, so a gear swap still does not switch the build. The
-- wiring belongs in Profiles and is what makes these functions live.
--
-- In Adapters/ and not Display/ or Core/ because it does what an adapter does: it reads another
-- addon's saved variables and hooks its function. Hard rule 3 draws the line at naming the client's
-- globals, and `ItemRackUser` is one.
--
-- **The label, and nothing else.** The callback fires ~0.5 s BEFORE the new gear is actually in the
-- equipment slots, so anything read from here about set counts, bonuses or weapons describes the
-- gear the player is LEAVING. Those all come from the debounced PLAYER_EQUIPMENT_CHANGED path
-- instead (docs/01 §3). The single most tempting mistake in this file is to "helpfully" read gear
-- while we are already here.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

local Rack = {}

-- ItemRack's own bookkeeping sets are prefixed with a tilde (`~BaseGear`, `~CombatQueue`,
-- `~Unequip`). They are not loadouts the player chose and must never select a build.
local function isInternal(name)
  return type(name) ~= "string" or name == "" or name:sub(1, 1) == "~"
end

function Rack.current()
  -- ItemRackUser is ItemRack's SavedVariables table; it exists only once ItemRack has loaded.
  if type(ItemRackUser) ~= "table" then return nil end
  local set = ItemRackUser.CurrentSet
  if isInternal(set) then return nil end
  return set
end

function Rack.onChange(cb)
  if type(cb) ~= "function" then return false end
  if type(ItemRack) ~= "table" or type(ItemRack.UpdateCurrentSet) ~= "function" then
    -- Nothing to hook. Say so rather than registering a callback that can never fire: a silent
    -- no-op here is exactly the failure that cost an in-game round at M0. D26 (2026-09-07
    -- Notifications pass): a warning, not a plain print -- gear-swap switching going off is exactly
    -- the kind of thing the panel's "Problems" category exists to surface.
    local text = L["ItemRack.UpdateCurrentSet not found; gear-swap build switching is off."]
    if ns.Announce then ns.Announce.emit("warning", text) else ns.log("%s", text) end
    return false
  end
  -- UpdateCurrentSet takes NO arguments (docs/08): reading a hook parameter here would read
  -- whatever ItemRack happened to pass, which is nothing.
  hooksecurefunc(ItemRack, "UpdateCurrentSet", function() cb(Rack.current()) end)
  return true
end

-- Called from Core/Init.lua once the client has finished loading addons. Gated on ItemRack actually
-- being there: this file ships inside core now, so unlike the retired companion addon its mere
-- presence says nothing about whether the user has ItemRack. Registering unconditionally would put
-- an override source in the registry that can only ever answer nil, which reads to everything
-- downstream -- and to the options panel -- as "ItemRack is set up and you have no loadout".
function Rack.Register()
  if type(ItemRack) ~= "table" and type(ItemRackUser) ~= "table" then return false end
  if not (ns.API and ns.API.RegisterOverrideSource) then return false end
  return ns.API.RegisterOverrideSource{
    name = "ItemRack",
    current = Rack.current,
    onChange = Rack.onChange,
  }
end

ns.ItemRack = Rack
return Rack
