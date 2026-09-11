-- Elmira/Adapters/Interface.lua — the State contract (docs/01-ARCHITECTURE.md §2) + capability
-- flags. Names no WoW global: it is a contract declaration and a null implementation, not an
-- adapter. It lives in Adapters/ by ownership (this is what every adapter must implement), and
-- stays dofile-able so the contract can be tested headlessly against tests/fake_state.lua.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Interface = {}

-- The same MEMBERS as docs/01 §2, which is what interface_spec.lua enforces — not the same order.
-- The grouping below is chronological (original set, then M1's level/rune/sealLinger, then M2's
-- gcdDuration and baseCooldown/powerCost) because each block carries the comment explaining why it
-- was added; docs/01 §2 groups by topic instead, so `gcdDuration` sits next to `gcd` there. This
-- comment used to claim "verbatim, in order", which was false and invited someone to trust the order
-- as meaningful. A literal list here still means doc/code drift in MEMBERSHIP fails a test rather
-- than rotting silently.
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
  -- Added at M2 after the acceptance run: Simulation stepped the virtual clock by `gcd()`, but that
  -- is the REMAINING gcd and reads 0 whenever you are not mid-global — so the clock never advanced
  -- and every queue slot came back at t=0. `gcdDuration` is how long a GCD lasts; `gcd` is how much
  -- of one is left. Conflating them is invisible in tests that hand-set a nonzero `gcd`.
  "gcdDuration",
  -- Also M1: the client knows a spell's real cooldown and cost better than any shipped table can,
  -- because both track the rank the character actually has and neither goes stale on a tuning pass.
  -- GetSpellPowerCost delivers on that and tracks runes (345 -> 69 measured). GetSpellBaseCooldown
  -- does NOT: it returned 15000 in all three gear states while Exorcism's real cooldown was 6.0 s,
  -- so baseCooldown is fed by observing GetSpellCooldown and caching (docs/07 §9.1, §9.4). No
  -- static fallback is safe, and a reading taken during the GCD must never be cached as a duration.
  "baseCooldown", "powerCost",
  -- Added at M5g. "Do you know this spell at all" is a different question from `usable`, which is
  -- IsUsableSpell and answers false when you are merely out of mana or out of range -- its SECOND
  -- return (PE9-D2) says which of those two it was: true means the resource half. Core/Engine
  -- skips an unknown ability silently and correctly (ADR-0006 rule 5); Core/Gates has to be able to
  -- SAY so, which nothing on the contract could.
  "known",
  -- Added at PE9 (D6). `targetExists` is UnitExists and says nothing about hostility, so the
  -- "in combat, or when you have a target" visibility mode showed the strip for a bank NPC.
  -- Separate member rather than a stricter `targetExists`, because the Rotation panel's context
  -- line legitimately wants the loose reading ("target: yes").
  "targetAttackable",
}

-- docs/01 §2: class-specific accessors are optional members guarded by a capability flag, so Core
-- can ask before calling rather than relying on a nil return. `seal` is the paladin case.
-- `addonMemory` is a DIAGNOSTIC capability rather than a State one: nothing in the rotation depends
-- on it, but `/elm debug perf` must be able to say "this client will not tell me" instead of falling
-- back to the whole-heap figure and calling it Elmira's.
-- `chatMessageGroups` is a PRESENTATION capability, declared for the same reason: Display/Announcers
-- reaches for a FrameXML helper that this client does not ship, and a fallback nobody has declared
-- is indistinguishable from a fallback nobody noticed.
--
-- `spellNameLookup` is R2's (Core/Spells.lua, D53/D54c): whether this client can resolve a spell ID
-- from a NAME at all. `GetSpellInfo(id)` is already relied on elsewhere with no flag, but calling it
-- with a STRING is a genuinely different capability -- the cheat sheet's own deprecation note says
-- the retail replacement, `C_Spell.GetSpellInfo`, takes an id only, so "resolve by name" is a real
-- axis a future adapter can answer false on even though this one answers true.
--
-- `addonLoaded` is AT4-D2's: whether this client will say if ANOTHER addon is loaded. The texture
-- library lists WeakAuras' and PowerAuras' files by path on a character that has WeakAuras, and
-- lists neither on one that does not -- so "we cannot ask" has to read as "do not offer them"
-- rather than as an error out of the picker.
Interface.CAPABILITIES = { "runes", "setAPI", "swing", "inspect", "nameplates", "engraving", "seal",
                           "addonMemory", "chatMessageGroups", "spellNameLookup", "addonLoaded" }

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
    gcdDuration = function() return 0 end,
    cooldown = function() return 0 end,
    -- Two returns since PE9-D2: "can I cast this" and "is the reason a RESOURCE one". The second is
    -- false here rather than nil for the same reason the strip only dims on it -- "this client has
    -- not told me you are out of mana" must never be drawn as "you are out of mana".
    usable = function() return false, false end,
    -- nil, not false: "this client cannot tell me" is not "you have not learned it", and Gates
    -- would dim every row in the build on the strength of the difference.
    known = function() return nil end,
    castTime = function() return 0 end,
    buff = function() return nil end,
    debuff = function() return nil end,
    power = function() return 0, 0 end,
    targetType = function() return nil end,
    targetHPPct = function() return nil end,
    targetExists = function() return false end,
    targetAttackable = function() return false end,
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
