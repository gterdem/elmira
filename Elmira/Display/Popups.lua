-- Elmira/Display/Popups.lua — the one place `StaticPopup_Show` is called from (D2, review
-- audit of 65896ad).
--
-- Before this file existed, "raise the dialog above the options panel, then prefill its edit box"
-- was a discipline every new `StaticPopup_Show` call site had to remember by hand -- and it shipped
-- broken FOUR times (Options/Rotation.lua's New rotation, Copy-and-edit, the confirm dialog, and
-- Setup/Wizard.lua's first-run popup, which had no `raiseAbovePanel` at all until this file). `show`
-- below is now the only function in the addon that calls `StaticPopup_Show`, so raising and
-- prefilling correctly is what calling it DOES, not something a caller can forget --
-- `tests/spec/popups_source_spec.lua` proves this from the source text, addon-wide.
--
-- Lives under `Display/` rather than `Options/` or `Setup/`, both of which use it: this is where
-- files that draw and talk to the player already live (`Announcers.lua`), `.luacheckrc` already
-- permits it the presentation globals it needs, and it loads (Elmira_Vanilla.toc) before both
-- `Setup\Wizard.lua` and `Options\Rotation.lua`, so neither has to reach forward for it.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Popups = {}

-- D61 (2026-09-07 in-game round): New rotation, Copy-and-edit and Rename were all unusable, for
-- three separate root causes, each verified rather than assumed:
--   * D61a -- always occluded, not intermittently: AceGUI's options Frame renders at
--     FULLSCREEN_DIALOG (Elmira/Libs/AceGUI-3.0/widgets/AceGUIContainer-Frame.lua:81-82/185-186/194),
--     strictly ABOVE every Blizzard StaticPopup's default DIALOG strata -- so with the options
--     window open, the popup was always drawn behind it. Fixed by `raiseAbovePanel` below.
--   * D61b -- the edit box was always empty: `StaticPopup_Show` clears the edit box AFTER `OnShow`
--     runs, so a prefill written from inside OnShow is wiped before the player ever sees it. Fixed
--     by `prefillNow` below, applied to the RETURN VALUE of `StaticPopup_Show` -- which happens
--     after that clear -- with each dialog's own `OnShow` prefill kept only as a fallback for
--     anything shown outside `show()`.
--   * D61c -- the button (and Enter) did nothing: neither dialog defined `EditBoxOnEnterPressed`
--     (Blizzard requires it for Enter to do anything at all) -- fixed at the caller, which still
--     owns its own accept handling.
--
-- D62 (review finding on D61a): raising STRATA alone was not enough. AceGUI's options Frame is
-- FULLSCREEN_DIALOG at FRAME LEVEL 100 with SetToplevel(true) (AceGUIContainer-Frame.lua:185-186,
-- 194), and SetFrameStrata never touches a frame's level -- two frames in the same strata still
-- draw by level, so StaticPopup1 at its own (low) level kept losing to level 100. Verified against
-- code that solves this exact clash on this client: ElvUI's
-- Game/Shared/General/StaticPopups.lua:409-420 ("boost static popups over ace gui") raises both,
-- mirrored here.
--
-- D63 (same review): the OnHide restore must be gated on OUR OWN raise, not fired unconditionally --
-- StaticPopup1-4 are shared with every other addon's popups, and a hook that always forces DIALOG/
-- whatever-level-we-found on hide would still fire (HookScript chains, and never unregisters) the
-- next time some OTHER addon's popup uses the same frame WITHOUT us having raised it, corrupting
-- THEIR strata/level. `elmiraRaised` is that gate, set here and cleared by the restore; the
-- double-hook guard (`elmiraStrataHooked`) is separate and unchanged -- it stops a SECOND hook from
-- stacking, not a hide handler from over-firing. ElvUI gates its own restore the same way
-- (`self.frameStrataIncreased`, StaticPopups.lua:565-573).
--
-- D67 (re-review, pass with two residuals): the level-100/level-101 THRESHOLD this
-- inherited from ElvUI is asymmetric at level 0 -- raise fires when `level < 100`, restore only
-- when `level > 100`, so a frame that started at 0 goes to 100 and STAYS there forever (probed:
-- `0 -> 100 -> 100`), permanently mutating a frame shared with every other addon. ElvUI has the
-- same flaw; citing it was evidence about frame LEVELS existing at all, never a specification to
-- copy verbatim. Fixed by storing the PRE-RAISE level (`elmiraOriginalLevel`) next to the raised
-- flag and restoring exactly that value -- correct at level 0, at level 100, and above it, with no
-- threshold anywhere in either direction. Captured only on the FIRST raise of a given showing (the
-- `not dialog.elmiraRaised` guard): a second `show` call before the popup has hidden must not
-- re-capture the ALREADY-raised level as if it were the original.
--
-- The raise itself adds 101, not ElvUI's 100: a frame starting at level 0 (the exact case D67's
-- probe used) would otherwise land at exactly 100, TIED with AceGUI's Frame rather than above it --
-- ties are not a reliable "we win" in frame stacking. +101 clears it from every starting level
-- without needing a floor/threshold check.
local function raiseAbovePanel(dialog)
  if not (dialog and dialog.SetFrameStrata and dialog.GetFrameLevel and dialog.SetFrameLevel) then
    return
  end
  if not dialog.elmiraRaised then
    dialog.elmiraOriginalLevel = dialog:GetFrameLevel()
    dialog.elmiraRaised = true
  end
  dialog:SetFrameStrata("FULLSCREEN_DIALOG")
  dialog:SetFrameLevel(dialog.elmiraOriginalLevel + 101)
  if not dialog.elmiraStrataHooked and dialog.HookScript then
    dialog.elmiraStrataHooked = true
    dialog:HookScript("OnHide", function(self)
      if not self.elmiraRaised then return end
      self.elmiraRaised = nil
      self:SetFrameStrata("DIALOG")
      self:SetFrameLevel(self.elmiraOriginalLevel)
      self.elmiraOriginalLevel = nil -- mutants: equivalent the next raise re-captures it regardless, gated on elmiraRaised alone
    end)
  end
