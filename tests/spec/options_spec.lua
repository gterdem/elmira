local helper = require("tests.helper")

-- Elmira/Options/Options.lua — the settings UI (AceConfig-3.0). This spec covers only the
-- overlay/peripheral-cue section (`overlayGroup()`), reached through `Options.table()`. The
-- options table is plain data: `type = "group"`, `args = { ... get = fn, set = fn ... }`, so a spec
-- can call a row's `get`/`set` directly without AceConfig, AceConfigDialog or any frame.
--
-- Why this file exists: a pre-commit audit found that deleting `ns.Display.refresh()` from the cue
-- toggle's `set` handler breaks NO test — yet without that line the fix for "peripheral cue never
-- fires in combat" never reaches the renderer, because the driver only repaints when the queue
-- itself changes and turning a cue on changes neither the queue nor the build. That is exactly the
-- shape this project keeps shipping: a covered function with an uncovered call site. Every test
-- below was confirmed to fail against a deliberately broken Options.lua before being kept (see the
-- task report for the list of mutations tried).
describe("Options (overlay/peripheral cues)", function()
  local Options, ns

  -- Loads Options.lua fresh with the real Overlay.lua underneath it (so isEnabled/SetEnabled are
  -- the real logic under test, not a mock of themselves) and the real Colors.lua (Options.table()
  -- calls ns.Colors.wrap(...) at build time). ns.L is stubbed with the same identity fallback
  -- Core/Slash.lua and Core/API.lua install for real, so L["some string"] just returns the string.
  before_each(function()
    ns = helper.reset()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Display/Overlay.lua")
    ns.db = { profile = { overlay = { cues = {} } } }

    -- Overlay.Flare would call Overlay.Create(), which calls CreateFrame — not available to a Core
    -- spec (no wow_mock is loaded here). Stub it exactly like tests/spec/slash_spec.lua's "debug
    -- cues" block does: count calls instead of animating a frame that cannot exist.
    ns.Overlay.Flare = function() return true end

    ns.Display = {
      activeBuild = function() return { visuals = { cues = {} } } end,
      refresh = function() end,
    }

    Options = helper.load("Elmira/Options/Options.lua")
  end)

  -- Cue fixtures. `cueA` is the ordinary fireable case (event = "now_slot"); `cueB` is the
  -- event = "check" case that Overlay.availableCues() always marks unavailable until M5b
  -- (ADR-0009) — the wrong-soul-shaped case for this file, i.e. "looks like a cue, cannot fire".
  local function cueA()
    return { event = "now_slot", spell = "EXORCISM", reason = "Exorcism up", edge = "left",
             color = { 1, 1, 1 } }
  end
  local function cueB()
    return { event = "check", key = "SEAL_DROPPED", reason = "Seal dropped" }
  end

  local function stubCues(list)
    ns.Display.activeBuild = function() return { visuals = { cues = list } } end
  end

  -- Rebuilds Options.table() (overlayGroup() runs at build time, so a fresh call is needed after
  -- changing which cues the active build suggests) and returns just the overlay group's args.
  local function overlayArgs()
    return Options.table().args.overlay.args
  end

  -- Counts calls to ns.Display.refresh() across the test, restoring nothing (each test gets a
  -- fresh ns from before_each).
  local function countRefreshCalls()
    local n = 0
    ns.Display.refresh = function() n = n + 1 end
    return function() return n end
  end

  local function countFlareCalls()
    local n = 0
    ns.Overlay.Flare = function() n = n + 1; return true end
    return function() return n end
  end

  describe("an available cue's row", function()
    it("calls ns.Display.refresh() when ticked -- regression guard for the audit finding", function()
      stubCues{ cueA() }
      local refreshCalls = countRefreshCalls()
      local row = overlayArgs().cue1
      row.set(nil, true)
      assert.equal(1, refreshCalls())
    end)

    it("calls ns.Display.refresh() when unticked too", function()
      stubCues{ cueA() }
      local row = overlayArgs().cue1
      row.set(nil, true)
      local refreshCalls = countRefreshCalls()
      row.set(nil, false)
      assert.equal(1, refreshCalls())
    end)

    it("calls Overlay.SetEnabled(cue, true) when ticked, and Overlay.SetEnabled(cue, false) when unticked", function()
      stubCues{ cueA() }
      local calls = {}
      local realSetEnabled = ns.Overlay.SetEnabled
      ns.Overlay.SetEnabled = function(cue, v, opts)
        calls[#calls + 1] = v
        return realSetEnabled(cue, v, opts)
      end
      local row = overlayArgs().cue1
      row.set(nil, true)
      row.set(nil, false)
      assert.same({ true, false }, calls)
    end)

    it("fires the one-shot preview flare on enable", function()
      stubCues{ cueA() }
      local flareCalls = countFlareCalls()
      local row = overlayArgs().cue1
      row.set(nil, true)
      assert.equal(1, flareCalls())
    end)

    it("does NOT flare on disable", function()
      stubCues{ cueA() }
      local row = overlayArgs().cue1
      row.set(nil, true)
      local flareCalls = countFlareCalls()
      row.set(nil, false)
      assert.equal(0, flareCalls())
    end)

    it("get() reflects Overlay.isEnabled()", function()
      stubCues{ cueA() }
      local row = overlayArgs().cue1
      assert.is_false(row.get())
      row.set(nil, true)
      assert.is_true(row.get())
      row.set(nil, false)
      assert.is_false(row.get())
    end)
  end)

  describe("an unavailable cue's row (event = \"check\", ADR-0009)", function()
    it("is disabled = true", function()
      stubCues{ cueB() }
      local row = overlayArgs().cue1
      assert.is_true(row.disabled)
    end)

    it("set is inert: enabling it writes nothing into db.profile.overlay.cues", function()
      stubCues{ cueB() }
      local row = overlayArgs().cue1
      row.set(nil, true)
      assert.same({}, ns.db.profile.overlay.cues)
    end)

    it("get always answers false, regardless of what set was asked to do", function()
      stubCues{ cueB() }
      local row = overlayArgs().cue1
      row.set(nil, true)
      assert.is_false(row.get())
    end)
  end)

  describe("a build suggesting no cues", function()
    it("renders the \"no peripheral cues\" description instead of an empty group", function()
      stubCues{}
      local args = overlayArgs()
      assert.equal("description", args.none.type)
      assert.equal("This build suggests no peripheral cues.", args.none.name)
      assert.is_nil(args.cue1)
    end)
  end)

  describe("a build suggesting at least one cue", function()
    it("does not render the \"no peripheral cues\" description", function()
      stubCues{ cueA() }
      local args = overlayArgs()
      assert.is_nil(args.none)
    end)
  end)
end)
