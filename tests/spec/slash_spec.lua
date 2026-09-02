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

    it("lists queue as an available debug subcommand", function()
      local out = table.concat(Slash.run("debug"), "\n")
      assert.truthy(out:find("queue", 1, true), out)
    end)
  end)
end)
