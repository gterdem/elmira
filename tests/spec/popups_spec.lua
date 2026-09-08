local helper = require("tests.helper")

-- Elmira/Display/Popups.lua (D2, review audit of 65896ad) — the one place
-- `StaticPopup_Show` is called from in the whole addon. `rotation_spec.lua`'s D61-D67 harness and
-- `wizard_spec.lua`'s first-run popup test already exercise this module through its two real
-- callers; this file targets the mechanism directly and in isolation -- the raise/restore pair
-- (D62/D63/D67) and the field-then-name-addressed-global fallback (D64) -- so a future change to
-- either caller cannot quietly stop covering it.
describe("Display.Popups", function()
  local Popups

  before_each(function()
    helper.reset()
    Popups = helper.load("Elmira/Display/Popups.lua")
  end)

  after_each(function()
    _G.StaticPopup_Show, _G.StaticPopupDialogs = nil, nil
    _G.StaticPopup1EditBox, _G.StaticPopup1Button1 = nil, nil
  end)

  -- A minimal real-shaped StaticPopup frame: starts at DIALOG strata and whatever level the caller
  -- gives it (Blizzard's real popups sit well under AceGUI's Frame's level 100), and HookScript
  -- never unregisters -- exactly like the client, which is the property D63's gate depends on.
  local function newFrame(startLevel)
    local frame = { level = startLevel or 0, strata = "DIALOG" }
    function frame:SetFrameStrata(s) self.strata = s end
    function frame:GetFrameStrata() return self.strata end
    function frame:SetFrameLevel(l) self.level = l end
    function frame:GetFrameLevel() return self.level end
    local hideHooks = {}
    function frame:HookScript(event, fn)
      if event == "OnHide" then hideHooks[#hideHooks + 1] = fn end
    end
    function frame:Hide()
      for _, fn in ipairs(hideHooks) do fn(self) end
    end
    return frame
  end

  describe("show()", function()
    it("answers false, and never errors, when StaticPopup_Show is not available", function()
      _G.StaticPopup_Show, _G.StaticPopupDialogs = nil, { X = {} }
      assert.is_false(Popups.show("X"))
    end)

    it("answers false when the dialog key is not registered", function()
      _G.StaticPopup_Show = function() return newFrame() end
      _G.StaticPopupDialogs = {}
      assert.is_false(Popups.show("X"))
    end)

    it("answers true and returns the raised dialog when the key is registered", function()
      local frame = newFrame()
      _G.StaticPopup_Show = function() return frame end
      _G.StaticPopupDialogs = { X = {} }
      local ok, dialog = Popups.show("X")
      assert.is_true(ok)
      assert.equal(frame, dialog)
    end)

    -- D62: strata alone is not enough -- AceGUI's options Frame sits at FULLSCREEN_DIALOG, FRAME
    -- LEVEL 100, and SetFrameStrata never touches level, so a popup at its own (low) level still
    -- loses within the same strata. +101, not ElvUI's +100, so a frame starting at level 0 does not
    -- land TIED with level 100.
    it("raises the dialog to FULLSCREEN_DIALOG, above AceGUI's options Frame", function()
      local frame = newFrame(5)
      _G.StaticPopup_Show = function() return frame end
      _G.StaticPopupDialogs = { X = {} }
      Popups.show("X")
      assert.equal("FULLSCREEN_DIALOG", frame:GetFrameStrata())
      assert.equal(106, frame:GetFrameLevel())
    end)

    -- D67: the restore must return to the PRE-RAISE level exactly, including 0 -- the asymmetric
    -- threshold this inherited from ElvUI left a frame that started at 0 stuck at 100 forever.
    it("restores the original strata and level on hide, correct even starting at level 0", function()
      local frame = newFrame(0)
      _G.StaticPopup_Show = function() return frame end
      _G.StaticPopupDialogs = { X = {} }
      Popups.show("X")
      frame:Hide()
      assert.equal("DIALOG", frame:GetFrameStrata())
      assert.equal(0, frame:GetFrameLevel())
    end)

    -- D67's own guard: a second raise before the popup has hidden must not re-capture the
    -- ALREADY-raised level as if it were the original.
    it("does not re-capture the already-raised level as the original on a second show before hide",
      function()
        local frame = newFrame(5)
        _G.StaticPopup_Show = function() return frame end
        _G.StaticPopupDialogs = { X = {} }
        Popups.show("X")
        Popups.show("X")
        frame:Hide()
        assert.equal(5, frame:GetFrameLevel(), "must restore the ORIGINAL level, not the raised one")
      end)

    it("does not stack a second OnHide hook on a second show", function()
      local frame = newFrame(5)
      local hooks = 0
      function frame:HookScript(event) if event == "OnHide" then hooks = hooks + 1 end end
      _G.StaticPopup_Show = function() return frame end
      _G.StaticPopupDialogs = { X = {} }
      Popups.show("X")
      Popups.show("X")
      assert.equal(1, hooks)
    end)

    it("does nothing, no error, on a frame with no GetFrameLevel/SetFrameLevel at all", function()
      local frame = {}
      function frame:SetFrameStrata(s) self.strata = s end
      _G.StaticPopup_Show = function() return frame end
      _G.StaticPopupDialogs = { X = {} }
      assert.has_no.errors(function() Popups.show("X") end)
      assert.is_nil(frame.strata)
    end)

    -- D63: the restore is gated on OUR OWN raise, not fired unconditionally -- StaticPopup frames
    -- are shared with every other addon, so a later hide of a showing WE never raised must leave
    -- whatever strata/level that OTHER popup set alone.
    it("does not fire the restore for a later hide this module never raised", function()
      local frame = newFrame(5)
      _G.StaticPopup_Show = function() return frame end
      _G.StaticPopupDialogs = { X = {} }
      Popups.show("X")
      frame:Hide() -- our own raise/restore cycle completes; elmiraRaised is nil again
      frame:SetFrameStrata("DIALOG")
      frame:SetFrameLevel(42) -- some OTHER addon's popup, reusing the same shared frame
      frame:Hide()
      assert.equal("DIALOG", frame:GetFrameStrata())
      assert.equal(42, frame:GetFrameLevel())
    end)

    -- D61b: `StaticPopup_Show` clears the edit box AFTER `OnShow` runs, so the prefill has to be
    -- written to the RETURNED dialog, after that clear -- writing it any earlier is wiped.
    it("prefills the edit box after the client's own post-OnShow clear", function()
      local editBox = { text = "" }
      function editBox:SetText(t) self.text = t or "" end
      function editBox:GetText() return self.text end
      function editBox:HighlightText() self.highlighted = true end
      local frame = newFrame()
      frame.editBox = editBox
      _G.StaticPopup_Show = function()
        editBox:SetText("") -- the client's own post-OnShow clear, simulated
        return frame
      end
      _G.StaticPopupDialogs = { X = {} }
      Popups.show("X", nil, nil, nil, "My rotation")
      assert.equal("My rotation", editBox:GetText())
      assert.is_true(editBox.highlighted)
    end)

    it("does not touch the edit box when no prefill is given", function()
      local editBox = { text = "kept" }
      function editBox:SetText(t) self.text = t end
      function editBox:GetText() return self.text end
      local frame = newFrame()
      frame.editBox = editBox
      _G.StaticPopup_Show = function() return frame end
      _G.StaticPopupDialogs = { X = {} }
      Popups.show("X")
      assert.equal("kept", editBox:GetText())
    end)
  end)

  -- D64: `.editBox`/`.button1` are not how the real client's shared StaticPopup frames expose their
  -- children -- they are NAME-ADDRESSED GLOBALS. Field checked first (so a fake, or a future client
  -- shape, that DOES carry the field keeps working), the name-addressed global second, never the
  -- reverse.
  describe("editBox() / button1()", function()
    it("prefers the dialog's own field when it has one", function()
      local dialog = { editBox = "field-box", button1 = "field-button" }
      assert.equal("field-box", Popups.editBox(dialog))
      assert.equal("field-button", Popups.button1(dialog))
    end)

    it("falls back to the name-addressed global the real client actually uses", function()
      local dialog = { GetName = function() return "StaticPopup1" end }
      _G.StaticPopup1EditBox, _G.StaticPopup1Button1 = "global-box", "global-button"
      assert.equal("global-box", Popups.editBox(dialog))
      assert.equal("global-button", Popups.button1(dialog))
    end)

    it("answers nil, not an error, for a nil dialog", function()
      assert.is_nil(Popups.editBox(nil))
      assert.is_nil(Popups.button1(nil))
    end)
  end)
end)
