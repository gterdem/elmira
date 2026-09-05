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
-- before anyone's ADDON_LOADED fires, and an external class pack reads Elmira.API at file scope
-- too — publishing inside OnInitialize would make that a nil index and crash on login. This only
-- helps modules the TOC actually orders after core: see docs/08-MODULE-API.md on why no module may
-- use `## LoadWith:`.
Elmira = NA
Elmira.API = ns.API

-- Overrides the no-op set in Core/API.lua, so a rejected registration is now visible in chat.
-- AceConsole hardcodes `|cff33ff99<name>|r:` as its prefix (Libs/AceConsole-3.0:37), which is the
-- colour every Ace addon prints in — Elmira looked like six other addons in the same chat frame.
-- Overriding here rather than editing the library keeps the vendored copy pristine for the packager.
-- `print` rather than DEFAULT_CHAT_FRAME:AddMessage: print is a standard Lua global that WoW routes
-- to the default chat frame, so this needs no WoW-API exception. Naming a real frame here would have
-- meant widening .luacheckrc's empty read_globals for Elmira/Core/, and that empty list IS hard
-- rule 3 — worth more than the two characters it would have saved.
function NA:Print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  print(ns.Colors.prefix() .. ": " .. table.concat(parts, " "))
end

function NA:Printf(fmt, ...)
  print(ns.Colors.prefix() .. ": " .. string.format(tostring(fmt), ...))
end

ns.log = function(fmt, ...) NA:Printf(fmt, ...) end

-- The second half of the library-ownership probe (Adapters/LibOwner.lua, listed before embeds.xml).
-- Sealed HERE, at file scope of the last file in our TOC, because that is still inside our own load:
-- every file between embeds.xml and this line is ours and none calls LibStub:NewLibrary, and no
-- other addon's code can run until our TOC finishes. Deferring it to OnInitialize would let every
-- addon that loads after us register its libraries first, and we would report theirs as ours.
if ns.LibOwner then ns.LibOwner.sealAfterEmbeds() end

-- Overrides the no-op in Core/Slash.lua. Only ONE snapshot is kept: the dump is a diagnostic, and
-- docs/12 budgets the Insights/Tracker ENCOUNTER history (20/100/250 records), which is a different
-- thing from the recorder's mark/cast ring buffer — that one is budgeted in Core/Recorder.lua itself.
-- Either way an append-forever history would quietly grow the SV file
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
  if ns.Recorder.count() == 0 and ns.Recorder.castCount() == 0 then return false end
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

  -- Display and Options read settings through this; Init is the only place that owns the handle.
  ns.db = self.db

  -- The import/export codec (Core/Serialize.lua) never names LibStub itself; both libraries are
  -- handed in here. They are OptionalDeps, and `LibStub(name, true)` is the silent lookup: shipped
  -- without one, the codec reports itself unavailable and `/elm export` says so instead of erroring.
  if ns.Serialize then
    ns.Serialize.use{ serializer = LibStub("LibSerialize", true), deflate = LibStub("LibDeflate", true) }
  end

  -- F37. Core/Announce is pure, so the clock and the combat question are handed in: `now` stamps
  -- the log, `inCombat` is what holds an on-screen message back until the fight ends.
  if ns.Announce then
    ns.Announce.use{
      now = ns.now,
      inCombat = function()
        local state = ns.API and ns.API.GetState()
        return state and state:inCombat() == true or false
      end,
    }
  end

  self:RegisterChatCommand("elm", "OnSlash")
  self:RegisterChatCommand("elmira", "OnSlash")

  self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
  self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
  self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", "OnEquipChanged")
  -- The other two things that move a static gate. SPELLS_CHANGED also covers learning a rank, which
  -- is how a levelling character's rotation grows.
  self:RegisterEvent("PLAYER_LEVEL_UP", "OnGearOrCharacterChanged")
  -- Learning a rank changes which spells `known` can see, and the adapter caches the spellbook.
  self:RegisterEvent("SPELLS_CHANGED", "OnGearOrCharacterChanged")
  -- A talent respec that learns no new spell fires only this, and a talent can move a spell's mana
  -- cost (Benediction), which the adapter now holds until told otherwise.
  self:RegisterEvent("CHARACTER_POINTS_CHANGED", "OnGearOrCharacterChanged")
  -- Engraving. The event name is SoD's and exists on no other flavor, so it is registered only
  -- where the adapter says runes are readable at all -- and inside a pcall, because registering an
  -- event the client does not know is an error, not a no-op.
  local caps = ns.Adapter and ns.Adapter.capabilities and ns.Adapter.capabilities()
  if caps and caps.runes then
    pcall(function() self:RegisterEvent("RUNE_UPDATED", "OnGearOrCharacterChanged") end)
  end
  self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", "OnCastSucceeded")
  self:RegisterEvent("PLAYER_LOGOUT", function() ns.flushRecorder() end)

  -- What makes the queue stale. `Display.invalidate` only sets a flag; Core/Ticker decides when to
  -- act on it, so a spammy event cannot drag the recompute rate up with it.
  --
  -- PLAYER_REGEN_DISABLED/ENABLED and PLAYER_EQUIPMENT_CHANGED are NOT in this list, though they
  -- belong in it by meaning. AceEvent registers one handler per (object, event): a second
  -- RegisterEvent for the same event silently REPLACES the first. All three were registered above
  -- by name and again here as a closure, so the closure won and OnCombatStart, OnCombatEnd and
  -- OnEquipChanged never ran at all -- taking the recorder's combat sampling, its gear marks, the
  -- announcement flush and the move-mode exit with them. Their named handlers invalidate for
  -- themselves now, and tests/spec/init_spec.lua proves no event is registered twice again.
  for _, event in ipairs({
    "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_USABLE", "ACTIONBAR_UPDATE_USABLE",
    "UNIT_AURA", "UNIT_POWER_UPDATE", "PLAYER_TARGET_CHANGED",
  }) do
    self:RegisterEvent(event, function() if ns.Display then ns.Display.invalidate() end end)
  end

  -- The bar map, separately: these change which BUTTON holds a spell, not whether to suggest it.
  -- UPDATE_SHAPESHIFT_FORM is in this list because a stance, form or Shadowform swap repages the
  -- bars. The bar-provider addon used to watch it while core did not, so a stance change dropped the
  -- provider's map and left core's Blizzard map -- and its one-shot "no button found" set -- stale.
  -- Nothing on a paladin ever exposed that; a druid or warrior would have hit it immediately.
  for _, event in ipairs({
    "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
    "UPDATE_MACROS", "PLAYER_ENTERING_WORLD", "UPDATE_SHAPESHIFT_FORM",
  }) do
    self:RegisterEvent(event, function(fired)
      -- Entering the world is also the moment the adapter's held answers (spell costs, runes, the
      -- soul on the shoulders) may have been read before the client could give them. Registered
      -- HERE rather than a second time by name, for the AceEvent reason above.
      if fired == "PLAYER_ENTERING_WORLD" and ns.Adapter and ns.Adapter.forgetSpellbook then
        ns.Adapter.forgetSpellbook()
      end
      if ns.BarGlow then ns.BarGlow.Invalidate() end
      if ns.BarProviders then ns.BarProviders.Invalidate() end
      if ns.Display then ns.Display.refresh() end
    end)
  end
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
  ns.Recorder.mark(label, ns.now(), function() return mark end,
    (not always) and ns.Recorder.fingerprint(mark) or nil)
