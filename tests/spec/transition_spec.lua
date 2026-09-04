local helper = require("tests.helper")

-- Elmira/Core/Transition.lua — the strip's geometry and its motion plan (ADR-0015 §3).
--
-- Every number here is a design decision the owner approved on the canvas, so every number is
-- asserted literally rather than derived from the table under test. A spec that recomputes
-- `base * firstScale` passes whatever the file says and can never report that someone changed it.
describe("Core.Transition", function()
  local T

  before_each(function()
    helper.reset()
    T = helper.load("Elmira/Core/Transition.lua")
  end)

  describe("constants", function()
    it("keeps slot 1 at 1.3x a 40px base, 4px apart", function()
      assert.equal(40, T.LAYOUT.base)
      assert.equal(4, T.LAYOUT.gap)
      assert.equal(1.3, T.LAYOUT.firstScale)
    end)

    it("steps opacity down across five slots", function()
      assert.same({ 1, 0.7, 0.55, 0.4, 0.3 }, T.LAYOUT.alpha)
    end)

    it("animates in 150ms and pops a cast to 1.15x", function()
      assert.equal(0.15, T.DURATION)
      assert.equal(1.15, T.POP_SCALE)
      assert.equal(0.8, T.LEAVE_SCALE)
    end)
  end)

  describe("ghostScale", function()
    it("starts a pop oversized and settles it back to the slot", function()
      local startScale, animScale = T.ghostScale("pop")
      assert.equal(1.15, startScale)
      assert.is_true(math.abs(animScale - 1 / 1.15) < 1e-9)
    end)

    it("shrinks anything else away from true size", function()
      local startScale, animScale = T.ghostScale("leave")
      assert.equal(1, startScale)
      assert.equal(0.8, animScale)
    end)
  end)

  describe("layout", function()
    it("sizes slot 1 larger than the rest", function()
      local slots = T.layout(3)
      assert.equal(52, slots[1].size)
      assert.equal(40, slots[2].size)
      assert.equal(40, slots[3].size)
    end)

    it("places each slot after the previous one plus the gap", function()
      local slots = T.layout(3)
      assert.equal(0, slots[1].x)
      assert.equal(56, slots[2].x)    -- 52 + 4
      assert.equal(100, slots[3].x)   -- 56 + 40 + 4
    end)

    it("carries the alpha ramp onto the slots", function()
      local slots = T.layout(5)
      assert.equal(1, slots[1].alpha)
      assert.equal(0.7, slots[2].alpha)
      assert.equal(0.3, slots[5].alpha)
    end)

    it("returns a width that ends at the last icon, not after a trailing gap", function()
      local _, width = T.layout(3)
      assert.equal(140, width)        -- 52 + 4 + 40 + 4 + 40
      local _, oneWide = T.layout(1)
      assert.equal(52, oneWide)
    end)

    -- The container used to be `SIZE` tall. At 1.3x that clips the one icon the strip exists for.
    it("is as tall as the biggest slot", function()
      local _, _, height = T.layout(3)
      assert.equal(52, height)
    end)

    it("clamps depth to the ramp it has colours for", function()
      assert.equal(1, #T.layout(0))
      assert.equal(5, #T.layout(9))
    end)
  end)

  -- What counts as "the same icon". Tested through plan() rather than through an exported helper:
  -- a function only a spec calls is a bug report, and this is only ever asked as part of planning.
  describe("identity", function()
    it("ignores the label, so two rules producing one spell do not make it twitch", function()
      local plan = T.plan({ { spell = "A", label = "seal expiring" } }, { { spell = "A", label = "filler" } })
      assert.equal("stay", plan.ops[1].kind)
    end)

    -- A trinket row is a slot like any other: it must slide and pop rather than blink in place.
    it("tracks a trinket across a shift like a spell", function()
      local plan = T.plan({ { spell = "A" }, { item = 13 } }, { { item = 13 }, { spell = "A" } })
      assert.equal("shift", plan.ops[1].kind)
      assert.equal(2, plan.ops[1].from)
    end)

    it("does not confuse one trinket slot with another", function()
      local plan = T.plan({ { item = 13 } }, { { item = 14 } })
      assert.equal("enter", plan.ops[1].kind)
      assert.equal("leave", plan.leaving[1].kind)
    end)

    it("does not confuse a spell key with an item slot of the same name", function()
      local plan = T.plan({ { spell = "13" } }, { { item = 13 } })
      assert.equal("enter", plan.ops[1].kind)
    end)

    it("treats a slot with neither spell nor item as new every time", function()
      local plan = T.plan({ {} }, { {} })
      assert.equal("enter", plan.ops[1].kind)
    end)
  end)

  describe("plan", function()
    local function q(...)
      local out = {}
      for i, key in ipairs({ ... }) do out[i] = { spell = key } end
      return out
    end

    it("marks an unchanged slot as stay", function()
      local plan = T.plan(q("A", "B"), q("A", "B"))
      assert.equal("stay", plan.ops[1].kind)
      assert.equal("stay", plan.ops[2].kind)
      assert.equal(0, #plan.leaving)
    end)

    it("marks a moved icon as a shift and says where from", function()
      local plan = T.plan(q("A", "B", "C"), q("B", "C", "D"))
      assert.equal("shift", plan.ops[1].kind)
      assert.equal(2, plan.ops[1].from)
      assert.equal("shift", plan.ops[2].kind)
      assert.equal(3, plan.ops[2].from)
    end)

    it("fades a tail arrival in rather than sliding it", function()
      local plan = T.plan(q("A", "B", "C"), q("B", "C", "D"))
      assert.equal("enter", plan.ops[3].kind)
      assert.is_falsy(plan.ops[3].promote)
    end)

    -- The distinction the ADR is built on: a promotion is the rotation changing its mind.
    it("slides a promotion in from above", function()
      local plan = T.plan(q("A", "B", "C"), q("H", "A", "B"))
      assert.equal("enter", plan.ops[1].kind)
      assert.is_true(plan.ops[1].promote)
      assert.equal("shift", plan.ops[2].kind)
      assert.equal(1, plan.ops[2].from)
    end)

    it("reports a dropped icon as a plain leave", function()
      local plan = T.plan(q("A", "B", "C"), q("A", "B"))
      assert.equal(1, #plan.leaving)
      assert.equal("leave", plan.leaving[1].kind)
      assert.equal(3, plan.leaving[1].from)
      assert.equal("C", plan.leaving[1].slot.spell)
    end)

    it("pops slot 1 when that spell was the one cast", function()
      local plan = T.plan(q("A", "B"), q("B", "C"), "A")
      assert.equal("pop", plan.leaving[1].kind)
      assert.equal(1, plan.leaving[1].from)
    end)

    -- Crusader Strike is cast and comes straight back further down. It still popped: what makes it
    -- a pop is that it stopped being the answer, not that it left the screen.
    it("pops a cast spell that reappears later in the queue", function()
      local plan = T.plan(q("A", "B"), q("B", "A"), "A")
      assert.equal(1, #plan.leaving)
      assert.equal("pop", plan.leaving[1].kind)
      assert.equal("shift", plan.ops[2].kind)   -- and it still slides to its new home
    end)

    it("does not pop when the cast was not the top suggestion", function()
      local plan = T.plan(q("A", "B"), q("B", "C"), "B")
      assert.equal("leave", plan.leaving[1].kind)
    end)

    it("does not pop when slot 1 did not change", function()
      local plan = T.plan(q("A", "B"), q("A", "C"), "A")
      for _, row in ipairs(plan.leaving) do assert.not_equal("pop", row.kind) end
    end)

    it("never reports the same old slot as both popped and left", function()
      local plan = T.plan(q("A"), q("B"), "A")
      assert.equal(1, #plan.leaving)
      assert.equal("pop", plan.leaving[1].kind)
    end)

    it("treats a first render as all entries", function()
      local plan = T.plan(nil, q("A", "B"))
      assert.equal("enter", plan.ops[1].kind)
      assert.equal("enter", plan.ops[2].kind)
      assert.equal(0, #plan.leaving)
    end)

    it("treats an emptied queue as all leaving", function()
      local plan = T.plan(q("A", "B"), nil)
      assert.equal(2, #plan.leaving)
    end)
  end)
end)
