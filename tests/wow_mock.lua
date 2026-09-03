-- tests/wow_mock.lua — WoW client mock for ADAPTER tests only. Core specs must never load this
-- (docs/04): Core is pure Lua and a Core test that needs a client global is a hard-rule-3 violation
-- showing up as a test dependency.
--
-- This file writes into `_G`, so state leaks between specs unless `reset()` is called. Every spec
-- that loads it must call `mock.reset()` in before_each — `tests/spec/wow_mock_spec.lua` exists
-- precisely because until M2 nothing loaded this file at all, making it an untested harness that the
-- adapter specs were about to trust. A mock that lies produces green tests over a broken adapter.
--
-- Return values follow the Classic Era (1.15.x) signatures in the wow-addon-dev API cheat sheet, and
-- where the live client surprised us, THIS MOCK COPIES THE CLIENT, not the documentation. See
-- `GetSpellCooldown` (returns the GCD during the GCD) and `GetTalentTabInfo` (does not return the
-- name first) below — both verified in game, both recorded in docs/07 §9.
local M = {}

-- Defaults live here so reset() is a single assignment and can never drift from the initial state.
local function defaults()
  return {
    time = 0,
    cooldowns = {},          -- [spellID] = { start, duration }
    gcdActive = false,       -- when true, GetSpellCooldown reports the GCD for spells with no real CD
    castTimes = {},          -- [spellID] = milliseconds
    knownSpells = {},        -- [spellID] = true; nil means "not known"
    -- [spellID] = name. Classic has RANKS: several ids share one name, and that is precisely what
    -- lets a bar hold Rank 5 while the data pack ships Rank 6. Without this the mock gave every id a
    -- unique name, so a rank mismatch was unrepresentable and the bar-glow bug it causes could not
    -- be written as a test. Defaults to "Spell<id>" when unset, so existing specs are unaffected.
    spellNames = {},
    powerCosts = {},         -- [spellID] = amount (mana)
    auras = { player = {}, target = {} },
    power = { [0] = { 1000, 1000 } },
    inventory = {},          -- [slot] = itemID
    itemLinks = {},          -- [slot] = link string
    tooltipLines = {},       -- [slot] = { "line", ... }  (LEFT column)
    tooltipRight = {},       -- [slot] = { "line", ... }  (RIGHT column, same line numbers)
    itemInfo = {},           -- [itemID] = { name, equipLoc, speed }
    runes = {},              -- [slot] = { name =, learnedAbilitySpellIDs = {...} }
    engravingEnabled = true,
    creatureType = nil,
    attackSpeed = { 2.1, nil },
    level = 60,
    class = "PALADIN",
    talentTabs = { { 382, 31 }, { 383, 0 }, { 381, 20 } }, -- Arthorion's real spread, docs/07 §9.7
    speed = 0,
    health = { 100, 100 },
    inCombat = false,
    affectingCombat = false,   -- UnitAffectingCombat: the real "is the player fighting" answer
    targetExists = true,       -- was hardcoded true, so "no target" could never be tested
    itemCooldowns = {},        -- [slot] = { start, duration }; was hardcoded (0,0)
    -- Weapon tooltips live in tooltipLines too; base speed is only readable there.
    -- World-server round trip in ms, what GetNetStats reports 4th. Non-zero by default would make
    -- every swing spec depend on it silently, so it starts at 0 and a spec that cares sets it.
    latency = 0,
    actionInfo = {},           -- [slot] = { kind, id }, e.g. {"spell", 415073} or {"macro", 3}
    macroSpells = {},          -- [macroIndex] = spellID; nil means the macro resolves to nothing
    -- [i] = { name =, memory =, pendingMemory =, metadata = { [field] = value }, load = { loaded, reason } }.
    -- `memory` is the STALE snapshot GetAddOnMemoryUsage reports until UpdateAddOnMemoryUsage() copies
    -- `pendingMemory` into it — the client only refreshes these figures on request, which is exactly
    -- the trap `/elm debug perf` exists to not fall into. A spec that never sets `pendingMemory` sees
    -- `memory` unchanged either way. `metadata`/`load` back GetAddOnMetadata/LoadAddOn for
    -- Vanilla.loadClassPack's `X-Elmira-Class` scan (ADR-0011 §3); an addon entry with neither set
    -- behaves as one with no TOC metadata and a bare successful load, matching an addon nobody asked
    -- anything of.
    addons = {},
  }
end

local GCD = 1.5

-- Keys whose default is nil. `pairs()` skips nil values, so a plain copy of defaults() can never
-- clear them and a value set by one spec survives into the next — which is exactly how a stale
-- creatureType made an adapter spec see "Undead" after asking for no target. Nil defaults must be
-- erased explicitly, not assigned.
local NIL_DEFAULTS = { "creatureType" }

