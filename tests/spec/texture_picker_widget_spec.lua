local helper = require("tests.helper")
local mock = require("tests.wow_mock")
local ace3 = require("tests.ace3")

-- Elmira/Options/TexturePickerWidget.lua — ElmiraTexturePicker, the preview grid inside the
-- texture picker window (AT4-D2, DP2-D4).
--
-- Against the REAL AceGUI and the real client frame mock, for the reason texture_panel_spec.lua's
-- own header gives: everything this widget does is cell/border/scroll construction against real
-- frame methods (SetAllPoints, SetColorTexture, SetHighlightTexture, ClearAllPoints...), and a
-- hand-rolled fake of that surface is exactly where "I forgot to implement one" hides -- which a
-- first attempt at this file did, at scale. `tests.wow_mock` already gets every one of those
-- right, and now also models SetColorTexture and a raw ScrollFrame's own surface (added for this
-- file, since neither existed before and both are plain client API, not this file's own idiom).
describe("Elmira/Options/TexturePickerWidget.lua (the picker grid)", function()
  local AceGUI, tooltip

  local function newPicker() return AceGUI:Create("ElmiraTexturePicker") end

  -- The regions a cell draws, in creation order: the dark plate, the art, then the four border
  -- edges (top, bottom, left, right) -- `cellFor`'s own order in the source.
  local function cellRegions(cell)
    return { cell:GetRegions() }
  end

  before_each(function()
    mock.reset()
    helper.reset()
    AceGUI = ace3.load().gui
    -- GameTooltip, by hand: the established precedent (queue_spec.lua, card_widget_spec.lua) for
    -- a client global that is not the WoW frame API `tests/wow_mock.lua` already models.
    tooltip = { shown = false }
    function tooltip:SetOwner(owner, anchor) self.owner, self.anchor = owner, anchor end
    function tooltip:SetWidth(w) self.width = w end
    function tooltip:SetText(text) self.text = text end
    function tooltip:AddLine(text) self.line2 = text end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown = false end
    _G.GameTooltip = tooltip
    helper.load("Elmira/Options/TexturePickerWidget.lua")
  end)

  after_each(function()
    _G.GameTooltip = nil
  end)

  it("registers ElmiraTexturePicker under an explicit version", function()
    assert.equal(1, AceGUI:GetWidgetVersion("ElmiraTexturePicker"))
  end)

  it("does not overwrite a widget type already at least as new", function()
    AceGUI:RegisterWidgetType("ElmiraTexturePicker", function() error("should not run") end, 99)
    helper.load("Elmira/Options/TexturePickerWidget.lua")
    assert.equal(99, AceGUI:GetWidgetVersion("ElmiraTexturePicker"))
  end)

  it("starts empty, at the top of the scroll, on acquire", function()
    local picker = newPicker()
    assert.equal(0, picker.scrollOffset)
    assert.equal(0, picker.scroll:GetVerticalScroll())
    -- OnAcquire lays the (empty) grid out for real, rather than leaving these two fields at
    -- whatever the Constructor left them (nothing, on a widget's very first acquire ever).
    assert.equal(0, picker.shownCount)
    assert.equal(0, picker.contentHeight)
  end)

  -- Public state, the same way `TexturePanel.window`/`.grid` are: what a diagnostic (or a spec)
  -- can point at as the one evidence of what is actually on screen.
  it("exposes how many cells are shown and how tall the content grid is", function()
    local picker = newPicker()
    picker.frame:SetWidth(700)
    picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } } }
    assert.equal(2, picker.shownCount)
    assert.equal(128, picker.contentHeight, "one row, nothing to wrap onto a second")
  end)

  -- The scroll frame and its content child, the two things every cell is laid out inside of.
  it("builds a mouse-wheel-enabled scroll frame holding a content child, filling the widget",
    function()
      local picker = newPicker()
      assert.is_true(picker.scroll:IsMouseWheelEnabled())
      assert.same({ "TOPLEFT", picker.frame, "TOPLEFT", 8, -8 }, { picker.scroll:GetPoint(1) })
      assert.same({ "BOTTOMRIGHT", picker.frame, "BOTTOMRIGHT", -8, 8 }, { picker.scroll:GetPoint(2) })
      assert.equal(picker.content, picker.scroll:GetScrollChild())
    end)

  describe("SetCustomData -- laying the grid out", function()
    it("shows one cell per texture, each with its own picture", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = {
        { path = "a", name = "Alpha" }, { path = "b", name = "Beta" },
      } }
      assert.equal(2, #picker.cells)
      assert.is_true(picker.cells[1]:IsShown())
      assert.is_true(picker.cells[2]:IsShown())
      assert.equal("a", picker.cells[1].elmiraIcon:GetTexture())
      assert.equal("b", picker.cells[2].elmiraIcon:GetTexture())
    end)

    -- A Blizzard entry is a numeric file id and has to reach SetTexture as a NUMBER; a path arrives
    -- as a string -- the one thing that lets the same grid draw both kinds of entry.
    it("passes a numeric-looking path to SetTexture as an actual number", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "165558", name = "Icon 165558" } } }
      assert.equal(165558, picker.cells[1].elmiraIcon:GetTexture())
    end)

    -- Every cell built the same way: a fixed size, a dark plate behind the art (most of the
    -- library is white shapes with the picture in the alpha channel, invisible on a light
    -- background), the art inset from the plate's edge, and a highlight for hover.
    it("builds each cell as a fixed-size square with a dark plate behind the art", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" } } }
      local cell = picker.cells[1]
      assert.equal(120, cell:GetWidth())
      assert.equal(120, cell:GetHeight())
      local back = cellRegions(cell)[1]
      assert.equal(cell, back.__allPoints)
      assert.same({ 0, 0, 0, 0.55 }, { back:GetColorTexture() })
      assert.same({ "TOPLEFT", cell, "TOPLEFT", 3, -3 }, { cell.elmiraIcon:GetPoint(1) })
      assert.same({ "BOTTOMRIGHT", cell, "BOTTOMRIGHT", -3, 3 }, { cell.elmiraIcon:GetPoint(2) })
      assert.equal("Interface\\Buttons\\ButtonHilight-Square",
        cell:GetHighlightTexture():GetTexture())
    end)

    -- The gold border: four edge lines, hidden until a cell is selected, each anchored to run
    -- along its own edge of the cell rather than sitting as a filled backdrop over the art.
    it("builds a four-sided border, hidden until the cell is selected", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" } } }
      local cell = picker.cells[1]
      assert.equal(4, #cell.elmiraBorder)
      for _, edge in ipairs(cell.elmiraBorder) do
        assert.is_false(edge:IsShown(), "the border is not selected yet")
        local r, g, b, a = edge:GetColorTexture()
        assert.equal(1.0, r)
        assert.equal(0.83, g)
        assert.equal(0.48, b)
        assert.equal(1, a)
      end
      local top, bottom, left, right = cell.elmiraBorder[1], cell.elmiraBorder[2],
                                        cell.elmiraBorder[3], cell.elmiraBorder[4]
      assert.same({ "TOPLEFT", cell, "TOPLEFT", 0, 0 }, { top:GetPoint(1) })
      assert.same({ "TOPRIGHT", cell, "TOPRIGHT", 0, 0 }, { top:GetPoint(2) })
      assert.equal(3, top:GetHeight())
      assert.same({ "BOTTOMLEFT", cell, "BOTTOMLEFT", 0, 0 }, { bottom:GetPoint(1) })
      assert.same({ "BOTTOMRIGHT", cell, "BOTTOMRIGHT", 0, 0 }, { bottom:GetPoint(2) })
      assert.equal(3, bottom:GetHeight())
      assert.same({ "TOPLEFT", cell, "TOPLEFT", 0, 0 }, { left:GetPoint(1) })
      assert.same({ "BOTTOMLEFT", cell, "BOTTOMLEFT", 0, 0 }, { left:GetPoint(2) })
      assert.equal(3, left:GetWidth())
      assert.same({ "TOPRIGHT", cell, "TOPRIGHT", 0, 0 }, { right:GetPoint(1) })
      assert.same({ "BOTTOMRIGHT", cell, "BOTTOMRIGHT", 0, 0 }, { right:GetPoint(2) })
      assert.equal(3, right:GetWidth())
    end)

    it("draws the gold border on the selected cell alone", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } }, selected = "b" }
      assert.is_false(picker.cells[1].elmiraBorder[1]:IsShown())
      assert.is_true(picker.cells[2].elmiraBorder[1]:IsShown())
    end)

    it("hides every leftover pooled cell beyond the new, shorter list", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" }, { path = "c" } } }
      picker:SetCustomData{ textures = { { path = "a" } } }
      assert.is_true(picker.cells[1]:IsShown())
      assert.is_false(picker.cells[2]:IsShown())
      assert.is_false(picker.cells[3]:IsShown())
      -- A hidden cell must not still answer a click for the entry it no longer shows.
      assert.is_nil(picker.cells[2].elmiraPath)
    end)

    -- Cells are POOLED: a shorter list followed by a longer one reuses the same cell objects rather
    -- than making new ones, the reason a 145-picture category costs nothing to page back down from.
    it("reuses the same cell objects across relayouts instead of growing without bound", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } } }
      local first = picker.cells[1]
      picker:SetCustomData{ textures = {} }
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } } }
      assert.equal(first, picker.cells[1])
      assert.equal(2, #picker.cells)
    end)

    -- Every cell is repositioned on every redraw, whatever it was showing before: a cell left at a
    -- stale anchor from an earlier, wider layout is the drifting-grid bug pooling would invite.
    it("clears each cell's anchor before placing it fresh on every redraw", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" } } }
      local cell = picker.cells[1]
      cell:SetPoint("CENTER", picker.content, "CENTER", 999, 999)
      picker:SetCustomData{ textures = { { path = "a" } } }
      assert.equal(1, cell:GetNumPoints(), "the stale centre anchor was not cleared before the real one")
    end)

    -- Back to the top on a fresh list -- a 145-picture category's scroll offset left standing would
    -- otherwise show nothing but empty space above a 6-picture one.
    it("resets the scroll position on a new list, unless told to keep it", function()
      local picker = newPicker()
      picker.scroll:SetVerticalScroll(400)
      picker.scrollOffset = 400
      picker:SetCustomData{ textures = { { path = "a" } } }
      assert.equal(0, picker.scroll:GetVerticalScroll())
      assert.equal(0, picker.scrollOffset)

      picker.scroll:SetVerticalScroll(400)
      picker.scrollOffset = 400
      picker:SetCustomData{ textures = { { path = "a" } }, keepScroll = true }
      assert.equal(400, picker.scroll:GetVerticalScroll())
      assert.equal(400, picker.scrollOffset)
    end)

    it("copes with no data table at all, rather than erroring", function()
      local picker = newPicker()
      assert.has_no.errors(function() picker:SetCustomData(nil) end)
      assert.equal(0, #picker.cells)
    end)

    -- A width too narrow for even one full cell must still show one column, not zero -- a column
    -- count of 0 would put every texture on top of the one before it.
    it("never lays the grid out at zero columns, however narrow the widget is", function()
      local picker = newPicker()
      picker.frame:SetWidth(10)
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } } }
      -- Two cells stacked vertically (one column) means the second one's Y moved down, not right.
      local _, _, _, x1, y1 = picker.cells[1]:GetPoint(1)
      local _, _, _, x2, y2 = picker.cells[2]:GetPoint(1)
      assert.equal(x1, x2, "one column: the same X for every cell")
      assert.not_equal(y1, y2, "one column: a different Y for every cell")
    end)

    it("sizes the content frame to fit exactly what it holds, so the scrollbar range is real",
      function()
        local picker = newPicker()
        picker.frame:SetWidth(700)
        picker:SetCustomData{ textures = { { path = "a" }, { path = "b" }, { path = "c" },
                                            { path = "d" }, { path = "e" }, { path = "f" } } }
        -- Five across at 700px (five 120px cells plus four 8px gaps, minus the scrollbar's own
        -- room, comfortably fits five and not six): one row of five plus one more wraps to a
        -- second row, so the content is exactly two rows tall.
        assert.equal(5 * (120 + 8), picker.content:GetWidth())
        assert.equal(2 * (120 + 8), picker.content:GetHeight())
      end)

    -- AceGUI assigns the real width only after the control is parented; relaying out on that event
    -- is what lets the column count answer to the window it actually ended up in.
    it("relays the grid out when the widget's width changes", function()
      local picker = newPicker()
      picker.frame:SetWidth(700)
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" }, { path = "c" } } }
      local _, _, _, _, wideY = picker.cells[3]:GetPoint(1)
      picker:SetWidth(140)
      local _, _, _, _, narrowY = picker.cells[3]:GetPoint(1)
      assert.not_equal(wideY, narrowY, "a narrower widget must fit fewer columns and wrap sooner")
    end)
  end)

  describe("SetSelected -- moving the border without relaying the grid out", function()
    it("moves the border to the new path and clears it from the old one", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } }, selected = "a" }
      picker:SetSelected("b")
      assert.is_false(picker.cells[1].elmiraBorder[1]:IsShown())
      assert.is_true(picker.cells[2].elmiraBorder[1]:IsShown())
    end)

    it("does not touch the scroll position or rebuild the cells", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } } }
      local cellBefore = picker.cells[1]
      picker.scroll:SetVerticalScroll(55)
      picker.scrollOffset = 55
      picker:SetSelected("b")
      assert.equal(cellBefore, picker.cells[1])
      assert.equal(55, picker.scroll:GetVerticalScroll())
    end)

    -- SetSelected's own border move (above) uses the PATH IT WAS GIVEN directly; this proves it
    -- also REMEMBERS that choice for the next redraw a width change triggers on its own, without
    -- a fresh SetCustomData call in between to re-supply it.
    it("remembers the selection across a width-driven relayout", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } } }
      picker:SetSelected("b")
      picker:SetWidth(700)
      assert.is_true(picker.cells[2].elmiraBorder[1]:IsShown(),
        "the selection did not survive a relayout that was not a fresh SetCustomData")
    end)
  end)

  describe("clicking a cell", function()
    it("reports the path it was drawing to onSelect", function()
      local picker = newPicker()
      local chosen
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" } },
        onSelect = function(path) chosen = path end }
      picker.cells[2]:Click()
      assert.equal("b", chosen)
    end)

    it("does nothing for a cell with nothing drawn on it", function()
      local picker = newPicker()
      local calls = 0
      picker:SetCustomData{ textures = { { path = "a" }, { path = "b" }, { path = "c" } },
        onSelect = function() calls = calls + 1 end }
      picker:SetCustomData{ textures = { { path = "a" } } }
      assert.has_no.errors(function() picker.cells[2]:Click() end)
      assert.equal(0, calls)
    end)
  end)

  describe("the tooltip", function()
    it("shows the name and the path on hover, and hides on leave", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "Interface\\a", name = "Alpha" } } }
      picker.cells[1]:GetScript("OnEnter")(picker.cells[1])
      assert.is_true(tooltip.shown)
      assert.equal(picker.cells[1], tooltip.owner, "the tooltip did not anchor to the cell it is for")
      assert.equal("ANCHOR_RIGHT", tooltip.anchor)
      assert.equal(280, tooltip.width, "a tooltip this narrow would wrap a long path awkwardly")
      assert.equal("Alpha", tooltip.text)
      assert.equal("Interface\\a", tooltip.line2)
      picker.cells[1]:GetScript("OnLeave")(picker.cells[1])
      assert.is_false(tooltip.shown)
    end)

    it("does nothing, without erroring, with no GameTooltip at all", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a", name = "Alpha" } } }
      _G.GameTooltip = nil
      assert.has_no.errors(function() picker.cells[1]:GetScript("OnEnter")(picker.cells[1]) end)
    end)

    it("is hidden on release, so a leftover callback cannot fire into a closed window", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a", name = "Alpha" } } }
      picker.cells[1]:GetScript("OnEnter")(picker.cells[1])
      assert.is_true(tooltip.shown)
      AceGUI:Release(picker)
      assert.is_false(tooltip.shown)
    end)
  end)

  -- The pooling hazard this project has shipped once already (the file's own header): nothing
  -- acquired for one window may still answer for the next addon's.
  describe("OnRelease -- nothing survives to the next Create", function()
    it("gives an empty grid back to whatever addon acquires this pooled widget next", function()
      local picker = newPicker()
      local firedAfterRelease = false
      picker:SetCustomData{ textures = { { path = "a" } }, selected = "a",
        onSelect = function() firedAfterRelease = true end }
      local cellBefore = picker.cells[1]
      AceGUI:Release(picker)
      local reacquired = newPicker()
      assert.equal(picker, reacquired, "the same pooled widget came back")
      assert.is_false(cellBefore:IsShown(), "the old cell must not still be on screen")
      cellBefore:Click()
      assert.is_false(firedAfterRelease)
    end)

    -- Read off the very table `AceGUI:Release` was just handed, before anything re-acquires it:
    -- OnRelease's own reset, not merely whatever the next OnAcquire happens to do to the same
    -- fields anyway.
    it("resets the scroll position on the released widget itself", function()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" } } }
      picker.scroll:SetVerticalScroll(400)
      picker.scrollOffset = 400
      AceGUI:Release(picker)
      assert.equal(0, picker.scrollOffset)
      assert.equal(0, picker.scroll:GetVerticalScroll())
    end)
  end)

  describe("the mouse-wheel maths", function()
    local function wheelScroll()
      local picker = newPicker()
      picker:SetCustomData{ textures = { { path = "a" } } }
      return picker
    end

    it("clamps the target to 0 when already at the top and scrolling further up", function()
      local picker = wheelScroll()
      picker.scroll:SetVerticalScroll(0)
      picker.scroll.__scrollRange = 500
      picker.scroll:GetScript("OnMouseWheel")(picker.scroll, 1)   -- a positive delta is "up"
      assert.equal(0, picker.scroll:GetVerticalScroll())
      assert.equal(0, picker.scrollOffset)
    end)

    it("clamps the target to the range's own top when scrolling past it", function()
      local picker = wheelScroll()
      picker.scroll:SetVerticalScroll(480)
      picker.scroll.__scrollRange = 500
      picker.scroll:GetScript("OnMouseWheel")(picker.scroll, -1)  -- a negative delta is "down"
      assert.equal(500, picker.scroll:GetVerticalScroll())
      assert.equal(500, picker.scrollOffset)
    end)

    it("moves by one row's worth of pixels per notch, within the range", function()
      local picker = wheelScroll()
      picker.scroll:SetVerticalScroll(100)
      picker.scroll.__scrollRange = 500
      picker.scroll:GetScript("OnMouseWheel")(picker.scroll, -1)
      assert.equal(100 + 128, picker.scroll:GetVerticalScroll()) -- CELL(120) + GAP(8)
    end)

    it("does nothing, without erroring, if the scroll frame has no parent widget to update", function()
      local picker = wheelScroll()
      local scroll = picker.scroll
      scroll:SetParent(nil)
      assert.has_no.errors(function() scroll:GetScript("OnMouseWheel")(scroll, -1) end)
    end)
  end)
end)
