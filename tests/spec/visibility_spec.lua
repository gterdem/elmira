local helper = require("tests.helper")

-- Elmira/Core/Visibility.lua — when the display is on screen.
--
-- Written because the answer used to be "always", and nobody had decided that: the PRD specifies
-- what the queue contains (F5) and what the bar glow does (F6) and never says when either shows.
-- A rule that exists only as the absence of a check cannot be tested, changed or argued with.
describe("Core.Visibility", function()
  local V

  before_each(function()
    helper.reset()
    V = helper.load("Elmira/Core/Visibility.lua")
  end)

  -- PE9-D6: the second argument is "a target you can FIGHT", not "a target". `hasTarget` was what
  -- this asked for, and a bank NPC satisfied it -- clicking one in a city popped the strip up.
  local function show(mode, inCombat, attackable)
    return V.shouldShow(mode, { inCombat = inCombat, targetAttackable = attackable })
  end

  it("'always' shows in every state", function()
    assert.is_true(show("always", false, false))
    assert.is_true(show("always", true, true))
  end)

  it("'combat' shows only in combat, target or not", function()
    assert.is_true(show("combat", true, false))
    assert.is_true(show("combat", true, true))
    assert.is_false(show("combat", false, true))
    assert.is_false(show("combat", false, false))
  end)

  it("'combat_or_target' also shows while you have a target out of combat", function()
    assert.is_true(show("combat_or_target", false, true))
    assert.is_true(show("combat_or_target", true, false))
    assert.is_false(show("combat_or_target", false, false))
  end)

  -- PE9-D6. The reading Display/Driver hands in is UnitCanAttack, so a friendly target arrives here
  -- as `targetAttackable = false` -- and an old-shaped context carrying only `hasTarget` must not
  -- keep working by accident, or the fix is a rename nothing enforces.
  it("a target you cannot attack is not a reason to show anything", function()
    assert.is_false(V.shouldShow("combat_or_target",
                                 { inCombat = false, targetAttackable = false }))
    assert.is_false(V.shouldShow("combat_or_target", { inCombat = false, hasTarget = true }))
    local _, reason = V.shouldShow("combat_or_target", { inCombat = false, hasTarget = true })
    assert.equal("out of combat, no target", reason)
  end)

  it("says why, so an empty screen can be explained", function()
    local _, reason = show("combat", false, true)
    assert.equal("out of combat", reason)
    local _, why = show("combat_or_target", false, false)
    assert.equal("out of combat, no target", why)
  end)

  it("an unknown mode behaves as the default, never as 'hide everything'", function()
    -- A profile written by a newer version must not leave someone with a blank screen and no clue.
    assert.is_true(show("some_future_mode", false, true))
    assert.is_true(show(nil, true, false))
    assert.is_false(show("some_future_mode", false, false))
  end)

  it("missing context is not combat and not a target", function()
    assert.is_true(V.shouldShow("always"))
    assert.is_false(V.shouldShow("combat"))
  end)

  it("every mode the options offer is a mode this module knows", function()
    assert.equal(3, #V.MODES)
    for _, mode in ipairs(V.MODES) do assert.is_true(V.isMode(mode)) end
    assert.is_true(V.isMode(V.DEFAULT))
    assert.is_false(V.isMode("nonsense"))
  end)
end)
