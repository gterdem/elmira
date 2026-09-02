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

-- Published at FILE LOAD TIME, not inside OnInitialize. Dependency modules run their own file scope
-- before anyone's ADDON_LOADED fires, and Elmira_Paladin/Register.lua reads Elmira.API at file scope
-- too — publishing inside OnInitialize would make that a nil index and crash on login. This only
-- helps modules the TOC actually orders after core: see docs/08-MODULE-API.md on why no module may
-- use `## LoadWith:`.
Elmira = NA
Elmira.API = ns.API

-- Overrides the no-op set in Core/API.lua, so a rejected registration is now visible in chat.
ns.log = function(fmt, ...) NA:Printf(fmt, ...) end

-- Overrides the no-op in Core/Slash.lua. Only ONE snapshot is kept: the dump is a diagnostic, and
-- docs/12 budgets SavedVariables size — an append-forever history would quietly grow the SV file
-- every time the command is run. `global` scope, not `profile`: the snapshot describes the
-- character, not a set of user preferences, and must survive a profile switch.
-- Returns whether it actually saved. A silent `return` here while Slash prints "saved to ..." makes
-- failure indistinguishable from success — the pattern this codebase keeps getting caught by.
ns.saveDump = function(snapshot)
  if not (NA.db and NA.db.global) then return false end
  NA.db.global.dump = snapshot
  return true
end

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

-- Order matters: loadClassPack() triggers the pack's Register.lua at file scope, which is what calls
-- API.RegisterDataPack. Only after that has run can the adapter be given real data, so attaching
-- earlier would silently bind an empty pack and every symbolic key would resolve to nil forever.
function NA:OnEnable()
  local class = ns.Adapter.playerClass()
  ns.Adapter.loadClassPack(class)

  local pack = class and ns.API.GetProviders("dataPacks")[class]
  if not pack then
    ns.log("Elmira: no data pack registered for %s; running with a null state.", tostring(class))
  elseif not ns.Adapter.attachPack then
    -- Distinct from "no pack": the data arrived but the adapter is too old to take it. Reporting
    -- both as "no data pack" would send the next reader hunting the wrong problem.
    ns.log("Elmira: adapter cannot accept a data pack (no attachPack); running with a null state.")
  else
    ns.Adapter.attachPack(pack)
  end
end

function NA:OnSlash(input)
  for _, line in ipairs(ns.Slash.run(input)) do
    self:Print(line)
  end
end
