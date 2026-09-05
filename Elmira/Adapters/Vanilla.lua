-- Elmira/Adapters/Vanilla.lua — Classic Era / SoD implementation of the State contract.
--
-- This and Collector.lua are the only files under Elmira/ permitted to name a WoW global (hard rule
-- 3, enforced by .luacheckrc). Core sees only the table newState() returns.
--
-- Members are defined with COLON syntax because Core calls them that way (`state:cooldown(key)` in
-- Engine.lua and Schema.lua). Under dot syntax the state table itself arrives as the spell key and
-- every lookup silently misses — docs/01 §2 now states this explicitly.
--
-- Every accessor takes a SYMBOLIC KEY ("EXORCISM"), never a numeric id: Core must not know ids
-- (hard rule 4). Resolution to an id happens here, against the registered data pack.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Vanilla = {}

-- Readings at or below this are the global cooldown, not a spell's own. GetSpellCooldown returns the
-- GCD for ANY spell while the GCD runs (docs/07 §9.10), so caching one records 1.5 s as Exorcism's
-- cooldown forever. 1.6 leaves headroom for the 1.5 s GCD without swallowing a real short cooldown.
local GCD_CEILING = 1.6

local INVSLOT_SHOULDER = 3
-- The TEN slots Season of Discovery lets you engrave: helm, chest, belt, legs, boots, wrist, gloves,
-- both rings, cloak. Owner-confirmed and client-swept 2026-09-03. This list shipped as
-- { 1, 5, 6, 7, 8, 9, 10 }, which made every ring and CLOAK rune invisible: `rune` gates on
-- RUNE_RIGHTEOUS_VENGEANCE (all Ret), RUNE_SHIELD_OF_RIGHTEOUSNESS (Prot) and RUNE_SHOCK_AND_AWE
-- (Shockadin) could never be true, and the wizard told you to engrave runes you were wearing.
-- M2's in-game pass reported "all 7 runes match" -- seven, the exact number it was able to see.
--
-- Do NOT read `rune.equipmentSlot` back to learn which slot answered: the client does not set it to
-- the slot you queried. Observed live, querying 12 returned equipmentSlot=11 and querying 15
-- returned equipmentSlot=16. The queried slot is the truth.
local RUNE_SLOTS = { 1, 5, 6, 7, 8, 9, 10, 11, 12, 15 }

-- docs/07 §9.5: IsEngravingEnabled() is a real, independent call. Deriving both flags from
-- `C_Engraving ~= nil` made them incapable of ever disagreeing, which is what the M0 stub did.
function Vanilla.capabilities()
  local hasEngravingAPI = C_Engraving ~= nil
  local engravingOn = hasEngravingAPI
    and C_Engraving.IsEngravingEnabled ~= nil
    and C_Engraving.IsEngravingEnabled() == true
  return {
    runes = hasEngravingAPI,   -- can we ASK about runes?
    engraving = engravingOn,   -- is engraving actually enabled for this character?
    setAPI = false,
    -- Follows the library's REAL presence, not a hardcoded answer. A capability that cannot vary is
    -- not a capability -- `runes`/`engraving` were derived from one expression until docs/07 §9.5
    -- showed they genuinely disagree, and this flag was `false` in a file that shipped the wrapper.
    swing = ns.Swing ~= nil and ns.Swing.available() == true,
    -- Whether the client will report PER-ADDON memory. Classic Era does; a client that does not
    -- must make `/elm debug perf` say so rather than quietly fall back to the whole-heap number.
    addonMemory = (UpdateAddOnMemoryUsage or (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage)) ~= nil,
    inspect = false,
    nameplates = false,
    seal = true,               -- paladin seal accessor; class-gated at M5 when other classes land
  }
end

function Vanilla.detect()
  local build, revision, date, tocversion = GetBuildInfo()
  return {
    project = WOW_PROJECT_ID,
    isClassic = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC,
    build = build, revision = revision, date = date, interface = tocversion,
  }
