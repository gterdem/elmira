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
  "date", -- the client's calendar/clock global (Adapters/Vanilla.lua today())
  "GetTime", "GetSpellCooldown", "IsUsableSpell", "IsPlayerSpell", "IsSpellKnown", "GetSpellInfo",
  -- Rank-free "do I know this": the pack ships one id per ability and Classic gives every rank its
  -- own, so the spellbook is what answers when IsPlayerSpell says no to a max-rank id.
  "GetSpellBookItemName", "GetSpellBookItemInfo",
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
  -- M3b: GetNetStats gives the world-server round trip, which is the reaction lead subtracted from
  -- swing timing. LibStub is named here because Adapters/Swing.lua fetches the swing library.
  "GetNetStats", "LibStub",
  -- `/elm debug perf`: per-addon memory, so the diagnostic can answer "is ELMIRA expensive" instead
  -- of reporting the whole client's Lua heap.
  "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage",
  -- M5e: which frame owns the keyboard, so the Builder's live refresh never rebuilds the panel out
  -- from under a half-typed value. Presence-checked at the call site (Vanilla.typing) rather than
  -- assumed -- an every-frame FrameXML global is not the same promise as a documented C API.
  "GetCurrentKeyBoardFocus",
}

-- Core is pure Lua: naming a WoW global anywhere under Elmira/Core/ is a lint ERROR, by omission.
files["Elmira/Core/"] = { read_globals = {} }

-- Adapters/ is the only place the WoW API may be named (hard rule 3).
files["Elmira/Adapters/"] = { read_globals = WOW_API }

-- Presentation only. Note the absence of GetTime: Display takes its time from ns.now() like
-- everything else, so a second clock cannot appear here by accident.
files["Elmira/Display/"] = { read_globals = { "CreateFrame", "UIParent", "GameTooltip",
  "GetActionInfo", "GetMacroSpell", "PlaySoundFile", "GetSpellTexture", "GetItemIcon",
  -- Ranks: the id on a bar and the id in the data pack can be different ranks of one ability, so the
  -- bar map is keyed by the rank-free name as well. Presentation-side lookup, not state.
  "GetSpellInfo",
  -- The texture in a slot, for the Builder's item palette. Presentation, like GetItemIcon beside
  -- it: a build entry binds to the SLOT, so the icon has to be read from the slot too.
  "GetInventoryItemTexture",
  "GetInventoryItemID", "RANGE_INDICATOR",
  -- F37 announcements (Display/Announcers.lua). LibStub is here rather than at the top level so it
  -- stays out of Core/, and SendChatMessage is the ONE global in this addon that talks to other
  -- players -- worth being able to grep for.
  "LibStub", "DEFAULT_CHAT_FRAME", "NUM_CHAT_WINDOWS", "GetChatWindowInfo",
  "SendChatMessage", "IsInGroup", "IsInRaid" } }
files["Elmira/Setup/"] = { read_globals = { "CreateFrame", "UIParent", "UnitClass", "UnitLevel",
  "GetTalentTabInfo", "C_Engraving" } }
files["Elmira/Options/"] = { read_globals = { "CreateFrame", "UIParent",
  -- M5h, the options window's own chrome (Options.lua): the reposition button's tooltip, and
  -- CLOSE -- the client's localised button text, which is how AceGUI's anonymous Close button is
  -- identified (ElvUI Config.lua:1441-1447). Presentation only; no state is read through either.
  "GameTooltip", "CLOSE",
  -- Pass 2: a post-call hook on AceConfigDialog's own Open, filtered to our app name, so a refresh
  -- neither Options.Open nor AceConfigDialog's pooling triggers still re-runs Options.Decorate.
  "hooksecurefunc" } }

-- Shipped class data (ADR-0011): data only, and held to Core's bar. A WoW API call here is as wrong
-- as one in Core/ — these files are inside the core addon now, and hard rule 3 does not soften
-- because the contents happen to be tables.
--
-- Data ROWS are exempt from the line limit, for the same reason tests/ fixtures are: one row carries
-- a key, an id, a full Wowhead src URL (hard rule 2) and usually a note. Wrapping that across three
-- lines makes the table harder to read and much harder to diff when an id changes. The exemption is
-- wider than it was before M4b (it used to cover Data/ but not Register.lua) because the two are now
-- one file; the read_globals = {} half is what still holds the line that matters.
files["Elmira/Classes/"] = { read_globals = {}, max_line_length = false }

-- ItemRack's own globals, named only by the adapter that integrates with it. Scoped to the file
-- rather than added to WOW_API: these are another ADDON's globals, not the client's, and every other
-- adapter should still fail lint for touching them.
files["Elmira/Adapters/ItemRack.lua"] = { read_globals = { "ItemRack", "ItemRackUser" } }

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
    -- M3b: the swing adapter reads GetNetStats and reaches its library through LibStub.
    "GetNetStats",
    -- `/elm debug perf`: per-addon memory. C_AddOns already covers loadClassPack/addonVersion above;
    -- this mock also exercises its GetNumAddOns/GetAddOnInfo/UpdateAddOnMemoryUsage/
    -- GetAddOnMemoryUsage members, plus the bare-global forms of the memory pair.
    "C_AddOns", "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage",
    -- init_spec.lua loads the real vendored Ace3 stack (Elmira/Libs/) against Core/Init.lua, the one
    -- file allowed to touch LibStub. These are what those libraries read at file scope or per call.
    "geterrorhandler", "IsLoggedIn", "GetLocale", "SlashCmdList", "hash_SlashCmdList",
    "securecallfunction", "C_Timer", "DEFAULT_CHAT_FRAME",
    "GetRealmName", "UnitName", "UnitRace", "UnitFactionGroup", "GetCurrentRegion",
    "GetCurrentRegionName", "strmatch", "ElmiraDB", "__lastFrame",
    -- The options window's own chrome (tests/spec/options_window_spec.lua). CLOSE is the client's
    -- localised button text, which is how AceGUI's anonymous Close button is identified.
    "GameTooltip", "CLOSE",
  },
}
