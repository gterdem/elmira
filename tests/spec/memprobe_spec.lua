local helper = require("tests.helper")

-- Elmira/Core/MemProbe.lua — the A/B allocation sampler (see the file's own header for the reasoning
-- behind sampling instead of a single before/after reading). PURE: no WoW API, no clock, no frames --
-- time, the memory reading, the scheduler and the suspend/resume pair all arrive as injected
-- functions, which is what lets `run()` be driven end to end from a fake scheduler below instead of
-- by staring at a memory readout for forty seconds.
describe("Core.MemProbe", function()
  local MP

  before_each(function()
    helper.reset()
    MP = helper.load("Elmira/Core/MemProbe.lua")
  end)

  describe("newWindow():add()", function()
    it("sums positive steps into allocated", function()
      local w = MP.newWindow()
      w:add(0, 100) -- first reading only sets the baseline, no step yet
      w:add(2, 150)
      assert.equal(50, w.allocated)
    end)

    -- Pinned hard per the module's own comment: a window whose readings go 100, 200, 50, 150 must
    -- report 200 KB allocated (100 + 100), not 50 (which is what subtracting the GC dip would give).
    it("counts a negative step as a garbage collection, and does NOT subtract it from allocated", function()
      local w = MP.newWindow()
      w:add(0, 100)
      w:add(1, 200) -- +100 -> allocated 100
      w:add(2, 50)  -- GC dip -> collections 1, allocated unchanged
      w:add(3, 150) -- +100 -> allocated 200
      assert.equal(200, w.allocated)
      assert.equal(1, w.collections)
    end)

    -- The report prints the sample count, and a window that took two readings in twenty seconds is
    -- a window nobody should trust. Counting them is how that shows.
    it("counts every accepted reading and says it accepted them", function()
      local w = MP.newWindow()
      assert.is_true(w:add(0, 100), "an accepted reading answers true")
      assert.is_true(w:add(2, 120))
      assert.is_true(w:add(4, 140))
      assert.equal(3, w.samples)
    end)

    it("rejects non-number arguments and returns false, without touching allocated/samples", function()
      local w = MP.newWindow()
      assert.is_false(w:add("later", 10))
      assert.is_false(w:add(0, "ten"))
      assert.equal(0, w.allocated)
      assert.equal(0, w.samples)
    end)
  end)

  describe("elapsed()", function()
    it("is 0 before any reading, and 0 after exactly one (nothing to span yet)", function()
      local w = MP.newWindow()
      assert.equal(0, w:elapsed())
      w:add(5, 100)
      assert.equal(0, w:elapsed())
    end)

    it("is the span between the first and last reading", function()
      local w = MP.newWindow()
      w:add(5, 100)
      w:add(15, 150)
      assert.equal(10, w:elapsed())
    end)
  end)

  describe("rate()", function()
    it("is nil (not 0) for a window with fewer than two readings", function()
      local w = MP.newWindow()
      assert.is_nil(w:rate())
      w:add(5, 100)
      assert.is_nil(w:rate())
    end)

    it("is nil (not 0) when elapsed time is zero, even with readings", function()
      local w = MP.newWindow()
      w:add(5, 100)
      w:add(5, 200) -- same timestamp
      assert.is_nil(w:rate())
    end)

    it("is allocated / elapsed", function()
      local w = MP.newWindow()
      w:add(0, 100)
      w:add(10, 300)
      assert.equal(20, w:rate())
    end)
  end)

  describe("share()", function()
    it("is nil when either window has no rate", function()
      local running, suspended = MP.newWindow(), MP.newWindow()
      running:add(0, 100)
      running:add(10, 300)
      assert.is_nil(MP.share(running, suspended))
    end)

    it("is the fractional drop between the running and suspended rate", function()
      local running, suspended = MP.newWindow(), MP.newWindow()
      running:add(0, 0)
      running:add(10, 1000) -- 100 KB/s
      suspended:add(0, 0)
      suspended:add(10, 500) -- 50 KB/s
      assert.equal(0.5, MP.share(running, suspended))
    end)
  end)

  describe("summarise()", function()
    local function windowWithRate(rate)
      local w = MP.newWindow()
      w:add(0, 0)
      w:add(10, rate * 10)
      return w
    end

    it('says "NOT the render loop" when the two rates are within 25%', function()
      local running, suspended = windowWithRate(100), windowWithRate(90) -- 10% apart
      local lines = MP.summarise(running, suspended, nil)
      local found = false
      for _, line in ipairs(lines) do
        if line:find("NOT the render loop", 1, true) then found = true end
      end
      assert.is_true(found)
    end)

    it("reports the render loop's share when the two rates diverge by 25% or more", function()
      local running, suspended = windowWithRate(100), windowWithRate(50) -- 50% apart
      local lines = MP.summarise(running, suspended, nil)
      local found = false
      for _, line in ipairs(lines) do
        if line:find("render loop accounts for 50%", 1, true) then found = true end
      end
      assert.is_true(found)
    end)

    it("says not enough readings when one window never produced a rate", function()
      local running, suspended = MP.newWindow(), windowWithRate(50)
      local lines = MP.summarise(running, suspended, nil)
      local found = false
      for _, line in ipairs(lines) do
        if line:find("not enough readings to compare", 1, true) then found = true end
      end
      assert.is_true(found)
    end)

    it('names the owned-library count, and says "could not tell" when owned is nil', function()
      local running, suspended = windowWithRate(100), windowWithRate(90)
      local noneOwned = MP.summarise(running, suspended, nil)
      local unknownFound = false
      for _, line in ipairs(noneOwned) do
        if line:find("could not tell", 1, true) then unknownFound = true end
      end
      assert.is_true(unknownFound)

      local threeOwned = MP.summarise(running, suspended, 3)
      local countFound = false
      for _, line in ipairs(threeOwned) do
        if line:find("3 of the libraries", 1, true) then countFound = true end
      end
      assert.is_true(countFound)

      local zeroOwned = MP.summarise(running, suspended, 0)
      local zeroFound = false
      for _, line in ipairs(zeroOwned) do
        if line:find("none of Elmira's copies won LibStub", 1, true) then zeroFound = true end
      end
      assert.is_true(zeroFound)
    end)

    -- The count on its own is a number with no meaning. What makes it actionable is the sentence
    -- after it -- that other addons' use of those libraries lands on this figure -- and the command
    -- that lists which ones. Dropping either leaves the reader with a statistic and nowhere to go.
    it("says what an owned library COSTS, and where to see the list", function()
      local text = table.concat(MP.summarise(windowWithRate(100), windowWithRate(90), 3), "\n")
      assert.truthy(text:find("every other addon's use of them is billed to this figure", 1, true))
      assert.truthy(text:find("/elm debug libs", 1, true))
    end)
  end)

  -- run() end to end, driven by a scheduler we control by hand: `schedule` only queues, nothing
  -- happens until the spec pops the queue and calls it. This is what lets the whole 40-second A/B be
  -- asserted deterministically instead of trusting that the real timers eventually fire correctly.
  describe("run()", function()
    -- Drains a fake `schedule` queue, advancing a fake clock by each job's delay before calling it.
    local function drain(queue, clockRef)
      local guard = 0
      while #queue > 0 do
        guard = guard + 1
        assert.is_true(guard < 1000, "runaway scheduler: run() never finished")
        local job = table.remove(queue, 1)
        clockRef.now = clockRef.now + job.delay
        job.fn()
      end
    end

    it("samples the running window first, suspends exactly once, resumes exactly once, and reports exactly once", function()
      local queue = {}
      local clockRef = { now = 0 }
      local order = {}
      local readKBCalls = 0
      local callsAtSuspend, callsAtResume
      local kb = 1000
      local reportedLines

      local ok = MP.run({
        seconds = 4,
        interval = 2,
        now = function() return clockRef.now end,
        readKB = function()
          readKBCalls = readKBCalls + 1
          kb = kb + 50
          return kb
        end,
        schedule = function(s, fn) queue[#queue + 1] = { delay = s, fn = fn } end,
        suspend = function()
          order[#order + 1] = "suspend"
          callsAtSuspend = readKBCalls
        end,
        resume = function()
          order[#order + 1] = "resume"
          callsAtResume = readKBCalls
        end,
        report = function(lines)
          order[#order + 1] = "report"
          reportedLines = lines
        end,
      })

      assert.is_true(ok)
      assert.is_true(MP.isRunning())

      drain(queue, clockRef)

      assert.is_false(MP.isRunning())
      assert.same({ "suspend", "resume", "report" }, order)
      -- seconds=4, interval=2 -> samples at remaining 4, 2, 0: three per window, plus the one-off
      -- readKB() gate check run() makes before it opens the running window at all.
      assert.equal(4, callsAtSuspend)   -- 1 gate check + 3 RUNNING samples, all before suspend()
      assert.equal(7, callsAtResume)    -- + 3 more (suspended window) happened before resume()
      assert.is_table(reportedLines)
      assert.is_true(#reportedLines > 0)
    end)

    it("refuses a second concurrent run, and accepts a new one after the first completes", function()
      local function mkOpts(queue, clockRef)
        local kb = 1000
        return {
          seconds = 2,
          interval = 2,
          now = function() return clockRef.now end,
          readKB = function() kb = kb + 10; return kb end,
          schedule = function(s, fn) queue[#queue + 1] = { delay = s, fn = fn } end,
          suspend = function() end,
          resume = function() end,
          report = function() end,
        }
      end

      local queue, clockRef = {}, { now = 0 }
      assert.is_true(MP.run(mkOpts(queue, clockRef)))

      local ok2, reason2 = MP.run(mkOpts(queue, clockRef))
      assert.is_false(ok2)
      assert.is_string(reason2)

      drain(queue, clockRef)
      assert.is_false(MP.isRunning())

      local ok3 = MP.run(mkOpts(queue, clockRef))
      assert.is_true(ok3)
    end)

    it("returns false with a reason when readKB() answers nil, and does NOT suspend the display", function()
      local suspended = false
      local ok, reason = MP.run({
        seconds = 2,
        interval = 2,
        now = function() return 0 end,
        readKB = function() return nil end,
        schedule = function() end,
        suspend = function() suspended = true end,
        resume = function() end,
        report = function() end,
      })
      assert.is_false(ok)
      assert.is_string(reason)
      assert.is_false(suspended)
      assert.is_false(MP.isRunning())
    end)

    it("returns false with a reason when the wiring table is incomplete", function()
      local ok, reason = MP.run({ now = function() return 0 end, readKB = function() return 1 end })
      assert.is_false(ok)
      assert.is_string(reason)
    end)

    -- The display must never be left dark: even a suspended window that produced no usable readings
    -- (client stopped answering readKB mid-run) still has to end in resume().
    it("still calls resume() when the suspended window produced no usable readings", function()
      local queue, clockRef = {}, { now = 0 }
      local phase = "running"
      local resumed = false
      local reportedLines
      local kb = 1000

      local ok = MP.run({
        seconds = 2,
        interval = 2,
        now = function() return clockRef.now end,
        readKB = function()
          if phase == "suspended" then return nil end
          kb = kb + 10
          return kb
        end,
        schedule = function(s, fn) queue[#queue + 1] = { delay = s, fn = fn } end,
        suspend = function() phase = "suspended" end,
        resume = function() resumed = true end,
        report = function(lines) reportedLines = lines end,
      })

      assert.is_true(ok)
      drain(queue, clockRef)

      assert.is_true(resumed)
      assert.is_false(MP.isRunning())
      assert.is_table(reportedLines)
    end)
  end)

  -- Every step of a run is a scheduled callback, so a throw inside one breaks the chain: the second
  -- window never ends, `resume` is never called, and the display stays dark until the player
  -- reloads with no idea why. That is this codebase's characteristic failure and it must not be
  -- what a diagnostic command does -- least of all one that hides the display on purpose.
  describe("run() when something throws mid-measurement", function()
    local function drain(queue, clockRef)
      local guard = 0
      while #queue > 0 do
        guard = guard + 1
        assert.is_true(guard < 1000, "runaway scheduler: run() never finished")
        local job = table.remove(queue, 1)
        clockRef.now = clockRef.now + job.delay
        job.fn()
      end
    end

    -- opts: throwAt = "read" | "suspend"
    local function runWith(opts)
      local queue, clockRef = {}, { now = 0 }
      local env = { resumed = 0, reported = nil, suspended = false, reads = 0 }
      local kb = 1000
      local ok, why = MP.run({
        seconds = 4, interval = 2,
        now = function() return clockRef.now end,
        readKB = function()
          env.reads = env.reads + 1
          if opts.throwAt == "read" and env.reads == opts.onRead then error("client blew up", 0) end
          kb = kb + 50
          return kb
        end,
        schedule = function(s, fn) queue[#queue + 1] = { delay = s, fn = fn } end,
        suspend = function()
          if opts.throwAt == "suspend" then error("display blew up", 0) end
          env.suspended = true
        end,
        resume = function() env.resumed = env.resumed + 1 end,
        report = function(lines) env.reported = lines end,
      })
      drain(queue, clockRef)
      return ok, why, env
    end

    it("restores the display and says so when a reading throws", function()
      local ok, _, env = runWith{ throwAt = "read", onRead = 3 }
      assert.is_true(ok)
      assert.equal(1, env.resumed, "the display must be put back exactly once")
      assert.is_table(env.reported)
      assert.truthy(table.concat(env.reported, "\n"):find("stopped early", 1, true))
      assert.truthy(table.concat(env.reported, "\n"):find("client blew up", 1, true),
        "the reason has to reach the player, or the command just looks broken")
      assert.is_false(MP.isRunning(), "a run that died must not block the next one")
    end)

    -- The worst moment for it: suspend() is the call that darkens the display, so a throw here is
    -- the one that can leave it dark forever.
    it("restores the display when suspending it throws", function()
      local _, _, env = runWith{ throwAt = "suspend" }
      assert.equal(1, env.resumed)
      assert.truthy(table.concat(env.reported or {}, "\n"):find("The display is back", 1, true))
      assert.is_false(MP.isRunning())
    end)

    it("reports once, not once per remaining step, after it has given up", function()
      local reports = 0
      local queue, clockRef = {}, { now = 0 }
      local reads = 0
      MP.run({
        seconds = 6, interval = 2,
        now = function() return clockRef.now end,
        readKB = function()
          reads = reads + 1
          if reads >= 2 then error("still broken", 0) end
          return 1000
        end,
        schedule = function(s, fn) queue[#queue + 1] = { delay = s, fn = fn } end,
        suspend = function() end,
        resume = function() end,
        report = function() reports = reports + 1 end,
      })
      drain(queue, clockRef)
      assert.equal(1, reports)
    end)

    -- A run that died still has to hand the module back, or the command is dead for the session.
    it("accepts a fresh run after one has aborted", function()
      runWith{ throwAt = "read", onRead = 2 }
      local ok = MP.run({
        seconds = 0, interval = 2,
        now = function() return 0 end,
        readKB = function() return 1000 end,
        schedule = function() end,
        suspend = function() end, resume = function() end, report = function() end,
      })
      assert.is_true(ok)
    end)
  end)

  -- Knowing the render loop owns the growth is not knowing WHICH PART of it does, and the answer
  -- decides what gets rewritten. These are the numbers that say so.
  describe("phase accounting", function()
    after_each(function() MP.stopPhases() end)

    -- The off switch is the whole design: instrumentation left running would cost two heap reads
    -- per phase in the render loop, for ever, with nothing to say it was happening.
    it("is off until a measurement asks for it, and enter() costs nothing while off", function()
      assert.is_false(MP.isProfiling())
      assert.is_nil(MP.enter())
      assert.is_false(MP.leave("queue", 100), "a phase closed while off records nothing")
      assert.same({}, MP.stopPhases())
    end)

    it("records a call and its allocation once switched on", function()
      MP.startPhases()
      assert.is_true(MP.isProfiling())
      -- Collector paused for the measured span: allocating provokes GC steps of its own, and a
      -- phase that frees more than it allocates reads as zero. That is correct (positive steps
      -- only) and would make this assertion a coin toss.
      collectgarbage("stop")
      local mark = MP.enter()
      assert.is_number(mark)
      local sink = {}
      for i = 1, 200 do sink[i] = { i } end   -- allocate something real to attribute
      assert.is_true(MP.leave("simulate", mark))
      collectgarbage("restart")
      local rows = MP.stopPhases()
      assert.equal(1, #rows)
      assert.equal("simulate", rows[1].name)
      assert.equal(1, rows[1].calls)
      assert.is_true(rows[1].kb > 0, "200 tables have to show up as some kilobytes")
      assert.equal(#sink, 200)              -- keeps `sink` alive across the measurement
    end)

    it("sums repeat calls to the same phase and counts them", function()
      MP.startPhases()
      for _ = 1, 3 do MP.leave("build", MP.enter()) end
      local rows = MP.stopPhases()
      assert.equal(1, #rows)
      assert.equal(3, rows[1].calls)
    end)

    it("returns the phases heaviest first", function()
      MP.startPhases()
      MP.leave("cheap", MP.enter())
      collectgarbage("stop")
      local mark = MP.enter()
      local sink = {}
      for i = 1, 500 do sink[i] = { i } end
      MP.leave("simulate", mark)
      collectgarbage("restart")
      local rows = MP.stopPhases()
      assert.equal("simulate", rows[1].name, "the heaviest phase leads")
      assert.equal(#sink, 500)
    end)

    -- table.sort is not stable, so without an explicit tie-break two phases that allocated the same
    -- amount can come back in either order -- and a diagnostic that reorders itself between two runs
    -- of the same command is one nobody can compare. Registered in reverse so a comparator that
    -- only ranks by weight leaves them exactly wrong rather than accidentally right.
    it("breaks ties by name, so the same session reports the same order twice", function()
      MP.startPhases()
      for _, name in ipairs({ "zeta", "yankee", "xray", "whiskey", "victor", "uniform" }) do
        MP.leave(name, MP.enter())
      end
      local names = {}
      for _, row in ipairs(MP.stopPhases()) do names[#names + 1] = row.name end
      assert.same({ "uniform", "victor", "whiskey", "xray", "yankee", "zeta" }, names)
    end)

    it("switches itself off when the rows are taken", function()
      MP.startPhases()
      MP.stopPhases()
      assert.is_false(MP.isProfiling())
      assert.is_nil(MP.enter())
    end)

    it("phaseLines names each phase with a rate, a call count and a per-call cost", function()
      local rows = { { name = "simulate", kb = 400, calls = 80 } }
      local text = table.concat(MP.phaseLines(rows, 20), "\n")
      assert.truthy(text:find("where it went", 1, true))
      assert.truthy(text:find("simulate", 1, true))
      assert.truthy(text:find("20.0 KB/s", 1, true), "400 KB over 20s is 20 KB/s")
      assert.truthy(text:find("80 call(s)", 1, true))
      assert.truthy(text:find("5.00 KB each", 1, true))
    end)

    -- A report padded with "render:overlay 0.0 KB" for a renderer nobody switched on reads as
    -- though the measurement covered it. It did not.
    it("phaseLines says nothing at all when no phase ran", function()
      assert.same({}, MP.phaseLines({}, 20))
      assert.same({}, MP.phaseLines(nil, 20))
    end)

    it("phaseLines survives a zero-length window without dividing by it", function()
      local text = table.concat(MP.phaseLines({ { name = "build", kb = 5, calls = 0 } }, 0), "\n")
      assert.truthy(text:find("0.0 KB/s", 1, true))
      assert.truthy(text:find("0.00 KB each", 1, true))
    end)

    it("summarise folds the breakdown in under the two window lines", function()
      -- Local copy: `windowWithRate` belongs to the summarise() block above and is out of scope here.
      local function window(rate)
        local w = MP.newWindow()
        w:add(0, 1000)
        w:add(10, 1000 + rate * 10)
        return w
      end
      local lines = MP.summarise(window(100), window(10), 0,
                                 { { name = "simulate", kb = 400, calls = 80 } })
      local text = table.concat(lines, "\n")
      assert.truthy(text:find("display RUNNING", 1, true))
      assert.truthy(text:find("simulate", 1, true))
      assert.truthy(text:find("verdict:", 1, true))
    end)
  end)

  -- A run that hands back its rows but leaves accounting switched on is the silent version of this
  -- feature: everything still works, and the render loop quietly pays for it for ever.
  it("a finished run leaves phase accounting switched off", function()
    local queue, clockRef = {}, { now = 0 }
    local kb = 1000
    MP.run({
      seconds = 2, interval = 2,
      now = function() return clockRef.now end,
      readKB = function() kb = kb + 10; return kb end,
      schedule = function(s, fn) queue[#queue + 1] = { delay = s, fn = fn } end,
      suspend = function() end, resume = function() end, report = function() end,
    })
    assert.is_true(MP.isProfiling(), "the running window is profiled")
    while #queue > 0 do
      local job = table.remove(queue, 1)
      clockRef.now = clockRef.now + job.delay
      job.fn()
    end
    assert.is_false(MP.isProfiling(), "and it must not still be profiling afterwards")
  end)

  it("an aborted run leaves phase accounting switched off too", function()
    local queue, clockRef = {}, { now = 0 }
    local reads = 0
    MP.run({
      seconds = 4, interval = 2,
      now = function() return clockRef.now end,
      readKB = function()
        reads = reads + 1
        if reads == 3 then error("client blew up", 0) end
        return 1000 + reads
      end,
      schedule = function(s, fn) queue[#queue + 1] = { delay = s, fn = fn } end,
      suspend = function() end, resume = function() end, report = function() end,
    })
    while #queue > 0 do
      local job = table.remove(queue, 1)
      clockRef.now = clockRef.now + job.delay
      job.fn()
    end
    assert.is_false(MP.isProfiling())
  end)

  -- The rows have to be taken BEFORE the suspended window and carried into the summary. Dropping
  -- that hand-off costs nothing visible -- the run still completes, the verdict still prints -- and
  -- silently removes the only lines that say which part of the loop to rewrite.
  it("carries the running window's phase breakdown into the report", function()
    local queue, clockRef = {}, { now = 0 }
    local kb, reported = 1000, nil
    MP.run({
      seconds = 2, interval = 2,
      now = function() return clockRef.now end,
      readKB = function() kb = kb + 10; return kb end,
      schedule = function(s, fn) queue[#queue + 1] = { delay = s, fn = fn } end,
      suspend = function() end, resume = function() end,
      report = function(lines) reported = lines end,
    })
    -- A phase recorded during the running window, exactly as Display/Driver.lua does it.
    collectgarbage("stop")
    local mark = MP.enter()
    local sink = {}
    for i = 1, 400 do sink[i] = { i } end
    MP.leave("simulate", mark)
    collectgarbage("restart")
    assert.equal(400, #sink)

    while #queue > 0 do
      local job = table.remove(queue, 1)
      clockRef.now = clockRef.now + job.delay
      job.fn()
    end
    local text = table.concat(reported or {}, "\n")
    assert.truthy(text:find("where it went", 1, true), "the breakdown must reach the report")
    assert.truthy(text:find("simulate", 1, true))
  end)

  it("isRunning() is false before any run has started", function()
    assert.is_false(MP.isRunning())
  end)
  -- Which State question does one recompute pay for? The phase rows can say `simulate` cost N KB
  -- and nothing more; round 4 left 9.76 KB per recompute that the headless stack did not
  -- reproduce, and this is the instrument that places it instead of guessing.
  describe("attribute()", function()
    -- `seal` is the allocating member, and it sorts LAST by name: heaviest-first has to be doing
    -- the work for it to come out on top.
    local function fakeState()
      return {
        cooldown = function() return 0 end,                                 -- free
        buff = function() return 1, 2, 3 end,                               -- free
        seal = function() local t = {}; for i = 1, 50 do t[i] = i end; return t[1] and "SEAL" end, -- allocates
        power = function() return 100, 100 end,
      }
    end

    -- luacov's line hook allocates on every line, so under `make coverage` "free" is not
    -- measurable; the heavy row and the ordering still are.
    local hooked = debug.gethook() ~= nil

    it("charges each accessor's allocation to its name and restores the originals", function()
      local state = fakeState()
      local originals = { cooldown = state.cooldown, seal = state.seal }
      local result = MP.attribute(state, { "seal", "power", "cooldown", "buff", "missing" }, function()
        for _ = 1, 10 do state:cooldown("X"); state:seal() end
        state:buff("Y"); state:power("MANA")
      end)
      local rows = {}
      for _, row in ipairs(result.rows) do rows[row.name] = row end
      assert.equal(10, rows.cooldown.calls)
      assert.equal(10, rows.seal.calls)
      assert.equal(1, rows.buff.calls)
      assert.is_nil(rows.missing, "a member the state lacks is not a row")
      assert.is_true(rows.seal.kb > 0.5, "fifty-entry tables ten times must show")
      assert.is_true(hooked or rows.cooldown.kb < 0.05, "a free accessor reads as free")
      assert.is_true(result.attributed >= rows.seal.kb, "the sum covers the heavy row")
      assert.is_true(result.unattributed < result.total, "and the remainder is the rest")
      assert.equal("seal", result.rows[1].name, "heaviest first, whatever the name order says")
      assert.equal(originals.cooldown, state.cooldown, "restored")
      assert.equal(originals.seal, state.seal, "restored")
    end)

    it("orders equal rows by name, so two readings print alike", function()
      local state = fakeState()
      local free = { "power", "cooldown", "buff" }
      local names = {}
      for round = 1, 2 do
        local result = MP.attribute(state, free, function()
          state:power("MANA"); state:cooldown("X"); state:buff("Y")
        end)
        names[round] = {}
        for i, row in ipairs(result.rows) do names[round][i] = row.name end
      end
      if not hooked then assert.same({ "buff", "cooldown", "power" }, names[1]) end
      assert.same(names[1], names[2])
    end)

    it("stops the collector for the span and restarts it, on the error path too", function()
      local calls = {}
      local function collector(what)
        calls[#calls + 1] = what
        if what == "count" then return 100 end
      end
      MP.attribute(fakeState(), { "buff" }, function() end, collector)
      assert.same({ "stop", "count", "count", "restart" }, calls)
      calls = {}
      MP.attribute(fakeState(), { "buff" }, function() error("boom") end, collector)
      assert.same({ "stop", "count", "count", "restart" }, calls)
    end)

    it("passes every return value through, so the run behaves as it would unwrapped", function()
      local state = fakeState()
      local a, b, c, p1, p2
      MP.attribute(state, { "buff", "power" }, function()
        a, b, c = state:buff("Y")
        p1, p2 = state:power("MANA")
      end)
      assert.same({ 1, 2, 3 }, { a, b, c })
      assert.same({ 100, 100 }, { p1, p2 })
    end)

    it("reports the run's total and what no accessor accounts for", function()
      local state = fakeState()
      local result = MP.attribute(state, { "cooldown" }, function()
        local own = {}
        for i = 1, 200 do own[i] = { i } end                              -- the run's own cost
        state:cooldown(#own)
      end)
      assert.is_true(result.total > 1, "total covers the run's own allocation")
      assert.is_true(result.unattributed > 1, "and it is reported as unattributed")
      assert.is_true(hooked or result.attributed < 0.05)
    end)

    it("restores the state and says why when the run throws", function()
      local state = fakeState()
      local original = state.buff
      local result, err = MP.attribute(state, { "buff" }, function() error("boom") end)
      assert.is_nil(result)
      assert.matches("boom", err)
      assert.equal(original, state.buff)
    end)

    it("refuses incomplete wiring rather than wrapping nothing", function()
      assert.is_nil((MP.attribute(nil, {}, function() end)))
      assert.is_nil((MP.attribute({}, nil, function() end)))
      assert.is_nil((MP.attribute({}, {}, nil)))
    end)

    it("prints the rows that ran, free ones included, and the remainder", function()
      local lines = MP.attributionLines({
        total = 9.76, attributed = 4.5, unattributed = 5.26,
        rows = { { name = "buff", kb = 4.5, calls = 30 }, { name = "cooldown", kb = 0, calls = 40 },
                 { name = "seal", kb = 0, calls = 0 } },
      }, "PALADIN_EXODIN", 5)
      assert.matches("^one recompute of PALADIN_EXODIN at depth 5 allocated 9%.76 KB", lines[1])
      assert.matches("^  buff%s+4%.50 KB over  30 call%(s%), 0%.150 KB each", lines[2])
      assert.matches("^  cooldown%s+0%.00 KB over  40 call%(s%)", lines[3], "asked forty times, free: worth a line")
      assert.matches("^  unattributed%s+5%.26 KB", lines[4])
      assert.equal(4, #lines, "a member that never ran is not listed")
      assert.same({}, MP.attributionLines(nil))
    end)
  end)

end)
