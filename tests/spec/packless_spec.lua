-- tests/spec/packless_spec.lua — PF: a class with NO shipped data pack (every class but the one
-- that ships one) builds and plays a rotation from its own spellbook alone.
--
-- This is the "looks right, does nothing" guard for the whole change: a covered `UserBuilds.create`
-- and a covered `Engine.pick` prove nothing about whether the two ever actually meet with no pack
-- table anywhere in the chain. This walks the real path start to finish -- register two spells by
-- id, create a rotation, save one line, then two, resolve the active build, compile it, and let
-- Engine.pick choose from it against a fake State -- with `ns.API.GetProvider` answering nil for
-- every class, exactly as a genuinely pack-less class sees it.
local helper = require("tests.helper")
local FakeState = require("tests.fake_state")

describe("PF: rotations without a class data pack", function()
  local ns, UserBuilds

  before_each(function()
    ns = helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Spells.lua")
    helper.load("Elmira/Core/Profiles.lua")
    helper.load("Elmira/Core/Engine.lua")
    UserBuilds = helper.load("Elmira/Core/UserBuilds.lua")
    -- UserBuilds.replaceEntries invalidates Core/Slash's compile cache unconditionally on every
    -- write (its own file header explains why); the real file must be loaded for that call to land
    -- on a function rather than nil, exactly as userbuilds_spec.lua already does.
    helper.load("Elmira/Core/Slash.lua")
    ns.db = { keys = { class = "ROGUE", char = "Arthorion - Realm" },
              char = { spells = {} },
              global = { userBuilds = {} },
              profile = {} }
    -- No pack registered for ROGUE (or any class) at all -- Display.currentPack()'s own contract.
    ns.API = { GetProvider = function() return nil end, GetProviders = function() return {} end }
    ns.Adapter = { playerClass = function() return "ROGUE" end }
  end)

  local function ctx() return { spells = ns.Spells.merged(nil) } end

  it("registers two spells by id, builds a rotation from them, and plays it with no pack at all", function()
    -- Two spells "added" the way the Abilities palette adds one: by id, from the client.
    local sinister = ns.Spells.add(ns.db.char.spells, { id = 1752, name = "Sinister Strike", source = "id" })
    local slice = ns.Spells.add(ns.db.char.spells, { id = 5171, name = "Slice and Dice", source = "id" })
    assert.is_truthy(sinister)
    assert.is_truthy(slice)

    -- UserBuilds.create(nil, ...): no pack, the class comes from db.keys (F1c).
    local key, err = UserBuilds.create(nil, "My rogue rotation")
    assert.is_nil(err)
    assert.is_truthy(key:find("^USER_"))

    -- PF-D4: one line is enough. Schema.validate already refuses an EMPTY list; it does not refuse
    -- one.
    local ok1, reasons1 = UserBuilds.replaceEntries(nil, key, { { spell = sinister } })
    assert.is_true(ok1, reasons1 and table.concat(reasons1, " "))
    local build1 = UserBuilds.find(nil, key)
    assert.equal(1, #build1.entries)

    -- Then a second line, saved the same way -- the finisher ABOVE the filler in priority, so the
    -- pick below actually exercises which one fires rather than always landing on entry 1.
    local ok2, reasons2 = UserBuilds.replaceEntries(nil, key, {
      { spell = slice, when = { { "resource", "COMBO_POINTS", min = 4 } } },
      { spell = sinister },
    })
    assert.is_true(ok2, reasons2 and table.concat(reasons2, " "))
    local build2 = UserBuilds.find(nil, key)
    assert.equal(2, #build2.entries)

    -- Pin it, resolve it (Core/Profiles, no pack), compile it (Core/Schema, ctx from the registry
    -- alone) and let the engine pick from it against a fake State -- the whole chain, no pack table
    -- anywhere in it.
    ns.db.profile.activeBuild = key
    local resolvedKey, reason = ns.Profiles.resolve(nil, ns.db.profile)
    assert.equal(key, resolvedKey)
    assert.equal("pinned", reason)

    local compiled, errors = ns.Schema.compile(UserBuilds.find(nil, resolvedKey), ctx())
    assert.is_table(compiled, errors and table.concat(ns.Schema.errorLines(errors), " "))
    assert.equal(2, #compiled.entries)

    -- Nothing usable/known is restricted (FakeState defaults), and COMBO_POINTS starts at 0, so the
    -- first line's `min = 4` finisher condition fails and the filler -- Sinister Strike -- is the
    -- pick.
    local state = FakeState.new{}
    local entry, index = ns.Engine.pick(compiled, state)
    assert.is_not_nil(entry)
    assert.equal(2, index)
    assert.equal(sinister, entry.spell)

    -- Raise combo points past the line's threshold: the engine now picks the finisher, proving the
    -- condition -- not just the first entry -- was actually compiled and evaluated.
    state.powers.COMBO_POINTS = { 4, 5 }
    local entry2, index2 = ns.Engine.pick(compiled, state)
    assert.equal(slice, entry2.spell)
    assert.equal(1, index2)
  end)
end)
