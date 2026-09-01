-- Elmira/Core/Init.lua — composition root and AceAddon entry point. Loads last in the TOC.
--
-- This is the ONE file under Elmira/ permitted to read `LibStub` and write the `Elmira` global.
-- That is not a hard-rule-3 exception: AceAddon/AceDB/AceConsole are libraries shipped in our own
-- Libs/ folder, not client API. Their internals touch CreateFrame and SlashCmdList, but that is the
-- library's boundary crossing, not ours — which is exactly why those names are absent from
-- .luacheckrc. The moment this file needs UnitClass or CreateFrame directly, that call moves to
-- ns.Adapter; Init must not grow beyond composition.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local NA = LibStub("AceAddon-3.0"):NewAddon(ADDON, "AceEvent-3.0", "AceTimer-3.0", "AceConsole-3.0")
ns.addon = NA

-- Published at FILE LOAD TIME, not inside OnInitialize. LoadWith/Dependencies modules run their own
-- file scope before anyone's ADDON_LOADED fires, and Elmira_Paladin/Register.lua reads Elmira.API at
-- file scope too — publishing inside OnInitialize would make that a nil index and crash on login.
Elmira = NA
Elmira.API = ns.API

-- Overrides the no-op set in Core/API.lua, so a rejected registration is now visible in chat.
ns.log = function(fmt, ...) NA:Printf(fmt, ...) end

-- AceDB profile scope is deliberately character-specific (no third `true` argument to :New, unlike
-- the wow-addon-dev skill's generic skeleton): profile.activeBuild is class-specific, so a paladin
-- and a mage sharing one "Default" profile would fight over the same key.
function NA:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("ElmiraDB", ns.DB.defaults)
  ns.DB.migrate(self.db)
  ns.DB.migrateProfile(self.db.profile)

  -- AceDB materialises a profile only when it becomes current, so profile migration must also run
  -- on every profile switch, not just at login.
  self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
  self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
  self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")

  self:RegisterChatCommand("elm", "OnSlash")
  self:RegisterChatCommand("elmira", "OnSlash")
end

function NA:OnProfileChanged()
  ns.DB.migrateProfile(self.db.profile)
end

function NA:OnEnable()
  ns.Adapter.loadClassPack(ns.Adapter.playerClass())
end

function NA:OnSlash(input)
  for _, line in ipairs(ns.Slash.run(input)) do
    self:Print(line)
  end
end
