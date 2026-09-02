-- Elmira/Adapters/Interface.lua — the State contract (docs/01-ARCHITECTURE.md §2) + capability
-- flags. Names no WoW global: it is a contract declaration and a null implementation, not an
-- adapter. It lives in Adapters/ by ownership (this is what every adapter must implement), and
-- stays dofile-able so the contract can be tested headlessly against tests/fake_state.lua.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Interface = {}

-- Verbatim from docs/01 §2, in order. A literal list here means a doc/code drift fails a test
-- instead of rotting silently (see tests/spec/interface_spec.lua).
Interface.CONTRACT = {
  "now", "gcd", "cooldown", "usable", "castTime", "buff", "debuff", "power",
  "targetType", "targetHPPct", "targetExists", "inCombat", "moving", "weapon", "setCount",
  "enchant", "bonus", "itemCooldown", "itemUsable", "seal", "swingRemaining", "ttd",
  "enemies", "mode", "latency",
  -- Added at M1: docs/02-CONDITION-SCHEMA.md lists `level`, `rune`/`no_rune` and `seal_linger` as v1
  -- condition types, but nothing in the contract could answer them. Adapters fill these in later
  -- (runes M2, sealLinger M3b); until then newNullState()'s safe zeros mean such a condition reads
  -- false rather than erroring.
  "level", "rune", "sealLinger",
  -- Also M1: the client knows a spell's real cooldown and cost better than any shipped table can,
  -- because both track the rank the character actually has and neither goes stale on a tuning pass.
  -- GetSpellPowerCost delivers on that and tracks runes (345 -> 69 measured). GetSpellBaseCooldown
  -- does NOT: it returned 15000 in all three gear states while Exorcism's real cooldown was 6.0 s,
  -- so baseCooldown is fed by observing GetSpellCooldown and caching (docs/07 §9.1, §9.4). No
  -- static fallback is safe, and a reading taken during the GCD must never be cached as a duration.
  "baseCooldown", "powerCost",
}

-- docs/01 §2: class-specific accessors are optional members guarded by a capability flag, so Core
-- can ask before calling rather than relying on a nil return. `seal` is the paladin case.
Interface.CAPABILITIES = { "runes", "setAPI", "swing", "inspect", "nameplates", "engraving", "seal" }

-- Checks that `state` implements every contract member as a callable. Both dot-style
-- (state.now(state)) and colon-style (state:now()) implementations satisfy this, since both put a
-- function at state[member].
function Interface.validate(state)
  local missing = {}
  if type(state) ~= "table" then
    for _, member in ipairs(Interface.CONTRACT) do missing[#missing + 1] = member end
    return false, missing
  end
  for _, member in ipairs(Interface.CONTRACT) do
    if type(state[member]) ~= "function" then
      missing[#missing + 1] = member
    end
  end
  return #missing == 0, missing
end

-- Every member a no-op with a documented safe zero. This is what API.GetState() returns before an
-- adapter is loaded (or before M1's Engine gives it something to compute), so a module calling
-- GetState() at M0 gets a contract-shaped object, never nil.
function Interface.newNullState()
  return {
    now = function() return 0 end,
    gcd = function() return 0 end,
    cooldown = function() return 0 end,
    usable = function() return false end,
    castTime = function() return 0 end,
    buff = function() return nil end,
    debuff = function() return nil end,
    power = function() return 0, 0 end,
    targetType = function() return nil end,
    targetHPPct = function() return nil end,
    targetExists = function() return false end,
    inCombat = function() return false end,
    moving = function() return false end,
    weapon = function() return nil end,
    setCount = function() return 0 end,
    enchant = function() return nil end,
    bonus = function() return false end,
    itemCooldown = function() return 0 end,
    itemUsable = function() return false end,
    seal = function() return nil end,
    swingRemaining = function() return nil end,
    ttd = function() return nil end,
    enemies = function() return 1 end,
    mode = function() return "Single" end,
    latency = function() return 0 end,
    level = function() return 0 end,
    rune = function() return false end,
    sealLinger = function() return nil end,
    baseCooldown = function() return 0 end,
    powerCost = function() return 0, nil end,
  }
end

ns.Interface = Interface
return Interface
