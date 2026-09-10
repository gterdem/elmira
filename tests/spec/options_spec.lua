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
describe("Options (the settings pages)", function()
  local Options, ns

  -- Loads Options.lua fresh with the real Overlay.lua underneath it (nothing on these pages calls
  -- into it any more since AB2-D1, and this is what proves it) and the real Colors.lua (Options.table()
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

  -- ADR-0015 §3 split one switch into three. `enabled` is the whole display; `showQueue` is the
  -- strip alone (a player who watches only the glowing button had no way to lose the icons and keep
  -- the glow); `animate` is the motion. All three shipped as a single toggle labelled, confusingly,
  -- the same as the visibility dropdown below it.
  describe("Queue section switches", function()
    -- PE11-D2: the page is three inline panels now, so every row lives one level down in
    -- `queue.args.<panel>.args`. Flattened here rather than naming the panel at each call site: the
    -- KEYS did not change, only which panel holds them, so a row that moves between panels is still
    -- found -- while a row that disappeared still reads nil and still fails.
    local function queueArgs()
      local out = {}
      for _, panel in pairs(Options.table().args.queue.args) do
        for key, row in pairs(panel.args) do out[key] = row end
      end
      return out
    end
    -- The master switch and the wizard live on General; the strip's own settings on Queue. Two
    -- accessors rather than one, so a row moving pages fails here rather than silently reading nil.
    local function generalArgs() return Options.table().args.general.args end

    before_each(function()
      ns.db.profile.enabled = true
      ns.db.profile.showQueue = true
      ns.db.profile.animate = true
      ns.Display.Enable = function() end
      ns.Display.Disable = function() end
      ns.Queue = { Layout = function() end }
    end)

    -- Disable() stops the update loop, so no later tick can reach the glow to release it: the
    -- button lit by the last suggestion stayed lit while the panel promised "no bar glow".
    it("releases every glow when the master switch goes off", function()
      local stopped = 0
      ns.Glow = { StopAll = function() stopped = stopped + 1 end }
      generalArgs().enabled.set(nil, false)
      assert.equal(1, stopped)
    end)

    -- PE11-D5, the same class of stranding one line down: Disable() stops the ticks, and
    -- positioning mode is deliberately immune to the render loop -- so a strip left mid-positioning
    -- would sit on screen under a switch that says "no queue", with nothing left running to take it
    -- down. Only on the way OFF: switching the addon on must not end a mode nobody asked to end.
    it("takes a strip left mid-positioning down with the master switch", function()
      local stops = 0
      ns.Glow = { StopAll = function() end }
      ns.Queue.StopPositioning = function() stops = stops + 1 end
      generalArgs().enabled.set(nil, true)
      assert.equal(0, stops)
      generalArgs().enabled.set(nil, false)
      assert.equal(1, stops)
    end)

    it("names the master switch for the addon, not for the strip", function()
      local row = generalArgs().enabled
      assert.equal("Enable Elmira", row.name)
      assert.equal("Turns the whole display off: no queue, no bar glow, no update loop.", row.desc)
    end)

    -- PE11-D1: the switch is named for what it switches ("Enable the queue strip", the shape
    -- General's "Enable action bar glow" already uses). It used to be "Show the queue strip", five
    -- rows above a dropdown called "Show the queue" -- one page, two nearly identical labels.
    it("offers the strip separately, and says the glow survives it", function()
      local row = queueArgs().showQueue
      assert.equal("Enable the queue strip", row.name)
      assert.is_truthy(row.desc:find("keeps the action-bar glow", 1, true))
      assert.is_true(row.get())
      row.set(nil, false)
      assert.is_false(ns.db.profile.showQueue)
      assert.is_false(row.get())
    end)

    -- PE9-D4/D5. Three settings that all change how the strip DRAWS rather than what it contains,
    -- which is exactly the class of change the driver would never repaint for on its own.
    it("offers waits, keybinds and the rule name, defaulted so today's screen is unchanged", function()
      assert.equal("Show waits", queueArgs().waits.name)
      assert.equal("gcd", queueArgs().waits.get())
      assert.same({ "off", "gcd", "always" }, queueArgs().waits.sorting())
      assert.same({ off = "Off", gcd = "Only when longer than a GCD", always = "Always" },
                  queueArgs().waits.values())

      assert.equal("Keybinds", queueArgs().keybinds.name)
      assert.equal("first", queueArgs().keybinds.get())
      assert.same({ "off", "first", "all" }, queueArgs().keybinds.sorting())
      assert.same({ off = "Off", first = "On the first icon only", all = "On every icon" },
                  queueArgs().keybinds.values())

      assert.equal("Show the rule name", queueArgs().showReason.name)
      assert.is_false(queueArgs().showReason.get())

      queueArgs().waits.set(nil, "always")
      queueArgs().keybinds.set(nil, "off")
      queueArgs().showReason.set(nil, true)
      assert.equal("always", ns.db.profile.waits)
      assert.equal("off", ns.db.profile.keybinds)
      assert.is_true(ns.db.profile.showReason)
    end)

    -- Every one of these six strip settings is written down TWICE: once as the shipped default in
    -- Core/DB.lua, and once as this getter's own fallback for a profile that has never carried the
    -- key. Two copies of one answer drift, and the drift is silent -- each reading is defensible on
    -- its own, and the panel then shows one thing while the strip does another. So the pair is
    -- asserted as a pair, which is also the only observable a shipped default HAS: with the
    -- fallback beside it, deleting the default changes nothing a reader can see except this
    -- agreement.
    it("reads an unset profile as exactly the value Core/DB ships as the default", function()
      local DB = helper.load("Elmira/Core/DB.lua")
      helper.load("Elmira/Core/Transition.lua")  -- grow/spacing read their fallback out of it
      local d = queueArgs()
      -- None of the six is in ns.db.profile (see before_each), so each getter is answering from
      -- its fallback here -- which is the case a stale profile hits in the client.
      assert.equal(DB.defaults.profile.grow, d.grow.get())
      assert.equal(DB.defaults.profile.spacing, d.spacing.get())
      assert.equal(DB.defaults.profile.oocAlpha, d.oocAlpha.get())
      assert.equal(DB.defaults.profile.waits, d.waits.get())
      assert.equal(DB.defaults.profile.keybinds, d.keybinds.get())
      assert.equal(DB.defaults.profile.showReason, d.showReason.get())
    end)

    it("repaints on each of the three new rows, or the change waits for the queue to move", function()
      local redraws = 0
      ns.Display.refresh = function() redraws = redraws + 1 end
      queueArgs().waits.set(nil, "off")
      queueArgs().keybinds.set(nil, "all")
      queueArgs().showReason.set(nil, true)
      assert.equal(3, redraws)
    end)

    it("offers the motion separately", function()
      local row = queueArgs().animate
      assert.equal("Animate changes", row.name)
      -- PE11-D3: a function now, because the tooltip grows the reason the row is greyed out when
      -- it is. Read through the call, or every desc assertion on this page tests a closure address.
      assert.is_truthy(row.desc():find("Icons slide when the queue moves", 1, true))
      assert.is_true(row.get())
      row.set(nil, false)
      assert.is_false(ns.db.profile.animate)
      assert.is_false(row.get())
    end)

    -- A profile written before ADR-0015 has neither key. Reading a missing key as "off" would hide
    -- the strip on every existing install, which is how a default of nil differs from a default.
    it("reads a profile that predates both keys as on", function()
      ns.db.profile.showQueue, ns.db.profile.animate = nil, nil
      assert.is_true(queueArgs().showQueue.get())
      assert.is_true(queueArgs().animate.get())
    end)

    -- Changing either setting changes nothing about the queue itself, so the driver would not
    -- repaint on its own: the strip would keep animating, or stay hidden, until something else moved.
    it("repaints on every one of the three, or the change is invisible until the queue moves", function()
      local redraws = 0
      ns.Display.refresh = function() redraws = redraws + 1 end
      generalArgs().enabled.set(nil, true)
      queueArgs().showQueue.set(nil, false)
      queueArgs().animate.set(nil, false)
      assert.equal(3, redraws)
    end)
  end)

  -- The left menu, after the 2026-09-07 split. "Queue" used to be the front page and held the
  -- master switch, the wizard and the strip's own settings in one list; the window's scale had
  -- nowhere to live and the strip's scale was called, simply, "Scale". The 2026-09-07 pass-3 (D16-
  -- D19) moved position locking from Queue onto General as "Lock all positions" and added the
  -- minimap toggle, the rotation shortcut, and the read-only slash-command list.
  describe("General and Queue pages", function()
    local function args() return Options.table().args end

    before_each(function()
      ns.db.profile.enabled = true
      ns.db.profile.showQueue = true
      ns.db.profile.animate = true
      ns.db.profile.depth = 3
      ns.db.profile.scale = 1.0
      ns.db.global = { window = { scale = 1.2 } }
      ns.Display.Enable = function() end
      ns.Display.Disable = function() end
      ns.Queue = { Layout = function() end, isLocked = function() return true end,
                   SetLocked = function() end }
      ns.Visibility = { MODES = { "always" }, DEFAULT = "always" }
    end)

    it("opens on General, which holds the addon itself and nothing about the strip", function()
      local general = args().general
      assert.equal("General", general.name)
      assert.equal("Enable Elmira", general.args.enabled.name)
      assert.equal("Choose Your Rotation", general.args.chooseRotation.name)
      assert.equal("Jumps straight to picking or editing your rotation.", general.args.chooseRotation.desc)
      assert.equal("Show minimap button", general.args.minimap.name)
      assert.equal("Shows Elmira's launcher button on the minimap.", general.args.minimap.desc)
      assert.equal("Lock all positions", general.args.locked.name)
      -- The strip's settings are NOT here: that is the whole point of the split.
      assert.is_nil(general.args.depth)
      assert.is_nil(general.args.showQueue)
    end)

    -- D39: the wizard window and its "Run setup again" button are gone; the Rotations tree is the
    -- only front door now.
    it("no longer offers 'Run setup again': the Rotations tree is the one front door", function()
      assert.is_nil(args().general.args.setup)
    end)

    it("orders General's front controls, each exactly once, ahead of the window and slash groups",
      function()
        local general = args().general
        local seen = {}
        for key, row in pairs(general.args) do
          assert.is_number(row.order, key .. " has no order")
          assert.is_nil(seen[row.order], key .. " shares order " .. tostring(row.order))
          seen[row.order] = key
        end
        -- PE8: the three switches group on the left and the BUTTON ends the row, because a button
        -- is the only one of the four that fills its cell -- a toggle draws hard against its cell's
        -- left edge however wide the cell is, so it can never sit flush right.
        assert.same({ "enabled", "minimap", "locked", "chooseRotation" },
                    { seen[1], seen[2], seen[3], seen[4] })
        assert.equal("scale", seen[10])
        -- PE6-D3: Action Bars sits between the window's own scale and the slash-command list.
        assert.equal("bars", seen[15])
        assert.equal("slash", seen[20])
      end)

    -- ADR-0015 SS1's front door. AceConfigDialog:Open only creates a NEW frame when
    -- `OpenFrames[appName]` is nil, so calling it again on an already-open panel just moves the
    -- SAME frame's selection -- this button never closes and reopens the window.
    it("Choose Your Rotation runs Options.Open('rotation')", function()
      local calls = {}
      local original = Options.Open
      Options.Open = function(...) calls[#calls + 1] = { ... } end
      args().general.args.chooseRotation.func()
      Options.Open = original
      assert.same({ { "rotation" } }, calls)
    end)

    describe("Show minimap button", function()
      -- Options never touches LibDBIcon itself; the toggle calls through the addon
      -- object, and Core/Init.lua's NA:SetMinimapShown is the only place LibDBIcon is asked.
      it("routes through the addon object, never LibDBIcon directly", function()
        local calls = {}
        ns.addon = { SetMinimapShown = function(_, v) calls[#calls + 1] = v end }
        args().general.args.minimap.set(nil, true)
        assert.same({ true }, calls)
      end)

      it("reads the stored flag", function()
        ns.db.global.minimap = { hide = true }
        assert.is_false(args().general.args.minimap.get())
        ns.db.global.minimap.hide = false
        assert.is_true(args().general.args.minimap.get())
      end)

      it("reads as shown before anything has been stored", function()
        assert.is_true(args().general.args.minimap.get())
      end)
    end)

    describe("Lock all positions", function()
      it("replaces the Queue page's own lock toggle, reading and writing through Queue", function()
        local row = args().general.args.locked
        assert.equal("Locks the queue strip and the on-screen message. Same as /elm lock.", row.desc)
        assert.is_true(row.get()) -- ns.Queue.isLocked() stubbed true in before_each
        local set
        ns.Queue.SetLocked = function(v) set = v end
        row.set(nil, false)
        assert.is_false(set)
      end)

      -- PE13-D2: leaving the on-screen message's move mode used to happen here, which meant
      -- /elm lock -- the same decision, taken elsewhere -- left a mouse-eating frame across the
      -- middle of the screen. Queue.SetLocked owns both temporary modes now, so this row must NOT
      -- reach past it: a second owner is how the two paths drifted apart in the first place.
      it("leaves ending move mode to Queue.SetLocked rather than doing it itself", function()
        local stopped = 0
        ns.Announcers = { StopMoving = function() stopped = stopped + 1 end }
        args().general.args.locked.set(nil, true)
        assert.equal(0, stopped)
      end)
    end)

    -- Whole-window scale rather than a font size: AceGUI row heights are fixed, so a larger font
    -- clips inside the same row. Scale is the one lever that grows the text and the row together.
    -- PE6-D2: a plain row, not a titled box. An AceConfig inline group is always full width, so a
    -- panel around one 170px slider is a full-width frame drawn for nothing, and "Panel scale"
    -- already names what it scales.
    it("puts the panel's own scale on General as a plain row, with no box around it", function()
      assert.is_nil(args().general.args.window)
      local row = args().general.args.scale
      assert.equal("Panel scale", row.name)
      assert.equal("range", row.type)
      assert.equal(0.9, row.min)
      assert.equal(1.4, row.max)
      assert.equal(0.05, row.step)
      assert.is_true(row.isPercent)
      assert.equal("How large this settings window is drawn. Applies as you drag.", row.desc)
      assert.equal(1.2, row.get())
      row.set(nil, 1.35)
      assert.equal(1.35, ns.db.global.window.scale)
      assert.equal(1.35, row.get())
    end)

    -- Read from ns.Slash at table-build time so this list can never drift from what /elm offers.
    describe("Slash commands", function()
      it("lists every available command's key and desc, skipping unavailableNamed placeholders",
        function()
          ns.Slash = { availableEntries = function()
            return { { key = "help", desc = "Show this help" },
                      { key = "rotation", desc = "Choose or edit your rotation" } }
          end }
          local group = args().general.args.slash
          assert.equal("Slash commands", group.name)
          assert.is_true(group.inline)
          assert.equal("description", group.args.row1.type)
          assert.equal("medium", group.args.row1.fontSize)
          assert.is_truthy(group.args.row1.name:find("/elm help", 1, true))
          assert.is_truthy(group.args.row1.name:find("Show this help", 1, true))
          assert.is_truthy(group.args.row2.name:find("/elm rotation", 1, true))
        end)

      it("renders as empty, not an error, with no Slash module loaded", function()
        ns.Slash = nil
        assert.is_true(pcall(function() return args().general.args.slash.args end))
        assert.same({}, args().general.args.slash.args)
      end)
    end)

    -- PE11-D2: three inline panels, each answering one question, instead of a flat list of
    -- thirteen. The ORDER inside each panel is most-reached-for first, and it is asserted here
    -- because the whole point of the pass is which control sits next to which.
    it("lays Queue out as three panels, each row exactly once, and no lock any more",
      function()
        local queue = args().queue
        assert.equal("Queue", queue.name)
        local panels = {}
        for key, panel in pairs(queue.args) do
          assert.equal("group", panel.type, key .. " is not a panel")
          assert.is_true(panel.inline, key .. " is a tree node, not an inline panel")
          assert.is_number(panel.order, key .. " has no order")
          assert.is_nil(panels[panel.order], key .. " shares order " .. tostring(panel.order))
          panels[panel.order] = key
        end
        -- No outer wrapper around the three (the nesting weight the owner flagged on General): the
        -- panels are the page's own args, so there are exactly three of them and nothing else.
        assert.same({ "when", "size", "tells" }, { panels[1], panels[2], panels[3] })
        assert.equal("When you see it", queue.args.when.name)
        assert.equal("Size and position", queue.args.size.name)
        assert.equal("What it tells you", queue.args.tells.name)

        local function orderOf(panel)
          local seen = {}
          for key, row in pairs(queue.args[panel].args) do
            assert.is_number(row.order, key .. " has no order")
            assert.is_nil(seen[row.order], key .. " shares order " .. tostring(row.order))
            seen[row.order] = key
          end
          -- Read back by order, not by pairs(): the assertion below is about the order the player
          -- sees, and a gap in the numbering has to show up as a missing row rather than be sorted
          -- away. Past the last row seen[i] is nil, which assigns nothing.
          local out = {}
          for i = 1, 10 do out[i] = seen[i] end
          return out
        end
        assert.same({ "showQueue", "visibility", "oocAlpha" }, orderOf("when"))
        assert.same({ "depth", "scale", "matchBars", "grow", "spacing", "position" },
                    orderOf("size"))
        -- `animate` sits with what the strip TELLS you, not with its size: ADR-0015 §3 forbids the
        -- strip to glow, so motion is how it says "something changed" -- information, not decoration.
        assert.same({ "waits", "keybinds", "showReason", "animate", "learning" }, orderOf("tells"))

        -- The rows that left for General stayed gone, at either level.
        for _, panel in pairs(queue.args) do
          assert.is_nil(panel.args.enabled, "the master switch is back on the Queue page")
          assert.is_nil(panel.args.setup, "the wizard button is back on the Queue page")
          assert.is_nil(panel.args.locked, "Lock position belongs on General")
        end
      end)

    -- PE11-D1: it lives in a panel called "Size and position" now, so "Strip scale" was saying
    -- "size" twice. The window's own scale is on another page and still says which one it is.
    it("names the strip's size for what it is, inside the size panel", function()
      local row = args().queue.args.size.args.scale
      assert.equal("Size", row.name)
      assert.is_truthy(row.desc())
      assert.equal(1.0, row.get())
      row.set(nil, 1.3)
      assert.equal(1.3, ns.db.profile.scale)
    end)

    -- PE11-D1: the two names that collided are gone. Asserted as the literal strings, because the
    -- defect they fix is exactly "which one of these did I just change".
    it("no longer offers two controls whose names read the same", function()
      local queue = args().queue
      assert.equal("Enable the queue strip", queue.args.when.args.showQueue.name)
      assert.equal("When to show it", queue.args.when.args.visibility.name)
      assert.equal("Casts to show", queue.args.size.args.depth.name)
      assert.equal("Direction", queue.args.size.args.grow.name)
    end)

    -- PE10-D1. The four directions come from Core/Transition.GROW rather than from a list written
    -- out here, so the dropdown and the layout code cannot disagree about which directions exist --
    -- and the ORDER is the list's, not alphabetical: "right" first because it is what shipped, then
    -- its opposite, then the two vertical ones. AceConfig sorts a `values` table by its keys unless
    -- `sorting` says otherwise, which would have put "down" at the top.
    it("offers exactly the four growth directions Core/Transition names, in its order", function()
      helper.load("Elmira/Core/Transition.lua")
      local row = args().queue.args.size.args.grow
      assert.same({ "right", "left", "down", "up" }, row.sorting())
      assert.same({ right = "Right", left = "Left", down = "Down", up = "Up" }, row.values())
      assert.equal(4, #row.sorting())
      -- Reads and writes the same value Display/Queue lays the strip out from, and repaints: a
      -- direction that only reaches the profile leaves the strip pointing the old way until the
      -- rotation happens to move.
      assert.equal("right", row.get())
      local redraws = 0
      ns.Display.refresh = function() redraws = redraws + 1 end
      row.set(nil, "up")
      assert.equal("up", ns.db.profile.grow)
      assert.equal("up", row.get())
      assert.equal(1, redraws)
      -- A direction from a newer version reads as the shipped one rather than as an error.
      ns.db.profile.grow = "sideways"
      assert.equal("right", row.get())
    end)

    -- Every word on this page, pinned. The owner writes these tooltips as the page's actual
    -- documentation -- the "which of these two did I just change" fixes, the "your lock setting is
    -- left exactly as it was" promise, the sentence naming the three settings Learning mode
    -- rewrites -- and each is several source lines of concatenation. A test that only asked whether
    -- a desc was non-empty would pass with any one of those lines gone, which is how a promise
    -- quietly stops being made. Equality, so removing a sentence fails here rather than in a
    -- screenshot.
    it("says on every control exactly what the owner wrote there", function()
      local expected = {
      when_oocAlpha = "How solid the strip is while you are not fighting. It goes back to full the moment you enter combat. To hide it entirely out of combat, use \"When to show it\" above instead.",
      when_showQueue = "The row of icons showing what to press now and what comes after it. Turning it off hides the icons and keeps the action-bar glow, for players who watch only the highlighted button.",
      when_visibility = "Which moments the strip and its bar glow are on screen. Hiding it also stops the update loop, so a hidden queue costs nothing at all. The default keeps it out of your way in town and up the moment you have something to fight.",
      size_depth = "How many casts ahead the strip shows. The first icon is what to press now; the rest are what the rotation projects after it. One is the whole answer with nothing to read past it; five is a plan.",
      size_grow = "Which way the strip lays out after the first icon. The first icon does not move, so you can position the strip first and pick a direction afterwards. Down or Up suits a strip beside your character; Left suits one anchored to the right of the screen.",
      size_matchBars = "Measures a button on your action bars and sets the size above so the first icon is drawn the same. Needs one of the rotation's spells to be on a bar you can see.",
      size_position = "Puts the strip on screen with sample icons and lets you drag it, even in the moments it would normally be hidden. Press it again when the strip is where you want it. Nothing is saved except the position: your lock setting is left exactly as it was, and closing this window ends it too.",
      size_scale = "How large the queue icons are drawn on your screen. If you want them the size of the buttons you already read, use \"Match my action bars\" below rather than hunting for the number.",
      size_spacing = "How many pixels apart the icons sit. Zero makes the strip read as one block; a wide gap makes the first icon easier to pick out of the corner of your eye.",
      tells_animate = "Icons slide when the queue moves and pop when you cast the suggestion. The strip never glows, so movement is how it says something changed: with this off, a new first suggestion simply appears and is easy to miss.",
      tells_keybinds = "Prints the key each suggestion is bound to on your action bars, in the icon's top-right corner. Nothing appears for an ability you have not put on a bar. On the first icon only by default: on a later icon it is a key NOT to press yet.",
      tells_learning = "Shows one suggestion at a time, larger, with the name of the rule that chose it. It writes three settings on this page for you: \"Casts to show\" to 1, \"Size\" to 140% and \"Show the rule name\" on -- and puts all three back the way they were when you switch it off again. Anything you change yourself while it is on is yours and stays. Does not turn on any screen-edge cues; those stay your choice.",
      tells_showReason = "Writes the name of the rule that chose the first suggestion underneath it, so you learn why rather than memorising an order. Works at any number of icons; Learning mode below switches it on for you.",
      tells_waits = "Prints how many seconds until each later suggestion happens, in the icon's bottom-left corner. Most of the time the answer is just the next global cooldown, so by default the number only appears when the wait is longer than that -- which is exactly when it is worth knowing.",
      }
      local seen = 0
      for panelKey, panel in pairs(args().queue.args) do
        for rowKey, row in pairs(panel.args) do
          local want = expected[panelKey .. "_" .. rowKey]
          if want then
            local got = type(row.desc) == "function" and row.desc() or row.desc
            assert.equal(want, got, panelKey .. "." .. rowKey .. " no longer says what it said")
            seen = seen + 1
          end
        end
      end
      -- A row that moved panels or lost its desc would silently drop out of the walk above.
      assert.equal(14, seen)
    end)

    -- PE11-D4. The third instance this session of "the master switch is off and the twelve
    -- controls under it still look live", so it is the page's rule now.
    describe("with the strip switched off", function()
      local function rows()
        local queue = args().queue
        return { queue.args.when.args.visibility, queue.args.when.args.oocAlpha,
                 queue.args.size.args.depth, queue.args.size.args.scale,
                 queue.args.size.args.matchBars, queue.args.size.args.grow,
                 queue.args.size.args.spacing, queue.args.size.args.position,
                 queue.args.tells.args.waits, queue.args.tells.args.keybinds,
                 queue.args.tells.args.showReason, queue.args.tells.args.animate,
                 queue.args.tells.args.learning }
      end

      it("greys out every other control and names the switch that brings them back", function()
        local function nameOf(row)
          return type(row.name) == "function" and row.name() or row.name
        end
        for _, row in ipairs(rows()) do
          assert.is_falsy(row.disabled(), nameOf(row) .. " is greyed out while the strip is on")
        end
        ns.db.profile.showQueue = false
        for _, row in ipairs(rows()) do
          local name = nameOf(row)
          assert.is_true(row.disabled(), name .. " still looks live with the strip off")
          assert.is_truthy(row.desc():find("Enable the queue strip", 1, true),
                           name .. " does not say which switch turns it back on")
        end
        -- The switch itself is never greyed out: it is the way back.
        assert.is_nil(args().queue.args.when.args.showQueue.disabled)
      end)

      -- A greyed control must still show what is STORED. The `get = function() return false end`
      -- shape used by an unavailable cue elsewhere in this file would report `false` for a setting
      -- the player had turned on, which reads as "your setting was thrown away".
      it("keeps showing the stored value of every control it greys out", function()
        ns.db.profile.showReason = true
        ns.db.profile.animate = false
        ns.db.profile.depth = 5
        ns.db.profile.oocAlpha = 0.4
        ns.db.profile.showQueue = false
        local queue = args().queue
        assert.is_true(queue.args.tells.args.showReason.get())
        assert.is_false(queue.args.tells.args.animate.get())
        assert.equal(5, queue.args.size.args.depth.get())
        assert.equal(0.4, queue.args.when.args.oocAlpha.get())
      end)

      -- The fade has a second way to be dead: in combat-only mode there is no out-of-combat strip
      -- for it to act on, so the slider is offering to change nothing.
      it("also greys the out-of-combat fade when the strip is combat only", function()
        ns.Visibility = { MODES = { "always", "combat" }, DEFAULT = "always" }
        local function fade() return args().queue.args.when.args.oocAlpha end
        ns.db.profile.visibility = "always"
        assert.is_falsy(fade().disabled())
        ns.db.profile.visibility = "combat"
        assert.is_true(fade().disabled())
        assert.is_truthy(fade().desc():find("combat only", 1, true))
        -- and it is still the stored number, not a zero
        assert.equal(1, fade().get())

        -- A profile that has never chosen a mode is on the SHIPPED default, not on nothing: were
        -- the shipped default combat-only, the fade would be just as dead and would have to say so.
        ns.Visibility.DEFAULT = "combat"
        ns.db.profile.visibility = nil
        assert.is_true(fade().disabled())
        ns.Visibility.DEFAULT = "always"
        assert.is_falsy(fade().disabled())
      end)
    end)

    -- ADR-0015 SS3. Which moments the strip and its bar glow are on screen at all. The list comes
    -- from Core/Visibility rather than from a copy here, so a mode added there cannot appear in the
    -- dropdown unnamed or in the wrong place -- and the glow is released on the way, because a mode
    -- change that strands a lit action button leaves the panel promising something it is not doing.
    describe("When to show it", function()
      local function row() return args().queue.args.when.args.visibility end

      before_each(function()
        ns.Visibility = { MODES = { "always", "combat_or_target", "combat" }, DEFAULT = "combat_or_target" }
      end)

      it("offers Core/Visibility's own modes, in its own order, each with a name", function()
        assert.same({ "always", "combat_or_target", "combat" }, row().sorting())
        assert.same({ always = "Always",
                      combat_or_target = "In combat, or when you have a target",
                      combat = "In combat only" }, row().values())
      end)

      it("reads the shipped default until the player picks one", function()
        assert.equal("combat_or_target", row().get())
        ns.db.profile.visibility = "combat"
        assert.equal("combat", row().get())
      end)

      it("releases every glow and repaints when the mode changes", function()
        local stopped, redraws = 0, 0
        ns.Glow = { StopAll = function() stopped = stopped + 1 end }
        ns.Display.refresh = function() redraws = redraws + 1 end
        row().set(nil, "always")
        assert.equal("always", ns.db.profile.visibility)
        assert.equal(1, stopped, "a bar button lit by the last suggestion stays lit")
        assert.equal(1, redraws)
      end)
    end)

    -- PE10-D2/D3/D4 and PE9-D4: the numbers. Each of these writes a value Display/Queue reads back
    -- on the next paint, and each has to ASK for that paint -- changing a strip setting changes
    -- neither the queue nor the build, so the driver would not repaint on its own and the panel
    -- would look like it had done nothing.
    describe("the numbers on the Queue page", function()
      local redraws

      before_each(function()
        redraws = 0
        ns.Display.refresh = function() redraws = redraws + 1 end
      end)

      it("offers the fade as a percentage, from a tenth up to solid", function()
        local row = args().queue.args.when.args.oocAlpha
        assert.equal(0.1, row.min)
        assert.equal(1.0, row.max)
        assert.equal(0.05, row.step)
        assert.is_true(row.isPercent)
        row.set(nil, 0.45)
        assert.equal(0.45, ns.db.profile.oocAlpha)
        assert.equal(1, redraws)
      end)

      it("offers the spacing in whole pixels, and zero is a real answer", function()
        local row = args().queue.args.size.args.spacing
        assert.equal(0, row.min)
        assert.equal(20, row.max)
        assert.equal(1, row.step)
        helper.load("Elmira/Core/Transition.lua")
        assert.equal(4, row.get(), "a profile that predates the setting reads as the shipped gap")
        row.set(nil, 0)
        assert.equal(0, ns.db.profile.spacing)
        assert.equal(0, row.get())
        assert.equal(1, redraws)
      end)

      it("writes the icon count and the size straight through, as percentages", function()
        local depth, scale = args().queue.args.size.args.depth, args().queue.args.size.args.scale
        assert.is_true(scale.isPercent)
        depth.set(nil, 5)
        scale.set(nil, 1.3)
        assert.equal(5, ns.db.profile.depth)
        assert.equal(1.3, ns.db.profile.scale)
        assert.equal(2, redraws)
      end)
    end)

    -- PE10-D4. The button beside the size slider it writes. Its whole point is that it says what
    -- happened either way: one that computes nothing and reports nothing is indistinguishable from
    -- one that is broken, and the player is left dragging the slider by eye again.
    describe("Match my action bars", function()
      local said, redraws

      local function press()
        said, redraws = {}, 0
        -- The whole options table is built by args(), so the stub answers everything
        -- announceGroup() asks of it as well as emit (the shape the learning-mode test uses).
        ns.Announce = {
          emit = function(cat, text) said[#said + 1] = { cat, text } end,
          log = function() return {} end, category = function() return nil end,
          plain = function(t) return t end, CATEGORIES = {}, listed = function() return {} end,
          CHANNELS = { "chat", "screen", "sound", "party" }, routes = function() return {} end,
        }
        ns.Display.refresh = function() redraws = redraws + 1 end
        args().queue.args.size.args.matchBars.func()
      end

      it("applies the measured scale, repaints, and says what it set", function()
        ns.Queue.matchBarScale = function() ns.db.profile.scale = 0.87; return 0.87 end
        press()
        assert.equal(0.87, ns.db.profile.scale)
        assert.equal(1, redraws, "the slider still shows the old number")
        assert.equal(1, #said)
        assert.equal("status", said[1][1])
        assert.equal("Strip scale set to 87% to match your action bars.", said[1][2])
      end)

      it("says it could not measure one, and what to do about it", function()
        ns.Queue.matchBarScale = function() return nil, "no button" end
        press()
        assert.equal(1, #said)
        assert.is_truthy(said[1][2]:find("Could not measure an action button", 1, true))
        assert.is_truthy(said[1][2]:find("on a bar you can see", 1, true))
      end)
    end)

    -- PE11-D5. The strip is hidden out of combat with no target by default, so "unlock it and drag
    -- it" asked the player to drag something that is not on screen.
    describe("Position the Strip", function()
      local function row() return args().queue.args.size.args.position end

      it("starts and ends positioning mode, and relabels itself while it is on", function()
        local calls, on = {}, false
        ns.Queue.isPositioning = function() return on end
        ns.Queue.StartPositioning = function() calls[#calls + 1] = "start"; on = true; return true end
        ns.Queue.StopPositioning = function() calls[#calls + 1] = "stop"; on = false; return true end

        assert.equal("execute", row().type)
        assert.equal("Position the Strip", row().name())
        row().func()
        assert.same({ "start" }, calls)
        -- The label is read fresh on every build, and AceConfigDialog rebuilds after an execute.
        assert.equal("Done Positioning", row().name())
        row().func()
        assert.same({ "start", "stop" }, calls)
        assert.equal("Position the Strip", row().name())
      end)

      it("promises the lock is left alone, which is what makes it a mode and not a setting",
        function()
          assert.is_truthy(row().desc():find("lock setting is left exactly as it was", 1, true))
        end)
    end)
  end)

  -- AceConfig renders a `description` row in GameFontHighlightSmall (10pt) unless `fontSize` says
  -- otherwise (AceConfigDialog-3.0.lua:1404-1410), so the panel's CONTENT was two points smaller
  -- than the labels above it -- worst exactly where there is most to read. `medium` is the 12pt
  -- baseline the checkboxes, buttons and tree rows already use, so whole-window scale enlarges the
  -- panel evenly instead of enlarging the labels and leaving the prose behind.
  --
  -- A walk rather than a list: a description row added tomorrow has to be caught by this, and the
  -- `type` assertion is here because a row that lost its type is not a row this check would see.
  it("renders every description at the same size as the labels around it", function()
    local function walk(node, path)
      for key, row in pairs(node.args or {}) do
        local where = path .. "." .. tostring(key)
        assert.is_table(row, where .. " is not a table")
        assert.is_string(row.type, where .. " has no type")
        if row.type == "description" then
          assert.equal("medium", row.fontSize, where .. " is drawn smaller than its own label")
        elseif row.type == "group" then
          walk(row, where)
        end
      end
    end
    walk(Options.table(), "Elmira")
    -- Twice, because whole sections are built from the ACTIVE BUILD and the no-build panel is a
    -- different set of rows.
    ns.Display.activeBuild = function()
      return { entries = { { spell = "EXORCISM", index = 1 } } }, "PALADIN_EXODIN", "pinned"
    end
    walk(Options.table(), "Elmira(with an active build)")
  end)

  -- ADR-0015 §3 makes the bar glow the single attention signal, so it gets the range of control
  -- that deserves. Every row below could be present and do nothing; these check it does something.
  describe("Glow appearance", function()
    -- PE7-D3: the cast-after-next cluster lives on General -> Action Bars -> Action bar glow now,
    -- under the switch that decides whether anything on the bars glows at all. Same controls, same
    -- behaviour, one page across -- so these assertions moved with them rather than being rewritten.
    local function hintArgs() return Options.table().args.general.args.bars.args.check.args end

    before_each(function()
      -- AB1-D3: the appearance half of `profile.glow` is per ability now (Core/AbilitySettings);
      -- what is left here are the two switches that are not about any one ability.
      ns.db.profile.glow = { barGlow = true, secondary = false }
      ns.db.char = ns.db.char or {}
      ns.db.char.abilities = {}
      helper.load("Elmira/Core/AbilitySettings.lua")
      helper.load("Elmira/Display/Glow.lua")
      ns.Queue = { Layout = function() end }
    end)

    -- AB1-D8: renamed "Ability sounds", and stored per CHARACTER like everything else an ability
    -- can be set to do. AB4-D2: an inline panel on Notifications rather than a sub-page of it --
    -- one checkbox does not earn a node in the tree.
    it("offers the ability-sound mute, reading and writing db.char", function()
      helper.load("Elmira/Display/Sounds.lua")
      local sounds = Options.table().args.notifications.args.abilitySounds
      local row = sounds.args.enabled
      assert.equal("toggle", row.type)
      assert.equal(1, row.order)
      assert.is_true(sounds.inline)
      assert.equal("Ability sounds", sounds.name)
      assert.equal("Play ability sounds", row.name)
      assert.is_truthy(row.desc)
      ns.db.char.sounds = { enabled = false }
      assert.is_false(row.get())
      row.set(nil, true)
      assert.is_true(ns.db.char.sounds.enabled)
      assert.is_true(row.get())
      assert.is_nil(ns.db.profile.sounds, "the mute must not be written back into the profile")
    end)

    -- Reported from a client: the dim hint looked identical to the bright one on Proc, which
    -- drives its own alpha animation. How dim "dim" is has to be adjustable, and comparable.
    describe("the dim hint's brightness", function()
      it("offers a slider only once the hint is switched on", function()
        ns.db.profile.glow.secondary = false
        local row = hintArgs().secondaryAlpha
        assert.equal("range", row.type)
        assert.equal(0.05, row.min)
        assert.equal(1, row.max)
        -- The description carries the reason this is a setting at all: a value that reads dim on
        -- one style can look identical on another, so it names the way to check.
        assert.is_truthy(row.desc:find("look identical on another", 1, true))
        assert.is_truthy(row.desc:find("preview", 1, true))
        assert.is_true(row.hidden(), "a slider for something switched off is a dead control")
        ns.db.profile.glow.secondary = true
        assert.is_false(row.hidden())
      end)

      it("reads and writes the profile through Glow, so the render agrees with the panel", function()
        helper.load("Elmira/Display/Glow.lua")
        ns.db.profile.glow.secondary = true
        local row = hintArgs().secondaryAlpha
        assert.equal(ns.Glow.secondaryAlpha(), row.get())
        row.set(nil, 0.6)
        assert.equal(0.6, ns.db.profile.glow.secondaryAlpha)
        assert.equal(0.6, row.get())
      end)

      it("names the hint section and says why it ships off", function()
        assert.equal("The cast after next", hintArgs().hintHeader.name)
        assert.equal("header", hintArgs().hintHeader.type)
        local row = hintArgs().secondary
        assert.is_truthy(row.desc:find("compete for the same glance", 1, true))
      end)

      it("hides the next-cast controls until it is on, and offers no style of its own", function()
        ns.db.profile.glow.secondary = false
        assert.is_true(hintArgs().previewDim.hidden())
        assert.is_true(hintArgs().secondaryAlpha.hidden())
        ns.db.profile.glow.secondary = true
        assert.is_false(hintArgs().previewDim.hidden())
        -- PE7 amendment: brightness is the ONLY difference the second glow may make, so that once
        -- each ability carries its own style this cannot silently override what the player chose.
        assert.is_nil(hintArgs().secondaryStyle)
      end)

      it("previews the dim hint, and only when there is a hint to preview", function()
        ns.db.profile.glow.secondary = false
        local row = hintArgs().previewDim
        assert.equal("execute", row.type)
        assert.is_true(row.hidden())
        ns.db.profile.glow.secondary = true
        assert.is_false(row.hidden())

        local lit
        ns.BarGlow = { buttonsFor = function() return { "BUTTON" } end }
        ns.Glow = { Start = function(_, _, secondary) lit = secondary; return true end,
                    Stop = function() end, isRendererFrame = function() return false end,
                    styleFor = function() return "PIXEL" end }
        Options.setCheckSpell("EXORCISM")
        row.func()
        assert.is_true(lit, "the dim preview lit the bright glow")
        hintArgs().preview.func()
        assert.is_false(lit, "the ordinary preview should not be dim")
      end)
    end)

    -- The settings are worth playing with, and there was no way back: the colour picker's Default
    -- button belongs to Blizzard's frame and never touched what we stored. AB1-D3: it is the
    -- All abilities > Glow reset now, and its BUTTON lives on that tab (options_spells_spec).
    describe("resetting the glow (Options.resetGlow)", function()
      it("puts the All abilities glow back to nothing chosen, and repaints", function()
        local A = ns.AbilitySettings
        A.set(A.ALL, "glow", "style", "PROC")
        A.set(A.ALL, "glow", "particles", 19)
        A.setInherit("EXORCISM", "glow", false)
        A.set("EXORCISM", "glow", "enabled", false)
        local stopped = 0
        ns.Glow.StopAll = function() stopped = stopped + 1 end
        assert.is_true(Options.resetGlow())
        assert.equal("PIXEL", A.effective(A.ALL, "glow").style)
        assert.is_false(A.effective(A.ALL, "glow").particles)
        assert.same({}, ns.db.char.abilities[A.ALL], "the channel should be unset, not rewritten")
        assert.equal(1, stopped, "a running glow keeps its old look until it is torn down")
        -- One channel of ONE entry: an ability that has been unlinked and switched off stays off.
        assert.is_false(A.effective("EXORCISM", "glow").enabled)
      end)

      it("says so rather than erroring before the settings store is loaded", function()
        ns.AbilitySettings = nil
        assert.is_false(Options.resetGlow())
      end)

      it("says so rather than erroring with no character data yet", function()
        ns.db = nil
        assert.is_false(Options.resetGlow())
      end)
    end)

    -- The style picker, the colour, the four sliders, Preview and Reset are all on
    -- Abilities > (an ability) > Glow now; tests/spec/options_spells_spec.lua owns them, per key.

    it("announces the learning-mode change as status rather than printing it", function()
      local said = {}
      -- The whole table is built here, so the stub has to answer everything announceGroup() asks.
      ns.Announce = {
        emit = function(c, t) said[#said + 1] = { c, t } end,
        log = function() return {} end,
        category = function() return nil end,
        plain = function(t) return t end,
        CATEGORIES = {},
        listed = function() return {} end,
        CHANNELS = { "chat", "screen", "sound", "party" },
        routes = function() return {} end,
      }
      ns.Queue.ApplyLearningPreset = function() return { depth = 1, scale = 1.4, showReason = true } end
      ns.db.profile.learning = false
      Options.table().args.queue.args.tells.args.learning.set(nil, true)
      assert.equal(1, #said)
      assert.equal("status", said[1][1])
      assert.is_truthy(said[1][2]:find("Learning mode on"))
      -- PE9-D5: the preset now switches a third setting on, and a sentence that still listed two
      -- would be the settings screen lying about what it just did.
      assert.is_truthy(said[1][2]:find("rule names on"))
      assert.equal("Learning mode on: icons set to 1, scale to 140%, rule names on.", said[1][2])
      -- ...and the toggle reads back what the preset wrote, or the checkbox says off while the
      -- strip is plainly in learning mode.
      ns.db.profile.learning = true
      assert.is_true(Options.table().args.queue.args.tells.args.learning.get())
    end)

    -- PE12. Switching it OFF puts the settings back, and saying so matters just as much on the way
    -- out: three controls on this page change under the player's hand either way. Only the ones
    -- they left alone are named, because only those were restored -- anything they changed while
    -- learning stayed theirs, and naming it would claim to have overwritten a deliberate choice.
    it("names each setting that came back when learning mode goes off", function()
      local said = {}
      ns.Announce = {
        emit = function(c, t) said[#said + 1] = { c, t } end,
        log = function() return {} end, category = function() return nil end,
        plain = function(t) return t end, CATEGORIES = {}, listed = function() return {} end,
        CHANNELS = { "chat", "screen", "sound", "party" }, routes = function() return {} end,
      }
      local redraws = 0
      ns.Display.refresh = function() redraws = redraws + 1 end
      ns.Queue.ApplyLearningPreset = function()
        return { restored = true, depth = 4, scale = 0.9, showReason = false }
      end
      Options.table().args.queue.args.tells.args.learning.set(nil, false)
      assert.equal(1, #said)
      assert.equal("status", said[1][1])
      assert.equal("Learning mode off: icons back to 4, scale back to 90%, rule names off.",
                   said[1][2])
      assert.equal(1, redraws, "the three controls it just rewrote still show the old numbers")
    end)

    -- ...and it names only what actually came back. A setting the player changed themselves while
    -- learning was never restored, so listing it would be the panel claiming to have overwritten a
    -- deliberate choice.
    it("names only the settings that were actually put back", function()
      local said = {}
      ns.Announce = {
        emit = function(c, t) said[#said + 1] = { c, t } end,
        log = function() return {} end, category = function() return nil end,
        plain = function(t) return t end, CATEGORIES = {}, listed = function() return {} end,
        CHANNELS = { "chat", "screen", "sound", "party" }, routes = function() return {} end,
      }
      ns.Queue.ApplyLearningPreset = function() return { restored = true, scale = 0.9 } end
      Options.table().args.queue.args.tells.args.learning.set(nil, false)
      assert.equal("Learning mode off: scale back to 90%.", said[1][2])
    end)

    -- PE7-D3 moved the cast-after-next controls onto this panel because they are a glow ON THE
    -- BARS. That gives them a master here, and a master they do not follow is three live-looking
    -- controls that change nothing. `disabled` only, never a get() that lies or a set() that
    -- writes: turning the bar glow back on has to restore exactly what the player chose.
    it("greys the cast-after-next controls when the bars are not glowing at all", function()
      ns.db.profile.glow.secondary = true       -- so the two rows below it are not hidden as well
      local function rows()
        return { hintArgs().secondary, hintArgs().secondaryAlpha, hintArgs().previewDim }
      end
      for _, row in ipairs(rows()) do assert.is_false(row.disabled()) end
      ns.db.profile.glow.barGlow = false
      for _, row in ipairs(rows()) do
        assert.is_true(row.disabled(), "a cast-after-next control still looks live")
      end
      -- ...and the stored choice is still what they show, not a false.
      assert.is_true(hintArgs().secondary.get())
      -- The switch itself is never greyed: it is the way back.
      assert.is_nil(hintArgs().barGlow and hintArgs().barGlow.disabled)
    end)

    it("offers the dim second-suggestion hint, off, and says why", function()
      local row = hintArgs().secondary
      assert.is_false(row.get())
      assert.is_truthy(row.desc:find("queue itself stopped glowing"))
      row.set(nil, true)
      assert.is_true(ns.db.profile.glow.secondary)
    end)

    -- PE7-D3's two hint rows are the last controls this page still owns: they are ON the Action
    -- Bars panel, under the switch that decides whether the bars glow at all.
    it("builds the hint rows as the controls they claim to be", function()
      assert.equal("toggle", hintArgs().secondary.type)
      -- PE7-D3 renamed it to the string PE7-D1 freed: with the old master gone, "Glow the next
      -- cast" is no longer taken, and it says what the toggle does better than "hint" did.
      assert.equal("Glow the next cast", hintArgs().secondary.name)
      assert.equal("Preview", hintArgs().previewDim.name)
      assert.is_nil(hintArgs().secondaryStyle)
      assert.equal("How dim it is", hintArgs().secondaryAlpha.name)
    end)

    it("knows whether a preview is actually running", function()
      assert.is_false(Options.previewRunning())
      ns.BarGlow = { buttonsFor = function() return { { name = "bar" } }, "ElvUI" end }
      ns.Glow.Start = function() return true end
      ns.Glow.styleFor = function() return "PIXEL" end
      Options.checkSpell = function() return "EXORCISM" end
      Options.previewGlow()
      assert.is_true(Options.previewRunning())
    end)
  end)

  -- F37. The Log first, then where each kind of message goes: a player who has just been told
  -- something and missed it looks here, and finds the message before finding the switches.
  describe("Notifications (D21-D29, the single-page pass)", function()
    -- The old `Options.table().args.notifications.args.announce.args` path is gone (D28): the
    -- content that used to be the "Announcements" sub-page is now the page's own args.
    local function announceArgs()
      return Options.table().args.notifications.args
    end

    -- PE13-D1: the log lives in a panel of its own at the bottom of the page, so its rows are one
    -- level deeper than the settings. Same keys, one hop further in.
    local function logArgs()
      return announceArgs().log.args
    end

    before_each(function()
      helper.load("Elmira/Core/Announce.lua")
      ns.db.profile.announce = {
        sound = "None", sounds = {},
        screen = { font = "Friz Quadrata TT", size = 18, duration = 4,
                   anchor = { point = "TOP", relPoint = "TOP", x = 0, y = -140 } },
        routes = {},
      }
      ns.db.global = { announceLog = {} }
      ns.Announce.use{ now = function() return 1 end, inCombat = function() return false end }
      ns.Queue = { isLocked = function() return false end }
      ns.Announcers = {
        fonts = function() return { ["Friz Quadrata TT"] = "Friz Quadrata TT" } end,
        sounds = function() return { None = "None", Chime = "Chime" } end,
        ApplyFont = function() return true end,
        SetMoving = function() return true end,
        StopMoving = function() return true end,
        isMoving = function() return false end,
      }
    end)

    -- D28: the page opens with an intro sentence.
    it("opens with an intro sentence", function()
      local intro = announceArgs().intro
      assert.equal("description", intro.type)
      assert.equal(0, intro.order)
      assert.is_true(intro.order < announceArgs().log.order)
    end)

    -- PE13-D1. The log used to be the first thing on the page, one row per message, so every
    -- setting below it moved down as the addon talked and the page was never twice the same shape.
    -- It is one inline panel now, with ONE order, and that order is after everything else.
    it("keeps the log in a panel at the bottom, whatever the message count", function()
      local args = announceArgs()
      assert.equal("group", args.log.type)
      assert.is_true(args.log.inline)
      assert.equal("Notifications Log", args.log.name)
      -- Nothing on the page sits below it, and no row of it leaks back out to the page.
      for key, row in pairs(args) do
        if key ~= "log" and type(row) == "table" and row.order then
          assert.is_true(row.order < args.log.order, key .. " is below the log panel")
        end
      end
      assert.is_nil(args.logHeader)
      assert.is_nil(args.logClear)
      local before = args.log.order
      for i = 1, 12 do ns.Announce.emit("status", "line " .. i) end
      assert.equal(before, announceArgs().log.order)
      assert.equal(64, announceArgs().duration.order)  -- and the settings did not move either
    end)

    it("says so plainly when nothing has been said yet", function()
      assert.is_truthy(logArgs().logEmpty.name:find("Nothing yet"))
      assert.is_nil(logArgs().lines, "an empty box was offered with nothing to copy out of it")
    end)

    -- FX1-D3, the owner: "I think I should be able to copy any lines I want". The lines used to be
    -- `description` rows, which no widget lets you select -- the only way to quote one into a bug
    -- report was to retype it. One read-only multiline box in their place: newest first, plain
    -- text, and it scrolls rather than growing the page.
    describe("copying the log out", function()
      it("puts every line in a box the player can select and copy", function()
        ns.Announce.emit("status", "first")
        ns.Announce.emit("warning", "second")
        local box = logArgs().lines
        assert.equal("input", box.type)
        assert.is_true(box.multiline > 1, "a single-line box cannot show a log")
        assert.equal("full", box.width)
        assert.equal(2, box.order)
        assert.is_true(box.order < logArgs().logClear.order)

        local text = box.get()
        local shown = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do shown[#shown + 1] = line end
        assert.equal(2, #shown)
        assert.is_truthy(shown[1]:find("second", 1, true), "newest is not first")
        assert.is_truthy(shown[2]:find("first", 1, true))
        -- PE14-D1: the prefix on a log line is the category's label, so the rename shows here too.
        assert.is_truthy(shown[2]:find("Settings and setup", 1, true))
        assert.is_nil(logArgs().logEmpty)
      end)

      -- Copied text carries whatever is in the string, so a colour code would land in the middle of
      -- a pasted bug report.
      it("carries no colour escapes into what gets copied", function()
        ns.Announce.emit("warning", "second")
        assert.is_nil(logArgs().lines.get():find("|c", 1, true))
        assert.is_nil(logArgs().lines.get():find("|r", 1, true))
      end)

      -- Read-only: typing in the box must not become the record of what the addon said.
      it("keeps the box read-only", function()
        ns.Announce.emit("status", "first")
        local box = logArgs().lines
        assert.is_function(box.set, "AceConfig needs a setter even on a read-only box")
        box.set(nil, "typed over it")
        assert.equal(1, #ns.Announce.log())
        assert.is_truthy(logArgs().lines.get():find("first", 1, true))
      end)

      -- The box is fed by `get`, which AceConfig calls again on every refresh -- so a line said
      -- after the page was built is in the box without anything rebuilding the options table.
      it("reads the log again rather than freezing at what was said when the page was built",
        function()
          ns.Announce.emit("status", "first")
          local box = logArgs().lines
          ns.Announce.emit("status", "later")
          assert.is_truthy(box.get():find("later", 1, true))
        end)
    end)

    it("empties the log on request", function()
      ns.Announce.emit("status", "x")
      logArgs().logClear.func()
      assert.equal(0, #ns.Announce.log())
    end)

    it("gives every category its own row of channels", function()
      local args = announceArgs()
      for _, c in ipairs(ns.Announce.listed()) do
        assert.is_not_nil(args["cat" .. c.key], c.key .. " has no row")
        assert.is_true(args["cat" .. c.key].inline)
      end
    end)

    -- AB1-D10: the cooldown row is BACK, with the Party and Raid toggles that only it has ever
    -- shown -- and with no length slider, because length no longer decides anything. Party/Raid
    -- are gated on `shareable`, which is code, not a checkbox the player can widen.
    it("offers the cooldown row with Party and Raid, and no length slider anywhere", function()
      local args = announceArgs()
      assert.is_not_nil(args.catcooldown)
      assert.equal("toggle", args.catcooldown.args.party.type)
      assert.equal("Party", args.catcooldown.args.party.name)
      assert.equal("Raid", args.catcooldown.args.raid.name)
      -- Two rows, two places: sharing one order puts them in whatever order `pairs` felt like.
      assert.is_true(args.catcooldown.args.raid.order > args.catcooldown.args.party.order)
      assert.is_true(args.catcooldown.args.party.order > args.catcooldown.args.sound.order)
      for _, c in ipairs(ns.Announce.listed()) do
        local row = args["cat" .. c.key].args
        assert.is_nil(row.floor, c.key .. " still offers the cooldown slider")
        if not c.shareable then
          assert.is_nil(row.party, c.key .. " must not offer party")
          assert.is_nil(row.raid, c.key .. " must not offer raid")
        end
      end
    end)

    -- The routing write is the one that has bitten before: creating the stored row first makes
    -- `A.routes` stop falling back, so switching one channel on switched every other one off.
    it("stores a party choice without silently clearing the row's other channels", function()
      local row = announceArgs().catcooldown.args
      assert.is_false(row.party.get())
      row.party.set(nil, true)
      assert.is_true(ns.db.profile.announce.routes.cooldown.party)
      assert.is_true(row.party.get())
      row.raid.set(nil, true)
      assert.is_true(ns.db.profile.announce.routes.cooldown.raid)
      assert.is_true(row.party.get(), "turning raid on cleared party")
    end)

    -- AB1-D10: the row has to say when it fires, and the answer is now "when an ability you
    -- switched on is used" rather than "when a cooldown is longer than N seconds".
    it("says the cooldown row fires from the ability's own Announcement tab", function()
      local desc = announceArgs().catcooldown.args.chat.desc
      assert.is_truthy(desc:find("Announcement tab", 1, true))
    end)

    -- The Log is the record, not a channel: no row can switch it off.
    it("offers chat, screen and sound for every kind, and never the log", function()
      local args = announceArgs()
      assert.is_nil(args.catrotation.args.log)
      assert.is_not_nil(args.catrotation.args.chat)
      assert.is_not_nil(args.catrotation.args.screen)
      assert.is_not_nil(args.catrotation.args.sound)
    end)

    it("shows the shipped routing before the user has touched anything", function()
      local args = announceArgs()
      assert.is_true(args.catrotation.args.chat.get())
      assert.is_true(args.catrotation.args.screen.get())
      assert.is_false(args.catrotation.args.sound.get())
    end)

    -- Switching one channel on must not switch the category's other channels off: an empty stored
    -- row means "use the defaults", so the first touch has to copy them before writing.
    it("keeps the other channels when one is changed", function()
      announceArgs().catrotation.args.sound.set(nil, true)
      local args = announceArgs()
      assert.is_true(args.catrotation.args.sound.get())
      assert.is_true(args.catrotation.args.chat.get())
      assert.is_true(args.catrotation.args.screen.get())
    end)

    it("turns a channel off and keeps it off", function()
      announceArgs().catrotation.args.chat.set(nil, false)
      assert.is_false(announceArgs().catrotation.args.chat.get())
      assert.is_true(announceArgs().catrotation.args.screen.get())
    end)

    -- D25: there is no "which of my tabs" select any more -- a plain sentence says how Elmira
    -- decides, since the decision itself now lives in Display/Announcers, not a stored index here.
    it("explains how the chat sink picks a window, instead of offering a stale index", function()
      local row = announceArgs().chatInfo
      assert.equal("description", row.type)
      assert.is_truthy(row.name:find("System messages", 1, true))
      assert.is_nil(announceArgs().chatWindow)
    end)

    it("applies the font, size and duration to the frame as they change", function()
      local applied = 0
      ns.Announcers.ApplyFont = function() applied = applied + 1 end
      announceArgs().font.set(nil, "Expressway")
      announceArgs().size.set(nil, 22)
      announceArgs().duration.set(nil, 6)
      assert.equal(3, applied)
      assert.equal("Expressway", ns.db.profile.announce.screen.font)
      assert.equal(22, ns.db.profile.announce.screen.size)
      assert.equal(6, ns.db.profile.announce.screen.duration)
    end)

    it("shows what is currently set, not a blank control", function()
      local args = announceArgs()
      assert.equal("Friz Quadrata TT", args.font.get())
      assert.equal(18, args.size.get())
      assert.equal(4, args.duration.get())
    end)

    it("offers the fonts the player actually has", function()
      local args = announceArgs()
      assert.equal("Friz Quadrata TT", args.font.values()["Friz Quadrata TT"])
    end)

    -- PE13-D2/D3. It was a toggle disabled while positions were locked -- and `locked` defaults to
    -- TRUE, so out of the box it was grey and pointed at another page. It is the same control as
    -- the Queue page's "Position the Strip" now: an execute that relabels while the mode is on.
    it("relabels while move mode is on instead of ever going grey", function()
      local row = announceArgs().move
      assert.equal("execute", row.type)
      assert.equal("Move screen messages", row.name())
      assert.is_nil(row.disabled)
      assert.is_nil(row.get)
      ns.Announcers.isMoving = function() return true end
      assert.equal("Done Moving", announceArgs().move.name())
    end)

    -- Every word of the promise. "Your lock setting is left exactly as it was" is the sentence
    -- that makes this a MODE rather than a setting, and the desc is several lines of concatenation
    -- -- losing one of them loses the promise without emptying the tooltip.
    it("says exactly what pressing it does, and what it does not touch", function()
      assert.equal("Shows one sample of every kind so you can see how tall it gets, and lets you "
        .. "drag it. Press it again when it is where you want it. Your lock setting is left "
        .. "exactly as it was, and closing this window ends it too.", announceArgs().move.desc)
    end)

    -- The Notifications page is built whether or not Display/Announcers is loaded, so the button
    -- exists before there is anything to move. Pressing it then must answer, not error.
    it("does nothing rather than erroring with no announcers loaded", function()
      local row = announceArgs().move
      ns.Announcers = nil
      assert.has_no.errors(function() row.func() end)
    end)

    it("stays usable, and says nothing about unlocking, while positions are locked", function()
      ns.Queue.isLocked = function() return true end
      local row = announceArgs().move
      assert.equal("Move screen messages", row.name())
      assert.is_nil(row.disabled)
      assert.is_nil(row.desc:find("Unlock"))
      -- And pressing it while locked really does start the mode, rather than doing nothing.
      local moved
      ns.Announcers.SetMoving = function(v) moved = v end
      row.func()
      assert.is_true(moved)
    end)

    -- The mode is temporary and the lock is a setting: pressing this must never store one as the
    -- other, or a /reload mid-drag would leave the player unlocked for good.
    it("never writes the lock setting", function()
      ns.Queue.isLocked = function() return true end
      ns.db.profile.locked = true
      announceArgs().move.func()
      assert.is_true(ns.db.profile.locked)
      ns.Announcers.isMoving = function() return true end
      announceArgs().move.func()
      assert.is_true(ns.db.profile.locked)
    end)

    -- D24: the shared "Sound" select under "How they look" is gone; each row picks its own.
    it("has no shared sound select any more", function()
      assert.is_nil(announceArgs().sound)
    end)

    it("reveals a category's own sound select only while its Sound toggle is on", function()
      local args = announceArgs().catrotation.args
      assert.is_true(args.soundPick.hidden())    -- Rotation ships with sound off
      args.sound.set(nil, true)
      assert.is_false(args.soundPick.hidden())
    end)

    it("chooses a sound for one category without touching another's", function()
      local rotation, warning = announceArgs().catrotation.args, announceArgs().catwarning.args
      rotation.soundPick.set(nil, "Chime")
      assert.equal("Chime", ns.db.profile.announce.sounds.rotation)
      assert.equal("Chime", rotation.soundPick.get())
      -- Falls back to the shared sound until a category has one of its own.
      assert.equal("None", warning.soundPick.get())
    end)

    it("builds the per-category sound select as a real select, right after its Sound toggle", function()
      local args = announceArgs().catrotation.args
      assert.equal("select", args.soundPick.type)
      assert.equal("Sound", args.soundPick.name)
      assert.equal(args.sound.order + 0.5, args.soundPick.order)
      assert.equal("Chime", args.soundPick.values().Chime)
    end)

    -- The set() has to survive a profile that has never touched a per-category sound at all --
    -- not merely one the fixture already gave an empty table.
    it("creates announce.sounds on first use rather than assuming it exists", function()
      ns.db.profile.announce.sounds = nil
      announceArgs().catrotation.args.soundPick.set(nil, "Chime")
      assert.equal("Chime", ns.db.profile.announce.sounds.rotation)
    end)

    -- PE14-D2: picking a sound plays it. The names come from whatever media packs the player runs,
    -- so the list means nothing on its own, and the only other way to audition one was to go and
    -- make a real notification happen. It plays through the announcement sink itself, AFTER
    -- storing, so what is heard is exactly what the next real message will use.
    it("plays the sound it was just given, through the sink the announcement uses", function()
      local heard = {}
      ns.Announcers.sound = function(c)
        heard[#heard + 1] = { key = c and c.key, name = ns.db.profile.announce.sounds[c and c.key] }
      end
      announceArgs().catwarning.args.soundPick.set(nil, "Chime")
      assert.same({ { key = "warning", name = "Chime" } }, heard)
      -- "None" goes down the same path; staying silent is that path's own answer.
      announceArgs().catwarning.args.soundPick.set(nil, "None")
      assert.same({ key = "warning", name = "None" }, heard[2])
    end)

    -- It runs from inside a widget's own handler, where a throw is a visible Lua error.
    it("still stores the choice when there is nothing able to play it", function()
      ns.Announcers.sound = nil
      announceArgs().catwarning.args.soundPick.set(nil, "Chime")
      assert.equal("Chime", ns.db.profile.announce.sounds.warning)
    end)

    it("turns move mode on, and the second press ends it", function()
      local moved, stopped = nil, 0
      ns.Announcers.SetMoving = function(v) moved = v end
      ns.Announcers.StopMoving = function() stopped = stopped + 1 end
      announceArgs().move.func()
      assert.is_true(moved)
      assert.equal(0, stopped)
      ns.Announcers.isMoving = function() return true end
      announceArgs().move.func()
      assert.equal(1, stopped)
    end)

    -- One message per kind THE PAGE SHOWS. The button and the routing table read the same list,
    -- so it cannot go on testing a kind there is no row for -- which since AB1-D10 is all of them.
    it("sends one message of every kind the page shows, and none it does not", function()
      announceArgs().test.func()
      assert.equal(#ns.Announce.listed(), #ns.Announce.log())
      local seen = {}
      for _, entry in ipairs(ns.Announce.log()) do seen[entry.category] = true end
      for _, c in ipairs(ns.Announce.listed()) do
        assert.is_true(seen[c.key] == true, c.key .. " was never sent")
      end
    end)

    -- A button for previewing your own settings must not put six lines in a group's chat.
    it("keeps the test messages out of party, whatever the routing says", function()
      local partied = 0
      ns.Announce.registerSink("party", function() partied = partied + 1 end)
      ns.db.profile.announce.routes.rotation = { party = true, raid = true }
      announceArgs().test.func()
      assert.equal(0, partied)
    end)

    -- Each row is a control the user has to be able to recognise. A row with no type does not
    -- render, and one with no name renders as an unlabelled widget.
    it("builds every control as what it claims to be", function()
      local args = announceArgs()
      local expected = {
        intro      = { type = "description", order = 0 },
        log        = { type = "group", order = 90, name = "Notifications Log" },
        routing    = { type = "header", order = 40, name = "Where each kind of message goes" },
        where      = { type = "header", order = 60, name = "How they look" },
        chatInfo   = { type = "description", order = 61 },
        font       = { type = "select", order = 62, name = "Screen font" },
        size       = { type = "range", order = 63, name = "Screen text size" },
        duration   = { type = "range", order = 64, name = "Seconds on screen" },
        move       = { type = "execute", order = 66, name = "Move screen messages" },
        test       = { type = "execute", order = 67, name = "Test Each Kind" },
      }
      for key, want in pairs(expected) do
        local row = args[key]
        assert.is_not_nil(row, key .. " is missing")
        assert.equal(want.type, row.type, key .. " is the wrong kind of control")
        assert.equal(want.order, row.order, key .. " is in the wrong place")
        if want.name then
          local name = type(row.name) == "function" and row.name() or row.name
          assert.equal(want.name, name, key .. " is labelled wrongly")
        end
      end
      local log = logArgs()
      assert.equal("description", log.logHeader.type)
      assert.equal(1, log.logHeader.order)
      assert.is_truthy(log.logHeader.name:find("newest first"))
      assert.equal("medium", log.logHeader.fontSize)
      assert.equal("description", log.logEmpty.type)
      assert.equal(2, log.logEmpty.order)
      assert.equal("execute", log.logClear.type)
      assert.equal(30, log.logClear.order)
      assert.equal("Clear Messages", log.logClear.name)
      assert.is_truthy(args.move.desc)
      assert.is_truthy(args.test.desc)
      -- Removed entirely, not merely renamed (D24/D25).
      assert.is_nil(args.chatWindow)
      assert.is_nil(args.sound)
    end)

    it("bounds the size and duration sliders where a human can read them", function()
      local args = announceArgs()
      assert.equal(10, args.size.min)
      assert.equal(36, args.size.max)
      assert.equal(1, args.size.step)
      assert.equal(1, args.duration.min)
      assert.equal(15, args.duration.max)
      assert.equal(1, args.duration.step)
    end)

    it("names and colours each category's row and keeps them in order", function()
      local args = announceArgs()
      for i, c in ipairs(ns.Announce.listed()) do
        local group = args["cat" .. c.key]
        assert.equal("group", group.type)
        assert.equal(40 + i, group.order)
        assert.is_truthy(group.name:find(c.label), c.key .. " is not labelled")
        assert.is_truthy(group.name:find(ns.Colors[c.color].hex), c.key .. " is not in its colour")
      end
    end)

    -- The toggles used to be ordered by pairs(), so they came out in a different order for every
    -- category and a different order again on another Lua build.
    it("lays the channel toggles out in one fixed order in every row", function()
      for _, c in ipairs(ns.Announce.listed()) do
        local args = announceArgs()["cat" .. c.key].args
        for _, key in ipairs({ "chat", "screen", "sound" }) do
          assert.equal("toggle", args[key].type, key .. " is not a toggle")
          assert.is_not_nil(args[key].name, key .. " has no label")
        end
        assert.equal(1, args.chat.order)
        assert.equal(2, args.screen.order)
        assert.equal(3, args.sound.order)
      end
    end)

    -- D22: every toggle in a row shares the same "when it fires" sentence -- the whole point is
    -- that the reader learns WHEN before picking a pipe.
    it("gives every toggle in a row the same when-it-fires sentence", function()
      local args = announceArgs().catwarning.args
      assert.is_truthy(args.chat.desc)
      assert.equal(args.chat.desc, args.screen.desc)
      assert.equal(args.chat.desc, args.sound.desc)
    end)

    -- Each category's own sentence, not the same text copy-pasted for all four.
    -- Verbatim from the "When it fires" column of the Notifications artifact (e1fc0af9).
    it("gives each category its own when-it-fires sentence", function()
      local args = announceArgs()
      assert.truthy(args.catrotation.args.chat.desc:find(
        "a line in your rotation becomes usable or stops being usable", 1, true))
      assert.truthy(args.catwarning.args.chat.desc:find(
        "no visible bar button holds the spell, or a display component errored", 1, true))
      assert.truthy(args.catstatus.args.chat.desc:find(
        "Learning mode rewrites two other settings", 1, true))
    end)

    -- Without a cap the panel grows without limit and the switches below the log become
    -- unreachable on a long session.
    it("lists at most twenty log lines however many there are", function()
      for i = 1, 25 do ns.Announce.emit("status", "line " .. i) end
      local text = logArgs().lines.get()
      local shown = 0
      for _ in (text .. "\n"):gmatch("(.-)\n") do shown = shown + 1 end
      assert.equal(20, shown)
      assert.is_truthy(text:find("line 25", 1, true))
      assert.is_nil(text:find("line 5\n", 1, true), "a line past the cap is in the box")
    end)
  end)

  -- Move mode enables the mouse on a frame across the middle of the screen. Closing the panel has
  -- to end it, or that frame sits there eating clicks with nothing on screen to explain it.
  -- The gate on the Builder's live refresh (Options/Rotation.onQueueChanged). It runs on every
  -- queue change, which in combat is several times a second, and what it guards is expensive and
  -- destructive: `AceConfigRegistry:NotifyChange` rebuilds the WHOLE options table, and an AceGUI
  -- EditBox commits only on Enter -- so a rebuild that lands mid-keystroke silently throws away
  -- whatever was half-typed into a condition value.
  describe("builderIdle()", function()
    local function fakeDialog(opts)
      opts = opts or {}
      return {
        OpenFrames = opts.standalone and { Elmira = {} } or {},
        GetStatusTable = function(_, app, path)
          assert.equal("Elmira", app)
          assert.same({ "rotation" }, path)
          if opts.noGroups then return {} end
          return { groups = { selected = opts.tab or "builder" } }
        end,
      }
    end

    it("is true when the standalone panel is open on the Builder and nobody is typing", function()
      Options.dialog = fakeDialog{ standalone = true }
      assert.is_true(Options.builderIdle())
    end)

    it("is true for the Blizzard-embedded panel too", function()
      Options.dialog = fakeDialog{}
      Options.frame = { IsVisible = function() return true end }
      assert.is_true(Options.builderIdle())
      Options.frame = { IsVisible = function() return false end }
      assert.is_false(Options.builderIdle(), "a hidden embedded panel is not on screen")
    end)

    it("is false when no panel is on screen at all", function()
      Options.dialog = fakeDialog{}
      Options.frame = nil
      assert.is_false(Options.builderIdle())
    end)

    -- NotifyChange rebuilds every section, so refreshing while the player is reading Rotations
    -- would throw away their place for a status column they cannot see.
    it("is false when a different tab is showing", function()
      Options.dialog = fakeDialog{ standalone = true, tab = "rotations" }
      assert.is_false(Options.builderIdle())
      Options.dialog = fakeDialog{ standalone = true, tab = "share" }
      assert.is_false(Options.builderIdle())
    end)

    -- `groups` does not exist until the tab group has been opened once, which is the state on the
    -- very first render -- and indexing it is what would take the render loop down.
    it("is false, not an error, before the tab group has ever been opened", function()
      Options.dialog = fakeDialog{ standalone = true, noGroups = true }
      assert.is_false(Options.builderIdle())
    end)

    it("is false while someone is typing into a box", function()
      Options.dialog = fakeDialog{ standalone = true }
      ns.Adapter = { typing = function() return true end }
      assert.is_false(Options.builderIdle())
      ns.Adapter = { typing = function() return false end }
      assert.is_true(Options.builderIdle())
    end)

    it("is false, not an error, before the panel has been registered", function()
      Options.dialog = nil
      Options.frame = nil
      assert.is_false(Options.builderIdle())
    end)

    -- An adapter that cannot answer "is anyone typing" is a client where the refresh is a little
    -- too eager, not one where the render loop errors.
    it("tolerates an adapter with no typing() at all", function()
      Options.dialog = fakeDialog{ standalone = true }
      ns.Adapter = {}
      assert.is_true(Options.builderIdle())
      ns.Adapter = nil
      assert.is_true(Options.builderIdle())
    end)
  end)

  describe("Options.Open", function()
    it("ends move mode when the panel is closed", function()
      local stopped, closer = 0, nil
      ns.Announcers = { StopMoving = function() stopped = stopped + 1 end }
      Options.dialog = {
        Open = function() end,
        SelectGroup = function() end,
        OpenFrames = { Elmira = { SetCallback = function(_, event, fn)
          if event == "OnClose" then closer = fn end
        end } },
      }
      assert.is_true(Options.Open())
      assert.is_function(closer, "nothing was hooked to the panel closing")
      closer()
      assert.equal(1, stopped)
    end)

    -- The Rotation section is the front door, so /elm rotation has to land on it -- WITHOUT losing
    -- the left menu. AceConfigDialog:Open(appName, container, ...) stores a path as the frame's
    -- basepath and feeds THAT group as the window's root, showing only the Rotation subtree; the fix
    -- is to open with no path at all and move the selection with SelectGroup instead.
    it("opens with no basepath and selects the section separately, so the left menu survives", function()
      local opened, selected = {}, nil
      ns.Announcers = { StopMoving = function() end }
      Options.dialog = {
        Open = function(_, app, container, ...) opened = { app, container, ... } end,
        SelectGroup = function(_, app, ...) selected = { app, ... } end,
      }
      assert.is_true(Options.Open("rotation"))
      assert.same({ "Elmira" }, opened, "Open must carry no path, or it becomes the window's root")
      assert.same({ "Elmira", "rotation" }, selected)
    end)

    -- D61e (2026-09-07 in-game round): AceConfigDialog selects the LOWEST-order group when nothing
    -- has been selected yet, which is Rotations (order 0) -- so `/elm config` landed there instead
    -- of General (order 1). `Options.Open()` with no path now selects General explicitly.
    it("opens with no path at all, which is what /elm config wants, and lands on General", function()
      local got, selected = nil, nil
      ns.Announcers = { StopMoving = function() end }
      Options.dialog = {
        Open = function(_, app, container, ...) got = { app, container, ... } end,
        SelectGroup = function(_, app, ...) selected = { app, ... } end,
      }
      assert.is_true(Options.Open())
      assert.same({ "Elmira" }, got, "Open must carry no path, or it becomes the window's root")
      assert.same({ "Elmira", "general" }, selected)
    end)

    it("opens without erroring on a dialog that exposes no frames", function()
      ns.Announcers = { StopMoving = function() end }
      Options.dialog = { Open = function() end, SelectGroup = function() end }
      assert.is_true(Options.Open())
    end)

    -- AceGUI keeps ONE callback per event name (`widget.events[name]`), so setting OnClose here
    -- REPLACES the one AceConfigDialog has already installed -- FrameOnClose, which clears
    -- OpenFrames[appName] and releases the widget back to the pool. M5g shipped the replacing
    -- version, so from then on every close leaked the frame and left the app registered as open.
    -- Nothing noticed, because the move-mode assertion above passes either way.
    local function fakeWidget(prior)
      local w = { events = { OnClose = prior } }
      function w:SetCallback(event, fn) self.events[event] = fn end
      function w:fireClose() return self.events.OnClose(self, "OnClose") end
      return w
    end

    it("chains the dialog's own OnClose instead of replacing it", function()
      local released, stopped = 0, 0
      ns.Announcers = { StopMoving = function() stopped = stopped + 1 end }
      local widget = fakeWidget(function() released = released + 1 end)
      Options.dialog = { Open = function() end, SelectGroup = function() end,
                         OpenFrames = { Elmira = widget } }

      assert.is_true(Options.Open())
      widget:fireClose()

      assert.equal(1, stopped, "move mode was not ended")
      assert.equal(1, released, "AceConfigDialog's own OnClose never ran, so the frame leaks")
    end)

    -- Our own StopMoving runs from a frame's OnHide. If it throws, it must not take the dialog's
    -- cleanup down with it -- the whole reason the callback is chained rather than replaced.
    it("still runs the dialog's OnClose when ending move mode errors, and says so", function()
      local released, logged = 0, {}
      ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
      ns.Announcers = { StopMoving = function() error("MessageFrame has no Clear()") end }
      local widget = fakeWidget(function() released = released + 1 end)
      Options.dialog = { Open = function() end, SelectGroup = function() end,
                         OpenFrames = { Elmira = widget } }

      assert.is_true(Options.Open())
      widget:fireClose()

      assert.equal(1, released, "an error in our callback skipped the dialog's cleanup")
      -- Swallowing it would leave a mouse-enabled frame across the middle of the screen with
      -- nothing anywhere saying why -- the silent failure this codebase keeps producing.
      assert.equal(1, #logged, "the failure to leave move mode was never reported")
      assert.is_truthy(logged[1]:find("move mode", 1, true))
    end)

    -- The chain reads AceGUI's `widget.events` to find the callback it must not drop. A widget that
    -- does not expose it must still open and still end move mode, rather than erroring on the way.
    it("opens against a widget that exposes no events table", function()
      local stopped = 0
      ns.Announcers = { StopMoving = function() stopped = stopped + 1 end }
      local widget = { SetCallback = function(self, event, fn) self.closer = fn end }
      Options.dialog = { Open = function() end, SelectGroup = function() end,
                         OpenFrames = { Elmira = widget } }

      assert.is_true(Options.Open())
      assert.is_function(widget.closer, "nothing was hooked to the panel closing")
      widget.closer(widget, "OnClose")
      assert.equal(1, stopped)
    end)

    -- A second Open must chain onto the dialog's callback, never onto the wrapper the first Open
    -- installed. AceConfigDialog re-sets its own every time so this should be unreachable; without
    -- the guard the unreachable case is unbounded recursion, which is a worse failure than a leak.
    -- The dialog's callback must still survive the re-open, and be called once, not twice.
    it("does not chain onto itself when the panel is opened twice", function()
      local released, stopped = 0, 0
      ns.Announcers = { StopMoving = function() stopped = stopped + 1 end }
      local widget = fakeWidget(function() released = released + 1 end)
      Options.dialog = { Open = function() end, SelectGroup = function() end,
                         OpenFrames = { Elmira = widget } }

      assert.is_true(Options.Open())
      assert.is_true(Options.Open()) -- the dialog did NOT reinstate its own callback in between
      widget:fireClose()

      assert.equal(1, stopped, "move mode was not ended after a re-open")
      assert.equal(1, released, "the dialog's own OnClose was lost or run twice on a re-open")
    end)
  end)

  -- PRD F9: the Import/Export box. The import itself is Core/UserBuilds' job and is tested there;
  -- here the box must route text in and out and report the outcome under it.
  -- The WIDGET moved to Options/Rotation.lua's Share tab (ADR-0015 SS2); the state stayed here.
  -- This block drives that state through the accessors the tab reads, so it keeps testing the
  -- behaviour rather than the layout. The tab's own wiring is rotation_spec's job.
  -- AB1-D10: the cooldown floor is gone entirely -- from the page, from the profile defaults and
  -- from Core. A duration cannot tell a tank's defensive save from a DPS burst, which is the
  -- distinction that decides whether a group wants to hear about it, so the ability's own
  -- Announcement tab decides instead.
  describe("what counts as a cooldown worth announcing", function()
    it("is not asked anywhere on the Notifications page, and no longer exists in Core", function()
      helper.load("Elmira/Core/Announce.lua")
      local page = Options.table().args.notifications.args
      assert.is_nil(page.floor)
      for key, entry in pairs(page) do
        if type(entry) == "table" and type(entry.args) == "table" then
          assert.is_nil(entry.args.floor, key .. " still carries the cooldown slider")
        end
      end
      assert.is_nil(ns.Announce.cooldownFloor)
      assert.is_nil(ns.Announce.worthAnnouncing)
    end)
  end)

  describe("Import / Export box", function()
    local function box()
      return {
        text = { get = Options.exchangeText, set = function(_, v) Options.importText(v) end },
        note = { name = Options.exchangeNote },
      }
    end

    it("shows what /elm export placed in it", function()
      Options.setExchangeText("ELM1:abc")
      assert.equal("ELM1:abc", box().text.get())
      assert.equal("", box().note.name())
    end)

    it("starts empty, and exchangeText() reads the same value the box shows", function()
      assert.equal("", box().text.get())
      assert.equal("", box().note.name())
      Options.setExchangeText("ELM1:q")
      assert.equal(Options.exchangeText(), box().text.get())
    end)


    it("imports on set: clears the box, names the new fork, refreshes the display, and returns the key", function()
      local got, refreshes = nil, 0
      ns.Display.refresh = function() refreshes = refreshes + 1 end
      Options.setExchangeText("ELM1:xyz")
      ns.Display.currentPack = function() return { class = "PALADIN" } end
      ns.UserBuilds = { importString = function(str, pack, opts) got = { str = str, class = pack.class, today = opts.today }; return "USER_X" end }
      ns.Adapter = { today = function() return "2026-09-03" end }
      box().text.set(nil, "ELM1:xyz")
      assert.same({ str = "ELM1:xyz", class = "PALADIN", today = "2026-09-03" }, got)
      assert.equal("", box().text.get())
      assert.truthy(box().note.name():find("USER_X", 1, true))
      assert.equal(1, refreshes)
      local ok, key = Options.importText("ELM1:again")
      assert.is_true(ok); assert.equal("USER_X", key)
    end)

    it("a new string placed by /elm export clears an earlier failure note", function()
      ns.Display.currentPack = function() return { class = "PALADIN" } end
      ns.UserBuilds = { importString = function() return nil, "corrupted string" end }
      Options.importText("ELM1:bad")
      assert.truthy(box().note.name():find("corrupted", 1, true))
      Options.setExchangeText("ELM1:fresh")
      assert.equal("", box().note.name())
    end)

    -- AB2-D5: a rotation string may carry the settings of the abilities it names. They are applied
    -- by Core/UserBuilds at the one place a string is accepted; this line is what SAYS so --
    -- settings that arrived silently and overwrote what the player had are the worst surprise
    -- there is, and settings that did not arrive look identical to ones that did.
    it("says how many ability settings came with the rotation, and nothing when none did", function()
      ns.Display.currentPack = function() return { class = "PALADIN" } end
      ns.UserBuilds = { importString = function() return "USER_X", 3 end }
      Options.importText("ELM1:withsettings")
      assert.truthy(box().note.name():find("USER_X", 1, true))
      assert.truthy(box().note.name():find("3 abilities", 1, true))
      ns.UserBuilds = { importString = function() return "USER_Y", 0 end }
      Options.importText("ELM1:plain")
      assert.is_falsy(box().note.name():find("abilities", 1, true))
    end)

    -- The Rotations Share tab's Export button reports through the same one-line note (AB2-D5), and
    -- `setExchangeText` deliberately CLEARS that note -- a stale "Import failed" under a freshly
    -- exported string would be read as a failure to export.
    it("carries a note the exporter writes, and clears it when a new string is placed", function()
      Options.noteExchange("Exported PALADIN_EXODIN.")
      assert.equal("Exported PALADIN_EXODIN.", Options.exchangeNote())
      Options.setExchangeText("ELM1:new")
      assert.equal("", Options.exchangeNote())
      Options.noteExchange(nil)
      assert.equal("", Options.exchangeNote())
    end)

    it("keeps the text and shows the reason when the import fails, or when there is no pack", function()
      ns.Display.currentPack = function() return { class = "PALADIN" } end
      ns.UserBuilds = { importString = function() return nil, "corrupted string" end }
      assert.is_false(Options.importText("ELM1:bad"))
      assert.equal("ELM1:bad", box().text.get())
      assert.truthy(box().note.name():find("corrupted string", 1, true))
      ns.Display.currentPack = function() return nil end
      assert.is_false(Options.importText("ELM1:bad"))
      assert.truthy(box().note.name():find("no data pack", 1, true))
    end)
  end)

  -- AB4-D2. Everything an ability does on screen moved to `db.char` at AB1-D3, so this page's
  -- Copy From and Reset no longer reach any of it. That is a deliberate scope change and an
  -- invisible one: a player who copies a profile to an alt and finds none of their cues followed
  -- has no way to tell that from a bug.
  describe("the Profiles page says what a profile no longer carries", function()
    local function profilesTable()
      return Options.profilesTable({ GetOptionsTable = function()
        return { type = "group", name = "Profiles", args = { desc = { type = "description", order = 1 } } }
      end })
    end

    it("adds one line naming every per-character channel and where to copy them", function()
      local row = profilesTable().args.elmiraAbilityScope
      assert.equal("description", row.type)
      assert.is_true(row.order < 1, "the note has to be read before the Copy From button, not after")
      for _, word in ipairs({ "glow", "textures", "screen edge", "sounds", "announcements",
                             "per character", "Abilities > Share" }) do
        assert.truthy(row.name:find(word, 1, true), "the note never mentions " .. word)
      end
    end)

    it("keeps AceDBOptions' own rows, rather than replacing the page", function()
      local args = profilesTable().args
      assert.is_not_nil(args.desc, "the library's own page was thrown away")
      assert.equal("Profiles", profilesTable().name)
    end)

    it("adds the note to a library table that arrives with no args at all", function()
      local bare = Options.profilesTable({ GetOptionsTable = function()
        return { type = "group", name = "Profiles" }
      end })
      assert.is_not_nil(bare.args.elmiraAbilityScope)
    end)

    -- The call SITE, not just the function: this project's characteristic defect is a covered
    -- function nothing reaches, and `Options.Register` had no test at all before this. LibStub is
    -- faked rather than loaded, so what is asserted is the table AceConfig was actually handed.
    it("registers the annotated table, not AceDBOptions' own, when the panel is built", function()
      local registered = {}
      local realLibStub = _G.LibStub
      _G.LibStub = function(name)
        if name == "AceConfig-3.0" then
          return { RegisterOptionsTable = function(_, app, tbl) registered[app] = tbl end }
        elseif name == "AceConfigDialog-3.0" then
          return { AddToBlizOptions = function() return { frame = true } end }
        elseif name == "AceDBOptions-3.0" then
          return { GetOptionsTable = function() return { type = "group", args = {} } end }
        end
      end
      ns.db.profile.announce = { routes = {}, screen = {}, sounds = {} }
      local ok = Options.Register()
      _G.LibStub = realLibStub
      assert.is_true(ok)
      assert.is_not_nil(registered["Elmira"], "the main options table was never registered")
      assert.is_not_nil(registered["Elmira-Profiles"].args.elmiraAbilityScope,
        "the Profiles page went in without the note")
    end)
  end)

  -- AB2-D1 moved the screen flash onto the ability that owns it and left this page as a signpost.
  -- AB4-D2 removes the node: nothing has ever shipped, so there is nobody who knew the old page to
  -- lead anywhere, and the signpost was the last thing on the Notifications page that could send
  -- someone looking for cue settings anywhere but Abilities.
  describe("Peripheral cues (AB4-D2: the page is gone)", function()
    it("has no node under Notifications and no group anywhere in the table", function()
      assert.is_nil(Options.table().args.notifications.args.overlay)
      for key, arg in pairs(Options.table().args) do
        assert.is_nil(arg.args and arg.args.overlay, "a Peripheral cues node survives under " .. key)
      end
    end)

    -- The whole point of the rewrite: nothing on these pages reads the profile-scoped cue store or
    -- calls into Overlay any more, so a build that suggests nothing and a build that suggests three
    -- render identically.
    it("does not touch ns.Overlay at all", function()
      ns.Overlay = setmetatable({}, { __index = function(_, k)
        error("Options must not call ns.Overlay." .. tostring(k))
      end })
      assert.has_no.errors(function() Options.table() end)
    end)
  end)
end)

-- R2 (D52): the Spells page is wired into the top-level tree the same way Rotations is -- a
-- one-line guard that calls through to the module's own `group()`. This is its own top-level
-- `describe`, mirroring options_spec.lua's own top-level setup, rather than reusing the shared
-- before_each above: that one deliberately never loads ns.SpellsPage, and every test in it already
-- proves the ABSENT case (Options.table() never errors without it).
describe("Options.table() wires in the Spells page (R2 D52)", function()
  local Options, ns

  before_each(function()
    ns = helper.reset()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Display/Overlay.lua")
    ns.db = { profile = { overlay = { cues = {} } } }
    ns.Overlay.Flare = function() return true end
    ns.Display = { activeBuild = function() return { visuals = { cues = {} } } end,
                   refresh = function() end }
  end)

  it("reads the Spells page's own group() into args.spells when the module is loaded", function()
    ns.SpellsPage = { group = function() return { type = "group", name = "Spells", order = 0.5 } end }
    Options = helper.load("Elmira/Options/Options.lua")
    local spells = Options.table().args.spells
    assert.equal("group", spells.type)
    assert.equal("Spells", spells.name)
    assert.equal(0.5, spells.order)
  end)

  it("leaves args.spells nil, rather than erroring, when the module has not loaded", function()
    Options = helper.load("Elmira/Options/Options.lua")
    assert.is_nil(Options.table().args.spells)
  end)
end)