end

-- Sampling interval while fighting. combat-start captures t=0, before anything is on cooldown, and
-- combat-end captures after most cooldowns have expired — so neither sees the state the rotation
-- actually runs in. This is the only way an in-combat queue, with real cooldowns, reaches the file.
local COMBAT_SAMPLE = 3

-- How often the top suggestion is refreshed into memory during combat. NOT a mark: this writes two
-- fields to a local, so it is cheap enough to run between marks and gives the cast log a suggestion
-- that is at most this stale.
local SUGGEST_POLL = 1

-- Combat is the worst moment to be left with a mouse-enabled frame across the middle of the
-- screen, so move mode ends whether or not the panel is still open.
function NA:OnCombatStart()
  if ns.Display then ns.Display.invalidate() end
  if ns.Announcers then ns.Announcers.StopMoving() end
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

  -- Poll ONCE immediately as well as on the timer. The opening cast of a fight lands within a
  -- fraction of a second of PLAYER_REGEN_DISABLED, long before a 1 s timer first fires, so without
  -- this every fight's opener would record with no suggestion attached -- losing exactly the cast
  -- where the advice matters most.
  self:PollSuggestion()

  if self._suggestTimer then return end
  self._suggestTimer = self:ScheduleRepeatingTimer(function()
    if not (ns.Recorder and ns.Recorder.isRecording()) then
      self:CancelTimer(self._suggestTimer, true)
      self._suggestTimer = nil
      return
    end
    self:PollSuggestion()
  end, SUGGEST_POLL)
end

-- Keeps the most recent top suggestion in memory so a cast can be labelled with what Elmira was
-- saying JUST BEFORE it. Reading the queue inside the cast handler instead would be wrong: by then
-- the spell is already on cooldown and the queue has moved on to the NEXT suggestion, so every row
-- would compare a cast against the advice that followed it.
function NA:PollSuggestion()
  local packs = ns.API.GetProviders("dataPacks")
  local class = ns.Adapter.playerClass()
  local pack = class and packs[class]
  if not pack then return end
  local ok, top = pcall(function() return ns.topSuggestions(pack) end)
  if ok and top then self._suggestion = { at = ns.now(), top = top } end
