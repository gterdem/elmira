-- tests/spec/collector_spec.lua — Elmira/Adapters/Collector.lua against docs/01 §4a.
--
-- Written from the design, not the implementation. The point of the collector is that it shows a
-- mismatch between the client and our data, so the central test here feeds it the EXACT numbers from
-- the bug it exists to catch (docs/07 §9.12: chest returned 458287 while Spells.lua stored 425614)
-- and asserts the mismatch is reported. A test that only fed it matching data would pass against a
-- collector that never compares anything.
local helper = require("tests.helper")
local mock = require("tests.wow_mock")

describe("Adapters.Collector (docs/01 §4a)", function()
  local Collector

  before_each(function()
    mock.reset()
    helper.reset()
    Collector = helper.load("Elmira/Adapters/Collector.lua")
  end)

  -- The verbatim round-2 chest reading, against the id the data actually held at the time.
  local function chestReading()
    return { { slot = 5, name = "Hallowed Ground", ids = { 458287 } } }
  end

  -- Everything below this point drives the REAL read* functions against the mock. Until now every
  -- case fed hand-built readings tables, so the client-facing half of the collector — the half that
  -- actually runs in game — had no coverage at all. That is exactly how `known` shipped unable to be
  -- false: the pure comparison functions were tested, the reads were not.
  describe("readSpells (against the client mock)", function()
    it("reports a spell the player does not know as known = false, not nil", function()
      local spells = { EXORCISM = { id = 415073 } }
      local readings = Collector.readSpells(spells)
      assert.is_false(readings.EXORCISM.known,
        "known must be false for an unlearned spell; nil makes the NOT KNOWN branch unreachable")
    end)

    it("renders that as NOT KNOWN", function()
      local spells = { EXORCISM = { id = 415073 } }
      local rows = Collector.compareSpells(Collector.readSpells(spells), spells)
      local text = table.concat(Collector.formatSpells(rows), "\n")
      assert.truthy(text:find("NOT KNOWN", 1, true), text)
    end)

    it("reads cooldown and cost for a known spell", function()
      mock.spell(415073, { cooldown = 6, cost = 69 })
      local readings = Collector.readSpells({ EXORCISM = { id = 415073 } })
      assert.is_true(readings.EXORCISM.known)
      assert.equal(6, readings.EXORCISM.cooldown)
      assert.equal(69, readings.EXORCISM.cost)
    end)

    -- The trap the whole milestone turned on: a GCD reading must never be recorded as a cooldown.
    it("does not record a GCD reading as the spell's cooldown", function()
      mock.spell(415073, {})
      mock.gcdActive = true
      local readings = Collector.readSpells({ EXORCISM = { id = 415073 } })
      assert.is_nil(readings.EXORCISM.cooldown)
    end)

    it("skips a record with no usable id", function()
      assert.is_nil(Collector.readSpells({ BROKEN = { id = 0 } }).BROKEN)
    end)
  end)

  describe("readRunes (against the client mock)", function()
    it("returns nothing when no rune is engraved", function()
      assert.same({}, Collector.readRunes())
    end)

    it("reads learnedAbilitySpellIDs per slot", function()
      mock.runes[5] = { name = "Hallowed Ground", learnedAbilitySpellIDs = { 458287 } }
      local readings = Collector.readRunes()
      assert.equal(1, #readings)
      assert.equal(5, readings[1].slot)
      assert.same({ 458287 }, readings[1].ids)
    end)

    -- A scanned slot with no name prints a nil where the slot should be in `/elm debug` output.
    -- Fails the moment a slot joins RUNE_SLOTS without being named -- which is how the ten-slot
    -- sweep (rings + cloak, 2026-09-03) would otherwise have shipped half-done.
    it("names every slot it scans", function()
      for _, slot in ipairs(Collector.RUNE_SLOTS) do
        assert.is_string(Collector.SLOT_NAMES[slot], "slot " .. slot .. " is scanned but unnamed")
      end
    end)

    it("labels a cloak rune with its slot name", function()
      mock.runes[15] = { name = "Shock and Awe", learnedAbilitySpellIDs = { 462834 } }
      local rows = Collector.compareRunes(Collector.readRunes(), {})
      assert.equal(15, rows[1].slot)
      assert.equal("back", rows[1].slotName)
    end)

    -- End to end: client mock -> readRunes -> compareRunes, the verbatim shipped bug.
    it("feeds compareRunes so a teach id is reported as NO MATCH", function()
      mock.runes[5] = { name = "Hallowed Ground", learnedAbilitySpellIDs = { 458287 } }
      local spells = { RUNE_HALLOWED_GROUND = { id = 425614, rune = "chest" } }
      local rows = Collector.compareRunes(Collector.readRunes(), spells)
      assert.is_nil(rows[1].matched)
    end)
  end)

  describe("readAuraPresence (against the client mock)", function()
    it("reports zero scanned when the player has no buffs", function()
      local _, scanned = Collector.readAuraPresence({ X = { id = 1, verify = "in-game" } })
      assert.equal(0, #scanned)
    end)

    it("walks every buff and matches a provisional id", function()
      mock.auras.player[1] = { name = "Well Fed", spellID = 19705 }
      mock.auras.player[2] = { name = "Swift Judgement", spellID = 467530, count = 3 }
      local seen, scanned = Collector.readAuraPresence({
        SWIFT_JUDGEMENT_BUFF = { id = 467530, verify = "in-game" },
      })
      assert.equal(2, #scanned)
      assert.equal(467530, seen.SWIFT_JUDGEMENT_BUFF.spellID)
    end)

    it("ignores spells not tagged provisional", function()
      mock.auras.player[1] = { name = "Exorcism", spellID = 415073 }
      local seen = Collector.readAuraPresence({ EXORCISM = { id = 415073 } })
      assert.is_nil(seen.EXORCISM)
    end)
  end)

  describe("readItemTooltipLines / readCharacter (against the client mock)", function()
    it("reads the shoulder tooltip, where souls live", function()
      mock.tooltipLines[3] = { "Lawbringer Spaulders", "Exile" }
      assert.same({ "Lawbringer Spaulders", "Exile" }, Collector.readItemTooltipLines(3))
    end)

    it("reads level, class and engraving state", function()
      local c = Collector.readCharacter()
      assert.equal(60, c.level)
      assert.equal("PALADIN", c.class)
      assert.is_true(c.engravingEnabled)
    end)
  end)

  describe("compareRunes", function()
    it("reports NO MATCH when our stored id is the teach spell, not the ability", function()
      local spells = { RUNE_HALLOWED_GROUND = { id = 425614, rune = "chest" } }
      local rows = Collector.compareRunes(chestReading(), spells)

      assert.equal(1, #rows)
      assert.is_nil(rows[1].matched)
      -- The stored id must appear as a candidate, so the two numbers can be read side by side.
      assert.equal(1, #rows[1].candidates)
      assert.equal("RUNE_HALLOWED_GROUND", rows[1].candidates[1].key)
      assert.equal(425614, rows[1].candidates[1].id)
    end)

    it("matches once the ability id is stored", function()
      local spells = { RUNE_HALLOWED_GROUND = { id = 458287, rune = "chest" } }
      local rows = Collector.compareRunes(chestReading(), spells)
      assert.equal("RUNE_HALLOWED_GROUND", rows[1].matched)
      assert.equal(0, #rows[1].candidates)
    end)

    it("matches any id in learnedAbilitySpellIDs, not only the first", function()
      local readings = { { slot = 7, name = "Rebuke", ids = { 999999, 425609 } } }
      local spells = { RUNE_REBUKE = { id = 425609, rune = "legs" } }
      assert.equal("RUNE_REBUKE", Collector.compareRunes(readings, spells)[1].matched)
    end)

    it("says so when no data key claims the slot at all", function()
      local rows = Collector.compareRunes(chestReading(), { RUNE_WRATH = { id = 429139, rune = "head" } })
      assert.is_nil(rows[1].matched)
      assert.equal(0, #rows[1].candidates)
    end)

    -- Guards hard rule 3's spirit: a data pack is a plain table and may hold non-rune entries.
    it("ignores spell entries that are not runes", function()
      local spells = { EXORCISM = { id = 458287 }, RUNE_HALLOWED_GROUND = { id = 425614, rune = "chest" } }
      local rows = Collector.compareRunes(chestReading(), spells)
      assert.is_nil(rows[1].matched, "matched a non-rune entry that happened to share the id")
    end)

    it("returns an empty list rather than erroring with no readings", function()
      assert.same({}, Collector.compareRunes(nil, nil))
    end)
  end)

  describe("formatRunes", function()
    it("prints the client id and our stored id on a mismatch", function()
      local spells = { RUNE_HALLOWED_GROUND = { id = 425614, rune = "chest" } }
      local text = table.concat(Collector.formatRunes(Collector.compareRunes(chestReading(), spells)), "\n")
      assert.truthy(text:find("458287", 1, true), text)
      assert.truthy(text:find("425614", 1, true), text)
      assert.truthy(text:find("NO MATCH", 1, true), text)
    end)

    it("says MATCH when they agree", function()
      local spells = { RUNE_HALLOWED_GROUND = { id = 458287, rune = "chest" } }
      local text = table.concat(Collector.formatRunes(Collector.compareRunes(chestReading(), spells)), "\n")
      assert.truthy(text:find("MATCH", 1, true))
      assert.is_nil(text:find("NO MATCH", 1, true))
    end)
  end)

  describe("compareSpells", function()
    -- docs/07 §9.1: Wowhead says Exorcism's cooldown is 15 s; the real one on an engraved character
    -- is 6 s. The dump must show that disagreement rather than reconcile it.
    it("flags a live cooldown that differs from the shipped fallback", function()
      local readings = { EXORCISM = { cooldown = 6, cost = 69, known = true } }
      local spells = { EXORCISM = { id = 415073, cooldown = 15, cost = { mana = 345 } } }
      local row = Collector.compareSpells(readings, spells)[1]

      assert.equal(6, row.liveCooldown)
      assert.equal(15, row.shippedCooldown)
      assert.is_true(row.cooldownDiffers)
      assert.is_true(row.costDiffers)
    end)

    it("does not flag agreement", function()
      local readings = { JUDGEMENT = { cooldown = 10, known = true } }
      local row = Collector.compareSpells(readings, { JUDGEMENT = { id = 20271, cooldown = 10 } })[1]
      assert.is_false(row.cooldownDiffers)
    end)

    -- A spell with no shipped fallback must not read as "differs"; nothing was claimed to differ from.
    it("does not flag a missing fallback as a disagreement", function()
      local readings = { HOLY_WRATH = { cooldown = 60, known = true } }
      local row = Collector.compareSpells(readings, { HOLY_WRATH = { id = 429146 } })[1]
      assert.is_false(row.cooldownDiffers)
    end)

    it("orders rows deterministically so two dumps diff cleanly", function()
      local readings = { ZED = { known = true }, ALPHA = { known = true }, MID = { known = true } }
      local rows = Collector.compareSpells(readings, {})
      assert.same({ "ALPHA", "MID", "ZED" }, { rows[1].key, rows[2].key, rows[3].key })
    end)
  end)

  describe("mismatchCount", function()
    it("counts rune rows that did not match", function()
      local spells = { RUNE_HALLOWED_GROUND = { id = 425614, rune = "chest" } }
      local snapshot = { runes = Collector.compareRunes(chestReading(), spells) }
      assert.equal(1, Collector.mismatchCount(snapshot))
    end)

    it("is zero when everything matches", function()
      local spells = { RUNE_HALLOWED_GROUND = { id = 458287, rune = "chest" } }
      local snapshot = { runes = Collector.compareRunes(chestReading(), spells) }
      assert.equal(0, Collector.mismatchCount(snapshot))
    end)
  end)

  describe("compareSets", function()
    -- docs/07 §9.11: the tooltip reports (n/N) for the character's CURRENT spec and cannot go stale
    -- the way a shipped item list can, so a disagreement means our item list is wrong.
    it("flags our count disagreeing with the tooltip's own", function()
      local rows = Collector.compareSets({ PALADIN_T3_REDEMPTION = 3 }, { PALADIN_T3_REDEMPTION = 4 })
      assert.is_true(rows[1].differs)
    end)

    it("does not flag when the tooltip is silent", function()
      local rows = Collector.compareSets({ PALADIN_T3_REDEMPTION = 3 }, {})
      assert.is_false(rows[1].differs)
    end)
  end)

  describe("pendingVerification", function()
    -- docs/03: a provisional id ships, so nothing forces anyone to look at it. The dump is the only
    -- thing that will, which is why it has to name them rather than just carry them.
    it("lists only entries tagged verify=in-game, sorted", function()
      local spells = {
        TEMPLAR_BUFF = { id = 1226464, src = "wowsims ...", verify = "in-game" },
        SWIFT_JUDGEMENT_BUFF = { id = 467530, src = "wowsims ...", verify = "in-game" },
        EXORCISM = { id = 415073, src = "https://www.wowhead.com/classic/spell=415073" },
      }
      local rows = Collector.pendingVerification(spells)
      assert.equal(2, #rows)
      assert.equal("SWIFT_JUDGEMENT_BUFF", rows[1].key)
      assert.equal("TEMPLAR_BUFF", rows[2].key)
    end)

    it("renders nothing at all when everything is confirmed", function()
      local rows = Collector.pendingVerification({ EXORCISM = { id = 415073, src = "https://wowhead" } })
      assert.same({}, Collector.formatPending(rows))
    end)

    -- The decisive case: a soul's "permanent hidden aura" is only real if the client returns it.
    it("reports a provisional aura as VISIBLE when the client returns it", function()
      local rows = { { key = "SOUL_EXILE_AURA", id = 468431, src = "wowsims" } }
      local seen = { SOUL_EXILE_AURA = { name = "S03 - ZG Caster 5P", count = 0, spellID = 468431 } }
      local text = table.concat(Collector.formatPending(rows, seen), "\n")
      assert.truthy(text:find("VISIBLE", 1, true), text)
    end)

    it("does not claim absence is proof for a transient buff", function()
      local rows = { { key = "TEMPLAR_BUFF", id = 1226464, src = "wowsims" } }
      local text = table.concat(Collector.formatPending(rows, {}), "\n")
      assert.truthy(text:find("not on the player right now", 1, true), text)
      assert.truthy(text:find("absent proves nothing", 1, true), text)
      assert.is_nil(text:find("VISIBLE", 1, true))
    end)

    -- The lesson from the first live run: a bare "nothing matched" is not evidence.
    it("refuses to let an empty scan read as a disproved hypothesis", function()
      local text = table.concat(Collector.formatScan({}), "\n")
      assert.truthy(text:find("NO CONCLUSION", 1, true), text)
    end)

    it("says how many buffs were walked when the scan did run", function()
      local text = table.concat(Collector.formatScan({
        { name = "Blessing of Kings", spellID = 20217 }, { name = "Well Fed", spellID = 19705 },
      }), "\n")
      assert.truthy(text:find("walked 2 player buffs", 1, true), text)
      assert.truthy(text:find("Blessing of Kings", 1, true), text)
    end)

    it("prints the id and its source so the claim can be checked", function()
      local spells = { TEMPLAR_BUFF = { id = 1226464, src = "wowsims item_sets_pve_phase_8.go" } }
      spells.TEMPLAR_BUFF.verify = "in-game"
      local text = table.concat(Collector.formatPending(Collector.pendingVerification(spells)), "\n")
      assert.truthy(text:find("1226464", 1, true), text)
      assert.truthy(text:find("wowsims", 1, true), text)
    end)
  end)

  describe("format", function()
    it("renders without a client and labels the raw shoulder tooltip", function()
      local text = table.concat(Collector.format({
        character = { level = 60, class = "PALADIN", engravingEnabled = true },
        runes = {}, spells = {}, shoulderTooltip = { "Exile" },
      }), "\n")
      assert.truthy(text:find("level=60", 1, true), text)
      assert.truthy(text:find("Exile", 1, true), text)
      assert.truthy(text:find("no runes engraved", 1, true), text)
    end)
  end)
end)
