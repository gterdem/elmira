-- Minimal WoW API mock for adapter tests. Extend as Adapters/Vanilla.lua grows.
local M = { time = 0, cooldowns = {}, auras = { player = {}, target = {} }, power = { [0] = {1000, 1000} },
            inventory = {}, creatureType = nil, attackSpeed = {2.1, nil} }
function GetTime() return M.time end
function GetSpellCooldown(id) local c = M.cooldowns[id]; if c then return c[1], c[2], 1 end return 0, 0, 1 end
function IsUsableSpell(id) return true, false end
function GetSpellInfo(id) return "Spell"..id, nil, nil, M.castTimes and M.castTimes[id] or 0 end
function UnitAura(unit, i, filter)
  local list = M.auras[unit] or {}; local a = list[i]; if not a then return nil end
  return a.name, nil, a.count or 1, nil, a.duration or 10, (a.expires or M.time + 10), a.source or "player", nil, nil, a.spellID
end
function UnitPower(u, kind) return M.power[kind or 0][1] end
function UnitPowerMax(u, kind) return M.power[kind or 0][2] end
function UnitCreatureType(u) return M.creatureType end
function UnitExists(u) return true end
function GetInventoryItemID(u, slot) return M.inventory[slot] end
function UnitAttackSpeed(u) return M.attackSpeed[1], M.attackSpeed[2] end
function GetInventoryItemCooldown(u, slot) return 0, 0 end
function IsUsableItem(id) return true end
function InCombatLockdown() return false end
function CreateFrame() return setmetatable({}, { __index = function() return function() end end }) end
Enum = { PowerType = { Mana = 0, Rage = 1, Energy = 3 } }
WOW_PROJECT_ID, WOW_PROJECT_CLASSIC = 2, 2
return M
