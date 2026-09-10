local helper = require("tests.helper")
local mock = require("tests.wow_mock")
local ace3 = require("tests.ace3")

-- Elmira/Options/Options.lua — the options window's chrome, against the REAL AceGUI Frame widget
-- and the REAL AceConfigDialog, opened for "Elmira" exactly as `/elm config` opens it.
--
-- tests/spec/options_window_spec.lua covers the same code against a stand-in widget, and that is
-- the right place for "what does Options do when handed X". This file answers a different
-- question -- "does the window a player is looking at still have its title bar" -- and it can only
-- be answered against the library, because the two things that take the chrome away are the
-- library's own doing: AceConfigDialog re-Opens and re-titles the SAME pooled frame on every
-- option change, and AceGUI's shared pool hands that frame on to the next Ace3 addon when we let
-- go of it. A fake has no pool and re-titles nothing, so it agrees with whatever Options assumes.
--
-- FX2-D1. The owner, in game: "the top header has lost the Version info on top left and also only
-- way to drag the popup is clicking the Elmira in the middle." Both are Options.Decorate's work, so
-- every sequence below drives one route in or out of a Move mode and, AFTER EACH STEP, asserts the
-- three observables together: titlebg spans the frame (not AceGUI's 100px tab at TOP), the version
-- font string is shown carrying Options.versionLine(), and OpenFrames.Elmira is still the same
-- widget. Anything less and "the window looks fine" and "the window is dressed" stop being the
-- same claim.
describe("Options window, against the real AceGUI Frame", function()
  local Options, ns, libs, dialog, logged

  -- The smallest options table with the shapes these sequences need: two top-level groups (so a
  -- selected path exists to restore) and an `execute` inside one, because an execute is how every
  -- Move mode is actually started -- and AceConfigDialog re-Opens the whole window the instant that
  -- button's own func returns (ActivateControl, AceConfigDialog-3.0.lua:844-872). Elmira's real
  -- table is not used: it needs the whole Options/Display stack, and none of what this file is
  -- about depends on which controls the page holds.
  local function optionsTable(onMove)
    return {
      type = "group", name = "Elmira",
      args = {
        general = { type = "group", name = "General", order = 1, args = {
          toggle = { type = "toggle", name = "A toggle", order = 1,
                     get = function() return true end, set = function() end },
          move   = { type = "execute", name = "Move", order = 2, func = onMove },
        } },
        queue = { type = "group", name = "Queue", order = 2, args = {
          toggle = { type = "toggle", name = "Another", order = 1,
                     get = function() return false end, set = function() end },
        } },
      },
    }
  end

  before_each(function()
    mock.reset()
    ns = helper.reset()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    ns.db = { global = { window = { scale = 1.2, width = 960, height = 680,
                                    top = false, left = false } } }
    ns.Adapter = { addonVersion = function() return "1.4.0" end }
    ns.Announcers = { StopMoving = function() end }
    -- Core/Init.lua's chat printer, stood in for so a spec can read back what the addon reported.
    logged = {}
    ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end

    libs = ace3.load()
    dialog = libs.dialog
    Options = helper.load("Elmira/Options/Options.lua")
    -- Straight to the library, skipping Options.Register: Register builds Elmira's whole options
    -- table (every page, every module) and this file is about the window, not its contents.
    libs.registry:RegisterOptionsTable("Elmira", optionsTable(function()
      Options.BeginMove("strip")
    end))
    Options.dialog = dialog
  end)

  after_each(function()
    _G.LibStub, _G.UIParent, _G.CloseSpecialWindows, _G.hooksecurefunc = nil, nil, nil, nil
    _G.UISpecialFrames, _G.CLOSE, _G.PlaySound = nil, nil, nil
  end)

  -- The three observables, together, named so a failure says which step of which sequence lost the
  -- chrome rather than only which assertion it was.
  local function assertDressed(step)
    local widget = dialog.OpenFrames.Elmira
    assert.is_truthy(widget, step .. ": OpenFrames.Elmira is gone -- nothing can decorate it again")
    local point, relativeTo = widget.titlebg:GetPoint(1)
    assert.equal(2, widget.titlebg:GetNumPoints(),
                 step .. ": the title bar is back on AceGUI's single 100px anchor")
    assert.equal("TOPLEFT", point, step .. ": the title bar no longer starts at the window's left")
    assert.equal(widget.frame, relativeTo, step .. ": the title bar is not anchored to the window")
    assert.equal("TOPRIGHT", (select(1, widget.titlebg:GetPoint(2))),
                 step .. ": the title bar does not reach the window's right edge")
    local version = widget.frame.elmiraVersion
    assert.is_truthy(version, step .. ": there is no version font string on the window")
    assert.is_true(version:IsShown(), step .. ": the version is hidden")
    assert.equal(Options.versionLine(), version:GetText(), step .. ": the version says something else")
    return widget
  end

  local function open(...)
    assert.is_true(Options.Open(...))
    return assertDressed("after Open")
  end

  -- The execute button on the page, found the way a player finds it: by its label.
  local function clickMove()
    local found
    local function walk(container)
      for _, child in ipairs(container.children or {}) do
        if child.type == "Button" and child.text and child.text:GetText() == "Move" then found = child end
        walk(child)
      end
    end
    walk(dialog.OpenFrames.Elmira)
    assert.is_truthy(found, "the Move button is not on the page")
    found:Fire("OnClick")
  end

  describe("the chrome survives every way in and out of a Move mode (FX2-D1)", function()
    it("survives the execute button that starts one, and the Done button that ends it", function()
      local widget = open("general")
      clickMove()
      assert.equal(widget, assertDressed("after the Move button"))
      assert.is_false(widget.frame:IsShown(), "the window did not get out of the way")
      Options.EndMove()
      assert.equal(widget, assertDressed("after Done"))
      assert.is_true(widget.frame:IsShown(), "the window did not come back")
    end)

    it("survives Escape, including the close-everything sweep it triggers a frame later", function()
      local widget = open("general")
      clickMove()
      ace3.escape()
      assert.equal(widget, assertDressed("after Escape"))
      assert.is_true(widget.frame:IsShown(), "Escape did not bring the window back")
      -- AceConfigDialog wraps CloseSpecialWindows to ALSO close every options window on the next
      -- OnUpdate; `closeAllOverride` is what keeps the one we just restored out of that sweep.
      ace3.tick(dialog)
      assert.equal(widget, assertDressed("after the close-everything sweep"))
      assert.is_true(widget.frame:IsShown(), "the sweep shut the window Escape had just restored")
    end)

    it("survives the re-Open every execute button triggers while the window is hidden", function()
      local widget = open("general")
      clickMove()
      -- What ActivateControl does the moment the button's own func returns: re-Open the same frame,
      -- which SHOWS it again. The refresh hook has to decorate, re-chain OnClose and re-hide.
      dialog:Open("Elmira")
      assert.equal(widget, assertDressed("after the execute re-Open"))
      assert.is_false(widget.frame:IsShown(), "the window came back over the thing being moved")
      Options.EndMove()
      assert.equal(widget, assertDressed("after Done"))
      assert.is_true(widget.frame:IsShown())
    end)

    it("survives a mode that ends itself, the way /elm lock and combat end one", function()
      local widget = open("general")
      -- Every Stop* calls Options.EndMove, and Options' own close chain calls every Stop* -- so the
      -- mode ending itself re-enters EndMove. /elm lock and entering combat both arrive this way.
      ns.Announcers = { StopMoving = function() Options.EndMove() end }
      clickMove()
      assert.equal(widget, assertDressed("after the Move button"))
      Options.EndMove()
      assert.equal(widget, assertDressed("after the mode stopped itself"))
      assert.is_true(widget.frame:IsShown())
    end)

    it("survives one Move mode replacing another", function()
      local widget = open("general")
      clickMove()
      -- Textures.StartMove's shape: stop whatever is running (which shows the window) and start the
      -- next one (which hides it again), both inside one button press.
      Options.EndMove()
      assert.equal(widget, assertDressed("between the two modes"))
      Options.BeginMove("texture", "HAMMER")
      assert.equal(widget, assertDressed("after the second mode started"))
      assert.is_false(widget.frame:IsShown())
      Options.EndMove()
      assert.equal(widget, assertDressed("after Done"))
    end)

    it("survives asking for the panel while a mode has it hidden", function()
      local widget = open("general")
      clickMove()
      -- `/elm config` ends the mode rather than opening a second window over it.
      assert.is_true(Options.Open("queue"))
      assert.equal(widget, assertDressed("after /elm config"))
      assert.is_true(widget.frame:IsShown())
      assert.is_nil(Options.moveSubject(), "the Move mode outlived the window that started it")
    end)

    it("survives a refresh the options table itself triggers while hidden", function()
      local widget = open("general")
      clickMove()
      -- Any `set`, and SelectGroup itself, ends in NotifyChange -- which re-Opens the app on the
      -- next OnUpdate and shows the frame (AceConfigDialog-3.0.lua:1784-1788, 1930-1933).
      libs.registry:NotifyChange("Elmira")
      ace3.tick(dialog)
      assert.equal(widget, assertDressed("after the notified refresh"))
      assert.is_false(widget.frame:IsShown(), "the refresh put the window back over the sample")
    end)
  end)

  -- FX2-D3. None of the sequences above loses the chrome, so the guard is not a fix for one of
  -- them: it is the answer to "whatever took it off, the next time this window is put on screen it
  -- is dressed again". Undecorate is used here to produce the state the owner described, because it
  -- is the one thing in the addon that produces it -- it is what the close chain runs, and the
  -- close chain fires from the frame's own OnHide.
  describe("a window put back on screen is dressed again, whatever stripped it (FX2-D3)", function()
    it("re-dresses the window a Move mode gives back", function()
      local widget = open("general")
      clickMove()
      assert.is_true(Options.Undecorate(widget))
      assert.equal("stripped", Options.chromeState(), "Undecorate did not strip the frame")
      Options.EndMove()
      assert.equal(widget, assertDressed("after Done on a stripped window"))
      assert.is_true(widget.frame:IsShown())
    end)

    it("re-dresses it on the page it was left on, not only in the middle of the bar", function()
      local widget = open("queue")
      clickMove()
      assert.is_true(Options.Undecorate(widget))
      Options.EndMove()
      assert.equal(widget, assertDressed("after Done"))
      assert.equal("queue", dialog:GetStatusTable("Elmira", {}).groups.selected,
                   "the window came back on a different page")
    end)

    it("reports dressed or stripped, and neither when no window is open", function()
      assert.is_nil(Options.chromeState(), "there is no window, so there is no chrome to report on")
      local widget = open("general")
      assert.equal("dressed", Options.chromeState())
      Options.Undecorate(widget)
      assert.equal("stripped", Options.chromeState())
      Options.Decorate()
      assert.equal("dressed", Options.chromeState())
    end)

    -- Each observable alone, so the report cannot pass on half a title bar.
    it("calls a window with a full-width bar but no version stripped", function()
      local widget = open("general")
      widget.frame.elmiraVersion:Hide()
      assert.equal("stripped", Options.chromeState())
    end)

    it("calls a window with the version but AceGUI's 100px drag tab stripped", function()
      local widget = open("general")
      widget.titlebg:ClearAllPoints()
      widget.titlebg:SetPoint("TOP", widget.frame, "TOP", 0, 12)
      assert.equal("stripped", Options.chromeState())
    end)

    -- Half a title bar is not a title bar: anchored at the left corner alone it still stops 100px
    -- in, so everything right of that is not draggable and the version has nothing to sit on.
    it("calls a bar anchored only at the left corner stripped, not dressed", function()
      local widget = open("general")
      widget.titlebg:ClearAllPoints()
      widget.titlebg:SetPoint("TOPLEFT", widget.frame, "TOPLEFT", 0, 12)
      assert.equal("stripped", Options.chromeState())
    end)
  end)

  -- FX2-D2. None of the sequences above loses the chrome, but the ORDER inside Options.Decorate
  -- can: ApplyWindow runs first, it is the only step that hands numbers to the client, and until
  -- now a throw in there took the whole title bar with it -- and `chainClose` after it.
  describe("a window is still dressed when the client refuses its geometry (FX2-D2)", function()
    it("dresses a window whose size and place could not be applied, and says so", function()
      -- Broken on a frame that has been RELEASED, so the decoration that throws is the first one
      -- this frame gets on the way back out of the pool -- "the window opened undressed", not "it
      -- lost its chrome later". Undecorate has already put the stock title bar back by then, so
      -- there is nothing left over to make the assertion below pass by accident.
      local frame = open("general").frame
      frame:Hide()
      assert.equal(1, frame.obj.titlebg:GetNumPoints(), "the released frame is still dressed")
      frame.SetResizeBounds = function() error("SetResizeBounds: bad bounds") end

      local widget = open("general")
      assert.equal(frame, widget.frame, "the pool handed back a different frame -- nothing was tested")
      assert.equal("dressed", Options.chromeState())
      assert.is_true(#logged > 0, "the failure was swallowed rather than reported")
      assert.is_truthy(logged[#logged]:find("could not size or place the options window"),
                       "the log line does not say what failed: " .. logged[#logged])
    end)

    it("still chains the close callback when dressing the window throws outright", function()
      local widget = open("general")
      -- Broken AFTER the first, successful decoration, so the frame carries our chrome when the
      -- second decoration fails -- which is the state that leaks it to the next Ace3 addon.
      widget.frame.elmiraVersion = nil
      widget.frame.CreateFontString = function() error("out of font strings") end
      dialog:Open("Elmira")
      assert.is_true(#logged > 0, "the failure was swallowed rather than reported")
      assert.is_truthy(logged[#logged]:find("could not dress the options window"),
                       "the log line does not say what failed: " .. logged[#logged])
      -- The close chain is the thing being tested: it is what runs Undecorate before the widget
      -- goes back to the pool.
      widget.frame.CreateFontString = nil
      widget.frame:Hide()
      assert.is_nil(dialog.OpenFrames.Elmira)
      assert.equal(1, widget.titlebg:GetNumPoints(),
                   "the frame went back to the pool wearing Elmira's full-width title bar")
      assert.is_false(widget.frame.elmiraClose:IsShown(),
                      "the frame went back to the pool wearing Elmira's close button")
    end)
  end)

  describe("the chrome survives the library's own pooling (M5g/D15)", function()
    it("is put back on the same frame the pool hands back on the next open", function()
      local first = open("general")
      local frame = first.frame
      first.frame:Hide()
      assert.is_nil(dialog.OpenFrames.Elmira, "closing the window did not release the widget")
      local second = open("general")
      assert.equal(frame, second.frame, "the pool handed back a different frame -- reuse untested")
    end)

    it("leaves nothing of ours on the frame the next Ace3 addon acquires", function()
      libs.registry:RegisterOptionsTable("OtherAddon", {
        type = "group", name = "Other",
        args = { t = { type = "toggle", name = "T",
                       get = function() return false end, set = function() end } },
      })
      local ours = open("general")
      local frame = ours.frame
      ours.frame:Hide()

      dialog:Open("OtherAddon")
      local theirs = dialog.OpenFrames.OtherAddon
      assert.equal(frame, theirs.frame, "the pool did not hand our frame on -- nothing was tested")
      assert.equal(1, theirs.titlebg:GetNumPoints(), "our full-width title bar is on their window")
      assert.equal("TOP", (select(1, theirs.titlebg:GetPoint(1))))
      assert.is_false(theirs.frame.elmiraVersion:IsShown(), "our version text is on their window")
      assert.is_false(theirs.frame.elmiraClose:IsShown(), "our close button is on their window")
      theirs.frame:Hide()
    end)

    it("dresses the frame again when Elmira gets it back from another addon", function()
      libs.registry:RegisterOptionsTable("OtherAddon", {
        type = "group", name = "Other",
        args = { t = { type = "toggle", name = "T",
                       get = function() return false end, set = function() end } },
      })
      local frame = open("general").frame
      dialog.OpenFrames.Elmira.frame:Hide()
      dialog:Open("OtherAddon")
      dialog.OpenFrames.OtherAddon.frame:Hide()
      local again = open("general")
      assert.equal(frame, again.frame, "the pool handed back a different frame -- reuse untested")
    end)
  end)

  describe("closing still lets go of the frame", function()
    it("clears OpenFrames when Escape closes the window with no mode running", function()
      open("general")
      ace3.escape()
      ace3.tick(dialog)
      assert.is_nil(dialog.OpenFrames.Elmira, "Escape left the window in OpenFrames -- a pool leak")
    end)

    it("closes through the X, which is what the stock button's own click does", function()
      local widget = open("general")
      widget.frame.elmiraClose:GetScript("OnClick")()
      assert.is_nil(dialog.OpenFrames.Elmira, "the X did not run AceConfigDialog's own cleanup")
      assert.is_false(widget.frame:IsShown())
    end)
  end)
end)
