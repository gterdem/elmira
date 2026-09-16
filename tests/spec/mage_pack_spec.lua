-- tests/spec/mage_pack_spec.lua — structural pins for Elmira/Classes/Mage.lua data that no build
-- entry, no `requires`/`advice` list and no gear scenario reads (MG1-D7/D8).
--
-- Every generic data_sourcing_spec.lua check and every gear_matrix_spec.lua scenario walks whatever
-- IS in a table — deleting a whole record (a whole physical line, which is exactly what `make
-- mutants` tries) just makes those loops iterate one fewer time, and nothing notices. That is true
-- of Paladin.lua too (a `make mutants FILES=Elmira/Classes/Paladin.lua` sweep finds the same shape of
-- survivor in its own Sets/Souls/Catalog tables), it is simply never in a DIFF against a stable HEAD,
-- so nothing has had to fix it there. Mage.lua is a brand-new file — every line of it is a mutation
-- target on the very first `make mutants` run — so the records nothing else reaches are pinned here
-- directly, mirroring the pattern palette_spec.lua's "against the shipped Paladin pack" block already
-- uses for exactly this purpose.
local helper = require("tests.helper")

describe("Elmira/Classes/Mage.lua — structural pins (MG1-D8)", function()
  local pack, Palette

  before_each(function()
    helper.reset()
    Palette = helper.load("Elmira/Core/Palette.lua")
    pack = helper.classPack("Mage")
  end)

  -- The pack's identity fields and top-level tables (data_sourcing_spec.lua's equivalent checks are
  -- Paladin-only: `pack` there is always `helper.classPack("Paladin")`), so nothing else reads
  -- Mage's own `class`/`flavor`/`builds`/`catalog`/`advice`/`catalogVersion` wiring at all.
  it("carries the identity fields and top-level tables Core registers the pack under", function()
    assert.equal("MAGE", pack.class)
    assert.equal("SoD", pack.flavor)
    assert.is_table(pack.builds)
    assert.is_table(pack.catalog)
    assert.is_table(pack.advice)
    assert.is_table(pack.sets)
    assert.is_table(pack.souls)
    assert.is_table(pack.bonuses)
    assert.is_number(pack.catalogVersion)
    assert.equal(pack.catalog.version, pack.catalogVersion)
    assert.equal("SoD", pack.catalog.flavor)
    assert.equal("P8", pack.catalog.phase)
  end)

  -- palette_spec.lua's own pattern, against Mage.lua instead of Paladin.lua: a record added here
  -- without a classification (or removed outright) breaks THIS suite rather than the panel — and an
  -- exact list on both sides is what makes a record deleted outright visible too (the two lists
  -- between them cover every key in `D.Spells`).
  describe("against the shipped Mage pack", function()
    local CASTABLE = {
      "ARCANE_EXPLOSION", "BALEFIRE_BOLT", "BLAST_WAVE", "BLIZZARD", "COLD_SNAP", "COMBUSTION",
      "CONE_OF_COLD", "DEEP_FREEZE", "FIREBALL", "FIRE_BLAST", "FLAMESTRIKE", "FROSTBOLT",
      "FROSTFIRE_BOLT", "FROST_NOVA", "FROZEN_ORB", "ICE_BARRIER", "ICE_LANCE", "ICY_VEINS",
      "LIVING_BOMB", "LIVING_FLAME", "MANA_SHIELD", "MOLTEN_ARMOR", "PYROBLAST", "SCORCH",
      "SPELLFROST_BOLT",
      -- MG2: the Arcane healer's own castables.
      "ARCANE_MISSILES", "ARCANE_BLAST", "ARCANE_BARRAGE", "REGENERATION", "MASS_REGENERATION",
      "CHRONOSTATIC_PRESERVATION", "REWIND_TIME", "PRESENCE_OF_MIND", "ARCANE_POWER", "EVOCATION",
    }

    it("offers exactly the abilities a mage can press", function()
      local got = {}
      for _, row in ipairs(Palette.spells(pack, {})) do got[#got + 1] = row.key end
      table.sort(got)
      local want = {}
      for _, k in ipairs(CASTABLE) do want[#want + 1] = k end
      table.sort(want)
      assert.same(want, got)
    end)

    -- Every other key in `D.Spells` — runes, procs, debuffs — named individually so a deletion (or
    -- an addition the CASTABLE list above does not also gain) is caught, the same way Paladin's own
    -- palette_spec.lua block names its aura/rune keys rather than only counting them.
    local NON_CASTABLE = {
      "RUNE_HOT_STREAK", "RUNE_OVERHEAT", "RUNE_ENLIGHTENMENT", "RUNE_FINGERS_OF_FROST",
      "RUNE_BRAIN_FREEZE", "RUNE_SPELL_POWER", "RUNE_FIRE_SPECIALIZATION", "RUNE_FROST_SPECIALIZATION",
      "RUNE_LIVING_BOMB", "RUNE_FROSTFIRE_BOLT", "RUNE_BALEFIRE_BOLT", "RUNE_ICY_VEINS",
      "RUNE_DEEP_FREEZE", "RUNE_FROZEN_ORB", "RUNE_ICE_LANCE", "RUNE_SPELLFROST_BOLT",
      "RUNE_LIVING_FLAME", "RUNE_MOLTEN_ARMOR",
      "HOT_STREAK_BUFF", "FINGERS_OF_FROST_BUFF", "BRAIN_FREEZE_BUFF", "FIRE_VULNERABILITY",
      "GLACIATE", "ENIGMA_FIRE_CRIT_BUFF",
      -- MG2: the Arcane healer's own rune twins and auras.
      "RUNE_ARCANE_BLAST", "RUNE_MISSILE_BARRAGE", "RUNE_MASS_REGENERATION",
      "RUNE_CHRONOSTATIC_PRESERVATION", "RUNE_REWIND_TIME", "RUNE_ARCANE_BARRAGE",
      "RUNE_ADVANCED_WARDING", "RUNE_ARCANE_SPECIALIZATION",
      "ARCANE_BLAST_BUFF", "MISSILE_BARRAGE_BUFF", "ARCANE_TUNNELING",
    }

    it("offers no aura, debuff, passive or rune record — named individually", function()
      local offered = {}
      for _, row in ipairs(Palette.spells(pack, {})) do offered[row.key] = true end
      for _, key in ipairs(NON_CASTABLE) do
        assert.is_truthy(pack.spells[key], key .. " is gone from the pack; a build or `requires`/`advice` list names it")
        assert.is_nil(offered[key], key .. " can never be pressed, so it must not be offered")
      end
    end)

    it("names every D.Spells key exactly once between the two lists above", function()
      local seen = {}
      for _, k in ipairs(CASTABLE) do seen[k] = (seen[k] or 0) + 1 end
      for _, k in ipairs(NON_CASTABLE) do seen[k] = (seen[k] or 0) + 1 end
      local problems = {}
      for key in pairs(pack.spells) do
        if seen[key] == nil then problems[#problems + 1] = key .. ": in the pack but in neither list" end
      end
      for key, count in pairs(seen) do
        if count > 1 then problems[#problems + 1] = key .. ": listed twice" end
        if pack.spells[key] == nil then problems[#problems + 1] = key .. ": listed but not in the pack" end
      end
      table.sort(problems)
      assert.same({}, problems)
    end)
  end)

  -- BRAIN_FREEZE_BUFF and GLACIATE (MG1-D2) are shipped ahead of any build gating on them (no
  -- shipped entry reads either `{"buff",...}` — the AoE-only Brain Freeze rune and the shatter-combo
  -- Glaciate stack count are both future-build material per the dossier). The two lists above already
  -- protect them from outright deletion; this pins the actual VALUES so a future edit cannot silently
  -- swap one id for the other's.
  it("pins the two auras no build reads yet", function()
    assert.equal(400730, pack.spells.BRAIN_FREEZE_BUFF.id)
    assert.is_true(pack.spells.BRAIN_FREEZE_BUFF.proc)
    assert.equal(1218345, pack.spells.GLACIATE.id)
  end)

  -- MG3: `findAura` (Adapters/Vanilla.lua) matches by exact spell id, so these two records are only
  -- as good as the id inside them — a future research paste (or a careless merge) reintroducing the
  -- rune/ActionID confusion this fix corrected would compile and pass every gear-matrix scenario
  -- (those drive Hot Streak/FoF by KEY, never by id) while silently never firing again in game.
  it("pins Hot Streak's proc buff to its own client-verified id, not the rune or the WoWSims ActionID", function()
    assert.equal(400625, pack.spells.HOT_STREAK_BUFF.id,
      "client-verified 2026-09-14; 48108 is the WoWSims ActionID and 400624 the passive rune, neither ever appears on the player")
    assert.is_true(pack.spells.HOT_STREAK_BUFF.proc)
    assert.is_nil(pack.spells.HOT_STREAK_BUFF.verify, "client-verified — must not read as provisional")
    assert.equal(
      "client-verified 2026-09-14 (/dump on a level 45 Mage); 48108 is the WoWSims ActionID and " ..
        "never appears on the player; 400624 is the passive rune",
      pack.spells.HOT_STREAK_BUFF.note)
  end)

  it("pins Fingers of Frost's proc buff to its own id, not the passive rune", function()
    assert.equal(400669, pack.spells.FINGERS_OF_FROST_BUFF.id,
      "400647 is the passive rune (Proc Trigger Spell) and was never the buff the client applies")
    assert.is_true(pack.spells.FINGERS_OF_FROST_BUFF.proc)
    assert.equal("in-game", pack.spells.FINGERS_OF_FROST_BUFF.verify)
    assert.equal(
      "FoF's own proc buff; 400647 is the passive rune (Proc Trigger Spell), " ..
        "400670 the 1-charge dummy twin, 401741 the teach spell",
      pack.spells.FINGERS_OF_FROST_BUFF.note)
    -- The rune record itself is untouched by this fix: its id IS its own passive spell.
    assert.equal(400647, pack.spells.RUNE_FINGERS_OF_FROST.id)
  end)

  -- D.Sets: item lists are read only by the REAL Vanilla adapter's setCount() (item ids on the
  -- equipped character), never by FakeState (gear_matrix scenarios set `sets = { KEY = count }`
  -- directly) — so nothing exercises `.items` at all otherwise, exactly the shape DP2's Paladin sweep
  -- found on its own Sets tables.
  describe("D.Sets item lists and identity", function()
    it("Fireleaf Regalia: name, src and all eight piece ids", function()
      local set = pack.sets.MAGE_FIRELEAF_REGALIA
      assert.equal("Fireleaf Regalia", set.name)
      assert.equal("https://www.wowhead.com/classic/item-set=1943/fireleaf-regalia", set.src)
      assert.same({ 240056, 240054, 240053, 240055, 240058, 240052, 240057, 240059 }, set.items)
    end)

    it("Enigma Insight: name, src and all five piece ids", function()
      local set = pack.sets.MAGE_ENIGMA_INSIGHT
      assert.equal("Enigma Insight", set.name)
      assert.equal("https://www.wowhead.com/classic/item-set=1841/enigma-insight", set.src)
      assert.same({ 233404, 233403, 233406, 233405, 233402 }, set.items)
    end)

    -- The three Fireleaf thresholds and Enigma's own two are ALSO exercised through
    -- gear_matrix_spec.lua's `fireleaf_6pc_bonuses_resolve`/`fireleaf_below_threshold_bonuses_absent`
    -- scenarios (D.Bonuses' `.from` links) and the aura-dangling check (Enigma [2]'s `.aura` field)
    -- — this pins the threshold SPELL ids directly, which neither of those reaches.
    it("Fireleaf Regalia thresholds carry their sourced bonus spell ids", function()
      local bonuses = pack.sets.MAGE_FIRELEAF_REGALIA.bonuses
      assert.equal(1226423, bonuses[2].spell)
      assert.equal("passive", bonuses[2].kind)
      assert.equal(1226446, bonuses[4].spell)
      assert.equal("passive", bonuses[4].kind)
      assert.equal(1226432, bonuses[6].spell)
      assert.equal("passive", bonuses[6].kind)
    end)

    it("Enigma Insight thresholds carry their sourced bonus spell ids", function()
      local bonuses = pack.sets.MAGE_ENIGMA_INSIGHT.bonuses
      assert.equal(1213318, bonuses[2].spell)
      assert.equal("aura", bonuses[2].kind)
      assert.equal("ENIGMA_FIRE_CRIT_BUFF", bonuses[2].aura)
      assert.equal(1213319, bonuses[4].spell)
      assert.equal("passive", bonuses[4].kind)
    end)

    -- MG2-D2: Fireleaf Vestments (healer variant, item-set 1944, distinct from Fireleaf Regalia above).
    it("Fireleaf Vestments: name, src and all eight piece ids", function()
      local set = pack.sets.MAGE_FIRELEAF_VESTMENTS
      assert.equal("Fireleaf Vestments", set.name)
      assert.equal("https://www.wowhead.com/classic/item-set=1944/fireleaf-vestments", set.src)
      assert.same({ 240048, 240046, 240045, 240047, 240050, 240044, 240049, 240051 }, set.items)
    end)

    it("Fireleaf Vestments thresholds carry their sourced bonus spell ids", function()
      local bonuses = pack.sets.MAGE_FIRELEAF_VESTMENTS.bonuses
      assert.equal(1226407, bonuses[2].spell)
      assert.equal("aura", bonuses[2].kind)
      assert.equal("ARCANE_TUNNELING", bonuses[2].aura)
      assert.equal(1226415, bonuses[4].spell)
      assert.equal("passive", bonuses[4].kind)
      assert.equal(1226378, bonuses[6].spell)
      assert.equal("passive", bonuses[6].kind)
    end)
  end)

  -- D.Souls: `itemID`/`short` are reachable through the advice-completeness sweep in
  -- data_sourcing_spec.lua (both souls are named in `D.Advice.MAGE.*.soul`), but `verify`/`roles`
  -- sit on their own continuation line nothing else reads.
  describe("D.Souls provenance flags", function()
    it("Soul of the Torcher is tagged provisional with its Fire role", function()
      local soul = pack.souls.SOUL_OF_THE_TORCHER
      assert.equal(236529, soul.itemID)
      assert.equal("Torcher", soul.short)
      assert.equal("in-game", soul.verify)
      assert.same({ "MAGE_FIRE" }, soul.roles)
    end)

    it("Soul of the Cryomancer is tagged provisional with its Frost role", function()
      local soul = pack.souls.SOUL_OF_THE_CRYOMANCER
      assert.equal(236520, soul.itemID)
      assert.equal("Cryomancer", soul.short)
      assert.equal("in-game", soul.verify)
      assert.same({ "MAGE_FROST_SPELLFROST" }, soul.roles)
    end)

    -- MG2-D2.
    it("Soul of the Eternal Caretaker is tagged provisional with its healer role and grants nothing", function()
      local soul = pack.souls.SOUL_OF_THE_ETERNAL_CARETAKER
      assert.equal(236516, soul.itemID)
      assert.equal("Eternal Caretaker", soul.short)
      assert.equal("in-game", soul.verify)
      assert.same({ "MAGE_ARCANE_HEALER" }, soul.roles)
      assert.same({}, soul.grants)
    end)
  end)

  -- MG2-D4: data_sourcing_spec.lua's completeness sweep only proves every `advice.runes` key
  -- RESOLVES, not that the LIST is the one the dossier actually names — a whole line's worth of
  -- entries could vanish (or a wrong key sneak in that still happens to resolve) with that check
  -- alone still green.
  it("advice.runes for the Arcane healer names the full ten-slot kit, exactly", function()
    local runes = pack.advice.MAGE.MAGE_ARCANE_HEALER.runes
    local got = {}
    for _, k in ipairs(runes) do got[#got + 1] = k end
    table.sort(got)
    local want = { "RUNE_ADVANCED_WARDING", "RUNE_ARCANE_BARRAGE", "RUNE_ARCANE_BLAST",
                   "RUNE_ARCANE_SPECIALIZATION", "RUNE_CHRONOSTATIC_PRESERVATION", "RUNE_ENLIGHTENMENT",
                   "RUNE_FIRE_SPECIALIZATION", "RUNE_MASS_REGENERATION", "RUNE_MISSILE_BARRAGE", "RUNE_REWIND_TIME" }
    table.sort(want)
    assert.same(want, got)
  end)

  -- The Enigma Insight 2pc buff (MG1-D2): the aura-dangling check in data_sourcing_spec.lua proves
  -- the KEY resolves; this proves the compiled CONDITION actually behaves like every other `buff`
  -- entry against the real pack — present passes, absent fails, and the proc suppression the
  -- follow-up note's "verify in-game" caution exists alongside still applies for t>0.
  it("ENIGMA_FIRE_CRIT_BUFF compiles as a normal, proc-suppressed buff condition", function()
    local Schema = helper.load("Elmira/Core/Schema.lua")
    local FakeState = dofile("tests/fake_state.lua")
    local compiled, errors = Schema.compileWhen({ {"buff","ENIGMA_FIRE_CRIT_BUFF"} }, { spells = pack.spells })
    assert.same({}, errors)
    local up = FakeState.new{ buffs = { ENIGMA_FIRE_CRIT_BUFF = { stacks = 1, remaining = 8 } } }
    local down = FakeState.new{}
    assert.is_true(compiled.test(up, 0))
    assert.is_false(compiled.test(down, 0))
    -- proc = true: unpredictable in the simulated future, so it must read false for any t > 0 even
    -- while the fixture says it is up.
    assert.is_false(compiled.test(up, 1.5))
  end)
end)
