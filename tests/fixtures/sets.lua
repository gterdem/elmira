-- tests/fixtures/sets.lua and the bonuses table below mirror Data/<flavor>/Sets.lua + Souls.lua in
-- shape. `bonuses[key].from` is the same {{set=,pieces=},{soul=}} shape tests/fake_state.lua:39-47
-- already resolves, so a fixture bonus behaves exactly like a real one.
return {
  sets = {
    PALADIN_T2_JUDGEMENT    = { name = "Judgement Armor (fixture)", items = { 2001, 2002 } },
    PALADIN_T35_INQUISITION = { name = "Inquisition (fixture)", items = { 2010, 2011 } },
    PALADIN_T3_REDEMPTION   = { name = "Redemption (fixture)", items = { 2020, 2021 } },
  },
  bonuses = {
    JUDGEMENT_NO_CONSUME = { from = { { set = "PALADIN_T2_JUDGEMENT", pieces = 2 } } },
    HOLY_POWER_CONSUME   = { from = { { set = "PALADIN_T35_INQUISITION", pieces = 4 } } },
    HOLY_WRATH_INSTANT   = { from = { { set = "PALADIN_T3_REDEMPTION", pieces = 4 } } },
    -- The soul case ADR-0006 cares about: granted with zero set pieces equipped.
    CRUSADER_STRIKE_150  = { from = { { set = "PALADIN_T2_JUDGEMENT", pieces = 6 }, { soul = "SOUL_OF_THE_RETRIBUTOR" } } },
  },
}
