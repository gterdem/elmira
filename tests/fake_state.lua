-- Minimal State implementation for headless Core tests (no WoW API).
local FakeState = {}
FakeState.__index = FakeState
function FakeState.new(t)
  local s = setmetatable({}, FakeState)
  s._now = t.now or 0; s._gcd = t.gcd or 0
  -- Defaults to a real 1.5s global unless a scenario overrides it: a duration of 0 means the queue
  -- cannot advance, which is a client impossibility and only ever masks bugs.
  s._gcdDuration = t.gcdDuration or 1.5
  s.cooldowns = t.cooldowns or {}; s.buffs = t.buffs or {}; s.debuffs = t.debuffs or {}
  s.powers = t.power or { MANA = {1000, 1000} }; s._targetType = t.targetType; s._moving = t.moving or false
  s.weapons = t.weapon or {}; s.sets = t.sets or {}; s.items = t.items or {}; s._seal = t.seal
  s.usableSet = t.usable  -- nil = everything usable
  -- PE9-D2: which keys are unusable for a RESOURCE reason, the second value IsUsableSpell returns.
  -- Separate from `usable` because the strip must tell "no mana" from "out of range" and treat only
  -- the first as something to dim.
  s.noResourceSet = t.noResource or {}
  s.knownSet = t.known    -- nil = everything known
  s.souls = t.souls or {}; s.bonuses = t.bonuses or {}; s._swing = t.swing; s._ttd = t.ttd; s._enemies = t.enemies or 1; s._mode = t.mode or "Single"; s._inCombat = t.inCombat  -- nil = in combat (the default); false = out of combat
  s.setDefs = t.setDefs; s.bonusDefs = t.bonusDefs  -- optional: resolve bonus() from sets/souls like the adapter does
  s.enchants = t.enchants or {}   -- was read by :enchant() but never populated here, so it always returned nil
  s.castTimes = t.castTime or {}  -- key -> seconds; absent = instant. Simulation steps max(gcd, castTime)
  s._level = t.level or 60
  s._targetHp = t.targetHp        -- nil = 100% (no execute range); a number = that percentage
  s._targetAttackable = t.targetAttackable  -- nil = yes; false = a target you cannot fight
  s.runes = t.runes or {}         -- engraved rune keys, as a set: { RUNE_ART_OF_WAR = true }
  s._sealLinger = t.sealLinger    -- seal key still inside its linger window, or nil
  s.baseCooldowns = t.baseCooldown or {}  -- key -> full cooldown seconds (what GetSpellBaseCooldown gives)
  s.powerCosts = t.powerCost or {}        -- key -> amount, or {amount, kind}; kind defaults to MANA
  s._powerKind = t.powerKind or "MANA"
  return s
end
function FakeState:now() return self._now end
function FakeState:gcd() return self._gcd end
function FakeState:gcdDuration() return self._gcdDuration end
function FakeState:cooldown(key) return self.cooldowns[key] or 0 end
function FakeState:usable(key)
  local ok = self.usableSet == nil or self.usableSet[key] ~= false
  return ok, self.noResourceSet[key] == true
end
function FakeState:known(key) return self.knownSet == nil or self.knownSet[key] ~= false end
function FakeState:castTime(key) return self.castTimes[key] or 0 end
-- Three returns, like Adapters/Vanilla's own `findAura`: stacks, seconds LEFT, and how long the
-- aura lasts in total. The third was missing here while the adapter has always returned it, so
-- anything reading it (Display's "used -- 10s", AB4-D1's buff-remaining fill) saw nil in every
-- headless test and a real number in game -- the shape of drift this file exists to prevent.
-- `duration` defaults to whatever is left, so an unstated scenario reads as "it has just been cast".
function FakeState:buff(key)
  local b = self.buffs[key]
  if not b then return nil end
  local remaining = b.remaining or 10
  return b.stacks or 1, remaining, b.duration or remaining
end
-- Three returns, matching `buff` above and Adapters/Vanilla's one `findAura` behind both.
function FakeState:debuff(key, mine)
  local d = self.debuffs[key]
  if not (d and (not mine or d.mine)) then return nil end
  local remaining = d.remaining or 10
  return d.stacks or 1, remaining, d.duration or remaining
end
function FakeState:power(kind) local p = self.powers[kind] or {0,0}; return p[1], p[2] end
function FakeState:targetType() return self._targetType end
function FakeState:targetHPPct() return self._targetHp or 100 end  -- `targetHp = 15` puts the target in execute range
function FakeState:targetExists() return true end
-- PE9-D6. Defaults to true, matching targetExists above: a scenario that says nothing about the
-- target means "there is one and it is a mob", which is what every rotation fixture assumes.
function FakeState:targetAttackable() return self._targetAttackable ~= false end
function FakeState:inCombat() if self._inCombat == nil then return true end return self._inCombat end
function FakeState:moving() return self._moving end
function FakeState:weapon(slot) return self.weapons[slot] end
function FakeState:setCount(key) return self.sets[key] or 0 end
function FakeState:itemCooldown(slot) return (self.items[slot] and self.items[slot].cooldown) or 0 end
function FakeState:itemUsable(slot) return self.items[slot] ~= nil end
function FakeState:seal() return self._seal end
function FakeState:enchant(slot) return self.enchants[slot] end
function FakeState:bonus(key)
  if self.bonuses[key] ~= nil then return self.bonuses[key] end
  local def = self.bonusDefs and self.bonusDefs[key]; if not def then return false end
  for _, src in ipairs(def.from) do
    if src.set and (self.sets[src.set] or 0) >= src.pieces then return true end
    if src.soul then for _, have in ipairs(self.souls) do if have == src.soul then return true end end end
  end
  return false
end
function FakeState:swingRemaining() return self._swing end
function FakeState:ttd() return self._ttd end
function FakeState:enemies() return self._enemies end
function FakeState:mode() return self._mode end
function FakeState:latency() return 50 end
function FakeState:level() return self._level end
function FakeState:rune(key) return self.runes[key] == true end
function FakeState:sealLinger() return self._sealLinger end
function FakeState:baseCooldown(key) return self.baseCooldowns[key] or 0 end
function FakeState:powerCost(key)
  local c = self.powerCosts[key]
  if c == nil then return 0, nil end
  if type(c) == "table" then return c[1], c[2] or self._powerKind end
  return c, self._powerKind
end
return FakeState