end

-- The player's own casts. This is the passive answer to "was the top suggestion what you would have
-- pressed?" -- a question that cannot be answered any other way before M3, because there is no
-- display to look at and no way to type a command mid-fight.
function NA:OnCastSucceeded(_, unit, _, spellID)
  if unit ~= "player" then return end
  -- The strip needs this whether or not anything is recording: it is how a CAST is told apart from
  -- a PROMOTION on the next queue change (ADR-0015 §3). It used to sit below the recorder guard,
  -- so outside a recording session the event was observed and thrown away.
  -- Through Display, which tells the strip AND announces a long cooldown. Calling Queue directly
  -- skipped the announcement for anyone who had hidden the strip.
  if ns.Display and ns.Display.noteCast then ns.Display.noteCast(spellID) end
  if not (ns.Recorder and ns.Recorder.isRecording()) then return end
  if type(spellID) ~= "number" then return end
  local packs = ns.API.GetProviders("dataPacks")
  local class = ns.Adapter.playerClass()
  local pack = class and packs[class]
  if not pack then return end

  self._castKeys = self._castKeys or {}
  if self._castKeysPack ~= pack then
    self._castKeys = ns.spellKeyByID(pack)
    self._castKeysPack = pack
  end

  local row = ns.castRow(ns.now(), spellID, self._castKeys, self._suggestion)
  if row then ns.Recorder.cast(row) end
end

function NA:OnCombatEnd()
  if ns.Display then ns.Display.invalidate() end
  if self._combatTimer then
    self:CancelTimer(self._combatTimer, true)
    self._combatTimer = nil
  end
  if self._suggestTimer then
    self:CancelTimer(self._suggestTimer, true)
    self._suggestTimer = nil
  end
  self._suggestion = nil
  -- Anything held back while fighting (F37: on-screen messages wait rather than landing mid-pull).
  if ns.Announce then ns.Announce.flush() end
  self:RecordAuto("combat-end")
end

-- Equipment, runes and level all change which rows of the build can fire (ADR-0015). They arrive
-- as storms of events -- swapping a two-piece set fires PLAYER_EQUIPMENT_CHANGED twice -- so they
-- share one debounce and produce at most one announcement.
function NA:OnGearOrCharacterChanged()
  -- The adapter caches the spellbook, and this fires when a RANK is learned -- the case the cache
  -- exists to answer. Dropped before anything reads `known` again, or the palette and the gates
  -- would go on reporting the ability you just trained as not learned.
  if ns.Adapter and ns.Adapter.forgetSpellbook then ns.Adapter.forgetSpellbook() end
  if ns.Display then ns.Display.invalidate() end
  if self._equipTimer then self:CancelTimer(self._equipTimer, true) end
  self._equipTimer = self:ScheduleTimer(function()
    self._equipTimer = nil
    self:RecordAuto("gear-changed")
    if ns.Display and ns.Display.checkGates then ns.Display.checkGates() end
  end, EQUIP_DEBOUNCE)
end

-- Kept as the event handler's old name so nothing outside has to care that it grew a second job.
function NA:OnEquipChanged()
  self:OnGearOrCharacterChanged()
end

function NA:OnProfileChanged()
  ns.DB.migrateProfile(self.db.profile)
end

-- Order matters: both pack sources must have run before the adapter is given data, so attaching
-- earlier would silently bind an empty pack and every symbolic key would resolve to nil forever.
--
-- Two sources, in this order (ADR-0011):
--   1. the built-in thunk from Elmira/Classes/<Class>.lua, called here and only here;
--   2. an external LoadOnDemand addon claiming the class via `## X-Elmira-Class`, whose own file
--      scope calls API.RegisterDataPack.
-- External runs second and therefore wins. That is deliberate: a user who installed a third-party
-- pack for their class asked for it, and RegisterDataPack cannot tell the two apart by design (§3).
function NA:OnEnable()
  local class = ns.Adapter.playerClass()

  local builtin = ns.Packs and ns.Packs.BuiltinPack(class)
  if builtin then ns.API.RegisterDataPack(builtin) end

  -- LoadAddOn's second return is the reason it failed. Dropping it made "no pack for your class",
  -- "the pack is disabled" and "the pack errored" one indistinguishable log line, which is what
  -- ADR-0011 §Context names as a cost of the folder split. Only worth saying when there is no
  -- built-in pack to fall back on -- otherwise the addon is working and this is noise.
  local loaded, reason, name = ns.Adapter.loadClassPack(class)
  if not loaded and not builtin and reason and reason ~= "no-pack" then
    ns.log("Elmira: %s claims %s but did not load (%s).", tostring(name), tostring(class), tostring(reason))
  end

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

  -- Gear-swap build switching, if ItemRack is installed. Registered here rather than at file scope
  -- for the same reason the bar providers are: this code ships inside core now, so its presence says
  -- nothing about whether the integration target is there, and only the client can answer that.
  if ns.ItemRack then ns.ItemRack.Register() end

  self:StartDisplay()
