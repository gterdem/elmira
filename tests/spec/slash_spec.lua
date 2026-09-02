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

  it("'setup' returns the not-yet-available line naming its milestone", function()
    local lines = Slash.run("setup")
    assert.equal(1, #lines)
    assert.matches("not available yet %(M4%)", lines[1])
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
end)