end

function Vanilla.addonVersion()
  local version
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    version = C_AddOns.GetAddOnMetadata(ADDON, "Version")
  elseif GetAddOnMetadata then
    version = GetAddOnMetadata(ADDON, "Version")
  end
  return version or "dev"
end

-- Memory used by the Elmira addon family, in KB, or nil when the client will not say.
--
-- `/elm debug perf` asks "is Elmira expensive". `collectgarbage("count")` cannot answer that -- it
-- reports the whole client's Lua heap, every addon included, so a 300 MB reading says nothing about
-- us. This is the number that does. Summed across the family rather than the core addon alone,
-- because the class pack and the integration modules are Elmira's cost too.
--
-- nil, never 0, when the API is absent: "we could not tell" and "it is free" must not look alike.
function Vanilla.addonMemoryKB()
  local update = UpdateAddOnMemoryUsage or (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage)
  local usage = GetAddOnMemoryUsage or (C_AddOns and C_AddOns.GetAddOnMemoryUsage)
  local count = C_AddOns and C_AddOns.GetNumAddOns
  local info = C_AddOns and C_AddOns.GetAddOnInfo
  if not (update and usage and count and info) then return nil end
  -- The figures are a snapshot the client refreshes only on request, so without this every reading
  -- after the first would be the same stale number.
  update()
  local total = 0
  for i = 1, count() do
    local name = info(i)
    if name and name:sub(1, 6) == "Elmira" then total = total + (usage(i) or 0) end
  end
  return total
end