end

-- D64 (priority fix, 2026-09-07 in-game): `dialog.editBox`/`dialog.button1` are NOT how Blizzard's
-- shared StaticPopup frames expose their children on this client -- verified live: `/run print(
-- StaticPopup1EditBox, StaticPopup1Button1, StaticPopup1.button1)` answered two real widgets and a
-- `nil`. The children are NAME-ADDRESSED GLOBALS (`StaticPopup1EditBox`, `StaticPopup1Button1`), so
-- every `.editBox`/`.button1` read anywhere in the addon was silently `nil` on the real client:
-- prefilling never actually ran, `OnAccept` read no text at all (a typed name refused as empty), and
-- `acceptOnEnter`'s `parent.button1` was `nil` (Enter did nothing). Every earlier D61-D67 spec passed
-- because the FAKE dialog in those tests attaches `.editBox`/`.button1` as convenience fields -- a
-- shape no real StaticPopup has -- so the suite asserted our own assumption back to us. Field
-- checked FIRST (so a fake, or a future client shape, that DOES carry the field keeps working) and
-- the name-addressed global second, never the reverse -- trading one assumption for the opposite
-- one would only move the bug.
local function popupChild(dialog, field, suffix)
  if not dialog then return nil end
  if dialog[field] then return dialog[field] end
  local name = dialog.GetName and dialog:GetName()
  return name and _G[name .. suffix] or nil
end

-- Exposed: `Options/Rotation.lua`'s `acceptOnEnter` and every `OnShow`/`OnAccept` handler still need
-- to reach the real edit box / accept button of whatever dialog `show` raised.
function Popups.editBox(dialog) return popupChild(dialog, "editBox", "EditBox") end
function Popups.button1(dialog) return popupChild(dialog, "button1", "Button1") end

-- D61b: writes the prefill AFTER the client's own post-OnShow clear, which is what a dialog's own
-- `OnShow` prefill (kept by callers only as a fallback for anything shown outside this helper)
-- cannot do.
local function prefillNow(dialog, text)
  local box = Popups.editBox(dialog)
  if not box then return end
  box:SetText(text or "")
  if box.HighlightText then box:HighlightText() end
end

-- PB1 (2026-09-08, owner: "the FOURTH time this bug has shipped"), widened by D2 (review
-- audit of 65896ad, "a fifth StaticPopup_Show lives at Setup/Wizard.lua with no raiseAbovePanel"):
-- every popup in the ADDON goes through this one function, so raising above the options panel is
-- not a discipline each new call site has to remember -- it is what calling `show` does. `prefill`
-- is optional (a plain confirm dialog has no edit box to prefill) and, when given, is applied AFTER
-- the return from `StaticPopup_Show` for the same reason D61b's own `prefillNow` exists. The first
-- return value reports whether a popup was AVAILABLE to try (the same guard every call site had
-- before this helper existed) -- not whether `StaticPopup_Show` itself answered a real dialog, which
-- the real client can decline to do for reasons no caller here has ever needed to distinguish. The
-- second return value is the raised dialog itself, so a caller that needs to touch it further (the
-- first-run popup retitles its own button1) still can.
function Popups.show(which, text1, text2, data, prefill)
  if not (StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs[which]) then
    return false
  end
  local dialog = StaticPopup_Show(which, text1, text2, data)
  raiseAbovePanel(dialog)
  if prefill ~= nil then prefillNow(dialog, prefill) end
  return true, dialog
end

ns.Popups = Popups
return Popups
