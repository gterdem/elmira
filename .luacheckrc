std = "lua51"
max_line_length = 140
allow_defined_top = false
exclude_files = { "Elmira/Libs", ".release", "collected" }
ignore = {
  "211/ADDON", -- the mandated `local ADDON, ns = ...` leaves ADDON unused in most files
  "212/self",  -- Ace3 callback methods (OnEnable, OnProfileChanged, ...) often don't need self
}

-- Only two globals may ever be written, anywhere in the addon family.
globals = { "Elmira", "ElmiraDB" }

-- Top-level read_globals is deliberately minimal. This IS hard rule 3: Core never calls
-- the WoW API. `read_globals` inside a files[...] block below is ADDITIVE to this list, never a
-- substitute for it, so naming a WoW global here would silently permit it everywhere, including
-- Elmira/Core/. Keep this list to libraries only.
read_globals = { "LibStub" }

local WOW_API = {
  "GetTime", "GetSpellCooldown", "IsUsableSpell", "IsPlayerSpell", "IsSpellKnown", "GetSpellInfo",
  "UnitAura", "UnitPower", "UnitPowerMax", "UnitCreatureType", "UnitExists", "UnitHealth",
  "UnitHealthMax", "GetUnitSpeed", "GetInventoryItemID", "GetInventoryItemLink",
  "GetInventoryItemCooldown", "IsUsableItem", "GetItemInfo", "UnitAttackSpeed", "GetTalentTabInfo",
  "GetActiveTalentGroup", "GetActionInfo", "GetMacroSpell", "InCombatLockdown", "UnitAffectingCombat", "WOW_PROJECT_ID",
  "WOW_PROJECT_CLASSIC", "GetBuildInfo", "GetAddOnMetadata", "C_Engraving", "C_AddOns", "UnitClass", "UnitLevel",
  "UnitName", "GetRealmName", "hooksecurefunc", "Enum", "strsplit", "strjoin", "unpack", "bit",
  "UIParent", "GameTooltip", "CreateFrame", "PlaySoundFile",
  -- M2: GetSpellPowerCost tracks runes (345 -> 69 verified in game, docs/07 §9.3), unlike
  -- GetSpellBaseCooldown which is unusable and deliberately absent from this list.
  "GetSpellPowerCost", "AuraUtil",
}

-- Core is pure Lua: naming a WoW global anywhere under Elmira/Core/ is a lint ERROR, by omission.
files["Elmira/Core/"] = { read_globals = {} }

-- Adapters/ is the only place the WoW API may be named (hard rule 3).
files["Elmira/Adapters/"] = { read_globals = WOW_API }

-- Presentation only. Note the absence of GetTime: Display takes its time from ns.now() like
-- everything else, so a second clock cannot appear here by accident.
files["Elmira/Display/"] = { read_globals = { "CreateFrame", "UIParent", "GameTooltip",
  "GetActionInfo", "GetMacroSpell", "PlaySoundFile", "GetSpellTexture", "GetItemIcon",
  "GetInventoryItemID", "ActionButton_GetPagedID", "RANGE_INDICATOR" } }
files["Elmira/Setup/"] = { read_globals = { "CreateFrame", "UIParent", "UnitClass", "UnitLevel",
  "GetTalentTabInfo", "C_Engraving" } }
files["Elmira/Options/"] = { read_globals = { "CreateFrame", "UIParent" } }

-- Data packs: data only. A WoW API call here is as wrong as one in Core/.
files["Elmira_Paladin/"] = { read_globals = {} }

-- Data ROWS are exempt from the line limit, for the same reason tests/ fixtures are: one row carries
-- a key, an id, a full Wowhead src URL (hard rule 2) and usually a note. Wrapping that across three
-- lines makes the table harder to read and much harder to diff when an id changes. The limit still
-- applies to Register.lua and to any real code in a class pack — this exempts Data/ only.
files["Elmira_Paladin/Data/"] = { read_globals = {}, max_line_length = false }

files["Elmira_ElvUI/"] = { read_globals = { "ElvUI", "GetActionInfo", "GetMacroSpell", "CreateFrame",
  -- Blizzard parks an unbound button's hotkey text at this sentinel instead of clearing it, so a
  -- provider that does not compare against it reports the range dot as a keybind.
  "RANGE_INDICATOR" } }
files["Elmira_ItemRack/"] = { read_globals = { "ItemRack", "ItemRackUser", "hooksecurefunc" } }
files["Elmira_WoWSims/"] = { read_globals = { "C_AddOns" } }
files["Elmira_Insights/"] = { read_globals = { "Details" } }

files["tests/"] = {
  std = "lua51+busted",
  unused_args = false,     -- fake_state.lua's contract stubs legitimately ignore self/args
  max_line_length = false, -- fixture tables read better wide
  -- Every client global tests/wow_mock.lua writes into _G. This list is deliberately spelled out
  -- rather than reusing WOW_API above: the mock may only ever implement a SUBSET of the real API, and
  -- sharing one list would silently grant a spec permission to call something the mock does not
  -- provide — which fails as a nil-call at run time instead of as a lint error here.
  globals = {
    "GetTime", "GetSpellCooldown", "IsUsableSpell", "GetSpellInfo", "UnitAura", "UnitPower",
    "UnitPowerMax", "UnitCreatureType", "UnitExists", "GetInventoryItemID", "UnitAttackSpeed",
    "GetInventoryItemCooldown", "IsUsableItem", "InCombatLockdown", "CreateFrame", "Enum",
    "WOW_PROJECT_ID", "WOW_PROJECT_CLASSIC", "LibStub", "__ELM_NS",
    -- M2 additions, for the adapter surface.
    "IsPlayerSpell", "IsSpellKnown", "GetSpellPowerCost", "AuraUtil", "UnitHealth", "UnitHealthMax",
    "UnitLevel", "UnitClass", "GetUnitSpeed", "GetInventoryItemLink", "GetItemInfo",
    "GetTalentTabInfo", "C_Engraving", "UIParent", "UnitAffectingCombat",
  },
}
