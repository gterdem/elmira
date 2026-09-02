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

-- The recorder holds marks in memory; they only reach disk if something copies them into the DB
-- before the client writes SavedVariables. PLAYER_LOGOUT fires late enough to catch a /reload too,
-- so the player never has to remember to "save" — stop recording and reload is the whole ritual.
ns.flushRecorder = function()
  if not (NA.db and NA.db.global and ns.Recorder) then return false end
  if ns.Recorder.count() == 0 then return false end
  NA.db.global.recording = ns.Recorder.payload()
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

  self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
  self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
  self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", "OnEquipChanged")
  self:RegisterEvent("PLAYER_LOGOUT", function() ns.flushRecorder() end)
end

-- Automatic marks. The player asked not to have to type during a fight, and combat start/end plus
-- gear swaps are exactly the moments a gear-scenario test cares about. All of this costs nothing
-- while the recorder is stopped: Recorder.mark() returns immediately and never calls the capture.
--
-- Equipment changes are debounced because a single gear swap fires several events (one per slot),
-- and marking each would fill the ring buffer with near-identical snapshots and evict the earlier
-- states the test is actually comparing.
local EQUIP_DEBOUNCE = 0.5

-- `always` skips the dedupe fingerprint, for marks whose value is that they were taken at a
-- particular moment rather than in a particular gear state.
function NA:RecordAuto(label, always)
  if not (ns.Recorder and ns.Recorder.isRecording()) then return end
  local packs = ns.API.GetProviders("dataPacks")
  local class = ns.Adapter.playerClass()
  local pack = class and packs[class]
  if not pack then return end
  -- Fingerprint of everything a gear test cares about. Two consecutive auto-marks with the same
  -- fingerprint carry no new information, so the recorder skips the second — repeatedly pulling a
  -- dummy otherwise buries the gear states in identical combat snapshots.
  local mark = ns.captureMark(pack)
  if not mark then return end
  ns.Recorder.mark(label, ns.now and ns.now() or 0, function() return mark end,
    (not always) and ns.Recorder.fingerprint(mark) or nil)
end

-- Sampling interval while fighting. combat-start captures t=0, before anything is on cooldown, and
-- combat-end captures after most cooldowns have expired — so neither sees the state the rotation
-- actually runs in. This is the only way an in-combat queue, with real cooldowns, reaches the file.
local COMBAT_SAMPLE = 5

function NA:OnCombatStart()
  self:RecordAuto("combat-start")
  if not (ns.Recorder and ns.Recorder.isRecording()) then return end
  if self._combatTimer then return end
  -- Samples deliberately carry NO dedupe fingerprint: gear and combat state do not change during a
  -- fight, so a fingerprinted sample would be discarded as "unchanged" and we would capture nothing.
  -- The 5s throttle is what bounds them instead.
  self._combatTimer = self:ScheduleRepeatingTimer(function()
    -- Stop sampling the moment recording stops, even mid-fight; otherwise a `/elm rec stop` during
    -- combat leaves a repeating timer running for the rest of the session doing nothing.
    if not (ns.Recorder and ns.Recorder.isRecording()) then
      self:CancelTimer(self._combatTimer, true)
      self._combatTimer = nil
      return
    end
    self:RecordAuto("combat-sample", true)
  end, COMBAT_SAMPLE)
end

function NA:OnCombatEnd()
  if self._combatTimer then
    self:CancelTimer(self._combatTimer, true)
    self._combatTimer = nil
  end
  self:RecordAuto("combat-end")
end

function NA:OnEquipChanged()
  if self._equipTimer then self:CancelTimer(self._equipTimer, true) end
  self._equipTimer = self:ScheduleTimer(function()
    self._equipTimer = nil
    self:RecordAuto("gear-changed")
  end, EQUIP_DEBOUNCE)
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