-- The calendar date, for provenance stamps (a fork's `importedAt`, ADR-0010). Core never reads the
-- clock; `date` is the client's global.
function Vanilla.today()
  return date and date("%Y-%m-%d") or nil
end

function Vanilla.playerClass()
  local _, class = UnitClass("player")
  return class
end

-- Talent points per tree, for Setup/Detect's spec heuristic. An adapter EXTRA, deliberately not a
-- State contract member: no condition in docs/02 reads talents, and adding one would mean editing
-- the contract, its doc, the null state and interface_spec for something only the wizard wants.
--
-- The call shape is the one docs/07 §9.8 recorded from the live client, not the one the API docs
-- describe: GetTalentTabInfo does NOT return the name first. Position 1 is a numeric tab id
-- (382 Holy / 383 Prot / 381 Ret for paladins) and points spent are at position 5. Collector.lua
-- learned this the hard way; naming the first return `first` here keeps the mistake un-repeatable.
function Vanilla.talents()
  if not GetTalentTabInfo then return nil end
  local tabs, total, top, topPoints = {}, 0, nil, -1
  for i = 1, 3 do
    local ok, first, _, _, _, points = pcall(GetTalentTabInfo, i)
    -- A tab the client cannot describe means the whole reading is unusable. Without this the loop
    -- built three tabs of zero points and reported "tree 1, 0 points spent" — a confident answer
    -- that a level-1 character is Holy, which is worse than admitting we do not know.
    if not ok or first == nil then return nil end
    points = tonumber(points) or 0
    tabs[i] = { id = first, points = points }
    total = total + points
    if points > topPoints then top, topPoints = i, points end
  end
  -- `top` is the tree with the most points — a heuristic, and named as one. A 31/0/20 paladin is
  -- "Holy" by this measure and plays as a Shockadin hybrid; the wizard offers, it never decides.
  return { tabs = tabs, total = total, top = top, topPoints = topPoints }
end

-- Which of the pack's spells this character actually knows. An adapter EXTRA for the same reason
-- talents are one: no condition in docs/02 asks it, only the wizard's requirement check does.
--
-- `known` is NOT `usable`. The State's `usable()` answers "can I cast this right now", which is
-- false when out of mana or out of range — a fine answer for the engine and a terrible one for
-- "do you have this ability", which is what a requirement means.
function Vanilla.knownSpells(spells)
  if not (IsPlayerSpell and type(spells) == "table") then return nil end
  local out = {}
  for key, record in pairs(spells) do
    local id = type(record) == "table" and record.id
    if type(id) == "number" and id > 0 then
      -- A failed call leaves the key ABSENT, not false. Folding it to false would say "you do not
      -- know this" on the strength of a call that did not answer — the same conflation this whole
      -- record exists to avoid, just at per-key granularity instead of per-table.
      local ok, known = pcall(IsPlayerSpell, id)
      if ok then out[key] = known == true end
    end
  end
  return out
end

-- Loads an EXTERNAL class pack -- a separate addon claiming this class with `## X-Elmira-Class`.
-- Shipped classes come from Elmira/Classes/<Class>.lua and never take this path (ADR-0011 §3 keeps
-- the scan anyway: it is the whole third-party extension route).
--
-- Returns `loaded, reason, name`. The reason is LoadAddOn's own failure token when an addon claims
-- the class and fails to load, and the distinct "no-pack" when nothing claims it at all. Those are
-- different problems -- one is a broken install, the other is the normal case for eight of nine
-- classes -- and returning only `false` for both is what made them one log line.
function Vanilla.loadClassPack(class)
  if not (class and C_AddOns and C_AddOns.GetNumAddOns) then return false, "no-scan" end
  for i = 1, C_AddOns.GetNumAddOns() do
    local name = C_AddOns.GetAddOnInfo(i)
    if C_AddOns.GetAddOnMetadata(name, "X-Elmira-Class") == class then
      local loaded, reason = C_AddOns.LoadAddOn(name)
      return loaded, reason, name
    end
  end
  return false, "no-pack"
end

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------

local function idOf(spells, key)
  local record = spells and spells[key]
  if type(record) ~= "table" then return nil end
  local id = record.id
  -- A 0 is not an id, it is a placeholder. Treating it as one produces a lookup that can never
  -- match and never errors, so reject it here rather than passing it to the client.
  if type(id) ~= "number" or id <= 0 then return nil end
  return id
end

local scanTooltip
local SCAN_NAME = "ElmiraStateScanTooltip"

local function tooltipLines(slot)
  if not CreateFrame then return {} end
  if not scanTooltip then
    scanTooltip = CreateFrame("GameTooltip", SCAN_NAME, nil, "GameTooltipTemplate")
    if scanTooltip.SetOwner and UIParent then scanTooltip:SetOwner(UIParent, "ANCHOR_NONE") end
  end
  scanTooltip:ClearLines()
  scanTooltip:SetInventoryItem("player", slot)
  -- BOTH columns. A weapon tooltip puts "132 - 199 Damage" on the left and "Speed 2.10" on the
  -- RIGHT of the same line, so a left-only scan silently never finds the speed — which is why the
  -- first fix for base weapon speed did nothing in game and quietly fell back to the hasted value.
  local lines = {}
  for i = 1, scanTooltip:NumLines() do
    local left = _G[SCAN_NAME .. "TextLeft" .. i]
    local leftText = left and left:GetText()
    if leftText and leftText ~= "" then lines[#lines + 1] = leftText end
    local right = _G[SCAN_NAME .. "TextRight" .. i]
    local rightText = right and right:GetText()
    if rightText and rightText ~= "" then lines[#lines + 1] = rightText end
  end
  return lines
end

-- Base weapon speed from the item tooltip. Classic exposes it nowhere else: GetItemInfo returns the
-- equip location but no speed, and UnitAttackSpeed is already hasted. Falls back to nil (not to a
-- plausible-looking number) when the line is absent, so the caller can tell "unknown" from "2.10".
local function baseWeaponSpeed(slot)
  for _, line in ipairs(tooltipLines(slot)) do
    local speed = line:match("[Ss]peed%s+([%d%.]+)")
    if speed then return tonumber(speed) end
  end
  return nil
end

-- Builds a fresh State over a data pack. Returning a new table rather than mutating a singleton
-- keeps specs independent and means a profile/class switch cannot leave stale cached ids behind.
function Vanilla.newState(spells, sets, souls, bonusDefs, sealLingerWindow)
  spells, sets, souls = spells or {}, sets or {}, souls or {}

  local S = {}
  -- Observed cooldown durations, keyed by spell key. Never seeded from a shipped value and never
  -- from GetSpellBaseCooldown: that returned 15000 in every gear state while the real cooldown was
  -- 6 s (docs/07 §9.1), so there is no safe static seed and "unknown" must stay unknown.
  local observed = {}

  local function resolve(key) return idOf(spells, key) end

  function S:now() return GetTime() end

  -- The GCD is whatever GetSpellCooldown reports for a spell that has no cooldown of its own —
  -- which is the same behaviour that makes baseCooldown dangerous, used deliberately here.
  function S:gcd()
    for key in pairs(spells) do
      local id = resolve(key)
      if id and IsPlayerSpell and IsPlayerSpell(id) then
        local start, duration = GetSpellCooldown(id)
        if duration and duration > 0 and duration <= GCD_CEILING then
          local remaining = (start + duration) - GetTime()
          return remaining > 0 and remaining or 0
        end
      end
    end
    return 0
  end

  -- How long a global cooldown LASTS, as opposed to how much of one is left. Read from whatever
  -- spell is currently showing a GCD-length cooldown; falls back to the 1.5s base when nothing is,
  -- which is the common case out of combat. Melee GCDs are not haste-reduced on this client.
  function S:gcdDuration()
    for key in pairs(spells) do
      local id = resolve(key)
      if id and IsPlayerSpell and IsPlayerSpell(id) then
        local _, duration = GetSpellCooldown(id)
        if duration and duration > 0 and duration <= GCD_CEILING then return duration end
      end
    end
    return 1.5
  end

  function S:cooldown(key)
    local id = resolve(key)
    if not id then return 0 end
    local start, duration = GetSpellCooldown(id)
    if not duration or duration <= 0 then return 0 end
    -- A GCD reading is not this spell's cooldown. Reporting it would make every spell look
    -- unavailable for 1.5 s after any cast.
    if duration <= GCD_CEILING then return 0 end
    observed[key] = duration
    local remaining = (start + duration) - GetTime()
    return remaining > 0 and remaining or 0
  end

  -- Observe-and-cache. Only a reading taken while the spell is genuinely on cooldown counts.
  function S:baseCooldown(key)
    local id = resolve(key)
    if not id then return 0 end
    local _, duration = GetSpellCooldown(id)
    if duration and duration > GCD_CEILING then observed[key] = duration end
    return observed[key] or 0
  end

  function S:usable(key)
    local id = resolve(key)
    if not id then return false end
    local usable = IsUsableSpell(id)
    return usable == true
  end

  function S:castTime(key)
    local id = resolve(key)
    if not id then return 0 end
    local _, _, _, ms = GetSpellInfo(id)
    if not ms then return 0 end
    return ms / 1000
  end

  -- Reflects runes on the live client (345 -> 69 measured, docs/07 §9.3), which is why no static
  -- cost table is consulted here. Returns a LIST of cost tables, not a number.
  function S:powerCost(key)
    local id = resolve(key)
    if not id or not GetSpellPowerCost then return 0, nil end
    local costs = GetSpellPowerCost(id)
    if type(costs) ~= "table" or not costs[1] then return 0, nil end
    return costs[1].cost or 0, costs[1].name or "MANA"
  end

  local function findAura(unit, key, filter, mineOnly)
    local id = resolve(key)
    if not id then return nil end
    for i = 1, 40 do
      local name, _, count, _, duration, expires, source = UnitAura(unit, i, filter)
      if not name then return nil end
      local _, _, _, _, _, _, _, _, _, spellID = UnitAura(unit, i, filter)
      if spellID == id and (not mineOnly or source == "player") then
        local remaining = expires and (expires - GetTime()) or 0
        return (count and count > 0) and count or 1, remaining > 0 and remaining or 0, duration
      end
    end
    return nil
  end

  function S:buff(key) return findAura("player", key, "HELPFUL") end
  function S:debuff(key, mine) return findAura("target", key, "HARMFUL", mine == true) end

  function S:power(kind)
    local index = 0
    if Enum and Enum.PowerType then
      if kind == "RAGE" then index = Enum.PowerType.Rage
      elseif kind == "ENERGY" then index = Enum.PowerType.Energy
      else index = Enum.PowerType.Mana end
    end
    return UnitPower("player", index) or 0, UnitPowerMax("player", index) or 0
  end

  function S:targetType() return UnitCreatureType("target") end
  function S:targetExists() return UnitExists("target") == true end

  function S:targetHPPct()
    if not UnitExists("target") then return nil end
    local max = UnitHealthMax("target")
    if not max or max <= 0 then return nil end
    return (UnitHealth("target") / max) * 100
  end

  -- UnitAffectingCombat, NOT InCombatLockdown. The latter reports whether the UI is in protected-
  -- function lockdown — related, but not the same question, and it is not yet set at the instant
  -- PLAYER_REGEN_DISABLED fires. Every mark in the first two recordings reported combat=false,
  -- including the ones taken at combat start (docs/07 §9.16). Lockdown remains the right check
  -- before touching a secure frame; it is the wrong answer for "is the player fighting".
  function S:inCombat()
    if UnitAffectingCombat then return UnitAffectingCombat("player") == true end
    return InCombatLockdown() == true
  end
  function S:moving() return (GetUnitSpeed("player") or 0) > 0 end

  -- Takes a SLOT and returns a table, matching Schema.lua's `C.weapon`: it calls state:weapon(slot)
  -- with 16 for 2H/1H and 17 for Shield, then reads `w.type` and `w.speed`.
  --
  -- `speed` is the BASE item speed, parsed from the item tooltip's "Speed 2.10" line — NOT
  -- UnitAttackSpeed, which is haste-modified. The two genuinely diverge: Truthbearer (229749, the
  -- Exodin weapon) is a 2.10 speed 2H carrying a chance-on-hit that grants +30% attack speed for 8 s,
  -- so UnitAttackSpeed reads ~1.6 while the proc is up. A build gating on a speed range would flip
  -- its answer mid-fight on a proc. UnitAttackSpeed is kept as `hastedSpeed` for callers that
  -- genuinely want it (M3b's swing timer), so the two can never be confused for one another.
  function S:weapon(slot)
    slot = slot or 16
    local id = GetInventoryItemID("player", slot)
    if not id then return nil end
    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(id)
    local kind
    if equipLoc == "INVTYPE_2HWEAPON" then kind = "2H"
    elseif equipLoc == "INVTYPE_SHIELD" then kind = "Shield"
    elseif equipLoc then kind = "1H" end
    if not kind then return nil end
    local main, off = UnitAttackSpeed("player")
    local hasted = (slot == 17 and off) or main
    return { type = kind, itemID = id, speed = baseWeaponSpeed(slot) or hasted, hastedSpeed = hasted }
  end

  function S:setCount(setKey)
    local set = sets[setKey]
    if not set or not set.items then return 0 end
    local wanted = {}
    for _, itemID in ipairs(set.items) do wanted[itemID] = true end
    local count = 0
    for slot = 1, 19 do
      local equipped = GetInventoryItemID("player", slot)
      if equipped and wanted[equipped] then count = count + 1 end
    end
    return count
  end

  -- Souls come from the shoulder TOOLTIP, not the item link — the link's enchant field is empty even
  -- when a soul is equipped (docs/07 §9.10, confirmed again by the first dump). Matching is on the
  -- short localized name, which makes this enUS-only in v1: a known, recorded limitation.
  function S:enchant(slot)
    if slot ~= INVSLOT_SHOULDER then return nil end
    local lines = tooltipLines(slot)
    for _, line in ipairs(lines) do
      for key, soul in pairs(souls) do
        if type(soul) == "table" and soul.short and line == soul.short then return key end
      end
    end
    return nil
  end

  local function wearingSoul(soulKey)
    return S:enchant(INVSLOT_SHOULDER) == soulKey
  end

  -- A bonus is "enough set pieces OR a soul that grants it" (docs/01 §5a) — a build never cares
  -- which. Two schemas are in play and both are honoured: the shipped data carries a `Bonuses`
  -- table (`from = {{set=,pieces=},{soul=}}`, the shape tests/fake_state.lua walks), while docs/01 §5
  -- and the gear-matrix fixtures put a `bonus` key on each set threshold. Supporting only one would
  -- make the other resolve to false silently.
  function S:bonus(bonusKey)
    local def = bonusDefs and bonusDefs[bonusKey]
    if def and def.from then
      for _, src in ipairs(def.from) do
        if src.set and src.pieces and S:setCount(src.set) >= src.pieces then return true end
        if src.soul and wearingSoul(src.soul) then return true end
      end
    end

    for setKey, set in pairs(sets) do
      for threshold, bonus in pairs(set.bonuses or {}) do
        if bonus.bonus == bonusKey and S:setCount(setKey) >= threshold then return true end
      end
    end

    for soulKey, soul in pairs(souls) do
      for _, granted in ipairs((type(soul) == "table" and soul.grants) or {}) do
        if granted == bonusKey and wearingSoul(soulKey) then return true end
      end
    end

    return false
  end

  function S:itemCooldown(slot)
    local start, duration = GetInventoryItemCooldown("player", slot)
    if not duration or duration <= 0 then return 0 end
    local remaining = (start + duration) - GetTime()
    return remaining > 0 and remaining or 0
  end

  function S:itemUsable(slot)
    local id = GetInventoryItemID("player", slot)
    if not id then return false end
    return IsUsableItem(id) == true
  end

  -- Which seal is currently up, as a symbolic key. Class-specific, so it is guarded by the `seal`
  -- capability flag (docs/01 §2).
  local function activeSeal()
    for key, record in pairs(spells) do
      if type(record) == "table" and record.seal then
        if findAura("player", key, "HELPFUL") then return key end
      end
    end
    return nil
  end

  -- Remembers the seal that was active last time anyone looked, and when it stopped being active, so
  -- `sealLinger()` can name the OUTGOING seal. Updated from both accessors, because a twist build
  -- reads `seal` on essentially every tick and there is no separate event that means "a seal was
  -- replaced" — UNIT_AURA fires for everything.
  --
  -- Resolution is therefore bounded by how often the state is read (the display ticks at 10 Hz).
  -- That is finer than any plausible linger window, but it is a real limit and not a hidden one:
  -- a build that never evaluates a seal condition gets a memo that only updates when it asks.
  local sealMemo = { key = nil, previous = nil, changedAt = nil }

  local function pollSeal(now)
    local current = activeSeal()
    if current ~= sealMemo.key then
      -- Only a REPLACEMENT lingers. A seal falling off with nothing taking its place is an expiry,
      -- and docs/02 is explicit that expiry is not a twist.
      sealMemo.previous = (sealMemo.key ~= nil and current ~= nil) and sealMemo.key or nil
      sealMemo.changedAt = sealMemo.previous and now or nil
      sealMemo.key = current
    end
    return sealMemo
  end

  function S:seal()
    return pollSeal(GetTime()).key
  end

  function S:level() return UnitLevel("player") or 0 end

  -- Is the spell in the spellbook at all? Deliberately NOT `usable`, which is IsUsableSpell and
  -- reads false when you are merely out of mana. Returns nil rather than false when the client
  -- will not answer, so "cannot tell" stays distinguishable from "not learned".
  function S:known(spellKey)
    local id = resolve(spellKey)
    if not (id and IsPlayerSpell) then return nil end
    local ok, known = pcall(IsPlayerSpell, id)
    if not ok then return nil end
    return known == true
  end

  -- Matches the ABILITY ids the client reports in learnedAbilitySpellIDs. Storing a teach-spell id
  -- here compares false against every slot and reports "not engraved" for a rune the player is
  -- wearing, with no error anywhere — the bug that shipped (docs/07 §9.12).
  function S:rune(runeKey)
    if not (C_Engraving and C_Engraving.GetRuneForEquipmentSlot) then return false end
    local id = resolve(runeKey)
    if not id then return false end
    for _, slot in ipairs(RUNE_SLOTS) do
      local rune = C_Engraving.GetRuneForEquipmentSlot(slot)
      for _, learned in ipairs((rune and rune.learnedAbilitySpellIDs) or {}) do
        if learned == id then return true end
      end
    end
    return false
  end

  -- Seconds to the next main-hand swing, latency-compensated, or nil when unknown. All the judgement
  -- about what "unknown" means lives in Adapters/Swing.lua; this is the seam Core sees.
  function S:swingRemaining()
    if not ns.Swing then return nil end
    return ns.Swing.remaining(GetTime(), S:latency())
  end

  -- docs/02: the OUTGOING seal, while it can still proc — not the active one, and never a seal that
  -- merely expired. The window length is a flavor constant the DATA PACK supplies with a `-- src:`
  -- line; with no sourced value there is no window, so this answers nil and every `seal_linger`
  -- condition reads false. That is deliberate: a guessed timing constant would silently mis-time
  -- every twist, and hard rule 2's reasoning applies to server-side timings as much as to ids.
  function S:sealLinger()
    local window = tonumber(sealLingerWindow)
    if not (window and window > 0) then return nil end
    local memo = pollSeal(GetTime())
    if not (memo.previous and memo.changedAt) then return nil end
    if GetTime() - memo.changedAt > window then return nil end
    return memo.previous
  end

  function S:ttd() return nil end
  function S:enemies() return 1 end
  function S:mode() return "Single" end

  -- Round-trip to the world server, in ms. Used as the reaction lead on swing timing: the player
  -- needs to know when to PRESS, which is earlier than when the server swings. GetNetStats is
  -- refreshed by the client every ~30s, so this is cheap to call per read.
  function S:latency()
    if not GetNetStats then return 0 end
    local ok, _, _, _, world = pcall(GetNetStats)
    return (ok and tonumber(world)) or 0
  end

  return S
end

-- Rebuilt whenever the registered pack changes; Core reaches it through Elmira.API.GetState().
function Vanilla.attachPack(pack)
  pack = pack or {}
  -- `sealLingerWindow` is optional and usually absent: it is a sourced server-side timing constant,
  -- and a pack that has not sourced one leaves seal twisting inert rather than mis-timed.
  Vanilla.state = Vanilla.newState(pack.spells, pack.sets, pack.souls, pack.bonuses,
                                   pack.sealLingerWindow)
  return Vanilla.state
end

function Vanilla.describe()
  local d = Vanilla.detect()
  return {
    project = d.project,
    version = string.format("%s/%s", d.build or "?", d.revision or "?"),
    interface = d.interface,
    caps = Vanilla.capabilities(),
    state = Vanilla.state and "live" or "null (no data pack)",
  }
end

Vanilla.GCD_CEILING = GCD_CEILING
Vanilla.state = ns.Interface and ns.Interface.newNullState() or nil
ns.Adapter = Vanilla
return Vanilla
