local helper = require("tests.helper")

-- Elmira/Options/Options.lua — the Action Bars section.
--
-- Nothing in the suite asserted anything about the glow group before this file: `barGlow` and
-- `style` were untested at the options layer entirely, which is how the toggle that decides whether
-- the bar glow happens at all sat there uncovered.
--
-- What this section is FOR is worth stating, because it shapes every assertion below. "Nothing is
-- glowing" has four causes that need four different actions from the player: no bar addon, the
-- spell is not on a bar, the button is on a bar they cannot see, and the bar glow is switched off.
-- The panel's job is to tell those apart. A test that only checked "a row was rendered" would pass
-- against a panel that reported all four identically, which is the failure mode being designed out.
describe("Options (action bars)", function()
  local Options, ns

  local function load()
    ns = helper.reset()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    helper.load("Elmira/Core/Colors.lua")
    ns.db = { profile = { glow = { enabled = true, barGlow = true, style = "PIXEL" } } }
    ns.Display = { refresh = function() end, computeQueue = function() return { { spell = "EXORCISM" } } end }
    ns.Glow = { STYLES = { PIXEL = {}, BUTTON = {}, AUTOCAST = {} }, StopAll = function() end }
    ns.Queue = { Layout = function() end }
    ns.addon = { ScheduleTimer = function() return "timer" end, CancelTimer = function() end }
    helper.load("Elmira/Options/Rotation.lua")
    Options = helper.load("Elmira/Options/Options.lua")
    return Options
  end

  before_each(load)

  local function group() return Options.table().args.bars.args end
  local function rowText(args)
    local out = {}
    for _, row in pairs(args) do
      if row.type == "description" then
        out[#out + 1] = type(row.name) == "function" and row.name() or row.name
      end
    end
    return table.concat(out, "\n")
  end

  -- The panel has to explain itself. Somebody opening it for the first time should learn what the
  -- bar glow IS before being asked to configure it.
  it("says what the section is for, and names its two halves", function()
    local args = group()
    assert.truthy(rowText(args):find("glows the button holding your next suggested spell", 1, true))
    assert.equal("Bar addon", args.bars.name)
    assert.equal("Is my spell showing?", args.check.name)
    assert.equal("Preview glow", args.preview.name)
    assert.truthy(args.preview.desc:find("without waiting for a fight", 1, true))
    assert.truthy(args.check.args.pick.desc:find("suggesting right now", 1, true))
    assert.equal("Test with", args.check.args.pick.name)
  end)

  -- The client's font has no U+25CF/U+2714/U+2718: the first in-game run rendered every marker as
  -- an identical empty box, so all four bar states and every check verdict looked the same. A
  -- decoration that does not decode is worse than none, because it reads as a control.
  it("marks every state in characters the client can actually draw", function()
    ns.BarProviders = { status = function() return {
      { name = "ElvUI", state = "active", activeName = "ElvUI" },
      { name = "Dominos", state = "absent" },
    } end }
    ns.BarGlow = { check = function() return {
      { label = "placed", ok = true, detail = 1 },
      { label = "visible", ok = false },
      { label = "glow", ok = nil },
    } end }
    local text = rowText(group().bars.args) .. rowText(group().check.args.rows.args)
    for _, codepoint in ipairs({ "\226\151\143", "\226\151\139", "\226\156\148", "\226\156\152" }) do
      assert.is_nil(text:find(codepoint, 1, true), "an unrenderable glyph reached the panel")
    end
    assert.truthy(text:find("OK", 1, true))
    assert.truthy(text:find("FAIL", 1, true))
  end)

  describe("the bar addon list", function()
    local function statusOf(rows)
      ns.BarProviders = { status = function() return rows end }
      return rowText(group().bars.args)
    end

    -- Every supported bar addon is listed whether or not it is installed. Listing only what
    -- registered (Masque's pattern) gives no signal at all when the thing you installed did not
    -- show up, and a checkbox that looks identical either way (ElvUI's Skins pattern) is worse.
    it("names the bar addon in use, and says what it is doing", function()
      local text = statusOf({ { name = "ElvUI", state = "active", activeName = "ElvUI" } })
      assert.truthy(text:find("ElvUI", 1, true))
      assert.truthy(text:find("Detected — in use", 1, true))
      assert.truthy(text:find("glowing buttons on your ElvUI action bars", 1, true))
    end)

    -- The two-bar-addons case. None of the addons surveyed for this design handle it by name, and
    -- "why is only one of them glowing" is a predictable question with an unhelpful non-answer.
    it("says which addon won when two are installed", function()
      local text = statusOf({
        { name = "ElvUI", state = "active", activeName = "ElvUI" },
        { name = "Bartender4", state = "inactive", activeName = "ElvUI" },
      })
      assert.truthy(text:find("installed, but ElvUI is handling your bars", 1, true))
    end)

    -- "not installed" is a fact, not an error, and must not read as one.
    it("reports an absent bar addon plainly, and does not claim it is doing anything", function()
      local text = statusOf({ { name = "Dominos", state = "absent" } })
      assert.truthy(text:find("not installed", 1, true))
      assert.is_nil(text:find("glowing buttons on your Dominos", 1, true))
    end)

    -- Without this the panel says "not installed" three times to somebody whose bars work fine.
    it("always offers the Blizzard bars, so the panel never implies nothing is set up", function()
      local text = statusOf({ { name = "Blizzard", state = "fallback", activeName = "ElvUI" } })
      assert.truthy(text:find("Blizzard default bars", 1, true))
      assert.truthy(text:find("available (fallback)", 1, true))
    end)

    it("shows the Blizzard bars as the ones in use when no bar addon is installed", function()
      local text = statusOf({ { name = "Blizzard", state = "active" } })
      assert.truthy(text:find("Detected — in use", 1, true))
      assert.truthy(text:find("glowing buttons on the default action bars", 1, true))
    end)

    -- Rows carry an explicit `order`, and AceConfig sorts on it. Two rows sharing a number is not a
    -- tie the panel resolves sensibly -- it renders them in whatever order pairs() produced, which
    -- can put "Elmira is glowing buttons on your ElvUI bars" above a Bartender4 row it is not about.
    it("orders every row, so the list cannot shuffle between openings", function()
      ns.BarProviders = { status = function() return {
        { name = "ElvUI", state = "active", activeName = "ElvUI" },
        { name = "Bartender4", state = "inactive", activeName = "ElvUI" },
      } end }
      local seen = {}
      for _, row in pairs(group().bars.args) do
        assert.is_number(row.order)
        assert.is_nil(seen[row.order], "two rows share order " .. tostring(row.order))
        seen[row.order] = true
      end
    end)

    -- The generic row is what a KkthnxUI or NDui user sees. Without its own sentence it would be the
    -- only "in use" row in the panel that does not say what it is doing.
    it("tells an unrecognised bar addon's user that their bars are being glowed", function()
      local text = statusOf({ { name = "Action bars", state = "active", activeName = "Action bars" } })
      assert.truthy(text:find("Detected — in use", 1, true))
      assert.truthy(text:find("glowing buttons on your action bars", 1, true))
    end)

    it("names a Bartender4 user's bars in the sentence, not just the row", function()
      local text = statusOf({ { name = "Bartender4", state = "active", activeName = "Bartender4" } })
      assert.truthy(text:find("glowing buttons on your Bartender4 action bars", 1, true))
    end)

    it("names a Dominos user's bars in the sentence", function()
      local text = statusOf({ { name = "Dominos", state = "active", activeName = "Dominos" } })
      assert.truthy(text:find("glowing buttons on your Dominos action bars", 1, true))
    end)

    it("renders without a bar-provider module at all", function()
      ns.BarProviders = nil
      assert.is_true(pcall(function() return group().bars.args end))
    end)
  end)

  -- The panel's running order is a design decision, not an accident: Queue (what you see), Action
  -- Bars (where it points), Glow (how it looks), then the optional extras. Two groups sharing an
  -- `order` renders them in pairs() order, which differs between openings.
  it("orders the settings groups, each exactly once", function()
    local seen, orders = {}, {}
    for key, g in pairs(Options.table().args) do
      assert.is_number(g.order, key .. " has no order")
      assert.is_nil(seen[g.order], key .. " shares order " .. tostring(g.order))
      seen[g.order] = key
      orders[#orders + 1] = g.order
    end
    table.sort(orders)
    -- The Rotation section is the front door (ADR-0015 SS1), so it sorts above the display settings
    -- rather than sitting at the bottom where Import/Export used to be.
    assert.equal("rotation", seen[orders[1]])
    assert.equal("queue", seen[orders[2]])
    assert.equal("bars", seen[orders[3]])
    assert.equal("glow", seen[orders[4]])
    -- Everything that TELLS you something lives under one heading (ADR-0015 F37), rather than as
    -- three more peers of "Queue": announcements, flares and cue sounds are one question.
    assert.equal("notifications", seen[orders[5]])
  end)

  it("groups announcements, flares and cue sounds under Notifications, each exactly once", function()
    local notifications = Options.table().args.notifications
    assert.equal("tree", notifications.childGroups)
    local seen, orders = {}, {}
    for key, g in pairs(notifications.args) do
      assert.is_number(g.order, key .. " has no order")
      assert.is_nil(seen[g.order], key .. " shares order " .. tostring(g.order))
      seen[g.order] = key
      orders[#orders + 1] = g.order
    end
    table.sort(orders)
    assert.equal("announce", seen[orders[1]])
    assert.equal("overlay", seen[orders[2]])
    assert.equal("sounds", seen[orders[3]])
  end)

  describe("the bar glow toggle", function()
    -- It used to live under Glow, away from the status list that explains what it does. A toggle
    -- whose effect is invisible is where "I turned it on and nothing happened" starts.
    it("lives in Action Bars, not in Glow", function()
      assert.equal("toggle", group().barGlow.type)
      assert.is_nil(Options.table().args.glow.args.barGlow)
    end)

    it("reads the current setting, and explains what it does", function()
      assert.is_true(group().barGlow.get())
      ns.db.profile.glow.barGlow = false
      assert.is_false(group().barGlow.get())
      assert.truthy(group().barGlow.desc:find("not just the queue icon", 1, true))
    end)

    it("writes the setting, drops glows it will no longer refresh, and repaints", function()
      local stopped, painted = 0, 0
      ns.Glow.StopAll = function() stopped = stopped + 1 end
      ns.Display.refresh = function() painted = painted + 1 end
      group().barGlow.set(nil, false)
      assert.is_false(ns.db.profile.glow.barGlow)
      assert.equal(1, stopped)
      assert.equal(1, painted)
    end)
  end)

  -- The style list is derived from what the LOADED library can draw rather than repeated. A literal
  -- drifts the moment a style is added, offering the player a choice the renderer does not have --
  -- and a style the library is too old for draws nothing at all.
  it("offers exactly the glow styles the renderer implements", function()
    ns.Glow.available = function() return { PIXEL = true, BUTTON = true, AUTOCAST = true } end
    local values = Options.table().args.glow.args.style.values()
    local names = {}
    for key in pairs(values) do names[#names + 1] = key end
    table.sort(names)
    assert.same({ "AUTOCAST", "BUTTON", "PIXEL" }, names)

    ns.Glow.available = function() return { PIXEL = true, PROC = true } end
    local widened = Options.table().args.glow.args.style.values()
    assert.is_not_nil(widened.PROC)
  end)

  -- WeakAuras' View idea. This is the control that separates "the glow is broken" from "nothing is
  -- being suggested right now" -- indistinguishable to a player standing in a city, and the
  -- likeliest source of a bug report that is not a bug.
  describe("preview glow", function()
    it("glows the button for the current suggestion, in the configured style", function()
      local frame, lit, style = { "button" }, nil, nil
      ns.BarGlow = { buttonsFor = function() return { frame } end }
      ns.Glow.Start = function(f, s) lit, style = f, s; return true end
      local args = group()
      assert.is_true(Options.previewGlow())
      assert.equal(frame, lit)
      assert.equal("PIXEL", style)
      assert.truthy(args.previewNote.name():find("look at your action bars", 1, true))
    end)

    -- A previewed frame is not in the render loop's `nowFrames` set, so nothing in Display/Glow.lua
    -- will ever clear it. It has to stop itself or it burns until the next StopAll.
    it("schedules its own stop, because nothing else will clear it", function()
      local frame, stopped, scheduled = { "button" }, nil, nil
      ns.BarGlow = { buttonsFor = function() return { frame } end }
      ns.Glow.Start = function() return true end
      ns.Glow.Stop = function(f) stopped = f end
      -- Fired twice on purpose: a second stop must be a no-op, not a second Stop() on a frame that
      -- the render loop may since have taken over for a real suggestion.
      ns.addon = { ScheduleTimer = function(_, fn, secs) scheduled = secs; fn(); fn() end }
      local stops = 0
      ns.Glow.Stop = function(f) stopped = f; stops = stops + 1 end
      Options.previewGlow()
      assert.equal(4, scheduled)
      assert.equal(frame, stopped)
      assert.equal(1, stops)
    end)

    it("shows its note as a full-width line under the button", function()
      local note = group().previewNote
      assert.equal("description", note.type)
      assert.equal("full", note.width)
      assert.is_true(note.order > group().preview.order)
    end)

    it("opens with no note, even after a previous preview left one", function()
      ns.BarGlow = { buttonsFor = function() return { { "button" } } end }
      ns.Glow.Start = function() return true end
      local args = group()
      Options.previewGlow()
      assert.truthy(args.previewNote.name():find("action bars", 1, true))
      -- Reopening the panel rebuilds the table; a stale result must not greet the next visit.
      assert.equal("", group().previewNote.name())
    end)

    -- Two previews in a row must not leave the first button lit: nothing else will ever clear it.
    it("stops the previous preview before starting another", function()
      local first, second = { "one" }, { "two" }
      local target, stopped = first, {}
      ns.BarGlow = { buttonsFor = function() return { target } end }
      ns.Glow.Start = function() return true end
      ns.Glow.Stop = function(f) stopped[#stopped + 1] = f end
      Options.previewGlow()
      target = second
      Options.previewGlow()
      assert.same({ first }, stopped)
    end)

    it("previews in the style you actually chose, not a hardcoded one", function()
      ns.db.profile.glow.style = "AUTOCAST"
      local style
      ns.BarGlow = { buttonsFor = function() return { { "button" } } end }
      ns.Glow.Start = function(_, s) style = s; return true end
      Options.previewGlow()
      assert.equal("AUTOCAST", style)
    end)

    -- The button has to be wired to the function. A preview that works when a spec calls it
    -- directly, and does nothing when the player clicks it, is this project's recurring defect.
    it("is reachable from the button, not only from a spec", function()
      local lit = false
      ns.BarGlow = { buttonsFor = function() return { { "button" } } end }
      ns.Glow.Start = function() lit = true; return true end
      group().preview.func()
      assert.is_true(lit)
    end)

    -- Between lighting a button and the timer firing, the rotation can move on and the render loop
    -- can take that same frame -- as the real suggestion, or as the dim hint on the one after it.
    -- Stopping it then darkens a button that should be lit, and SetNowSlot still believes it is
    -- lit, so it stays dark until that suggestion changes away and back. Found by probing, not by
    -- mutation: the bug was in absent code, twice -- once for the now glow and again when the dim
    -- second glow arrived and the guard still asked only about the first.
    it("does not put out a real glow that has taken over its frame", function()
      local frame, stopped = { "button" }, false
      ns.BarGlow = { buttonsFor = function() return { frame } end }
      ns.Glow.Start = function() return true end
      ns.Glow.Stop = function() stopped = true end
      ns.Glow.isRendererFrame = function(f) return f == frame end   -- the render loop took it
      local fire
      ns.addon = { ScheduleTimer = function(_, fn) fire = fn; return "t" end, CancelTimer = function() end }
      Options.previewGlow()
      fire()
      assert.is_false(stopped)
    end)

    it("still cleans up a preview the render loop never took", function()
      local frame, stopped = { "button" }, false
      ns.BarGlow = { buttonsFor = function() return { frame } end }
      ns.Glow.Start = function() return true end
      ns.Glow.Stop = function() stopped = true end
      ns.Glow.isRendererFrame = function() return false end
      local fire
      ns.addon = { ScheduleTimer = function(_, fn) fire = fn; return "t" end, CancelTimer = function() end }
      Options.previewGlow()
      fire()
      assert.is_true(stopped)
    end)

    -- Without cancelling, click one's timer is still pending when click two starts, and fires four
    -- seconds after click one -- putting out the second preview early.
    it("cancels the previous timer, so an old one cannot cut the new preview short", function()
      local cancelled = {}
      ns.BarGlow = { buttonsFor = function() return { { "button" } } end }
      ns.Glow.Start = function() return true end
      ns.Glow.Stop = function() end
      local n = 0
      ns.addon = {
        ScheduleTimer = function() n = n + 1; return "timer" .. n end,
        CancelTimer = function(_, handle) cancelled[#cancelled + 1] = handle end,
      }
      Options.previewGlow()
      Options.previewGlow()
      assert.same({ "timer1" }, cancelled)
    end)

    -- A glow nothing will ever stop is a worse outcome than no preview, so it must not be announced
    -- as one that ends.
    it("does not promise a preview that ends when there is no timer to end it", function()
      ns.addon = nil
      ns.BarGlow = { buttonsFor = function() return { { "button" } } end }
      ns.Glow.Start = function() return true end
      local args = group()
      assert.is_true(Options.previewGlow())
      assert.truthy(args.previewNote.name():find("stay lit", 1, true))
    end)

    it("says why when the spell is not on a bar, rather than doing nothing", function()
      ns.BarGlow = { buttonsFor = function() return {} end }
      local args = group()
      assert.is_false(Options.previewGlow())
      assert.truthy(args.previewNote.name():find("not on a bar Elmira can see", 1, true))
    end)

    -- Distinct from "the spell is not placed": this one is the glow library itself missing, which
    -- no amount of dragging spells around will fix.
    it("distinguishes a missing glow library from a missing button", function()
      ns.BarGlow = { buttonsFor = function() return { { "button" } } end }
      ns.Glow.Start = function() return false end
      local args = group()
      assert.is_false(Options.previewGlow())
      assert.truthy(args.previewNote.name():find("glow library is not loaded", 1, true))
    end)
  end)

  describe("the per-spell check", function()
    local function checkWith(rows)
      ns.BarGlow = { check = function() return rows end }
      return rowText(group().check.args.rows.args)
    end

    it("names the spell it is checking", function()
      local text = checkWith({})
      assert.truthy(text:find("Checking EXORCISM", 1, true))
    end)

    it("passes every stage when the spell is on a visible button and the glow is on", function()
      local text = checkWith({
        { label = "bars", ok = true, detail = "ElvUI" },
        { label = "placed", ok = true, detail = 1 },
        { label = "visible", ok = true, detail = "ElvUI_Bar1Button3" },
        { label = "glow", ok = true },
      })
      assert.truthy(text:find("Bar addon detected", 1, true))
      assert.truthy(text:find("ElvUI_Bar1Button3", 1, true))
      assert.is_nil(text:find("FAIL", 1, true))
    end)

    -- The four failure sentences are the highest-value strings in the panel: each has to say what
    -- to DO, without the reader knowing anything about how Elmira works.
    it("tells a player whose spell is on no bar exactly that, and stops asking further questions", function()
      local text = checkWith({
        { label = "bars", ok = true, detail = "ElvUI" },
        { label = "placed", ok = false },
        { label = "visible", ok = nil },
        { label = "glow", ok = nil },
      })
      assert.truthy(text:find("Spell is on a bar", 1, true))
      assert.truthy(text:find("drag it onto a bar", 1, true))
      assert.truthy(text:find("FAIL", 1, true))
      assert.truthy(text:find("--", 1, true))
    end)

    it("blames the stance, not the bar addon, when the button is merely hidden", function()
      local text = checkWith({
        { label = "bars", ok = true, detail = "ElvUI" },
        { label = "placed", ok = true, detail = 1 },
        { label = "visible", ok = false },
      })
      assert.truthy(text:find("Button is visible", 1, true))
      assert.truthy(text:find("check your stance, form or bar paging", 1, true))
    end)

    -- Everything above can pass while the bar glow is off. A chain of green ticks ending in no glow
    -- is exactly the report this panel exists to prevent.
    it("points at the toggle above when every bar question passed but the glow is off", function()
      local text = checkWith({
        { label = "bars", ok = true, detail = "ElvUI" },
        { label = "placed", ok = true, detail = 1 },
        { label = "visible", ok = true, detail = "ElvUI_Bar1Button3" },
        { label = "glow", ok = false },
      })
      assert.truthy(text:find("Glow is switched on", 1, true))
      assert.truthy(text:find("Also glow your action bar", 1, true))
    end)

    -- An unknown spell key is not a bar problem, and must not be reported as one.
    it("labels an unknown spell as a playstyle question", function()
      local text = checkWith({ { label = "spell", ok = false } })
      assert.truthy(text:find("Spell is in your playstyle", 1, true))
      assert.truthy(text:find("not part of your current playstyle", 1, true))
    end)

    it("says there is nothing to check when nothing is being suggested", function()
      ns.Display.computeQueue = function() return {} end
      assert.truthy(rowText(group().check.args.rows.args):find("nothing to check", 1, true))
    end)

    -- The dropdown is the point: the spell you want to ask about is usually the one that is NOT
    -- being suggested, so defaulting to the top suggestion cannot be the only option.
    it("checks a spell you pick, instead of the current suggestion", function()
      ns.Display.currentPack = function() return { spells = { EXORCISM = {}, JUDGEMENT = {} } } end
      local asked
      ns.BarGlow = { check = function(key) asked = key; return {} end }
      assert.equal("EXORCISM", group().check.args.pick.get())
      group().check.args.pick.set(nil, "JUDGEMENT")
      rowText(group().check.args.rows.args)
      assert.equal("JUDGEMENT", asked)
      assert.equal("JUDGEMENT", group().check.args.pick.get())
    end)

    -- "Checking HAMMER_OF_WRATH" is engine vocabulary. Nothing else user-facing shows a symbolic key.
    it("shows the spell's real name, falling back to the key when the client cannot give one", function()
      ns.Display.currentPack = function() return { spells = { EXORCISM = { id = 415073 } } } end
      ns.BarGlow = { check = function() return {} end,
                     spellName = function(id) return id == 415073 and "Exorcism" or nil end }
      assert.truthy(rowText(group().check.args.rows.args):find("Checking Exorcism", 1, true))
      assert.equal("Exorcism", group().check.args.pick.values().EXORCISM)

      ns.BarGlow.spellName = function() return nil end
      assert.truthy(rowText(group().check.args.rows.args):find("Checking EXORCISM", 1, true))
    end)

    -- Offering the whole class data listed passive runes that can never be on a bar, and listed one
    -- ability twice when two records resolved to the same spell name. The question is only ever
    -- about things the rotation tells you to press.
    it("offers the spells the build actually suggests, not the whole class data", function()
      ns.Display.currentPack = function()
        return { spells = { EXORCISM = {}, JUDGEMENT = {}, RUNE_ART_OF_WAR = {} } }
      end
      ns.Display.activeBuild = function()
        return { entries = { { spell = "EXORCISM" }, { spell = "JUDGEMENT" } } }
      end
      local values = group().check.args.pick.values()
      assert.equal("EXORCISM", values.EXORCISM)
      assert.equal("JUDGEMENT", values.JUDGEMENT)
      assert.is_nil(values.RUNE_ART_OF_WAR)
    end)

    it("lists an ability once even when two keys resolve to the same spell", function()
      ns.Display.activeBuild = function()
        return { entries = { { spell = "SEAL_OF_MARTYRDOM" }, { spell = "RUNE_SEAL_OF_MARTYRDOM" } } }
      end
      ns.Display.currentPack = function()
        return { spells = { SEAL_OF_MARTYRDOM = { id = 1 }, RUNE_SEAL_OF_MARTYRDOM = { id = 2 } } }
      end
      ns.BarGlow = { check = function() return {} end, spellName = function() return "Seal of Martyrdom" end }
      ns.Display.computeQueue = function() return { { spell = "SEAL_OF_MARTYRDOM" } } end
      local n = 0
      for _ in pairs(group().check.args.pick.values()) do n = n + 1 end
      assert.equal(1, n)
    end)

    it("repeats a spell in the list only once even if the build names it on several lines", function()
      ns.Display.activeBuild = function()
        return { entries = { { spell = "JUDGEMENT" }, { spell = "JUDGEMENT" }, { spell = "JUDGEMENT" } } }
      end
      ns.Display.computeQueue = function() return { { spell = "JUDGEMENT" } } end
      local n = 0
      for _ in pairs(group().check.args.pick.values()) do n = n + 1 end
      assert.equal(1, n)
    end)

    -- A dropdown whose current value is not one of its options renders blank in AceConfig, which
    -- reads as "nothing selected" on the row that is in fact being checked.
    it("includes the current suggestion even when the pack does not list it", function()
      ns.Display.currentPack = function() return { spells = {} } end
      assert.equal("EXORCISM", group().check.args.pick.values().EXORCISM)
    end)

    it("survives a Display that cannot compute a queue at all", function()
      ns.Display.computeQueue = function() error("no pack attached") end
      assert.is_nil(Options.checkSpell())
    end)

    -- Three switches can darken a perfectly placed, perfectly visible button. The panel used to
    -- blame the same one every time, telling people to turn on a toggle that was already on.
    it("names the right switch when the glow is off, out of three", function()
      local function detailFor(which)
        return checkWith({ { label = "glow", ok = false, detail = which } })
      end
      assert.truthy(detailFor("addon"):find("Elmira itself is switched off", 1, true))
      assert.truthy(detailFor("queue"):find("Glow the next cast", 1, true))
      assert.truthy(detailFor("bars"):find("Also glow your action bar", 1, true))
    end)

    it("explains being hidden in the player's terms, not the display's", function()
      local function hidden(why)
        return checkWith({ { label = "showing", ok = false, detail = why } })
      end
      assert.truthy(hidden("out of combat, no target"):find("Elmira is showing right now", 1, true))
      assert.truthy(hidden("out of combat, no target"):find("in combat or have a target", 1, true))
      -- Each visibility mode gives a different reason, and telling somebody in "combat only" mode
      -- to select a target would be advice that does nothing.
      assert.truthy(hidden("out of combat"):find("hidden until you are in combat", 1, true))
      assert.truthy(hidden("out of combat"):find("this profile's setting", 1, true))
      assert.truthy(hidden("display disabled"):find("queue is switched off", 1, true))
      -- A reason nobody has written words for still has to say something.
      assert.truthy(hidden("some future reason"):find("hidden right now", 1, true))
    end)

    -- Detail is DATA on the Display side. A raw count or the internal literal "blizzard" reaching
    -- the panel is English escaping the localisation boundary.
    it("renders counts and sources as words, not as raw data", function()
      local text = checkWith({
        { label = "bars", ok = true, detail = "blizzard" },
        { label = "placed", ok = true, detail = 2 },
      })
      assert.truthy(text:find("Blizzard default bars", 1, true))
      assert.truthy(text:find("on 2 buttons", 1, true))
      local one = checkWith({ { label = "placed", ok = true, detail = 1 } })
      assert.truthy(one:find("on one button", 1, true))
    end)

    it("survives a Display that cannot answer at all", function()
      ns.Display.computeQueue = nil
      assert.is_nil(Options.checkSpell())
      ns.Display = nil
      assert.is_nil(Options.checkSpell())
    end)
  end)
end)
