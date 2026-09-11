local helper = require("tests.helper")
local mock = require("tests.wow_mock")
local ace3 = require("tests.ace3")

-- Elmira/Options/TexturePanel.lua and Elmira/Options/TexturePickerWidget.lua — the texture picker
-- window (AT4-D2), against the REAL AceGUI.
--
-- Against the real library on purpose, for the reason tests/spec/options_real_window_spec.lua gives:
-- the grid is a custom AceGUI widget, and everything that can go wrong with one -- a cell that is
-- never shown, a callback still wired to a released widget, a pooled frame handed on with our
-- children still parented to it -- lives in the seam between our code and AceGUI's own pool, which
-- a fake cannot have.
--
-- And every assertion here is about an OBSERVABLE: the settings row after a click, the frame that
-- is or is not shown, the path the ability draws. "SetCustomData was called" is not evidence that
-- anything was drawn.
describe("the texture picker window", function()
  local ns, Panel, A, refreshes, fired, flips

  -- Every cell the grid is currently showing, in order -- the widget pools them, so a cell that was
  -- used for a previous category and hidden must not count.
  local function cells()
    local out = {}
    for _, cell in ipairs(Panel.grid.cells) do
      if cell:IsShown() then out[#out + 1] = cell end
    end
    return out
  end

  local function pathsShown()
    local out = {}
    for _, cell in ipairs(cells()) do out[#out + 1] = cell.elmiraPath end
    return out
  end

  local function selectedPaths()
    local out = {}
    for _, cell in ipairs(Panel.grid.cells) do
      if cell.elmiraSelected then out[#out + 1] = cell.elmiraPath end
    end
    return out
  end

  before_each(function()
    mock.reset()
    ns = helper.reset()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    ace3.load()
    helper.load("Elmira/Core/Colors.lua")
    ns.db = { char = { abilities = {} } }
    A = helper.load("Elmira/Core/AbilitySettings.lua")
    helper.load("Elmira/Display/TextureLibrary.lua")

    refreshes, fired = 0, {}
    -- Display/Textures itself is exercised by its own spec; what this window needs from it is the
    -- category list, the repaint and the test-fire -- the three things a click is supposed to reach.
    flips = {}
    ns.Textures = {
      DEFAULT_PATH = "Interface\\AddOns\\Elmira\\media\\shape_ring",
      libraryGroups = function()
        return ns.TextureLibrary.groups(function() return false end)
      end,
      Refresh = function() refreshes = refreshes + 1 end,
      TestFire = function(key) fired[#fired + 1] = key end,
      movingKey = function() return nil end,
      -- AT8-D5: the real implementation lives in Display/Textures, its own spec; what this window
      -- needs to prove is that it is ASKED, and asked with the source the ability was actually on.
      flipSize = function(key, from, to) flips[#flips + 1] = { key, from, to } end,
    }
    ns.Display = { spellName = function(key) return "Name of " .. key end }

    helper.load("Elmira/Options/TexturePickerWidget.lua")
    Panel = helper.load("Elmira/Options/TexturePanel.lua")
  end)

  after_each(function()
    if Panel.isOpen() then Panel.Close(false) end
  end)

  describe("opening", function()
    it("puts a titled window on screen for the ability it was asked about", function()
      assert.is_false(Panel.isOpen())
      assert.is_true(Panel.Open("EXORCISM"))
      assert.is_true(Panel.isOpen())
      assert.equal("EXORCISM", Panel.abilityKey())
      assert.is_true(Panel.window.frame:IsShown())
      assert.equal("Elmira — Texture Picker", Panel.window.titletext:GetText())
      -- Above the configuration window, which is in the same strata and was already on screen --
      -- AceConfigDialog re-Opens it the instant the Choose… button's own func returns.
      assert.equal(1, Panel.window.frame.__raised, "the picker opened behind the options window")
    end)

    it("refuses a key that is not one, and opens no window", function()
      assert.is_false(Panel.Open(nil))
      assert.is_false(Panel.Open(""))
      assert.is_false(Panel.isOpen())
    end)

    -- A grid with no cells is a window that looks like it is working and offers nothing.
    it("fills the grid with the first category and lights up nothing yet", function()
      Panel.Open("EXORCISM")
      assert.equal(8, #cells(), "the Shapes category did not reach the grid")
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_ring", pathsShown()[1])
      assert.equal("Ring", cells()[1].elmiraName)
      -- The ability draws the ring by default, so the ring is the one cell already marked.
      assert.same({ "Interface\\AddOns\\Elmira\\media\\shape_ring" }, selectedPaths())
    end)

    it("opens on the category holding the texture this ability already draws", function()
      A.set("EXORCISM", "texture", "source", "path")
      A.set("EXORCISM", "texture", "path", "165558")     -- Blizzard's "Icons" category
      Panel.Open("EXORCISM")
      assert.equal(19, #cells())
      assert.same({ "165558" }, selectedPaths())
    end)
  end)

  describe("choosing", function()
    -- The live preview, and the whole reason the window writes as you browse: you judge a texture on
    -- screen at its real size, not in a grid.
    it("writes the clicked file to the ability and repaints it at once", function()
      Panel.Open("EXORCISM")
      cells()[4]:Click()
      local e = A.effective("EXORCISM", "texture")
      assert.equal("path", e.source)
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_diamond", e.path)
      assert.equal(1, refreshes, "the texture on screen was not repainted")
      -- Nothing is holding this texture on screen, so it is flashed -- "immediately" has to mean
      -- something for the case the picker is most used in.
      assert.same({ "EXORCISM" }, fired)
      assert.same({ "Interface\\AddOns\\Elmira\\media\\shape_diamond" }, selectedPaths())
      -- AT8-D5: picking a texture out of the icon default is a source change, asked of Textures
      -- the same way the tab's own toggle is.
      assert.same({ { "EXORCISM", "icon", "path" } }, flips)
    end)

    -- AT8-D5: browsing between two files the ability is already drawing one of is not a source
    -- change -- the ability was on `path` before the click and is on `path` after it.
    it("asks for no size flip when the ability was already on a path", function()
      A.set("EXORCISM", "texture", "source", "path")
      A.set("EXORCISM", "texture", "path", "165558")
      Panel.Open("EXORCISM")
      cells()[4]:Click()
      assert.same({ { "EXORCISM", "path", "path" } }, flips)
    end)

    it("does not flash a texture that is already on screen being dragged", function()
      ns.Textures.movingKey = function() return "EXORCISM" end
      Panel.Open("EXORCISM")
      cells()[2]:Click()
      assert.equal(1, refreshes)
      assert.same({}, fired, "the texture being dragged was flashed on top of itself")
    end)

    it("keeps the choice when Okay closes the window", function()
      Panel.Open("EXORCISM")
      cells()[4]:Click()
      Panel.okay.frame:Click()
      assert.is_false(Panel.isOpen())
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_diamond",
        A.effective("EXORCISM", "texture").path)
    end)

    -- Cancel is what makes browsing free: everything clicked was written, and every one of those
    -- writes is undone by the pair `Open` remembered.
    it("puts the ability back exactly as it was when Cancel closes the window", function()
      A.set("EXORCISM", "texture", "source", "path")
      A.set("EXORCISM", "texture", "path", "Interface\\Icons\\Mine")
      Panel.Open("EXORCISM")
      cells()[4]:Click()
      cells()[6]:Click()
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_star",
        A.effective("EXORCISM", "texture").path)
      Panel.cancel.frame:Click()
      assert.is_false(Panel.isOpen())
      local e = A.effective("EXORCISM", "texture")
      assert.equal("Interface\\Icons\\Mine", e.path)
      assert.equal("path", e.source)
      assert.equal(3, refreshes, "the screen still shows the texture the player cancelled")
    end)

    -- The X is the exit that has not said what it wants kept, so it means Cancel too -- otherwise
    -- closing a window you were only browsing in silently changes the ability.
    it("treats the window's own close button as Cancel", function()
      Panel.Open("EXORCISM")
      cells()[4]:Click()
      Panel.window.frame:Hide()
      assert.is_false(Panel.isOpen())
      assert.equal("icon", A.effective("EXORCISM", "texture").source)
    end)
  end)

  describe("the category dropdown and the search box", function()
    it("redraws the grid for the category picked", function()
      Panel.Open("EXORCISM")
      Panel.categories:Fire("OnValueChanged", "3")   -- Icons
      assert.equal(19, #cells())
      assert.equal("165558", pathsShown()[1])
    end)

    it("filters the current category by name as it is typed", function()
      Panel.Open("EXORCISM")
      Panel.search:Fire("OnTextChanged", "squ")
      assert.same({ "Interface\\AddOns\\Elmira\\media\\shape_square" }, pathsShown())
      -- ...and clearing it brings the rest back, rather than leaving a grid nothing can refill.
      Panel.search:Fire("OnTextChanged", "")
      assert.equal(8, #cells())
    end)

    it("shows an empty grid rather than everything when nothing matches", function()
      Panel.Open("EXORCISM")
      Panel.search:Fire("OnTextChanged", "no such texture")
      assert.same({}, pathsShown())
    end)
  end)

  -- AceGUI's pool is shared with every other Ace3 addon in the client. A window that leaves its
  -- children parented to the frame it gives back, or a grid that keeps its callback, arrives in the
  -- next addon's window carrying ours -- which this project has shipped once already.
  describe("giving the window back to the pool", function()
    it("leaves nothing of ours on the frame or on the grid", function()
      Panel.Open("EXORCISM")
      local frame, picker = Panel.window.frame, Panel.grid
      local button = Panel.okay.frame
      Panel.Close(false)

      assert.is_false(frame:IsShown())
      assert.is_nil(picker.onSelect, "a released grid still calls back into a closed window")
      assert.is_nil(picker.textures)
      assert.is_nil(picker.selected)
      for _, cell in ipairs(picker.cells) do
        assert.is_false(cell:IsShown(), "a cell went back to the pool still drawing a texture")
        assert.is_nil(cell.elmiraPath)
        assert.is_false(cell.elmiraSelected)
      end
      assert.equal(_G.UIParent, button:GetParent(), "a button of ours stayed on the pooled frame")
      assert.equal(_G.UIParent, picker.frame:GetParent())
    end)

    it("re-acquires the same widgets on the next open, showing the new ability", function()
      Panel.Open("EXORCISM")
      local picker = Panel.grid
      Panel.Close(false)
      Panel.Open("JUDGEMENT")
      assert.equal(picker, Panel.grid, "AceGUI handed back a different widget, not the pooled one")
      assert.equal("JUDGEMENT", Panel.abilityKey())
      assert.equal(8, #cells())
      assert.is_true(Panel.window.frame:IsShown())
    end)

    it("closes what is open before opening for another ability", function()
      Panel.Open("EXORCISM")
      cells()[4]:Click()
      Panel.Open("JUDGEMENT")
      assert.equal("JUDGEMENT", Panel.abilityKey())
      -- The first ability keeps what was clicked: opening a second picker is not a cancellation.
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_diamond",
        A.effective("EXORCISM", "texture").path)
    end)

    it("says so rather than erroring when there is nothing to close", function()
      assert.is_false(Panel.Close(true))
    end)
  end)

  describe("the WeakAuras categories (AT4-D3)", function()
    it("are absent on a character without it and present on one with it", function()
      Panel.Open("EXORCISM")
      local offered = {}
      for _, group in ipairs(ns.Textures.libraryGroups()) do offered[#offered + 1] = group.key end
      assert.same({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers" }, offered)

      Panel.Close(false)
      ns.Textures.libraryGroups = function()
        return ns.TextureLibrary.groups(function(name) return name == "WeakAuras" end)
      end
      Panel.Open("EXORCISM")
      Panel.categories:Fire("OnValueChanged", "9")   -- PowerAuras, the last category
      assert.equal(145, #cells())
    end)
  end)

  it("toggles: the button that opened the window shuts it", function()
    assert.is_true(Panel.Toggle("EXORCISM"))
    assert.is_true(Panel.isOpen())
    assert.is_true(Panel.Toggle("EXORCISM"))
    assert.is_false(Panel.isOpen())
  end)

  it("opens nothing at all on a client with no AceGUI", function()
    local saved = _G.LibStub
    _G.LibStub = nil
    assert.is_false(Panel.Open("EXORCISM"))
    _G.LibStub = saved
  end)

  -- Five across at the shipped width (owner, 2026-09-11) -- and a sixth that WRAPS. A column count
  -- that came out 1 (a grid measured before it had a width) draws the whole category down a single
  -- strip, and a count of 0 draws every texture on top of the one before it.
  it("lays the cells out five across, wrapping onto the next row", function()
    Panel.Open("EXORCISM")
    local first, fifth, sixth = cells()[1], cells()[5], cells()[6]
    local _, _, _, x1, y1 = first:GetPoint(1)
    local _, _, _, x5, y5 = fifth:GetPoint(1)
    local _, _, _, x6, y6 = sixth:GetPoint(1)
    assert.same({ 0, 0 }, { x1, y1 })
    assert.same({ 4 * 128, 0 }, { x5, y5 }, "the fifth cell did not fit on the first row")
    assert.same({ 0, -128 }, { x6, y6 }, "the sixth cell did not wrap onto the next row")
    -- ...and the content frame is as tall as what it holds, or the scroll goes nowhere.
    assert.equal(2 * 128, Panel.grid.content:GetHeight())
  end)
end)
