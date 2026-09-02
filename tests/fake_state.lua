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
  s.souls = t.souls or {}; s.bonuses = t.bonuses or {}; s._swing = t.swing; s._ttd = t.ttd; s._enemies = t.enemies or 1; s._mode = t.mode or "Single"
  s.setDefs = t.setDefs; s.bonusDefs = t.bonusDefs  -- optional: resolve bonus() from sets/souls like the adapter does
  s.enchants = t.enchants or {}   -- was read by :enchant() but never populated here, so it always returned nil
  s.castTimes = t.castTime or {}  -- key -> seconds; absent = instant. Simulation steps max(gcd, castTime)
  s._level = t.level or 60
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
function FakeState:usable(key) return self.usableSet == nil or self.usableSet[key] ~= false end
function FakeState:castTime(key) return self.castTimes[key] or 0 end
function FakeState:buff(key) local b = self.buffs[key]; if b then return b.stacks or 1, b.remaining or 10 end end
function FakeState:debuff(key, mine) local d = self.debuffs[key]; if d and (not mine or d.mine) then return d.stacks or 1, d.remaining or 10 end end
function FakeState:power(kind) local p = self.powers[kind] or {0,0}; return p[1], p[2] end
function FakeState:targetType() return self._targetType end
function FakeState:targetHPPct() return 100 end
function FakeState:targetExists() return true end
function FakeState:inCombat() return true end
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
