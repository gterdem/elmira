-- Minimal State implementation for headless Core tests (no WoW API).
local FakeState = {}
FakeState.__index = FakeState
function FakeState.new(t)
  local s = setmetatable({}, FakeState)
  s._now = t.now or 0; s._gcd = t.gcd or 0
  s.cooldowns = t.cooldowns or {}; s.buffs = t.buffs or {}; s.debuffs = t.debuffs or {}
  s.powers = t.power or { MANA = {1000, 1000} }; s._targetType = t.targetType; s._moving = t.moving or false
  s.weapons = t.weapon or {}; s.sets = t.sets or {}; s.items = t.items or {}; s._seal = t.seal
  s.usableSet = t.usable  -- nil = everything usable
  s.souls = t.souls or {}; s.bonuses = t.bonuses or {}; s._swing = t.swing; s._ttd = t.ttd; s._enemies = t.enemies or 1; s._mode = t.mode or "Single"
  s.setDefs = t.setDefs; s.bonusDefs = t.bonusDefs  -- optional: resolve bonus() from sets/souls like the adapter does
  return s
end
function FakeState:now() return self._now end
function FakeState:gcd() return self._gcd end
function FakeState:cooldown(key) return self.cooldowns[key] or 0 end
function FakeState:usable(key) return self.usableSet == nil or self.usableSet[key] ~= false end
function FakeState:castTime(key) return 0 end
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
function FakeState:enchant(slot) return self.enchants and self.enchants[slot] end
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
return FakeState
