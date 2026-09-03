local helper = require("tests.helper")

describe("Core.Slash", function()
  local Slash

  before_each(function()
    helper.reset()
    Slash = helper.load("Elmira/Core/Slash.lua")
  end)

  local function hasLineMatching(lines, pattern)
    for _, l in ipairs(lines) do
      if l:match(pattern) then return true end
    end
    return false
  end

  it("help output lists the debug command", function()
    assert.is_true(hasLineMatching(Slash.run(""), "debug"))
  end)

  it("empty input and 'help' produce byte-identical output (fixed order, never pairs())", function()
    local a = table.concat(Slash.run(""), "\n")
    local b = table.concat(Slash.run("help"), "\n")
    assert.equal(a, b)
  end)

  it("help output is stable across repeated calls", function()
    local a = table.concat(Slash.run(""), "\n")
    local b = table.concat(Slash.run(""), "\n")
    assert.equal(a, b)
  end)

  it("'debug' with no subcommand returns the usage line", function()
    local lines = Slash.run("debug")
    assert.is_true(hasLineMatching(lines, "^Usage: /elm debug"))
  end)

  it("'debug perf' returns at least one line and does not error", function()
    local lines = Slash.run("debug perf")
    assert.is_true(#lines >= 1)
  end)

  it("'debug bars' reports zero providers when none are registered", function()
    local lines = Slash.run("debug bars")
    assert.is_true(hasLineMatching(lines, "bar providers: 0"))
  end)

  it("verb matching is case-insensitive", function()
    local lower = table.concat(Slash.run("debug state"), "\n")
    local upper = table.concat(Slash.run("DEBUG state"), "\n")
    assert.equal(lower, upper)
  end)

  it("unknown input returns exactly one line and does not error", function()
    local lines = Slash.run("nonsense")
    assert.equal(1, #lines)
    assert.equal("Unknown command 'nonsense'. Type /elm for help.", lines[1])
  end)

  -- Was "not available yet (M4)" until M4 landed. Rewritten rather than deleted: the property worth
  -- keeping is that the command DEGRADES with a designed line instead of erroring when the module
  -- behind it is absent, which is what this spec's Core-only harness reproduces.
  it("'setup' degrades with a designed line when the wizard is not loaded", function()
    local lines = Slash.run("setup")
    assert.equal(1, #lines)
    assert.equal("setup: the wizard is not loaded", lines[1])
  end)

  it("'profile' and 'advise' degrade the same way rather than erroring", function()
    assert.equal("profile: no data pack for your class", Slash.run("profile")[1])
    assert.equal("advise: the advisor is not loaded", Slash.run("advise")[1])
  end)

  it("'sim' names a non-integer milestone label correctly", function()
    local lines = Slash.run("sim")
    assert.matches("not available yet %(M5c%)", lines[1])
  end)

  -- M2 acceptance runs through this command, so it must degrade with a DIAGNOSIS rather than an
  -- empty list — "nothing happened" is the shape that wastes an in-game round trip.
  describe("debug queue", function()
    it("says which builds exist when asked for one that does not", function()
      local ns = helper.ns()
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.API = { GetProviders = function() return { PALADIN = { builds = { PALADIN_EXODIN = {} } } } end,
                 GetState = function() return {} end }
      local out = table.concat(Slash.run("debug queue NOPE"), "\n")
      assert.truthy(out:find("PALADIN_EXODIN", 1, true), out)
    end)

    it("reports no builds rather than printing an empty queue", function()
      local ns = helper.ns()
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.API = { GetProviders = function() return {} end, GetState = function() return {} end }
      local out = table.concat(Slash.run("debug queue"), "\n")
      assert.truthy(out:find("no builds registered", 1, true), out)
    end)

    -- The player's own feedback after the acceptance run: copying chat output mid-combat is not
    -- workable. The queue has to reach the saved file, not just the chat frame.
    it("captures the queue as data for the dump file", function()
      local ns = helper.ns()
      ns.Schema = { compile = function(b) return { entries = { { spell = "EXORCISM", test = function() return true end } } } end,
                    errorLines = function() return {} end }
      ns.Simulation = { queue = function() return { { spell = "EXORCISM", t = 0 } } end }
      ns.API = { GetState = function() return { usable = function() return true end,
                                                cooldown = function() return 0 end,
                                                inCombat = function() return true end } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      assert.is_table(snap.PALADIN_EXODIN)
      assert.equal("EXORCISM", snap.PALADIN_EXODIN.queue[1].spell)
      assert.equal("EXORCISM", snap.PALADIN_EXODIN.entries[1].spell)
      assert.is_true(snap.PALADIN_EXODIN.inCombat)
    end)

    -- Contract: entries[i].usable is a real boolean for any entry that has a spell — true when the
    -- state reports it usable, and exactly `false` (never nil) when it does not. The bug this guards
    -- against was `entry.spell and (state:usable(entry.spell) == true) or nil`, which in Lua collapses
    -- `false or nil` to nil, so a not-usable spell read back as "not asked" instead of "not usable".
    it("records usable=true (a real boolean) for a spell the state reports usable", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return { entries = {
        { spell = "EXORCISM", test = function() return true end },
      } } end, errorLines = function() return {} end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {
        usable = function() return true end,
        cooldown = function() return 3 end,
        inCombat = function() return true end,
      } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      local entry = snap.PALADIN_EXODIN.entries[1]
      assert.is_true(entry.usable)
    end)

    it("records usable=false, never nil, for a spell the state reports as not usable", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return { entries = {
        { spell = "AVENGERS_SHIELD", test = function() return true end },
      } } end, errorLines = function() return {} end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {
        usable = function() return false end,
        cooldown = function() return 5 end,
        inCombat = function() return true end,
      } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      local entry = snap.PALADIN_EXODIN.entries[1]
      -- assert.falsy would also pass for nil, which is exactly the bug this test exists to catch —
      -- so the check has to distinguish false from nil explicitly.
      assert.is_false(entry.usable, "a not-usable spell must record usable=false, not nil")
      assert.is_not_nil(entry.usable, "nil means \"not asked\"; this spell WAS asked and said no")
    end)

    it("keeps a spell's cooldown of exactly 0 as 0, not nil or false", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return { entries = {
        { spell = "EXORCISM", test = function() return true end },
      } } end, errorLines = function() return {} end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {
        usable = function() return true end,
        cooldown = function() return 0 end,
        inCombat = function() return true end,
      } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      assert.equal(0, snap.PALADIN_EXODIN.entries[1].cooldown)
    end)

    -- Contract: an item entry has no spell to ask about, so usable and cooldown are nil — reserved
    -- for "not asked" rather than repurposed as a false verdict on a spell that was never in play.
    it("leaves usable and cooldown nil for an entry with no spell (an item entry)", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return { entries = {
        { item = 13 },
      } } end, errorLines = function() return {} end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {
        -- Return truthy values on purpose: a correct implementation gates on entry.spell existing,
        -- not on what these would answer if asked.
        usable = function() return true end,
        cooldown = function() return 42 end,
        inCombat = function() return true end,
      } end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      local entry = snap.PALADIN_EXODIN.entries[1]
      assert.equal(13, entry.item)
      assert.is_nil(entry.usable)
      assert.is_nil(entry.cooldown)
    end)

    it("records a validation failure instead of an empty queue", function()
      local ns = helper.ns()
      ns.Schema = { compile = function() return nil, { { message = "bad" } } end,
                    errorLines = function() return { "entry 1: bad" } end }
      ns.Simulation = { queue = function() return {} end }
      ns.API = { GetState = function() return {} end }
      local snap = ns.queueSnapshot({ builds = { PALADIN_EXODIN = {} } })
      assert.same({ "entry 1: bad" }, snap.PALADIN_EXODIN.error)
    end)

    -- Caught by luacheck as "never set", but it was a real defect: `local a, b = x and x:match(...)`
    -- truncates to one value, so every recorded mark would have been unlabelled.
    it("keeps the label given to rec mark", function()
      local ns = helper.ns()
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset(); ns.Recorder.start(0)
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.API = { GetProviders = function() return { PALADIN = { spells = {}, sets = {} } } end,
                 GetState = function() return {} end }
      ns.captureMark = function() return {} end

      Slash.run("rec mark 4of9-t3")
      assert.equal("4of9-t3", ns.Recorder.marks()[1].label)
    end)

    -- The first live run was started mid-combat, so its baseline mark was a combat snapshot and
    -- meant something different from every mark after it.
    it("refuses to start recording while in combat", function()
      local ns = helper.ns()
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset()
      ns.API = { GetState = function() return { inCombat = function() return true end } end,
                 GetProviders = function() return {} end }
      local out = table.concat(Slash.run("rec start"), "\n")
      assert.truthy(out:find("in combat", 1, true), out)
      assert.is_false(ns.Recorder.isRecording())
    end)

    it("starts out of combat and prints the plan", function()
      local ns = helper.ns()
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset()
      ns.API = { GetState = function() return { inCombat = function() return false end } end,
                 GetProviders = function() return {} end }
      local out = table.concat(Slash.run("rec start"), "\n")
      assert.is_true(ns.Recorder.isRecording())
      assert.truthy(out:find("baseline", 1, true), out)
      assert.truthy(out:find("/reload", 1, true), out)
    end)

    it("lists queue as an available debug subcommand", function()
      local out = table.concat(Slash.run("debug"), "\n")
      assert.truthy(out:find("queue", 1, true), out)
    end)
  end)

  -- Contract (docs/01 §2, rule 3): ns.now() is the addon's single source of time. It reads
  -- ns.API.GetState():now() and never calls the client's GetTime() directly. Nothing ever assigned
  -- ns.now, and every call site guarded it as `ns.now and ns.now() or 0`, so a real 4-fight recording
  -- stamped every mark at=0, elapsed=0, startedAt=0 — a recording with no time axis at all.
  describe("ns.now (the recorder's clock)", function()
    it("always exists and always returns a number, never nil", function()
      local ns = helper.ns()
      assert.is_function(ns.now)
      assert.is_number(ns.now())
    end)

    it("returns 0 when ns.API itself is not set yet (pre-OnInitialize)", function()
      local ns = helper.ns()
      ns.API = nil
      assert.equal(0, ns.now())
    end)

    it("returns 0 when ns.API is set but GetState() has nothing to give yet", function()
      local ns = helper.ns()
      ns.API = { GetState = function() return nil end }
      assert.equal(0, ns.now())
    end)

    -- The direct test for "reads from the injected state, never GetTime()": rig GetTime() to answer
    -- with a value nothing in the test set up, then prove ns.now() answers with the state's value
    -- instead. If ns.now() ever called GetTime() directly, this would observe the sentinel, not the
    -- state's clock.
    it("reads the time from ns.API.GetState():now(), not from GetTime()", function()
      local ns = helper.ns()
      local clock = { _now = 4242 }
      function clock:now() return self._now end
      ns.API = { GetState = function() return clock end }
      local realGetTime = _G.GetTime
      _G.GetTime = function() return 999999 end
      local result = ns.now()
      _G.GetTime = realGetTime
      assert.equal(4242, result)
    end)

    -- Drives the actual /elm rec start and /elm rec mark paths, since those are the call sites the
    -- live bug broke. A fake clock that changes between calls is what catches a hard-coded 0 or an
    -- unassigned ns.now — a spec that only checks "at is a number" would pass on either.
    it("stamps rec marks with the real elapsed time, and different marks get different `at`", function()
      local ns = helper.ns()
      local clock = { _now = 100 }
      function clock:now() return self._now end
      function clock:inCombat() return false end
      ns.API = { GetState = function() return clock end,
                 GetProviders = function() return { PALADIN = { spells = {}, sets = {} } } end }
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.Recorder = helper.load("Elmira/Core/Recorder.lua")
      ns.Recorder.reset()
      ns.captureMark = function() return {} end

      local startOut = table.concat(Slash.run("rec start"), "\n")
      assert.is_true(ns.Recorder.isRecording(), startOut)

      clock._now = 130
      Slash.run("rec mark first")
      clock._now = 175
      Slash.run("rec mark second")

      local marks = ns.Recorder.marks()
      assert.equal(2, #marks)
      assert.equal(130, marks[1].at)
      assert.equal(175, marks[2].at)
      assert.is_not.equal(marks[1].at, marks[2].at,
        "two marks taken at different times must carry different `at` values")
      assert.equal(30, marks[1].elapsed, "elapsed is `at` minus the recording's startedAt (100)")
      assert.equal(75, marks[2].elapsed)
    end)
  end)

  it("'debug swing' degrades with a designed line when the swing adapter is absent", function()
    local lines = Slash.run("debug swing")
    assert.equal(1, #lines)
    assert.equal("swing: adapter not loaded", lines[1])
  end)

  it("'debug' usage line mentions cues (peripheral cue diagnostics)", function()
    local lines = Slash.run("debug")
    assert.is_true(hasLineMatching(lines, "cues"))
  end)

  it("'debug cues' degrades with a designed line when the overlay is not loaded", function()
    local ns = helper.ns()
    assert.is_nil(ns.Overlay)
    local lines = Slash.run("debug cues")
    assert.same({ "cues: overlay not loaded" }, lines)
  end)

  -- Drives Overlay.lua for real (loaded fresh per test) rather than faking its output, so these
  -- tests catch the two fixed defects: TestFire silently attributing a bad index to cue 1, and a
  -- test-fired `event = "check"` cue printing a bare success line that contradicts the options
  -- screen (ADR-0009: check cues stay inert until M5b).
  describe("debug cues", function()
    local ns, calls

    -- Cue 1 is a now_slot cue (the ordinary, fireable case). Cue 2 is an event="check" cue, which
    -- Overlay.availableCues() always marks unavailable — Core/Checks.lua does not exist until M5b.
    local function cues()
      return {
        { event = "now_slot", spell = "EXORCISM", reason = "Exorcism up", edge = "left", color = { 1, 1, 1 } },
        { event = "check", spell = "SEAL_OF_MARTYRDOM", reason = "Seal dropped" },
      }
    end

    before_each(function()
      ns = helper.ns()
      helper.load("Elmira/Display/Overlay.lua")
      ns.db = { profile = { overlay = { cues = {} } } }
      ns.Display = { activeBuild = function() return { visuals = { cues = cues() } } end }
      -- Stubbed so no frame is ever created (Core specs must stay WoW-API-free) and so a flare can
      -- be counted instead of animated.
      calls = 0
      ns.Overlay.Flare = function() calls = calls + 1; return true end
    end)

    local function enableCue(id)
      ns.db.profile.overlay.cues[id] = { enabled = true, edge = "left", intensity = 0.5 }
    end

    it("lists each cue and marks the check cue UNAVAILABLE with its reason", function()
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "1%. Exorcism up %[now_slot:EXORCISM%]"))
      assert.is_true(hasLineMatching(lines, "2%. Seal dropped %[check:SEAL_OF_MARTYRDOM%]"))
      assert.is_true(hasLineMatching(lines, "UNAVAILABLE: needs readiness checks %(M5b%)"))
    end)

    it("an enabled cue reports on, and reports last fired=never before anything has flared", function()
      enableCue("now_slot:EXORCISM")
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "on  edge=left"))
      assert.is_true(hasLineMatching(lines, "last fired=never"))
    end)

    -- Regression coverage for the deliberate `ns.now` guard in Overlay.Render/describe: no flare has
    -- happened yet, so lastFired must carry nothing for this cue. (The separate case of a flare
    -- recorded while no clock exists is Overlay's own contract and is covered in overlay_spec.)
    it("reports never for a cue that is enabled but has not matched the now-slot", function()
      enableCue("now_slot:EXORCISM")
      local lines = Slash.run("debug cues")
      assert.is_true(hasLineMatching(lines, "matches now%-slot=false  last fired=never"))
    end)

    it("reports a real elapsed time, not never, after a flare driven via Overlay.Render", function()
      local clock = { _now = 50 }
      function clock:now() return self._now end
      ns.API = { GetState = function() return clock end }
      enableCue("now_slot:EXORCISM")

      ns.Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(1, calls, "Render must flare the matching enabled now_slot cue exactly once")

      clock._now = 53
      local lines = Slash.run("debug cues")
      assert.is_false(hasLineMatching(lines, "last fired=never"))
      assert.is_true(hasLineMatching(lines, "last fired=3%.0s ago"))
    end)

    it("'debug cues 1' test-fires cue 1 and flares exactly once", function()
      local lines = Slash.run("debug cues 1")
      assert.equal(1, calls)
      assert.is_true(hasLineMatching(lines, "^test%-fired: Exorcism up$"))
    end)

    -- Fixed defect: `tonumber(index) or 1` silently fired cue 1 and attributed the flare to it for
    -- any non-numeric argument. The fix must refuse instead of guessing.
    it("regression: 'debug cues zzz' does not flare and reports it is not a cue number", function()
      local lines = Slash.run("debug cues zzz")
      assert.equal(0, calls, "a non-numeric argument must never flare any cue")
      assert.is_true(hasLineMatching(lines, "not a cue number: zzz"))
    end)

    -- Fixed defect: test-firing an event="check" cue printed a bare "test-fired: Seal dropped",
    -- which contradicts the options screen telling the user that cue cannot fire (ADR-0009). The
    -- renderer test still flares (that is the point of the command), but the line must say so.
    it("regression: test-firing the check cue still flares but says it will not fire in play", function()
      local lines = Slash.run("debug cues 2")
      assert.equal(1, calls, "TestFire answers \"can this edge flare at all\" even for an unavailable cue")
      assert.is_true(hasLineMatching(lines, "^test%-fired: Seal dropped %(needs readiness checks %(M5b%)"))
      assert.is_true(hasLineMatching(lines, "will not fire in play%)$"))
    end)

    it("'debug cues 99' reports no such cue and does not flare", function()
      local lines = Slash.run("debug cues 99")
      assert.equal(0, calls)
      assert.is_true(hasLineMatching(lines, "no cue 99"))
    end)
  end)
end)
