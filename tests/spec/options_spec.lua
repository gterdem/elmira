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

  -- An AVAILABLE cue renders as an inline group (toggle + colour + edge + intensity); an unavailable
  -- one stays a single disabled toggle, so those tests still read args.cueN directly.
  local function cueRow(n)
    return overlayArgs()["cue" .. (n or 1)].args
  end
  local function enabledToggle(n) return cueRow(n).enabled end

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

  -- Every existing preview assertion below only ever counted Flare() calls, so `preview()` could be
  -- reduced to `ns.Overlay.Flare()` -- no arguments at all -- and the count-only assertions would
  -- stay green: Flare() defaults nils to the left edge and Colors.HIGHLIGHT, so the CHANGELOG's
  -- promise that each change "flares once as you make it" in the CHOSEN colour/edge/intensity could
  -- silently break. This records the (edge, color, intensity) triple of every call so tests can
  -- assert on what preview() actually told Flare to draw.
  local function recordFlareCalls()
    local calls = {}
    ns.Overlay.Flare = function(edge, color, intensity)
      calls[#calls + 1] = { edge = edge, color = color, intensity = intensity }
      return true
    end
    return calls
  end

  describe("an available cue's row", function()
    it("calls ns.Display.refresh() when ticked -- regression guard for the audit finding", function()
      stubCues{ cueA() }
      local refreshCalls = countRefreshCalls()
      local row = enabledToggle()
      row.set(nil, true)
      assert.equal(1, refreshCalls())
    end)

    it("calls ns.Display.refresh() when unticked too", function()
      stubCues{ cueA() }
      local row = enabledToggle()
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
      local row = enabledToggle()
      row.set(nil, true)
      row.set(nil, false)
      assert.same({ true, false }, calls)
    end)

    it("fires the one-shot preview flare on enable", function()
      stubCues{ cueA() }
      local flareCalls = countFlareCalls()
      local row = enabledToggle()
      row.set(nil, true)
      assert.equal(1, flareCalls())
    end)

    it("the preview flare on enable is called with the cue's own edge/colour/intensity, not blank defaults", function()
      stubCues{ cueA() }
      local calls = recordFlareCalls()
      local row = enabledToggle()
      row.set(nil, true)
      assert.equal(1, #calls)
      assert.equal("left", calls[1].edge)
      assert.same({1, 1, 1}, calls[1].color)
      assert.equal(0.5, calls[1].intensity)
    end)

    it("does NOT flare on disable", function()
      stubCues{ cueA() }
      local row = enabledToggle()
      row.set(nil, true)
      local flareCalls = countFlareCalls()
      row.set(nil, false)
      assert.equal(0, flareCalls())
    end)

    it("get() reflects Overlay.isEnabled()", function()
      stubCues{ cueA() }
      local row = enabledToggle()
      assert.is_false(row.get())
      row.set(nil, true)
      assert.is_true(row.get())
      row.set(nil, false)
      assert.is_false(row.get())
    end)
  end)

  describe("an available cue's row shape", function()
    it("is an inline group named for the cue, not a bare toggle", function()
      stubCues{ cueA() }
      local row = overlayArgs().cue1
      assert.equal("group", row.type)
      assert.is_true(row.inline)
      assert.equal("Exorcism up", row.name)
    end)

    it("the enabled toggle carries its own widget type, name and the cue's reason as its description", function()
      stubCues{ cueA() }
      local row = enabledToggle()
      assert.equal("toggle", row.type)
      assert.equal("Enabled", row.name)
      assert.equal("Exorcism up", row.desc)
    end)
  end)

  describe("an available cue's appearance controls (colour/edge/intensity)", function()
    it("carry the widget type AceConfig needs to render them", function()
      stubCues{ cueA() }
      local row = cueRow()
      assert.equal("color", row.color.type)
      assert.equal("select", row.edge.type)
      assert.equal("range", row.intensity.type)
    end)

    it("are disabled while the cue is off, and enabled once it is turned on", function()
      stubCues{ cueA() }
      local row = cueRow()
      assert.is_true(row.color.disabled())
      assert.is_true(row.edge.disabled())
      assert.is_true(row.intensity.disabled())

      enabledToggle().set(nil, true)
      row = cueRow()
      assert.is_false(row.color.disabled())
      assert.is_false(row.edge.disabled())
      assert.is_false(row.intensity.disabled())
    end)

    it("the colour widget's get returns r, g, b as three separate values", function()
      stubCues{ cueA() }
      local r, g, b = cueRow().color.get()
      assert.same({1, 1, 1}, {r, g, b})
    end)

    it("the colour widget's set stores {r,g,b} and fires exactly one preview flare", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)
      local flareCalls = countFlareCalls()
      cueRow().color.set(nil, 0.1, 0.2, 0.3)
      assert.equal(1, flareCalls())
      local r, g, b = cueRow().color.get()
      assert.same({0.1, 0.2, 0.3}, {r, g, b})
    end)

    it("the colour widget's preview flare is called WITH the newly chosen colour, not a blank default", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)
      local calls = recordFlareCalls()
      cueRow().color.set(nil, 0.1, 0.2, 0.3)
      assert.equal(1, #calls)
      assert.same({0.1, 0.2, 0.3}, calls[1].color)
    end)

    it("the edge widget carries a description", function()
      stubCues{ cueA() }
      assert.equal("Which screen edge this cue flares on.", cueRow().edge.desc)
    end)

    it("the edge widget's get reflects Overlay.GetOption, and set stores + previews once", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)
      assert.equal("left", cueRow().edge.get())
      local flareCalls = countFlareCalls()
      cueRow().edge.set(nil, "right")
      assert.equal(1, flareCalls())
      assert.equal("right", cueRow().edge.get())
    end)

    it("the edge widget's preview flare is called WITH the newly chosen edge, not a blank default", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)
      local calls = recordFlareCalls()
      cueRow().edge.set(nil, "right")
      assert.equal(1, #calls)
      assert.equal("right", calls[1].edge)
    end)

    it("the edge dropdown's values come from Overlay.EDGES, not a hardcoded list", function()
      stubCues{ cueA() }
      local values = cueRow().edge.values()
      -- Human-friendly labels come from EDGE_LABELS, keyed by Overlay.EDGES.
      assert.equal("Left", values.left)
      assert.equal("Right", values.right)
      assert.equal("Top", values.top)
      assert.equal("Bottom", values.bottom)
      assert.is_nil(values.diagonal)

      -- Prove it is not hardcoded: grow a COPY of EDGES and confirm the dropdown grows with it.
      -- (Options.lua reads ns.Overlay.EDGES fresh every time edgeChoices() runs, so replacing the
      -- table the real module already owns is enough -- no source file is touched.)
      local grown = {}
      for _, e in ipairs(ns.Overlay.EDGES) do grown[#grown + 1] = e end
      grown[#grown + 1] = "diagonal"
      ns.Overlay.EDGES = grown

      values = cueRow().edge.values()
      assert.equal("diagonal", values.diagonal)
    end)

    it("the intensity widget's get reflects Overlay.GetOption, and set stores + previews once", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)
      assert.equal(0.5, cueRow().intensity.get())
      local flareCalls = countFlareCalls()
      cueRow().intensity.set(nil, 0.9)
      assert.equal(1, flareCalls())
      assert.equal(0.9, cueRow().intensity.get())
    end)

    it("the intensity widget's preview flare is called WITH the newly chosen intensity, not a blank default", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)
      local calls = recordFlareCalls()
      cueRow().intensity.set(nil, 0.9)
      assert.equal(1, #calls)
      assert.equal(0.9, calls[1].intensity)
    end)

    it("changing appearance previews but touches neither enablement nor the queue", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)   -- baseline enable, its own refresh/preview already counted
      local refreshCalls = countRefreshCalls()
      local setEnabledCalls = 0
      local realSetEnabled = ns.Overlay.SetEnabled
      ns.Overlay.SetEnabled = function(...)
        setEnabledCalls = setEnabledCalls + 1
        return realSetEnabled(...)
      end

      cueRow().color.set(nil, 0.4, 0.5, 0.6)
      cueRow().edge.set(nil, "top")
      cueRow().intensity.set(nil, 0.8)

      assert.equal(0, refreshCalls())
      assert.equal(0, setEnabledCalls)
    end)
  end)

  -- Overlay.SetOption returns false (and writes nothing) when the cue is OFF -- opting out deletes
  -- the whole record (ADR-0009, "absent means never asked for") -- or when the value is invalid (an
  -- edge Flare cannot draw). The three appearance setters guard `preview()` behind that return value
  -- so the user is never shown a flare for a change that was refused. `disabled` on the row only
  -- greys the widget for AceConfigDialog; `set` stays directly callable (profile import and
  -- Elmira.API reach it the same way a test does), so the guard has to live in `set` itself.
  describe("appearance setters refuse to preview a refused write", function()
    it("colour: cue OFF, set() produces zero flares", function()
      stubCues{ cueA() }
      local flareCalls = countFlareCalls()
      cueRow().color.set(nil, 0.4, 0.5, 0.6)
      assert.equal(0, flareCalls())
    end)

    it("edge: cue OFF, set() produces zero flares", function()
      stubCues{ cueA() }
      local flareCalls = countFlareCalls()
      cueRow().edge.set(nil, "top")
      assert.equal(0, flareCalls())
    end)

    it("intensity: cue OFF, set() produces zero flares", function()
      stubCues{ cueA() }
      local flareCalls = countFlareCalls()
      cueRow().intensity.set(nil, 0.8)
      assert.equal(0, flareCalls())
    end)

    it("edge: cue ON but given a value outside Overlay.EDGES produces zero flares, and does not store it", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)
      local flareCalls = countFlareCalls()
      cueRow().edge.set(nil, "diagonal")
      assert.equal(0, flareCalls())
      assert.equal("left", cueRow().edge.get())
    end)

    it("edge: cue ON with a value inside Overlay.EDGES previews exactly once, with that edge", function()
      stubCues{ cueA() }
      enabledToggle().set(nil, true)
      local calls = recordFlareCalls()
      cueRow().edge.set(nil, "right")
      assert.equal(1, #calls)
      assert.equal("right", calls[1].edge)
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

    it("stays a plain disabled toggle -- no colour/edge/intensity controls to grey out", function()
      stubCues{ cueB() }
      local row = overlayArgs().cue1
      assert.equal("toggle", row.type)
      assert.is_nil(row.args)
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