function M.reset()
  for _, key in ipairs(NIL_DEFAULTS) do M[key] = nil end
  for key, value in pairs(defaults()) do M[key] = value end
  return M
end

-- Convenience: makes a spell known AND gives it a cooldown/cost in one call, so a spec's intent
-- reads as one line instead of three assignments that can fall out of sync.
function M.spell(id, opts)
  opts = opts or {}
  M.knownSpells[id] = opts.known ~= false
  if opts.cooldown then M.cooldowns[id] = { opts.start or M.time, opts.cooldown } end
  if opts.cost then M.powerCosts[id] = opts.cost end
  if opts.castTime then M.castTimes[id] = opts.castTime end
end

function GetTime() return M.time end

-- Verified in game (docs/07 §9.10): this returns the GLOBAL cooldown for any spell while the GCD is
-- running, not that spell's own cooldown. An adapter that caches the return blindly records 1.5 s as
-- Exorcism's cooldown. The mock reproduces the trap so a spec can prove the filter works.
function GetSpellCooldown(id)
  local c = M.cooldowns[id]
  if c then return c[1], c[2], 1 end
  if M.gcdActive then return M.time, GCD, 1 end
  return 0, 0, 1
end

function IsUsableSpell(id) return M.knownSpells[id] == true, false end
function IsPlayerSpell(id) return M.knownSpells[id] == true end
function IsSpellKnown(id) return M.knownSpells[id] == true end

function GetSpellInfo(id)
  if M.knownSpells[id] == nil then return nil end
  -- Field 2 (rank) is absent on this client — docs/07 §9.6. Returning nil keeps specs honest.
  return M.spellNames[id] or ("Spell" .. tostring(id)), nil, nil, M.castTimes[id] or 0
end

-- Returns a LIST of cost tables, not a bare number. Reflects runes on the live client (345 -> 69
-- measured), which is why the adapter may call it directly instead of shipping a static table.
function GetSpellPowerCost(id)
  local cost = M.powerCosts[id]
  if not cost then return {} end
  return { { cost = cost, type = 0, name = "MANA" } }
end

function UnitAura(unit, i, filter)
  local list = M.auras[unit] or {}
  local a = list[i]
  if not a then return nil end
  return a.name, nil, a.count or 1, nil, a.duration or 10, (a.expires or M.time + 10),
         a.source or "player", nil, nil, a.spellID
end

AuraUtil = {
  FindAuraByName = function(name, unit, filter)
    for i = 1, 40 do
      local auraName = UnitAura(unit, i, filter)
      if not auraName then return nil end
      if auraName == name then return UnitAura(unit, i, filter) end
    end
    return nil
  end,
}

function UnitPower(u, kind) return M.power[kind or 0][1] end
function UnitPowerMax(u, kind) return M.power[kind or 0][2] end
function UnitCreatureType(u) return M.creatureType end
function UnitExists(u)
  if u == "target" then return M.targetExists end
  return true
end
function UnitHealth(u) return M.health[1] end
function UnitHealthMax(u) return M.health[2] end
function UnitLevel(u) return M.level end
function UnitClass(u) return "ClassName", M.class end
function GetUnitSpeed(u) return M.speed end
function GetInventoryItemID(u, slot) return M.inventory[slot] end
function GetInventoryItemLink(u, slot) return M.itemLinks[slot] end
function UnitAttackSpeed(u) return M.attackSpeed[1], M.attackSpeed[2] end
function GetInventoryItemCooldown(u, slot)
  local c = M.itemCooldowns[slot]
  if c then return c[1], c[2] end
  return 0, 0
end
function IsUsableItem(id) return true end

-- BarGlow's Blizzard-scan fallback (Elmira/Display/BarGlow.lua): `type, id = GetActionInfo(slot)`.
-- Only "spell" and "macro" kinds matter to the addon; the mock does not model the rest (item, etc.).
-- Written through `_G.` rather than as a bare global function: these three are not in the
-- `tests/` luacheck globals allowlist (.luacheckrc lives outside tests/, out of bounds for this
-- change), and an explicit `_G.` field assignment is not a "setting non-standard global variable"
-- warning the way an implicit bare assignment is.
_G.GetActionInfo = function(slot)
  local info = M.actionInfo[slot]
  if not info then return nil end
  return info[1], info[2]
end

-- A `#showtooltip` macro's resolved spell id, or nil if it casts nothing this addon recognises.
_G.GetMacroSpell = function(index)
  return M.macroSpells[index]
