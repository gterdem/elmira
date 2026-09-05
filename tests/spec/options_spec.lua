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
    local function queueArgs() return Options.table().args.queue.args end

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
      queueArgs().enabled.set(nil, false)
      assert.equal(1, stopped)
    end)

    it("names the master switch for the addon, not for the strip", function()
      local row = queueArgs().enabled
      assert.equal("Enable Elmira", row.name)
      assert.equal("Turns the whole display off: no queue, no bar glow, no update loop.", row.desc)
    end)

    it("offers the strip separately, and says the glow survives it", function()
      local row = queueArgs().showQueue
      assert.equal("Show the queue strip", row.name)
      assert.equal("Off keeps the action-bar glow and hides the icons.", row.desc)
      assert.is_true(row.get())
      row.set(nil, false)
      assert.is_false(ns.db.profile.showQueue)
      assert.is_false(row.get())
    end)

    it("offers the motion separately", function()
      local row = queueArgs().animate
      assert.equal("Animate changes", row.name)
      assert.equal("Icons slide when the queue moves and pop when you cast the suggestion.", row.desc)
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
      queueArgs().enabled.set(nil, true)
      queueArgs().showQueue.set(nil, false)
      queueArgs().animate.set(nil, false)
      assert.equal(3, redraws)
    end)
  end)

  -- ADR-0015 §3 makes the bar glow the single attention signal, so it gets the range of control
  -- that deserves. Every row below could be present and do nothing; these check it does something.
  describe("Glow appearance", function()
    local function glowArgs() return Options.table().args.glow.args end

    before_each(function()
      ns.db.profile.glow = { enabled = true, style = "PIXEL", barGlow = true, color = false,
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
        local row = glowArgs().secondaryAlpha
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
        local row = glowArgs().secondaryAlpha
        assert.equal(ns.Glow.secondaryAlpha(), row.get())
        row.set(nil, 0.6)
        assert.equal(0.6, ns.db.profile.glow.secondaryAlpha)
        assert.equal(0.6, row.get())
      end)

      -- The SAME button, so the two brightnesses are directly comparable rather than at the mercy
      -- of where two different buttons sit.
      -- The owner's design, not just a brightness knob: two glows of the SAME shape are hard to
      -- tell apart however dim one is, and on Proc dimming does not read at all.
      it("offers the hint its own style, defaulting to the main one", function()
        helper.load("Elmira/Display/Glow.lua")
        ns.Glow.available = function() return { PIXEL = true, PROC = true } end
        ns.db.profile.glow.secondary = true
        local row = glowArgs().secondaryStyle
        assert.equal("select", row.type)
        assert.equal("Same as above", row.values()[""])
        assert.equal("Proc", row.values().PROC)
        assert.equal("", row.get(), "unset means the same style as the main glow")
        -- Changing the hint's shape has to tear the running glows down, or the button keeps the
        -- old shape until the suggestion happens to change.
        local stopped = 0
        ns.Glow.StopAll = function() stopped = stopped + 1 end
        ns.Queue = { Layout = function() end }
        row.set(nil, "PROC")
        assert.equal(1, stopped, "the running glow was not restarted in the new style")
        assert.equal("PROC", ns.db.profile.glow.secondaryStyle)
        assert.equal("PROC", row.get())
        -- Back to "same as above" stores a falsey value, not the empty string.
        row.set(nil, "")
        assert.is_false(ns.db.profile.glow.secondaryStyle)
        assert.equal("", row.get())
      end)

      it("names the hint section and says why it ships off", function()
        assert.equal("The cast after next", glowArgs().hintHeader.name)
        assert.equal("header", glowArgs().hintHeader.type)
        local row = glowArgs().secondary
        assert.is_truthy(row.desc:find("compete for the same glance", 1, true))
        assert.is_truthy(glowArgs().secondaryStyle.desc:find("Same as above", 1, true))
      end)

      it("hides the hint's controls until the hint is on", function()
        ns.db.profile.glow.secondary = false
        assert.is_true(glowArgs().secondaryStyle.hidden())
        assert.is_true(glowArgs().previewDim.hidden())
        ns.db.profile.glow.secondary = true
        assert.is_false(glowArgs().secondaryStyle.hidden())
      end)

      -- Both pickers read one list, so they can never offer styles the other does not.
      it("offers the same styles for the hint as for the main glow", function()
        helper.load("Elmira/Display/Glow.lua")
        ns.Glow.available = function() return { PIXEL = true } end
        ns.db.profile.glow.secondary = true
        assert.is_nil(glowArgs().style.values().PROC)
        assert.is_nil(glowArgs().secondaryStyle.values().PROC)
        assert.equal("Pixel", glowArgs().secondaryStyle.values().PIXEL)
      end)

      it("previews the dim hint, and only when there is a hint to preview", function()
        ns.db.profile.glow.secondary = false
        local row = glowArgs().previewDim
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
        dropped = function() return 0 end,
        CATEGORIES = {},
        CHANNELS = { "chat", "screen", "sound", "party" },
        routes = function() return {} end,
      }
      ns.Queue.ApplyLearningPreset = function() return { depth = 1, scale = 1.4 } end
      ns.db.profile.learning = false
      Options.table().args.queue.args.learning.set(nil, true)
      assert.equal(1, #said)
      assert.equal("status", said[1][1])
      assert.is_truthy(said[1][2]:find("Learning mode on"))
    end)

    it("offers the dim second-suggestion hint, off, and says why", function()
      local row = glowArgs().secondary
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
      assert.equal("toggle", glowArgs().secondary.type)
      assert.equal("Also hint the cast after next", glowArgs().secondary.name)
      assert.equal("execute", glowArgs().preview.type)
      assert.equal("Preview glow", glowArgs().preview.name)
      assert.is_truthy(glowArgs().preview.desc)
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
      glowArgs().secondary.set(nil, true)
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
  describe("Announcements", function()
    local function announceArgs()
      return Options.table().args.notifications.args.announce.args
    end

    before_each(function()
      helper.load("Elmira/Core/Announce.lua")
      ns.db.profile.announce = {
        chatWindow = 0, sound = "None",
        screen = { font = "Friz Quadrata TT", size = 18, duration = 4,
                   anchor = { point = "TOP", relPoint = "TOP", x = 0, y = -140 } },
        routes = {},
      }
      ns.db.global = { announceLog = {}, announceDropped = 0 }
      ns.Announce.use{ now = function() return 1 end, inCombat = function() return false end }
      ns.Announcers = {
        chatWindows = function() return { [0] = "Default", [2] = "Addons" } end,
        fonts = function() return { ["Friz Quadrata TT"] = "Friz Quadrata TT" } end,
        sounds = function() return { None = "None", Chime = "Chime" } end,
        ApplyFont = function() return true end,
        SetMoving = function() return true end,
        isMoving = function() return false end,
      }
    end)

    it("says so plainly when nothing has been said yet", function()
      assert.is_truthy(announceArgs().logEmpty.name:find("Nothing yet"))
      assert.is_nil(announceArgs().log1)
    end)

    it("lists what was said, newest first, in the category's own colour", function()
      ns.Announce.emit("status", "first")
      ns.Announce.emit("warning", "second")
      local args = announceArgs()
      assert.is_truthy(args.log1.name:find("second"))
      assert.is_truthy(args.log1.name:find(ns.Colors.WARN.hex))
      assert.is_truthy(args.log2.name:find("first"))
      assert.is_nil(args.logEmpty)
      -- Each line is its own row, in order, under the header and above the Clear button.
      assert.equal("description", args.log1.type)
      assert.equal(2, args.log1.order)
      assert.equal(3, args.log2.order)
      assert.is_true(args.log2.order < args.logClear.order)
    end)

    it("empties the log on request", function()
      ns.Announce.emit("status", "x")
      announceArgs().logClear.func()
      assert.equal(0, #ns.Announce.log())
    end)

    it("gives every category its own row of channels", function()
      local args = announceArgs()
      for _, c in ipairs(ns.Announce.CATEGORIES) do
        assert.is_not_nil(args["cat" .. c.key], c.key .. " has no row")
        assert.is_true(args["cat" .. c.key].inline)
      end
    end)

    -- The Log is the record, not a channel; party is offered only where the category is shareable
    -- in code, so no amount of clicking can put "my rotation changed" into a group's chat.
    it("offers party only where the category may leave the client, and never offers the log", function()
      local args = announceArgs()
      assert.is_nil(args.catrotation.args.party)
      assert.is_nil(args.catwarning.args.party)
      assert.is_not_nil(args.catcooldown.args.party)
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

    it("chooses a chat window from the player's own tabs", function()
      local row = announceArgs().chatWindow
      assert.equal("Addons", row.values()[2])
      assert.equal(0, row.get())
      row.set(nil, 2)
      assert.equal(2, ns.db.profile.announce.chatWindow)
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
      assert.equal("None", args.sound.get())
      assert.is_false(args.move.get())
    end)

    it("offers the fonts and sounds the player actually has", function()
      local args = announceArgs()
      assert.equal("Friz Quadrata TT", args.font.values()["Friz Quadrata TT"])
      assert.equal("Chime", args.sound.values().Chime)
    end)

    it("reflects move mode being on", function()
      ns.Announcers.isMoving = function() return true end
      assert.is_true(announceArgs().move.get())
    end)

    it("chooses a sound", function()
      announceArgs().sound.set(nil, "Chime")
      assert.equal("Chime", ns.db.profile.announce.sound)
      assert.equal("Chime", announceArgs().sound.get())
    end)

    it("turns move mode on and reports it", function()
      local moved
      ns.Announcers.SetMoving = function(v) moved = v end
      announceArgs().move.set(nil, true)
      assert.is_true(moved)
    end)

    it("sends one message of every kind on request", function()
      announceArgs().test.func()
      assert.equal(#ns.Announce.CATEGORIES, #ns.Announce.log())
    end)

    -- A button for previewing your own settings must not put six lines in a group's chat.
    it("keeps the test messages out of party, whatever the routing says", function()
      local partied = 0
      ns.Announce.registerSink("party", function() partied = partied + 1 end)
      ns.db.profile.announce.routes.cooldown = { party = true }
      announceArgs().test.func()
      assert.equal(0, partied)
    end)

    -- Each row is a control the user has to be able to recognise. A row with no type does not
    -- render, and one with no name renders as an unlabelled widget.
    it("builds every control as what it claims to be", function()
      local args = announceArgs()
      local expected = {
        logHeader  = { type = "description", order = 1 },
        logEmpty   = { type = "description", order = 2 },
        logClear   = { type = "execute", order = 30, name = "Clear the log" },
        routing    = { type = "header", order = 40, name = "Where each kind of message goes" },
        where      = { type = "header", order = 60, name = "How they look" },
        chatWindow = { type = "select", order = 61, name = "Chat window" },
        font       = { type = "select", order = 62, name = "Screen font" },
        size       = { type = "range", order = 63, name = "Screen text size" },
        duration   = { type = "range", order = 64, name = "Seconds on screen" },
        sound      = { type = "select", order = 65, name = "Sound" },
        move       = { type = "toggle", order = 66, name = "Move the on-screen message" },
        test       = { type = "execute", order = 67, name = "Test each kind" },
      }
      for key, want in pairs(expected) do
        local row = args[key]
        assert.is_not_nil(row, key .. " is missing")
        assert.equal(want.type, row.type, key .. " is the wrong kind of control")
        assert.equal(want.order, row.order, key .. " is in the wrong place")
        if want.name then assert.equal(want.name, row.name, key .. " is labelled wrongly") end
      end
      assert.is_truthy(args.logHeader.name:find("Log"))
      assert.equal("medium", args.logHeader.fontSize)
      assert.is_truthy(args.chatWindow.desc)
      assert.is_truthy(args.move.desc)
      assert.is_truthy(args.test.desc)
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
      for i, c in ipairs(ns.Announce.CATEGORIES) do
        local group = args["cat" .. c.key]
        assert.equal("group", group.type)
        assert.equal(40 + i, group.order)
        assert.is_truthy(group.name:find(c.label), c.key .. " is not labelled")
        assert.is_truthy(group.name:find(ns.Colors[c.color].hex), c.key .. " is not in its colour")
      end
    end)

    -- The toggles used to be ordered by pairs(), so they came out in a different order for every
    -- category and a different order again on another Lua build.
    it("lays the channel toggles out in one fixed order, party last", function()
      local args = announceArgs().catcooldown.args
      for key, row in pairs(args) do
        assert.equal("toggle", row.type, key .. " is not a toggle")
        assert.is_not_nil(row.name, key .. " has no label")
      end
      assert.equal(1, args.chat.order)
      assert.equal(2, args.screen.order)
      assert.equal(3, args.sound.order)
      assert.equal(4, args.party.order)
    end)

    it("numbers a non-shareable category's toggles without a gap where party would be", function()
      local args = announceArgs().catrotation.args
      assert.equal(1, args.chat.order)
      assert.equal(2, args.screen.order)
      assert.equal(3, args.sound.order)
    end)

    -- A counter that nothing reads is a number that can be wrong forever without anyone noticing.
    it("says how many lines the log has thrown away, once it has thrown any", function()
      assert.is_nil(announceArgs().logDropped)
      for i = 1, ns.Announce.MAX_LOG + 2 do ns.Announce.emit("status", "line " .. i) end
      local row = announceArgs().logDropped
      assert.is_not_nil(row)
      assert.equal("description", row.type)
      assert.is_truthy(row.name:find("2"))
    end)

    -- Without a cap the panel grows without limit and the switches below the log become
    -- unreachable on a long session.
    it("lists at most twenty log lines however many there are", function()
      for i = 1, 25 do ns.Announce.emit("status", "line " .. i) end
      local args = announceArgs()
      assert.is_not_nil(args.log20)
      assert.is_nil(args.log21)
      assert.is_truthy(args.log1.name:find("line 25"))
    end)
  end)

  -- Move mode enables the mouse on a frame across the middle of the screen. Closing the panel has
  -- to end it, or that frame sits there eating clicks with nothing on screen to explain it.
  describe("Options.Open", function()
    it("ends move mode when the panel is closed", function()
      local stopped, closer = 0, nil
      ns.Announcers = { StopMoving = function() stopped = stopped + 1 end }
      Options.dialog = {
        Open = function() end,
        OpenFrames = { Elmira = { SetCallback = function(_, event, fn)
          if event == "OnClose" then closer = fn end
        end } },
      }
      assert.is_true(Options.Open())
      assert.is_function(closer, "nothing was hooked to the panel closing")
      closer()
      assert.equal(1, stopped)
    end)

    -- The Rotation section is the front door, so /elm rotation has to land on it. AceConfigDialog
    -- takes the path as Open(appName, container, ...); passing it as the CONTAINER would silently
    -- open the panel wherever it was last left.
    it("passes a section path through to the dialog, after the container slot", function()
      local got
      ns.Announcers = { StopMoving = function() end }
      Options.dialog = { Open = function(_, app, container, ...) got = { app, container, ... } end }
      assert.is_true(Options.Open("rotation"))
      assert.same({ "Elmira", nil, "rotation" }, got)
    end)

    it("opens with no path at all, which is what /elm config wants", function()
      local got
      ns.Announcers = { StopMoving = function() end }
      Options.dialog = { Open = function(_, app, container, ...) got = { app, container, ... } end }
      assert.is_true(Options.Open())
      assert.same({ "Elmira" }, got)
    end)

    it("opens without erroring on a dialog that exposes no frames", function()
      ns.Announcers = { StopMoving = function() end }
      Options.dialog = { Open = function() end }
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
      Options.dialog = { Open = function() end, OpenFrames = { Elmira = widget } }

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
      Options.dialog = { Open = function() end, OpenFrames = { Elmira = widget } }

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
      Options.dialog = { Open = function() end, OpenFrames = { Elmira = widget } }

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
      Options.dialog = { Open = function() end, OpenFrames = { Elmira = widget } }

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
