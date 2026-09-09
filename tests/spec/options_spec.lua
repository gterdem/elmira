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
      assert.equal("Only when longer than a GCD", queueArgs().waits.values().gcd)

      assert.equal("Keybinds", queueArgs().keybinds.name)
      assert.equal("first", queueArgs().keybinds.get())
      assert.same({ "off", "first", "all" }, queueArgs().keybinds.sorting())
      assert.equal("On every icon", queueArgs().keybinds.values().all)

      assert.equal("Show the rule name", queueArgs().showReason.name)
      assert.is_false(queueArgs().showReason.get())

      queueArgs().waits.set(nil, "always")
      queueArgs().keybinds.set(nil, "off")
      queueArgs().showReason.set(nil, true)
      assert.equal("always", ns.db.profile.waits)
      assert.equal("off", ns.db.profile.keybinds)
      assert.is_true(ns.db.profile.showReason)
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
    -- Twice, because whole sections are built from the ACTIVE BUILD and the empty-build panel is a
    -- different set of rows: the peripheral-cue page is a single "nothing suggests one" line until
    -- a build suggests a cue, and then it is a heading and a group per cue.
    ns.Display.activeBuild = function()
      return { visuals = { cues = { { event = "now_slot", spell = "EXORCISM",
                                      reason = "Exorcism up", edge = "left" } } } }
    end
    walk(Options.table(), "Elmira(with cues)")
  end)

  -- ADR-0015 §3 makes the bar glow the single attention signal, so it gets the range of control
  -- that deserves. Every row below could be present and do nothing; these check it does something.
  describe("Glow appearance", function()
    local function glowArgs() return Options.table().args.glow.args end
    -- PE7-D3: the cast-after-next cluster lives on General -> Action Bars -> Action bar glow now,
    -- under the switch that decides whether anything on the bars glows at all. Same controls, same
    -- behaviour, one page across -- so these assertions moved with them rather than being rewritten.
    local function hintArgs() return Options.table().args.general.args.bars.args.check.args end

    before_each(function()
      ns.db.profile.glow = { style = "PIXEL", barGlow = true, color = false,
                             particles = false, frequency = false, thickness = false,
                             speed = false, secondary = false }
      helper.load("Elmira/Display/Glow.lua")
      ns.Queue = { Layout = function() end }
    end)

    it("still offers the cue-sound switch after the move under Notifications", function()
      local row = Options.table().args.notifications.args.sounds.args.enabled
      assert.equal("toggle", row.type)
      assert.equal(1, row.order)
      assert.equal("Play cue sounds", row.name)
      assert.is_truthy(row.desc)
      ns.db.profile.sounds = { enabled = false }
      assert.is_false(row.get())
      row.set(nil, true)
      assert.is_true(ns.db.profile.sounds.enabled)
      assert.is_true(row.get())
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
                    Stop = function() end, isRendererFrame = function() return false end }
        Options.setCheckSpell("EXORCISM")
        row.func()
        assert.is_true(lit, "the dim preview lit the bright glow")
        glowArgs().preview.func()
        assert.is_false(lit, "the ordinary preview should not be dim")
      end)
    end)

    -- The settings are worth playing with, and there was no way back: the colour picker's Default
    -- button belongs to Blizzard's frame and never touched what we stored.
    describe("resetting the section", function()
      it("puts every glow setting back the way it shipped", function()
        helper.load("Elmira/Core/DB.lua")
        ns.db.profile.glow.style = "PROC"
        ns.db.profile.glow.color = { r = 1, g = 0, b = 0 }
        ns.db.profile.glow.secondary = true
        ns.db.profile.glow.particles = 19
        assert.is_true(Options.resetGlow())
        local shipped = ns.DB.defaults.profile.glow
        assert.equal(shipped.style, ns.db.profile.glow.style)
        assert.equal(shipped.particles, ns.db.profile.glow.particles)
        assert.equal(shipped.secondary, ns.db.profile.glow.secondary)
        assert.equal(shipped.color, ns.db.profile.glow.color)
      end)

      -- The defaults table is what every future profile is copied from: writing through a shared
      -- reference would change the shipped default for everyone made afterwards.
      it("never hands out the defaults table itself", function()
        helper.load("Elmira/Core/DB.lua")
        ns.DB.defaults.profile.glow.color = { r = 0.1, g = 0.2, b = 0.3 }
        Options.resetGlow()
        assert.is_not.equal(ns.DB.defaults.profile.glow, ns.db.profile.glow)
        assert.is_not.equal(ns.DB.defaults.profile.glow.color, ns.db.profile.glow.color)
        -- and the copy actually carries the values, rather than being an empty table that merely
        -- happens not to be the same object.
        assert.equal(0.1, ns.db.profile.glow.color.r)
        assert.equal(0.2, ns.db.profile.glow.color.g)
        assert.equal(0.3, ns.db.profile.glow.color.b)
        ns.db.profile.glow.color.r = 0.9
        assert.equal(0.1, ns.DB.defaults.profile.glow.color.r)
      end)

      it("asks before throwing the settings away", function()
        local row = glowArgs().reset
        assert.equal("execute", row.type)
        assert.is_true(row.confirm)
        assert.is_truthy(row.confirmText)
      end)

      it("says so rather than erroring with no profile", function()
        -- DB loaded, so the defaults exist and the PROFILE guard is the one that has to fire.
        helper.load("Elmira/Core/DB.lua")
        ns.db = nil
        assert.is_false(Options.resetGlow())
      end)

      it("says so rather than erroring before the defaults are loaded", function()
        ns.DB = nil
        assert.is_false(Options.resetGlow())
      end)

      it("repaints, or the buttons keep the glow you just reset away from", function()
        helper.load("Elmira/Core/DB.lua")
        local stopped = 0
        ns.Glow = { StopAll = function() stopped = stopped + 1 end }
        ns.Queue = { Layout = function() end }
        Options.resetGlow()
        assert.equal(1, stopped)
      end)

      it("is reachable from the panel", function()
        helper.load("Elmira/Core/DB.lua")
        ns.db.profile.glow.particles = 19
        glowArgs().reset.func()
        assert.equal(ns.DB.defaults.profile.glow.particles, ns.db.profile.glow.particles)
      end)
    end)

    it("offers Proc alongside the three older styles", function()
      ns.Glow.available = function() return { PIXEL = true, PROC = true } end
      local values = glowArgs().style.values()
      assert.equal("Proc", values.PROC)
      assert.equal("Pixel", values.PIXEL)
    end)

    -- Proc arrived in LibCustomGlow minor 25. Offering it against an older copy that won LibStub
    -- is a menu entry that silently draws nothing.
    it("does not offer a style the loaded library cannot draw", function()
      ns.Glow.available = function() return { PIXEL = true } end
      local values = glowArgs().style.values()
      assert.is_nil(values.PROC)
      assert.equal("Pixel", values.PIXEL)
    end)

    it("shows the brand highlight as the colour until one is picked", function()
      local r, g, b = glowArgs().color.get()
      assert.equal(ns.Colors.HIGHLIGHT.r, r)
      assert.equal(ns.Colors.HIGHLIGHT.g, g)
      assert.equal(ns.Colors.HIGHLIGHT.b, b)
      glowArgs().color.set(nil, 0.1, 0.2, 0.3)
      assert.same({ r = 0.1, g = 0.2, b = 0.3 }, ns.db.profile.glow.color)
    end)

    -- A row the current style cannot use would let the user move a slider and watch nothing happen.
    it("hides the rows the chosen style has no use for", function()
      assert.is_false(glowArgs().particles.hidden())
      assert.is_false(glowArgs().thickness.hidden())
      assert.is_true(glowArgs().speed.hidden())          -- Proc only
      ns.db.profile.glow.style = "AUTOCAST"
      assert.is_true(glowArgs().thickness.hidden())      -- Pixel only
      assert.is_false(glowArgs().particles.hidden())
      ns.db.profile.glow.style = "BUTTON"
      assert.is_true(glowArgs().particles.hidden())
      assert.is_false(glowArgs().frequency.hidden())
      ns.db.profile.glow.style = "PROC"
      assert.is_false(glowArgs().speed.hidden())
      assert.is_true(glowArgs().frequency.hidden())
    end)

    it("shows the library's default in the slider, not zero", function()
      assert.equal(8, glowArgs().particles.get())
      assert.equal(1, glowArgs().thickness.get())
      ns.db.profile.glow.style = "AUTOCAST"
      assert.equal(4, glowArgs().particles.get())
    end)

    it("writes a real number once the slider moves", function()
      glowArgs().particles.set(nil, 14)
      assert.equal(14, ns.db.profile.glow.particles)
      assert.equal(14, glowArgs().particles.get())
    end)

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
    end)

    it("offers the dim second-suggestion hint, off, and says why", function()
      local row = hintArgs().secondary
      assert.is_false(row.get())
      assert.is_truthy(row.desc:find("queue itself stopped glowing"))
      row.set(nil, true)
      assert.is_true(ns.db.profile.glow.secondary)
    end)

    it("builds each number row as a real slider with real bounds", function()
      local row = glowArgs().particles
      assert.equal("range", row.type)
      assert.equal(5, row.order)
      assert.equal("Particles", row.name)
      assert.equal(1, row.min)
      assert.equal(20, row.max)
      assert.equal(1, row.step)
      assert.is_truthy(row.desc)
      local speed = glowArgs().speed
      assert.equal(0.2, speed.min)
      assert.equal(3, speed.max)
      assert.equal(0.1, speed.step)
      -- Autocast's own default is 0.125: a coarser step cannot land on it, so the first nudge
      -- would change the look for no reason the user asked for.
      local step = glowArgs().frequency.step
      assert.equal(0.025, step)
      assert.is_true(math.abs(0.125 / step - 5) < 1e-9, "Autocast's default is not on a step")
    end)

    it("builds the colour, hint and preview rows as the controls they claim to be", function()
      assert.equal("color", glowArgs().color.type)
      assert.equal("Colour", glowArgs().color.name)
      assert.is_falsy(glowArgs().color.hasAlpha)
      assert.is_truthy(glowArgs().color.desc)
      assert.equal("toggle", hintArgs().secondary.type)
      -- PE7-D3 renamed it to the string PE7-D1 freed: with the old master gone, "Glow the next
      -- cast" is no longer taken, and it says what the toggle does better than "hint" did.
      assert.equal("Glow the next cast", hintArgs().secondary.name)
      assert.equal("execute", glowArgs().preview.type)
      assert.equal("Preview Glow", glowArgs().preview.name)
      assert.is_truthy(glowArgs().preview.desc)
    end)

    -- PE1-D7: button labels are Title Case, the way the client's own UI writes them. Asserted as
    -- the literal strings a player reads, so a future lowercase label is a test failure rather
    -- than something only a screenshot review would catch. Minor words inside a phrase stay lower
    -- case ("Reset These to Defaults"), and prose is untouched.
    it("labels every glow button in Title Case", function()
      assert.equal("Preview Glow", glowArgs().preview.name)
      assert.equal("Reset These to Defaults", glowArgs().reset.name)
      -- PE7-D3 dropped "hint" from the cluster's labels once the toggle stopped saying it, and the
      -- amendment dropped the style picker altogether -- the next-cast glow follows the main style.
      assert.equal("Preview", hintArgs().previewDim.name)
      assert.is_nil(hintArgs().secondaryStyle)
      assert.equal("How dim it is", hintArgs().secondaryAlpha.name)
    end)

    -- The driver only repaints when the queue changes, so a colour change would otherwise not
    -- appear until the rotation happened to move on.
    it("repaints after an appearance change", function()
      local redraws = 0
      ns.Glow.StopAll = function() end
      ns.Display.refresh = function() redraws = redraws + 1 end
      glowArgs().color.set(nil, 1, 1, 1)
      assert.equal(1, redraws)
    end)

    it("knows whether a preview is actually running", function()
      assert.is_false(Options.previewRunning())
      ns.BarGlow = { buttonsFor = function() return { { name = "bar" } }, "ElvUI" end }
      ns.Glow.Start = function() return true end
      Options.checkSpell = function() return "EXORCISM" end
      Options.previewGlow()
      assert.is_true(Options.previewRunning())
    end)

    it("previews from the Glow page too, not only from Action bars", function()
      local fired = 0
      Options.previewGlow = function() fired = fired + 1 end
      glowArgs().preview.func()
      assert.equal(1, fired)
    end)

    -- LibCustomGlow builds its frames from the arguments it was started with: a running glow cannot
    -- be restyled, only replaced. Without the teardown the panel changes and the button does not.
    it("tears down every running glow when an appearance setting changes", function()
      local stopped = 0
      ns.Glow.StopAll = function() stopped = stopped + 1 end
      glowArgs().color.set(nil, 1, 1, 1)
      glowArgs().particles.set(nil, 10)
      glowArgs().frequency.set(nil, 0.5)
      glowArgs().thickness.set(nil, 2)
      ns.db.profile.glow.style = "PROC"
      glowArgs().speed.set(nil, 2)
      hintArgs().secondary.set(nil, true)
      assert.equal(6, stopped)
      -- The style picker has always done its own teardown; it must keep doing it.
      glowArgs().style.set(nil, "BUTTON")
      assert.equal(7, stopped)
    end)

    -- The preview is the one glow no render will ever redraw, so it has to be relit by hand.
    it("relights a preview that was running, so it shows the new settings", function()
      local previews = 0
      ns.Glow.StopAll = function() end
      Options.previewRunning = function() return true end
      Options.previewGlow = function() previews = previews + 1 end
      glowArgs().particles.set(nil, 10)
      assert.equal(1, previews)
    end)

    it("does not start a preview that was not running", function()
      local previews = 0
      ns.Glow.StopAll = function() end
      Options.previewRunning = function() return false end
      Options.previewGlow = function() previews = previews + 1 end
      glowArgs().particles.set(nil, 10)
      assert.equal(0, previews)
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
      assert.is_nil(logArgs().log1)
    end)

    it("lists what was said, newest first, in the category's own colour", function()
      ns.Announce.emit("status", "first")
      ns.Announce.emit("warning", "second")
      local args = logArgs()
      assert.is_truthy(args.log1.name:find("second"))
      assert.is_truthy(args.log1.name:find(ns.Colors.WARN.hex))
      assert.is_truthy(args.log2.name:find("first"))
      -- PE14-D1: the prefix on a log row is the category's label, so the rename shows here too.
      assert.is_truthy(args.log2.name:find("Settings and setup", 1, true))
      assert.is_nil(args.logEmpty)
      -- Each line is its own row, in order, under the header and above the Clear button.
      assert.equal("description", args.log1.type)
      assert.equal(2, args.log1.order)
      assert.equal(3, args.log2.order)
      assert.is_true(args.log2.order < args.logClear.order)
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

    -- PE14-D3: the cooldown row is off this page entirely -- announcing a long cooldown is a
    -- property of the ability, not a routing choice, so it moves to the Abilities tab. It was the
    -- only `shareable` category, so the Party and Raid toggles and the cooldown-length slider come
    -- off the page with it. Nothing in the engine changed; only the page stopped offering it.
    it("no longer offers the cooldown row, its group toggles or its length slider", function()
      local args = announceArgs()
      assert.is_nil(args.catcooldown)
      for _, c in ipairs(ns.Announce.listed()) do
        local row = args["cat" .. c.key].args
        assert.is_nil(row.party, c.key .. " still offers party")
        assert.is_nil(row.raid, c.key .. " still offers raid")
        assert.is_nil(row.floor, c.key .. " still offers the cooldown slider")
      end
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

    -- PE14-D3: one message per kind THE PAGE SHOWS. The button and the routing table read the
    -- same list, so it cannot go on testing a kind there is no row for.
    it("sends one message of every kind the page shows, and none it does not", function()
      announceArgs().test.func()
      assert.equal(#ns.Announce.listed(), #ns.Announce.log())
      for _, entry in ipairs(ns.Announce.log()) do
        assert.is_not.equal("cooldown", entry.category)
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
      local args = logArgs()
      assert.is_not_nil(args.log20)
      assert.is_nil(args.log21)
      assert.is_truthy(args.log1.name:find("line 25"))
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
  -- The category shipped routable to party with nothing ever emitting it, so "what will appear
  -- here" was unanswerable from the panel. The slider is the answer, and its description is the
  -- explanation the owner asked for.
  -- PE14-D3: the SLIDER left the panel with the cooldown row -- a duration floor cannot tell a
  -- tank's defensive save from a DPS burst, which is the distinction that decides whether a group
  -- wants to hear about it, so it becomes a per-ability setting. The RULE stayed exactly where it
  -- was: the engine still asks it on every cast, and the stored floor is still what answers.
  describe("what counts as a cooldown worth announcing", function()
    it("is no longer asked anywhere on the Notifications page", function()
      helper.load("Elmira/Core/Announce.lua")
      local page = Options.table().args.notifications.args
      assert.is_nil(page.catcooldown)
      assert.is_nil(page.floor)
      for key, entry in pairs(page) do
        if type(entry) == "table" and type(entry.args) == "table" then
          assert.is_nil(entry.args.floor, key .. " still carries the cooldown slider")
        end
      end
    end)

    it("still decides, off the page, from the stored floor", function()
      helper.load("Elmira/Core/Announce.lua")
      ns.db.profile.announce = ns.db.profile.announce or {}
      assert.equal(120, ns.Announce.cooldownFloor())
      assert.is_true(ns.Announce.worthAnnouncing(180))
      assert.is_false(ns.Announce.worthAnnouncing(30))
      ns.db.profile.announce.cooldownFloor = 45
      assert.equal(45, ns.Announce.cooldownFloor())
      assert.is_true(ns.Announce.worthAnnouncing(60))
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
    return Options.table().args.notifications.args.overlay.args
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