end

-- Blizzard parks an unbound button's hotkey text at this sentinel string instead of clearing it
-- (docs/07 verified equivalent, see BarGlow.lua's own comment). Any plain non-empty placeholder
-- serves the mock; the real client's exact glyph is not something a headless spec can compare.
_G.RANGE_INDICATOR = "RANGE_INDICATOR_SENTINEL"
function InCombatLockdown() return M.inCombat end
-- Distinct from lockdown on purpose: the adapter must use this one, and a mock that aliased them
-- would let the wrong API keep passing. `combatLockdown` defaults to inCombat unless a spec splits
-- them, which is the case that reproduces PLAYER_REGEN_DISABLED firing before lockdown is set.
function UnitAffectingCombat(unit) return M.affectingCombat end

function GetItemInfo(id)
  local info = M.itemInfo[id]
  if not info then return nil end
  -- Real signature has itemEquipLoc at 9 and speed nowhere; specs read what the adapter reads.
  return info.name, nil, nil, nil, nil, nil, nil, nil, info.equipLoc, nil, nil, nil, nil, nil, nil,
         nil, nil
end

-- Verified in game (docs/07 §9.8): this does NOT return the name first. Position 1 held a numeric tab
-- id (382 Holy / 383 Prot / 381 Ret) and points spent were in position 5. The mock copies the client,
-- so any code written against the documented shape fails here rather than in game.
function GetTalentTabInfo(tab)
  local t = M.talentTabs[tab]
  if not t then return nil end
  return t[1], nil, nil, nil, t[2]
end

C_Engraving = {
  IsEngravingEnabled = function() return M.engravingEnabled end,
  GetRuneForEquipmentSlot = function(slot) return M.runes[slot] end,
  RefreshRunesList = function() end,
}

-- A scanning tooltip: CreateFrame("GameTooltip", name, ...) must also publish the per-line font
-- strings as globals, because that is the only way Classic exposes tooltip text.
function CreateFrame(frameType, name, parent, template)
  local frame = {}
  local lines = {}
  -- Real RegisterEvent/SetScript bookkeeping, not the generic no-op fallback below: without this,
  -- a frame-driven watcher (e.g. Elmira_ElvUI/Provider.lua's `watcher:SetScript("OnEvent", fn)`)
  -- cannot be proven wired at all — the call would succeed silently whether or not it did anything.
  local scripts, registered = {}, {}
  function frame:RegisterEvent(event) registered[event] = true end
  function frame:UnregisterEvent(event) registered[event] = nil end
  function frame:IsEventRegistered(event) return registered[event] == true end
  function frame:SetScript(event, handler) scripts[event] = handler end
  function frame:GetScript(event) return scripts[event] end
  -- NOT a real WoW frame method. A spec-only hook to simulate the client delivering a REGISTERED
  -- event to this frame, mirroring how the client actually dispatches: every event, whichever one
  -- fired, is delivered through the single "OnEvent" script (not a script named after the event),
  -- and only if RegisterEvent(event) was called. A frame that never registered `event` stays quiet,
  -- same as in game.
  function frame:Fire(event, ...)
    if not registered[event] then return end
    local handler = scripts.OnEvent
    if handler then return handler(frame, event, ...) end
  end
  function frame:SetOwner() end
  function frame:ClearLines() lines = {} end
  function frame:NumLines() return #lines end
  -- Models BOTH columns, because the client does: a weapon's "Speed 2.10" is right-column text on
  -- the same line as its damage range. Modelling only the left let a left-only parse pass its test
  -- and then find nothing in game. `tooltipLines[slot]` is the left column; `tooltipRight[slot]` the
  -- right, indexed by the same line number.
  function frame:SetInventoryItem(unit, slot)
    lines = M.tooltipLines[slot] or {}
    local right = M.tooltipRight[slot] or {}
    if name then
      for i = 1, 40 do
        local l, r = lines[i], right[i]
        _G[name .. "TextLeft" .. i] = l and { GetText = function() return l end } or nil
        _G[name .. "TextRight" .. i] = r and { GetText = function() return r end } or nil
      end
    end
  end
  setmetatable(frame, { __index = function() return function() end end })
  -- NOT a real WoW global. A file that builds its own event-watcher frame at load time (e.g.
  -- Elmira_ElvUI/Provider.lua) gives a spec no other handle on it; this is the cheapest way to
  -- reach "the frame that file just made" without inventing a return value CreateFrame never has.
  _G.__lastFrame = frame
  return frame
end

-- down, up, lagHome, lagWorld. Only the 4th is ever read: home latency is the chat/realm server and
-- has nothing to do with when a swing lands.
function GetNetStats() return 0, 0, 0, M.latency end

-- Per-addon memory (KB), as read by Vanilla.addonMemoryKB. Classic Era exposes these as bare
-- globals; `C_AddOns.*` below mirrors the same DATA rather than delegating to the bare-global names,
-- so a spec can nil out the bare globals and prove the adapter's `C_AddOns.*` fallback path works on
-- its own, not merely by forwarding to a global that test just removed.
local function updateAddOnMemoryUsage()
  for _, a in ipairs(M.addons) do
    if a.pendingMemory ~= nil then a.memory = a.pendingMemory end
  end
end

local function getAddOnMemoryUsage(i)
  local a = M.addons[i]
  return a and a.memory or 0
end

function UpdateAddOnMemoryUsage() updateAddOnMemoryUsage() end
function GetAddOnMemoryUsage(i) return getAddOnMemoryUsage(i) end

-- By NAME, matching the real API (and Vanilla.loadClassPack's own call shape: it resolves a name via
-- GetAddOnInfo(i) first, then asks GetAddOnMetadata(name, field) — never GetAddOnMetadata(i, field)).
local function findAddonByName(name)
  for _, a in ipairs(M.addons) do
    if a.name == name then return a end
  end
  return nil
end

C_AddOns = {
  GetNumAddOns = function() return #M.addons end,
  GetAddOnInfo = function(i)
    local a = M.addons[i]
    return a and a.name or nil
  end,
  UpdateAddOnMemoryUsage = function() updateAddOnMemoryUsage() end,
  GetAddOnMemoryUsage = function(i) return getAddOnMemoryUsage(i) end,
  GetAddOnMetadata = function(name, field)
    local a = findAddonByName(name)
    return a and a.metadata and a.metadata[field] or nil
  end,
  -- Defaults to a plain success when a fixture named an addon but never configured `load`, so a spec
  -- only needs to set `load` when it cares about a specific failure reason.
  LoadAddOn = function(name)
    local a = findAddonByName(name)
    if not a then return nil, "MISSING" end
    local load = a.load or { true, nil }
    return load[1], load[2]
  end,
}

UIParent = {}
Enum = { PowerType = { Mana = 0, Rage = 1, Energy = 3 } }
WOW_PROJECT_ID, WOW_PROJECT_CLASSIC = 2, 2

-- The Ace3 surface below is for specs that load the REAL vendored Ace3 libraries (Elmira/Libs/) --
-- e.g. tests/spec/init_spec.lua, which is Core/Init.lua's composition root and the one file
-- permitted to touch LibStub. Everything here is what those libraries read at their own file scope
-- or on every call; none of it is Elmira-specific behaviour, so faking it here (rather than in the
-- spec) is mirroring the client, not inventing a fixture that asserts the spec's own assumptions.
-- LibStub itself expects this WoW string-library alias (`strmatch(minor, "%d+")` in NewLibrary).
strmatch = string.match
function geterrorhandler() return function(err) return err end end
function IsLoggedIn() return true end
function GetLocale() return "enUS" end
-- AceDB-3.0 builds its per-character/per-realm/per-faction profile keys from these at file scope.
-- Values are fixed and arbitrary (no spec depends on a particular realm/race/faction), unlike
-- `M.class`, which adapter specs do depend on and which already has its own real accessor above.
function GetRealmName() return "TestRealm" end
function UnitName(u) return "TestChar" end
function UnitRace(u) return "Human", "Human" end
function UnitFactionGroup(u) return "Alliance" end
function GetCurrentRegion() return 1 end
function GetCurrentRegionName() return "US" end
-- AceConsole-3.0 writes RegisterChatCommand entries into these; both are read/write tables the
-- client provides, never rebuilt per-spec (mirrors SLASH_* globals, which nothing ever resets either).
SlashCmdList = {}
hash_SlashCmdList = {}
-- CallbackHandler-1.0's Dispatch() runs every registered callback through this. The real one is a
-- taint boundary; headless code has no taint to guard against, so a straight pass-through is
-- behaviourally identical for a spec's purposes.
function securecallfunction(f, ...) return f(...) end
-- AceTimer-3.0 captures `C_Timer.After` as a file-scope upvalue, so the table must exist (with an
-- `.After` field) before that file loads, even though nothing in Core/Init.lua's own tests fires a
-- scheduled timer.
C_Timer = { After = function() end }

-- AceConsole-3.0 falls back to this when a caller doesn't hand it its own chat frame.
DEFAULT_CHAT_FRAME = CreateFrame("Frame")

M.GCD = GCD
return M.reset()