end

-- Wiring the renderers to the driver. Deliberately after attachPack: a queue built before the pack
-- is attached compiles against no data and every symbolic key resolves to nil, which renders as an
-- empty strip rather than an error.
function NA:StartDisplay()
  if not (ns.Display and ns.Queue) then return end
  -- Bar providers first: one per LibActionButton-1.0 library the client has loaded, which is how
  -- ElvUI and Bartender4 are both supported by the same code. Registering here rather than at file
  -- scope means the libraries have finished loading and their buttons exist to be attributed.
  if ns.BarProviders then
    ns.BarProviders.Register()
    -- A provider may know its bars changed before any client event we watch does -- that is what
    -- `onLayoutChanged` is for (docs/08). Subscribing here is what finally gives it a caller.
    ns.BarProviders.Subscribe(function()
      if ns.BarGlow then ns.BarGlow.Invalidate() end
      if ns.Display then ns.Display.refresh() end
    end)
  end
  ns.Queue.Create()
  ns.Queue.SetLocked(self.db.profile.locked)
  -- Registered before the first render, or the first thing Elmira says on login has nowhere to go
  -- but the Log -- and the login line is the one message every player sees.
  if ns.Announcers then
    ns.Announcers.Create()
    ns.Announcers.Register()
  end
  ns.Display.register("queue", ns.Queue.Render)
  -- The bar glow is its own renderer, not something the strip does on the side (ADR-0015 §3): the
  -- two were joined, so hiding the strip took the glow with it and the player lost the half of the
  -- display they were actually watching.
  if ns.Glow then ns.Display.register("glow", ns.Glow.Render) end
  -- Registered even though every cue is off by default: the renderer costs one comparison per
  -- render when nothing is opted in, and wiring it conditionally would mean the first opt-in
  -- silently does nothing until a reload.
  if ns.Overlay then
    ns.Overlay.Create()
    ns.Display.register("overlay", ns.Overlay.Render)
  end
  if self.db.profile.enabled then
    ns.Display.Enable()
  end

  if ns.Options then ns.Options.Register() end
  self:SetupMinimapButton()

  -- Offering setup must never be able to break the display that has just been started. The wizard
  -- is the newest and least-exercised code in the addon and it runs on every login of every
  -- character, which is the worst possible combination for an unguarded call.
  if ns.Wizard then
    local ok, err = pcall(ns.Wizard.OfferOnLogin)
    if not ok then ns.log("Elmira: setup offer failed (%s); everything else is unaffected.", tostring(err)) end
  end
end

-- LibDataBroker object + LibDBIcon button. Both are already vendored. The icon is our own TGA
-- rather than an `Interface\\Icons\\...` path: Classic Era ships a subset of retail's icons and a
-- missing one renders as a green question mark, which is a silly way to discover a typo.
function NA:SetupMinimapButton()
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
  if not (LDB and DBIcon) then return end

  local obj = LDB:NewDataObject("Elmira", {
    type = "launcher",
    icon = "Interface\\AddOns\\Elmira\\media\\icon",
    OnClick = function(_, button)
      if button == "RightButton" then
        if ns.Queue then ns.Queue.SetLocked(not ns.Queue.isLocked()) end
      elseif ns.Options then
        ns.Options.Open()
      end
    end,
    OnTooltipShow = function(tt)
      if not tt then return end
      tt:AddLine(ns.Colors.prefix())
      tt:AddLine(ns.L["Left-click: options"], 1, 1, 1)
      tt:AddLine(ns.L["Right-click: lock/unlock the queue"], 1, 1, 1)
  -- The last few things Elmira said. A player who has routed announcements away from chat still
  -- has somewhere to notice one, without opening the panel.
  local recent = ns.Announce and ns.Announce.log(3) or {}
  if #recent > 0 then tt:AddLine(" ") end
  for _, row in ipairs(recent) do
    local cat = ns.Announce.category(row.category)
    local c = (cat and ns.Colors[cat.color]) or ns.Colors.MUTED
    tt:AddLine(ns.Announce.plain(row.text), c.r, c.g, c.b)
  end
    end,
  })

  self.db.global.minimap = self.db.global.minimap or {}
  DBIcon:Register("Elmira", obj, self.db.global.minimap)
end

function NA:OnSlash(input)
  for _, line in ipairs(ns.Slash.run(input)) do
    self:Print(line)
  end
end
