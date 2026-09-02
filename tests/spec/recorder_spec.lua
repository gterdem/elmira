-- tests/spec/recorder_spec.lua — Core/Recorder.lua.
--
-- The recorder exists because SavedVariables only flushes on /reload, so one snapshot per reload made
-- an eight-scenario gear test cost eight reloads. It buffers many marks and flushes once.
--
-- The cases that matter are the ones where losing data would be silent: a stopped recorder must not
-- capture, a full buffer must say it dropped something rather than quietly shortening the record, and
-- a capture that fails must not push a nil mark that reads later as "we tested this and saw nothing".
local helper = require("tests.helper")

describe("Core.Recorder", function()
  local Recorder

  before_each(function()
    helper.reset()
    Recorder = helper.load("Elmira/Core/Recorder.lua")
    Recorder.reset()
  end)

  local function capture(tag)
    return function() return { tag = tag or "snap" } end
  end

  it("does not capture while stopped", function()
    local called = false
    local ok, why = Recorder.mark("x", 0, function() called = true; return {} end)
    assert.is_false(ok)
    assert.equal("not recording", why)
    assert.is_false(called, "a stopped recorder must not pay for a snapshot")
  end)

  it("captures once started", function()
    Recorder.start(100)
    assert.is_true(Recorder.mark("first", 101, capture()))
    assert.equal(1, Recorder.count())
    assert.equal("first", Recorder.marks()[1].label)
  end)

  it("records elapsed time from the start of the session", function()
    Recorder.start(100)
    Recorder.mark("later", 130, capture())
    assert.equal(30, Recorder.marks()[1].elapsed)
  end)

  it("keeps marks in order so gear states can be compared", function()
    Recorder.start(0)
    Recorder.mark("4of9", 1, capture())
    Recorder.mark("3of9", 2, capture())
    Recorder.mark("4of9-again", 3, capture())
    local m = Recorder.marks()
    assert.same({ "4of9", "3of9", "4of9-again" }, { m[1].label, m[2].label, m[3].label })
  end)

  -- A truncated record that looks complete is worse than a short one: the reader would compare two
  -- gear states that were never adjacent.
  it("reports how many marks it dropped when the buffer fills", function()
    Recorder.start(0)
    for i = 1, Recorder.MAX_MARKS + 3 do Recorder.mark("m" .. i, i, capture()) end
    assert.equal(Recorder.MAX_MARKS, Recorder.count())
    assert.equal(3, Recorder.dropped())
    assert.equal("m4", Recorder.marks()[1].label, "oldest marks are dropped, newest kept")
    assert.truthy(Recorder.payload().dropped == 3)
  end)

  it("refuses a capture that returns nothing rather than storing a hollow mark", function()
    Recorder.start(0)
    local ok, why = Recorder.mark("bad", 1, function() return nil end)
    assert.is_false(ok)
    assert.equal("capture returned nothing", why)
    assert.equal(0, Recorder.count())
  end)

  it("refuses a missing capture function", function()
    Recorder.start(0)
    assert.is_false(Recorder.mark("bad", 1, nil))
  end)

  it("stops and reports the count", function()
    Recorder.start(0)
    Recorder.mark("a", 1, capture())
    assert.equal(1, Recorder.stop())
    assert.is_false(Recorder.isRecording())
    assert.is_false(Recorder.mark("b", 2, capture()))
  end)

  it("keeps marks after stopping so a reload can still write them", function()
    Recorder.start(0)
    Recorder.mark("a", 1, capture())
    Recorder.stop()
    assert.equal(1, Recorder.count())
    assert.equal(1, Recorder.payload().count)
  end)

  describe("status", function()
    it("says nothing is captured when idle", function()
      assert.truthy(Recorder.status():find("not recording", 1, true))
    end)

    it("says it is recording, with the count", function()
      Recorder.start(0)
      Recorder.mark("a", 1, capture())
      assert.truthy(Recorder.status():find("RECORDING", 1, true))
      assert.truthy(Recorder.status():find("1 mark", 1, true))
    end)

    -- The reload is the one unavoidable step, so the status has to name it.
    it("tells the user to reload once stopped with marks held", function()
      Recorder.start(0)
      Recorder.mark("a", 1, capture())
      Recorder.stop()
      assert.truthy(Recorder.status():find("/reload", 1, true), Recorder.status())
    end)

    it("surfaces dropped marks in the status line", function()
      Recorder.start(0)
      for i = 1, Recorder.MAX_MARKS + 1 do Recorder.mark("m" .. i, i, capture()) end
      assert.truthy(Recorder.status():find("dropped", 1, true))
    end)
  end)

  -- The first live recording filled 20+ of its 40 slots with identical combat-start/combat-end pairs
  -- from repeatedly pulling a dummy, which would have evicted the gear states being compared.
  describe("automatic-mark dedupe", function()
    it("skips a consecutive auto-mark whose fingerprint is unchanged", function()
      Recorder.start(0)
      assert.is_true(Recorder.mark("combat-start", 1, capture(), "gearA"))
      local ok, why = Recorder.mark("combat-end", 2, capture(), "gearA")
      assert.is_false(ok)
      assert.equal("unchanged since last mark", why)
      assert.equal(1, Recorder.count())
      assert.equal(1, Recorder.deduped())
    end)

    it("records again as soon as the fingerprint changes", function()
      Recorder.start(0)
      Recorder.mark("a", 1, capture(), "gearA")
      Recorder.mark("b", 2, capture(), "gearA")
      assert.is_true(Recorder.mark("c", 3, capture(), "gearB"))
      assert.equal(2, Recorder.count())
    end)

    -- A mark the player explicitly asked for must never be swallowed, even mid-identical-gear.
    it("never dedupes a manual mark", function()
      Recorder.start(0)
      Recorder.mark("auto", 1, capture(), "gearA")
      assert.is_true(Recorder.mark("i-want-this", 2, capture()))
      assert.is_true(Recorder.mark("and-this", 3, capture()))
      assert.equal(3, Recorder.count())
    end)

    it("does not pay for a snapshot it is going to discard", function()
      Recorder.start(0)
      Recorder.mark("a", 1, capture(), "gearA")
      local called = false
      Recorder.mark("b", 2, function() called = true; return {} end, "gearA")
      assert.is_false(called)
    end)

    it("reports deduped count in the payload", function()
      Recorder.start(0)
      Recorder.mark("a", 1, capture(), "gearA")
      Recorder.mark("b", 2, capture(), "gearA")
      assert.equal(1, Recorder.payload().deduped)
    end)
  end)
end)
