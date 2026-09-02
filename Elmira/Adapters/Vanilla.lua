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
local RUNE_SLOTS = { 1, 5, 6, 7, 8, 9, 10 }

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
    swing = false,             -- Adapters/Swing.lua, M3b
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

function Vanilla.playerClass()
  local _, class = UnitClass("player")
  return class
end

function Vanilla.loadClassPack(class)
  if not (class and C_AddOns and C_AddOns.GetNumAddOns) then return false end
  for i = 1, C_AddOns.GetNumAddOns() do
    local name = C_AddOns.GetAddOnInfo(i)
    if C_AddOns.GetAddOnMetadata(name, "X-Elmira-Class") == class then
      return C_AddOns.LoadAddOn(name)
    end
  end
  return false
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
  local lines = {}
  for i = 1, scanTooltip:NumLines() do
    local fs = _G[SCAN_NAME .. "TextLeft" .. i]
    local text = fs and fs:GetText()
    if text and text ~= "" then lines[#lines + 1] = text end
  end
  return lines
end

-- Builds a fresh State over a data pack. Returning a new table rather than mutating a singleton
-- keeps specs independent and means a profile/class switch cannot leave stale cached ids behind.
function Vanilla.newState(spells, sets, souls, bonusDefs)
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

  function S:inCombat() return InCombatLockdown() == true end
  function S:moving() return (GetUnitSpeed("player") or 0) > 0 end

  -- Takes a SLOT and returns a table, matching Schema.lua's `C.weapon`: it calls state:weapon(slot)
  -- with 16 for 2H/1H and 17 for Shield, then reads `w.type` and `w.speed`.
  --
  -- KNOWN GAP: `speed` is UnitAttackSpeed, which is HASTE-MODIFIED. docs/01 wants the base
  -- ITEM speed for build selection, and the two diverge under haste — a hasted 3.6 weapon can read
  -- under a build's `maxSpeed = 3.0` and wrongly qualify. Classic exposes base speed only via the
  -- item tooltip ("Speed 3.60"), the same scan souls use; wiring that is deliberately not done here
  -- so the gap stays visible rather than being papered over with a number that looks right.
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
    return { type = kind, itemID = id, speed = (slot == 17 and off) or main }
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
  function S:seal()
    for key, record in pairs(spells) do
      if type(record) == "table" and record.seal then
        if findAura("player", key, "HELPFUL") then return key end
      end
    end
    return nil
  end

  function S:level() return UnitLevel("player") or 0 end

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

  -- M3b (Adapters/Swing.lua). Documented safe zeros until then, so a condition reads false rather
  -- than erroring.
  function S:sealLinger() return nil end
  function S:swingRemaining() return nil end
  function S:ttd() return nil end
  function S:enemies() return 1 end
  function S:mode() return "Single" end
  function S:latency() return 0 end

  return S
end

-- Rebuilt whenever the registered pack changes; Core reaches it through Elmira.API.GetState().
function Vanilla.attachPack(pack)
  pack = pack or {}
  Vanilla.state = Vanilla.newState(pack.spells, pack.sets, pack.souls, pack.bonuses)
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
