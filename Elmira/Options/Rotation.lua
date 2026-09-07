-- Elmira/Options/Rotation.lua — the Rotation section: the addon's front door (ADR-0015 §1-2).
--
-- Three tabs. **Rotations** is where you see what you are running and pick something else:
-- the class's catalog entries as READ-ONLY templates, and your own forks beside them in their own
-- section (ADR-0010 — a fork is never merged into the catalog, which stays shipped-only).
-- **Builder** edits the active fork. **Share** is the ELM1 import/export.
--
-- Why a section and not a wizard: no rotation helper surveyed ships one, and the things a wizard
-- would have explained are the ones people ask about afterwards anyway — so they are explained in
-- the panel where they live, not in a flow you see once (ADR-0015 Context).
--
-- Everything here is plain data and closures, the way Options.lua is: a spec calls `Rotation.group()`
-- and drives a row's `get`/`set` with no AceConfig, no AceConfigDialog and no frame. The Builder's
-- custom widget, when it lands, keeps its logic in Core/ for the same reason — the widget file
-- itself cannot be loaded headlessly, so almost nothing may live in it.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Rotation = {}
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

local function pack()
  return ns.Display and ns.Display.currentPack and ns.Display.currentPack()
end

-- What is selected, and whether it is actually going. THREE states, not two: nothing selected, a
-- build selected that could not be loaded, and a build running. `Display.activeBuild` answers
-- compiled, key, reason -- and the KEY SURVIVES A COMPILE FAILURE (Display/Driver.lua:75-77 returns
-- `nil, key, "...failed to compile"`), so reading the key on its own prints "Running: Exodin" while
-- nothing is queued at all. That is the exact shape this panel exists to stop.
--
-- Not `local a, b = cond and f()` either: in Lua an `and` expression is adjusted to ONE value, so
-- every return past the first silently arrives as nil. luacheck caught that twice in this file.
local function activeState()
  if not (ns.Display and ns.Display.activeBuild) then return nil end
  local compiled, key, reason = ns.Display.activeBuild()
  return key, compiled ~= nil, reason
end

-- The selected key, broken or not: "which row is highlighted" is a question about selection.
local function activeKey()
  local key = activeState()
  return key
end

-- find() answers build, origin, fork -- and only ever through this, for the truncation reason above.
local function findBuild(p, key)
  if not (ns.UserBuilds and ns.UserBuilds.find) then return nil end
  return ns.UserBuilds.find(p, key)
end

-- READING falls back to the shipped defaults, so the panel renders correctly if it is ever built
-- before AceDB has handed over a profile.
local function profile()
  return (ns.db and ns.db.profile) or (ns.DB and ns.DB.defaults.profile) or {}
end

-- WRITING must never fall back. `DB.defaults.profile` is one shared table that every future profile
-- is copied from, so a setter reaching it would not lose the click -- it would silently change the
-- default for every character made afterwards, for the rest of the session.
local function writableProfile()
  return ns.db and ns.db.profile
end

-- ---------------------------------------------------------------- the tree (R1, ADR-0015 amendment)

-- The catalog's `updated` date for a template key. Delegated, never re-derived: Core/UserBuilds is
-- what stamps `derivedAt` from this same answer, and two copies drift into a banner that quietly
-- stops appearing.
function Rotation.templateUpdatedAt(key)
  if not (ns.UserBuilds and ns.UserBuilds.catalogUpdated) then return nil end
  return ns.UserBuilds.catalogUpdated(pack(), key)
end

-- A key a person can read. The answer itself is Core's (`UserBuilds.displayName`) -- a pure lookup
-- over the catalog and the fork records, which Display/Driver's gear-change announcement needs as
-- much as this panel does, and which nothing in Display may reach into Options to get. This is the
-- panel's shorthand for it: the pack argument, filled in.
function Rotation.displayName(key)
  if not (ns.UserBuilds and ns.UserBuilds.displayName) then
    return type(key) == "string" and key or "?"
  end
  return ns.UserBuilds.displayName(pack(), key)
end

-- The class's catalog entries, read-only, in the order the wizard already sorts them (recommended
-- first, then newest) -- ALL of them, each carrying its own `available` flag.
--
-- `Wizard.rows`, deliberately not `Wizard.choices`: choices is the filtered "pick one of these for
-- me" list, and reading it here is what made a playstyle the pack cannot yet run vanish from the
-- tree altogether. D30 shows those muted, on a page that says why -- a name that is simply absent
-- is a question the addon never gets asked, and answering it is the whole point of the page.
function Rotation.templateRows()
  if not (ns.Wizard and ns.Wizard.rows) then return {} end
  local ok, rows = pcall(ns.Wizard.rows)
  if not ok then return {} end
  local active = activeKey()
  for _, row in ipairs(rows) do row.active = (row.build == active) end
  return rows
end

-- "Your rotations" (ADR-0010). Separate section, separately labelled, never mixed into the
-- templates above.
function Rotation.forkRows()
  local p = pack()
  local out = {}
  for _, key in ipairs((ns.UserBuilds and ns.UserBuilds.list and ns.UserBuilds.list(p)) or {}) do
    local _, _, fork = findBuild(p, key)
    out[#out + 1] = {
      build = key,
      name = Rotation.displayName(key),
      derivedFrom = fork and fork.derivedFrom,
      active = (key == activeKey()),
    }
  end
  return out
end

-- The template a fork ultimately traces back to (D30's depth cap): a copy of a copy nests directly
-- under the ORIGINAL template rather than under the fork it happened to be copied from, so the tree
-- never grows more than two levels deep. Returns nil for a fork that traces to nothing (D35's "New
-- rotation") or to a cycle (a hand-edited SavedVariables file, never something the addon writes).
function Rotation.rootParent(key)
  local p = pack()
  local seen, current = {}, key
  for _ = 1, 32 do -- a bound, not a limit anyone should reach: only a cycle needs it
    if not current or seen[current] then return nil end
    seen[current] = true -- mutants: equivalent the 32-hop bound below (line 132) already answers
    -- nil for a short cycle even without this table -- bouncing the same two keys 32 times still
    -- exhausts the loop; this is only what makes THAT nil arrive after 2 hops instead of 32.
    local _, origin, fork = findBuild(p, current)
    if origin == "pack" then return current end
    if not (fork and fork.derivedFrom) then return nil end
    current = fork.derivedFrom
  end
  return nil -- mutants: equivalent the last statement of a function; Lua returns nil either way
end

-- D34. The one function that WRITES a selection: pins the build, records the catalog version this
-- character has now seen (so the once-per-version re-offer, Wizard.shouldOffer, does not immediately
-- fire again), refreshes the display, and -- unlike the old wizard's plain print -- announces the
-- switch on screen by default, because a rotation change is exactly what the "Rotation changed"
-- category exists for. Use on the rotation already running is never offered a button at all
-- (D34); this is still the function a re-click would run, and it is harmless either way.
function Rotation.use(key)
  local p = pack()
  local prof, char = writableProfile(), ns.db and ns.db.char
  if not (prof and char) then return false, "no profile" end
  -- `p` must be present before either lookup: UserBuilds.find skips its class check when handed a
  -- nil pack, so without this a class with no data pack would pin another class's fork.
  if not p then return false, "unknown build " .. tostring(key) end
  if not (ns.UserBuilds and ns.UserBuilds.find and ns.UserBuilds.find(p, key)) then
    if not (p.builds and p.builds[key]) then return false, "unknown build " .. tostring(key) end
  end
  prof.activeBuild = key
  if ns.Wizard and ns.Wizard.catalogVersion then char.setupDone = ns.Wizard.catalogVersion(p) end
  if ns.Display and ns.Display.refresh then ns.Display.refresh() end
  if ns.Announce then
    ns.Announce.emit("rotation", string.format(L["Now using %s."], Rotation.displayName(key)))
  end
  Rotation.notifyChange()
  return true, key
end

-- Customize: fork the template AND activate the fork, in one click (ADR-0015 §2). The two halves
-- must not come apart -- Hekili's copy-then-forget, where the copy has to be separately activated
-- and people carry on playing the original, is the failure this is designed against.
function Rotation.customize(templateKey)
  local p = pack()
  if not (ns.UserBuilds and ns.UserBuilds.fork) then return false, "builds module is not loaded" end
  local key, err = ns.UserBuilds.fork(p, templateKey, {
    today = ns.Adapter and ns.Adapter.today and ns.Adapter.today() or nil,
  })
  if not key then return false, err end
  -- If activation fails the fork still exists, and saying so is better than a click that appears
  -- to do nothing: the copy is on the tree either way, nested under this template.
  local ok, useErr = Rotation.use(key)
  if not ok then return false, useErr end
  return true, key
end

-- ---------------------------------------------------------------- D35: naming a new rotation

-- Is this display NAME already in use by one of this class's forks? Used only to pick a PREFILL
-- that does not collide -- what a player actually types is used verbatim either way.
local function forkNameTaken(name)
  local p = pack()
  for _, key in ipairs((ns.UserBuilds and ns.UserBuilds.list and ns.UserBuilds.list(p)) or {}) do
    local _, _, fork = findBuild(p, key)
    if fork and fork.name == name then return true end
  end
  return false -- mutants: equivalent every caller only ever tests this with `not`/in a `while`
  -- condition, where Lua's implicit nil (falling off the end) and an explicit `false` read alike
end

-- "Exodin (mine)", then "Exodin (mine 2)" the next time the same template is copied.
function Rotation.copyPrefillName(templateName)
  local base = string.format(L["%s (mine)"], templateName)
  if not forkNameTaken(base) then return base end
  local n = 2
  while forkNameTaken(string.format(L["%s (mine %d)"], templateName, n)) do n = n + 1 end
  return string.format(L["%s (mine %d)"], templateName, n)
end

function Rotation.newRotationPrefillName()
  local base = L["My rotation"]
  if not forkNameTaken(base) then return base end
  local n = 2
  while forkNameTaken(base .. " " .. n) do n = n + 1 end
  return base .. " " .. n
end

-- D35's "New rotation": creates an EMPTY fork (no `derivedFrom`, so it sits directly under
-- Rotations) and switches to it in the same click, for the same Hekili-avoidance reason `customize`
-- exists.
function Rotation.createAndUse(name)
  if type(name) ~= "string" or name:match("^%s*$") then return false, "a rotation needs a name" end
  local p = pack()
  if not (ns.UserBuilds and ns.UserBuilds.create) then return false, "builds module is not loaded" end
  local key, err = ns.UserBuilds.create(p, name)
  if not key then return false, err end
  return Rotation.use(key)
end

-- "Copy and edit", from a template's own page: the same fork-and-switch as `customize`, but with
-- the name the player typed instead of the template's own "(mine)" default.
function Rotation.copyAndUse(templateKey, name)
  if type(name) ~= "string" or name:match("^%s*$") then return false, "a rotation needs a name" end
  local p = pack()
  if not (ns.UserBuilds and ns.UserBuilds.fork) then return false, "builds module is not loaded" end
  local key, err = ns.UserBuilds.fork(p, templateKey, {
    name = name, today = ns.Adapter and ns.Adapter.today and ns.Adapter.today() or nil,
  })
  if not key then return false, err end
  return Rotation.use(key)
end

-- The key stays stable (SelectGroup/derivedFrom paths depend on it); only the display name changes.
function Rotation.rename(key, name)
  if not (ns.UserBuilds and ns.UserBuilds.rename) then return false, "builds module is not loaded" end
  local ok, err = ns.UserBuilds.rename(key, name)
  if ok then Rotation.notifyChange() end
  return ok, err
end

-- Deleting the rotation you are running leaves none in use (D35): a rotation cannot go on being
-- "active" once its own record is gone, and saying nothing would leave the display quietly running
-- a build that no longer exists in the tree.
function Rotation.remove(key)
  if not (ns.UserBuilds and ns.UserBuilds.remove) then return false end
  local wasActive = activeKey() == key
  local ok = ns.UserBuilds.remove(key)
  if not ok then return false end
  if wasActive then
    local prof = writableProfile()
    if prof then prof.activeBuild = false end
    if ns.Display and ns.Display.refresh then ns.Display.refresh() end
  end
  Rotation.notifyChange()
  return true
end

-- D44: `Rotation.use` returns `false, reason` and a click that drops it on the floor looks like a
-- dead button -- this project's characteristic failure. Every call site that changes what rotation
-- is active or how one is named funnels its failure through here rather than swallowing it.
-- `fmt` lets a caller phrase what failed (a playstyle switch, D61c's create/rename) without a
-- second copy of this function; it defaults to the original D44 wording.
local function announceFailure(err, fmt)
  if ns.Announce then
    ns.Announce.emit("warning",
      string.format(fmt or L["Elmira: could not set that playstyle (%s)."], tostring(err)))
  end
end

-- ---------------------------------------------------------------- D35: the popups themselves
--
-- One AceGUI-free mechanism for both "New rotation" and "Copy and edit": a StaticPopup with a
-- prefilled edit box, registered through the Options layer (never Core, which may not know what a
-- popup is). `data.templateKey` is what tells the shared accept handler which of the two it is.
--
-- D61 (2026-09-07 in-game round): all three of Copy-and-edit, New rotation and Rename were
-- unusable. Three separate root causes, each verified rather than assumed:
--   * D61a -- always occluded, not intermittently: AceGUI's options Frame renders at
--     FULLSCREEN_DIALOG (Elmira/Libs/AceGUI-3.0/widgets/AceGUIContainer-Frame.lua:81-82/185-186/194),
--     strictly ABOVE every Blizzard StaticPopup's default DIALOG strata -- so with the Builder open,
--     the popup was always drawn behind it. Fixed by `raiseAbovePanel` below.
--   * D61b -- the edit box was always empty: `StaticPopup_Show` clears the edit box AFTER `OnShow`
--     runs, so a prefill written from inside OnShow is wiped before the player ever sees it. Fixed
--     by `prefillNow` below, applied to the RETURN VALUE of `StaticPopup_Show` -- which happens
--     after that clear -- with `OnShow`'s own prefill kept only as a fallback.
--   * D61c -- the button (and Enter) did nothing: neither dialog defined `EditBoxOnEnterPressed`
--     (Blizzard requires it for Enter to do anything at all), and every `OnAccept` discarded its
--     handler's `ok, err` -- so an empty-name refusal caused by D61b's own bug looked exactly like a
--     dead button, and there was no way to tell the two apart from in-game alone.

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
-- `not dialog.elmiraRaised` guard): a second `open*Popup` call before the popup has hidden must not
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

-- D61b: writes the prefill AFTER the client's own post-OnShow clear, which is what `OnShow`'s own
-- prefill (kept below as a fallback for anything that does not go through this helper) cannot do.
local function prefillNow(dialog, text)
  if not (dialog and dialog.editBox) then return end
  dialog.editBox:SetText(text or "")
  if dialog.editBox.HighlightText then dialog.editBox:HighlightText() end
end

function Rotation.openNewRotationPopup()
  if not (StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs.ELMIRA_NAME_ROTATION) then
    return false
  end
  local prefill = Rotation.newRotationPrefillName()
  local dialog = StaticPopup_Show("ELMIRA_NAME_ROTATION", nil, nil, { prefill = prefill })
  raiseAbovePanel(dialog)
  prefillNow(dialog, prefill)
  return true
end

function Rotation.openCopyPopup(templateKey, templateName)
  if not (StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs.ELMIRA_NAME_ROTATION) then
    return false
  end
  local prefill = Rotation.copyPrefillName(templateName)
  local dialog = StaticPopup_Show("ELMIRA_NAME_ROTATION", nil, nil,
    { prefill = prefill, templateKey = templateKey })
  raiseAbovePanel(dialog)
  prefillNow(dialog, prefill)
  return true
end

function Rotation.openRenamePopup(key, currentName)
  if not (StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs.ELMIRA_RENAME_ROTATION) then
    return false
  end
  local dialog = StaticPopup_Show("ELMIRA_RENAME_ROTATION", currentName, nil,
    { prefill = currentName, renameKey = key })
  raiseAbovePanel(dialog)
  prefillNow(dialog, currentName)
  return true
end

-- D71 (2026-09-07 in-game round): "Maybe we can provide direct link for the source?" -- WoW cannot
-- open a URL, so the convention (same as the wizard's old rune links) is a popup showing the full
-- address in a selectable, pre-highlighted edit box the player copies out. SAME mechanism as the
-- three popups above -- one more StaticPopupDialogs entry through `registerPopups`, the same
-- `raiseAbovePanel`/`prefillNow` pair -- never a second popup layer, and never the strata-only fix
-- that left the D61 naming popups behind the options window twice before it was actually fixed.
function Rotation.openSourcePopup(url)
  if not (StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs.ELMIRA_SHOW_SOURCE) then
    return false
  end
  local text = url ~= nil and tostring(url) or ""
  local dialog = StaticPopup_Show("ELMIRA_SHOW_SOURCE", nil, nil, { prefill = text })
  raiseAbovePanel(dialog)
  prefillNow(dialog, text)
  return true
end

-- D61c: the standard Blizzard idiom (StaticPopup's edit box has no OnEnterPressed of its own) --
-- click the dialog's own accept button, so Enter and the button always agree about what happens.
local function acceptOnEnter(self)
  local parent = self:GetParent()
  if parent and parent.button1 then parent.button1:Click() end
end

-- Registered once, guarded so re-loading this file (every spec's before_each) does not stack a
-- second definition on top of the first -- harmless for StaticPopup itself, but a needless rebuild
-- of two closures on every panel open otherwise.
local function registerPopups()
  local dialogs = StaticPopupDialogs
  if not dialogs then return end

  if not dialogs.ELMIRA_NAME_ROTATION then
    dialogs.ELMIRA_NAME_ROTATION = {
      text = L["Name this rotation:"],
      button1 = L["Create and switch"], button2 = L["Cancel"],
      hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true,
      EditBoxOnEnterPressed = acceptOnEnter,
      OnShow = function(self, data)
        data = data or self.data
        local box = self.editBox
        if box then
          box:SetText((data and data.prefill) or "")
          if box.HighlightText then box:HighlightText() end
        end
      end,
      OnAccept = function(self, data)
        data = data or self.data
        local name = self.editBox and self.editBox:GetText()
        local ok, err -- mutants: equivalent deleting the declaration only makes both globals; luacheck catches it
        if data and data.templateKey then
          ok, err = Rotation.copyAndUse(data.templateKey, name)
        else
          ok, err = Rotation.createAndUse(name)
        end
        if not ok then announceFailure(err, L["Elmira: could not create that rotation (%s)."]) end
      end,
    }
  end

  if not dialogs.ELMIRA_RENAME_ROTATION then
    dialogs.ELMIRA_RENAME_ROTATION = {
      text = L["Rename \"%s\":"],
      button1 = L["Rename"], button2 = L["Cancel"],
      hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true,
      EditBoxOnEnterPressed = acceptOnEnter,
      OnShow = function(self, data)
        data = data or self.data
        local box = self.editBox
        if box then
          box:SetText((data and data.prefill) or "")
          if box.HighlightText then box:HighlightText() end
        end
      end,
      OnAccept = function(self, data)
        data = data or self.data
        if not (data and data.renameKey) then return end
        local name = self.editBox and self.editBox:GetText()
        local ok, err = Rotation.rename(data.renameKey, name)
        if not ok then announceFailure(err, L["Elmira: could not rename that rotation (%s)."]) end
      end,
    }
  end

  -- D71: nothing to accept -- this popup exists only to show the URL, pre-selected, for the player
  -- to copy. `button1` is a plain close, same as clicking the X or hitting Escape.
  if not dialogs.ELMIRA_SHOW_SOURCE then
    dialogs.ELMIRA_SHOW_SOURCE = {
      text = L["Copy this link:"],
      button1 = L["Close"],
      hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true,
      OnShow = function(self, data)
        data = data or self.data
        local box = self.editBox
        if box then
          box:SetText((data and data.prefill) or "")
          if box.HighlightText then box:HighlightText() end
        end
      end,
    }
  end
end
registerPopups()

-- ---------------------------------------------------------------- Builder tab: the palette

-- Inventory slots, named for humans. Here rather than in Core/Palette for the reason Options.lua
-- gives about Core/Visibility's modes: Core decides what a slot IS, Options decides what it is
-- called, and only this side goes through AceLocale.
local SLOT_LABELS = {
  [1] = "Head", [2] = "Neck", [3] = "Shoulder", [5] = "Chest", [6] = "Waist", [7] = "Legs",
  [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Ring 1", [12] = "Ring 2",
  [13] = "Trinket 1", [14] = "Trinket 2", [15] = "Back", [16] = "Main hand",
  [17] = "Off hand", [18] = "Ranged",
}

-- Transient, like Options.lua's exchange box: what you typed to filter is about this visit to the
-- panel, not a setting worth carrying between sessions. `paletteAllSlots` IS a setting, so it lives
-- in the profile instead.
local paletteSearch = "" -- mutants: equivalent deletion only makes it a global

function Rotation.setSearch(text)
  paletteSearch = tostring(text or "")
end

function Rotation.search() return paletteSearch end

-- The name a person reads for a pack spell key. Client-aware when the client can answer, and
-- Detect.readableName otherwise -- which is also the only one reachable headlessly, so the palette
-- is never blank in a spec or on a client that cannot resolve an id.
function Rotation.spellLabel(key)
  local p = pack()
  local data = p and p.spells and p.spells[key]
  local name = data and data.id and ns.BarGlow and ns.BarGlow.spellName
    and ns.BarGlow.spellName(data.id)
  if name then return name end
  if ns.Detect and ns.Detect.readableName then return ns.Detect.readableName(key, data) end
  return key
end

-- R2 (D55): registers every castable spell the current pack defines, `source = "pack"`, so a fresh
-- character sees a usable palette the moment a class pack loads rather than only after something
-- has already referenced one of its spells (which nothing could, the first time). Idempotent --
-- `Spells.registerPack` no-ops on a key that is already there -- so calling this on every palette
-- read costs nothing once the registry is warm.
function Rotation.syncSpells()
  if not (ns.Spells and ns.Palette) then return end
  local s = ns.Spells.store()
  local p = pack()
  if not (s and p and p.spells) then return end
  for key, data in pairs(p.spells) do
    if ns.Palette.castable(data) and type(data) == "table" and data.id then
      ns.Spells.registerPack(s, key, data.id, Rotation.spellLabel(key))
    end
  end
end

-- D58 (comment corrected at D64): the Builder's "Add a spell" control reads the REGISTRY, not
-- `Palette.spells(pack())` directly -- Palette is still what a pack-sourced entry's known/reason
-- data comes from (a rune gate on an un-learned ability must still say "engrave X"), but only for
-- spells the registry lists. `syncSpells` (above) seeds every castable pack spell unconditionally,
-- so in the common case this is EVERY pack spell plus whatever was added by hand -- not a narrower
-- list, and not gated on any rotation actually using one yet (D55). A registry entry with no
-- matching pack record (added by id, by name or from the spellbook, on a class with no pack at all)
-- is offered too, undimmed -- `known` reads nil for it, "the client cannot tell", which is the
-- right answer for something deliberately added by hand.
function Rotation.paletteSpells()
  if not ns.Spells then return {} end
  Rotation.syncSpells()
  local p = pack()
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  local packRows = (ns.Palette and ns.Palette.spells(p, {
    label = Rotation.spellLabel,
    known = state and state.known and function(key) return state:known(key) end or nil,
  })) or {}
  local byKey = {}
  for _, row in ipairs(packRows) do byKey[row.key] = row end

  local rows = {}
  for _, entry in ipairs(ns.Spells.list(ns.Spells.store())) do
    rows[#rows + 1] = byKey[entry.key] or { key = entry.key, label = entry.name, known = nil }
  end
  return Rotation.filtered(rows, function(row) return row.label end)
end

function Rotation.paletteItems()
  if not ns.Palette then return {} end
  local rows = ns.Palette.items{
    allSlots = profile().paletteAllSlots and true or false,
    -- Guard the METHOD, not just the module: a Display without itemIcon errors here, which is the
    -- same asymmetry an audit already caught once in this file.
    filled = function(slot)
      if not (ns.Display and ns.Display.itemIcon) then return false end
      return ns.Display.itemIcon(slot) ~= nil
    end,
  }
  for _, row in ipairs(rows) do row.label = L[SLOT_LABELS[row.slot] or ("Slot " .. row.slot)] end
  return Rotation.filtered(rows, function(row) return row.label end)
end

-- One filter for both lists. Case-insensitive and plain-text: a palette search box that treats
-- what you typed as a Lua pattern errors on a bracket, which is not a thing a search box may do.
function Rotation.filtered(rows, textOf)
  if paletteSearch == "" then return rows end
  local needle = paletteSearch:lower()
  local out = {}
  for _, row in ipairs(rows) do
    if tostring(textOf(row)):lower():find(needle, 1, true) then out[#out + 1] = row end
  end
  return out
end

-- Core/Palette answers WHY a row is unavailable as a token; the sentence is written here, because
-- every user-facing string on this screen goes through AceLocale and Core has no business holding
-- English (the same split Options.lua states for Core/Visibility's mode names).
function Rotation.reasonText(row)
  if row.reason == "rune" and row.reasonKey then
    return string.format(L["engrave %s"], Rotation.spellLabel(row.reasonKey))
  end
  return L["not learned yet"]
end

-- A palette row is a BUTTON while a draft is open and a plain line otherwise. A template has no
-- draft, so clicking one of these must not appear to do something: read-only is the whole point
-- (ADR-0005, hard rule 7), and the Customize banner above the list is where that click belongs.
--
-- Un-known rows are clickable too, deliberately. Runes cost 1c and a rotation you cannot yet run is
-- one you are about to be able to run (hard rule 8's authoring permission); the engine skips the
-- line until the spell is learned, which is exactly the right runtime behaviour.
local function paletteRow(order, name, append)
  if not append then
    return { type = "description", fontSize = "medium", order = order, width = "full", name = name }
  end
  return { type = "execute", order = order, width = "full", name = name,
           desc = L["Adds this to the bottom of the draft."], func = append }
end

-- D58's last row: navigation, not editing, so it stays clickable even on a read-only template's
-- Builder view -- unlike every other row here, which `paletteRow` ties to `editable`. "Focused on
-- the spellbook add row" is as far as AceConfig's tree can point: selecting the group puts the
-- reader on the page the row already lives on (D52's root page), which is the whole of what
-- "focused" can mean for a page with no sub-widget scroll target.
local function addFromSpellbookRow(order)
  return {
    type = "execute", order = order, width = "full", name = L["Add from spellbook…"],
    desc = L["Opens the Spells page, where you can register more from your spellbook, by id or by name."],
    func = function()
      if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
        ns.Options.dialog:SelectGroup("Elmira", "spells")
      end
    end,
  }
end

local function spellPaletteArgs(editable)
  local rows = Rotation.paletteSpells()
  if #rows == 0 then
    return { none = { type = "description", fontSize = "medium", order = 1, width = "full",
                      name = L["Nothing matches."] },
             add = addFromSpellbookRow(2) }
  end
  local args = {}
  for i, row in ipairs(rows) do
    local icon = ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(row.key)
    local prefix = icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
    -- Un-known rows are dimmed and carry the reason rather than being hidden: "why can I not add
    -- Divine Storm" is the question, and "engrave Divine Storm" is the answer to it. A nil `known`
    -- means the client cannot tell, which must not read as "you do not have it".
    local body -- mutants: equivalent deleting the declaration only makes it a global; luacheck catches it
    if row.known == false then
      body = string.format("|cff9AA0A6%s|r  |cff9AA0A6(%s)|r", row.label, Rotation.reasonText(row))
    else
      body = string.format("|cffFFFFFF%s|r", row.label)
    end
    local key = row.key
    args["s" .. i] = paletteRow(i, prefix .. body,
      editable and function() Rotation.appendSpell(key) end or nil)
  end
  args.add = addFromSpellbookRow(#rows + 1)
  return args
end

local function itemPaletteArgs(editable)
  local rows = Rotation.paletteItems()
  local args = {
    all = {
      type = "toggle", order = 0, width = "full", name = L["Show every equipment slot"],
      desc = L["Off lists your trinkets only, which is what nearly every rotation uses."],
      get = function() return profile().paletteAllSlots and true or false end,
      set = function(_, v)
        local p = writableProfile()
        if p then p.paletteAllSlots = v and true or false end
      end,
    },
  }
  for i, row in ipairs(rows) do
    local icon = ns.Display and ns.Display.itemIcon and ns.Display.itemIcon(row.slot)
    local prefix = icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
    -- An empty slot is still listed: a rotation may name a slot you have not filled yet, exactly as
    -- it may name a rune you have not engraved, and `item_ready` gates it at runtime either way.
    local body = row.filled
      and string.format("|cffFFFFFF%s|r", row.label)
      or string.format("|cff9AA0A6%s|r  |cff9AA0A6(%s)|r", row.label, L["empty"])
    local slot = row.slot
    args["i" .. i] = paletteRow(i, prefix .. body,
      editable and function() Rotation.appendItem(slot) end or nil)
  end
  return args
end

-- ---------------------------------------------------------------- Builder tab: the draft
--
-- The Builder edits a DRAFT and writes it on Save (owner decision, 2026-09-05). Every edit goes to
-- the draft -- the arrows and the enable toggle included, which used to write straight through --
-- so that "unsaved changes" means exactly one thing and Discard can put all of it back. It also
-- ends a smaller lie: the arrows repainted the display on every click, so the strip flickered
-- through half-finished orderings while a rotation was being rearranged.
--
-- A draft row is a deep copy of a stored line plus ONE extra field, `src`: the position it came
-- from in the SAVED rotation. That is what lets the live status column talk about the rotation
-- that is actually running while the list shows the one being written, and `src == nil` is how an
-- appended row says it is not running yet. Core/UserBuilds strips it on save (ENTRY_FIELDS), which
-- is what keeps it out of SavedVariables and out of the next export string.
local draft -- mutants: equivalent deletion only makes it a global; luacheck catches that

local function now()
  return (ns.now and ns.now()) or 0
end

local function refreshDisplay()
  if ns.Display and ns.Display.refresh then ns.Display.refresh() end
end

-- Guard the METHOD, not just the module -- the same asymmetry an audit already caught once in this
-- file over `itemIcon`. Both of these answer a legitimate runtime state anyway: no queue on screen
-- (hidden, no target, out of combat) and no compiled build (no pack for this class).
local function shownQueue()
  if not (ns.Display and ns.Display.currentQueue) then return nil end
  return ns.Display.currentQueue()
end

local function shownGates()
  if not (ns.Display and ns.Display.gateRows) then return nil, {} end
  return ns.Display.gateRows()
end

-- No nil-draft guard: every caller has already found the draft, so a check here could not fail and
-- would be a line no test can reach (tasks/lessons.md -- a guard that cannot fail is not a guard).
local function markDirty()
  draft.dirty = true
  draft.lastEditAt = now()
  -- The reasons a refused Save gave are about the rotation as it was THEN. Leaving them up after
  -- an edit reports a problem that may already be fixed.
  draft.saveErrors = nil
  return true
end

local function newDraft(key, build)
  local entries = {}
  for i, entry in ipairs(build.entries or {}) do
    local copy = ns.UserBuilds.copy(entry)
    copy.src = i
    entries[i] = copy
  end
  return { key = key, entries = entries, dirty = false, lastEditAt = 0 }
end

-- The draft for the active rotation, or nil when the active rotation is not one of the user's own.
-- A template has no draft at all rather than an un-saveable one: read-only is the whole point
-- (ADR-0005, hard rule 7), and a Save button that always refuses is worse than no Save button.
function Rotation.draft()
  local key = activeKey()
  local p = pack()
  local build, origin = findBuild(p, key)
  if origin ~= "fork" or not (build and build.entries) then
    draft = nil
    return nil
  end
  if not draft or draft.key ~= key then draft = newDraft(key, build) end
  return draft
end

-- What a line DOES, named for a person: the spell as the client calls it, or the inventory slot.
-- One copy, because the list, the queue mirror, the conditions pane and the diagnostics all have to
-- name the same line the same way -- and because the chain this replaces
-- (`entry.spell and label(...) or (entry.item and ...) or "?"`) is the collapsing idiom, three times.
local function actionName(entry)
  if entry.spell then return Rotation.spellLabel(entry.spell) end
  if entry.item then return L[SLOT_LABELS[entry.item] or ("Slot " .. entry.item)] end
  return "?"
end

-- Everything the pane and the status column need from the pack, in the shape Core/Conditions and
-- Core/Gates read it. `name` is what turns EXORCISM into "Exorcism" in a sentence.
--
-- D79 (review finding on R2b): this used to pass `p.spells` alone, un-merged with the
-- registry, so D65's stopgap below fired for every registry spell and greyed Save on a line
-- `Rotation.save()` itself would happily accept -- the one place in the whole feature a player
-- actually touches. `ns.Spells.merged(p)` is the same merge `Core/UserBuilds.ctxFor` already uses;
-- widening it here is what makes the two agree. The `ns.Spells and ... or p.spells` fallback is
-- for the handful of specs that load this file without `Core/Spells.lua`, exactly as `ctxFor`'s own
-- comment explains -- not a silent narrowing for anyone else.
local function wordCtx()
  local p = pack()
  local spells = (p and ns.Spells and ns.Spells.merged and ns.Spells.merged(p)) or (p and p.spells)
  return { L = L, name = Rotation.spellLabel,
           spells = spells, sets = p and p.sets,
           souls = p and p.souls, bonuses = p and p.bonuses }
end

function Rotation.discard()
  draft = nil
  return true
end

-- The lines the Builder is SHOWING, as build entries: the draft's while one is open, the stored
-- rotation's otherwise. The diagnostics read these too, so a warning appears the moment an edit
-- creates it rather than only after Save.
local function builderEntries()
  local d = Rotation.draft()
  if d then return d.entries end
  local build = findBuild(pack(), activeKey())
  return build and build.entries
end

-- Every problem that would stop this draft being saved, as lines a person can read.
--
-- `Schema.compileWhen` reports a condition the compiler cannot read; it never returns nil, so
-- `#errors == 0` is the check. The reasons from the last REFUSED save are appended because they
-- come from `Schema.validate` over the whole build and catch what a per-condition compile cannot --
-- a line naming a spell the pack does not carry, or a rotation with no lines at all.
function Rotation.problems()
  local lines = {}
  if not draft then return lines end
  local ctx = wordCtx()
  for i, entry in ipairs(draft.entries) do
    local _, errors = ns.Schema.compileWhen(entry.when, ctx)
    for _, err in ipairs(errors) do
      lines[#lines + 1] = string.format(L["line %d: %s"], i, err.message)
    end
    -- D65 STOPGAP (review finding on R2): a spell the Spells registry added by id, by name or
    -- from the spellbook can be offered here and appended (D58) with no matching pack record, and
    -- until now nothing said so until the click -- Save looked enabled, then `Schema.validate`
    -- refused it with exactly this message, after the fact. Mirrors that one check (Schema.lua's
    -- `ctx.spells[entry.spell] == nil`) so Save greys out with the reason visible FIRST. This does
    -- NOT close the R2 architecture gap -- the registry still cannot feed the engine a key it did
    -- not get from a data pack -- only the owner can decide to widen the engine to accept one
    -- (R2b/R3); this just stops the click from being the first place the player hears about it.
    if entry.spell and ctx.spells and ctx.spells[entry.spell] == nil then
      lines[#lines + 1] = string.format(L["line %d: spell '%s' is not in the spells data pack"],
                                         i, entry.spell)
    end
  end
  for _, line in ipairs(draft.saveErrors or {}) do lines[#lines + 1] = line end
  return lines
end

-- Rotation.save() -> true | false, reasons
function Rotation.save()
  local d = Rotation.draft()
  if not d then return false, { L["This rotation is not one of your own."] } end
  -- No pre-check against `problems()`: `replaceEntries` validates the WHOLE candidate build through
  -- the same compiler and refuses atomically, so a second gate here would be a line no test could
  -- make fail. `problems()` is what greys the Save button and lists the reasons under it.
  local ok, reasons = ns.UserBuilds.replaceEntries(pack(), d.key, d.entries)
  if not ok then
    d.saveErrors = reasons
    return false, reasons
  end
  -- Rebuilt rather than merely marked clean: `src` has to be re-stamped from the positions that
  -- were actually stored, or the status column would go on describing where the lines used to be.
  -- The selection survives, because the saved order IS the draft order.
  local selected = d.selected
  draft = nil
  local fresh = Rotation.draft()
  if fresh then fresh.selected = selected end
  refreshDisplay()
  return true
end

-- The three list edits. All of them touch the draft and none of them repaints: the display is still
-- running the SAVED rotation, and repainting here would show a queue built from an order the player
-- has not committed to.
function Rotation.moveRow(index, delta)
  local d = Rotation.draft()
  if not d then return false end
  local to = (tonumber(index) or 0) + (tonumber(delta) or 0)
  local entries = d.entries
  if not (entries[index] and entries[to]) then return false end
  entries[index], entries[to] = entries[to], entries[index]
  -- The selection follows the line it is on, not the position: moving the row you are editing must
  -- not silently switch the conditions pane to a different ability.
  if d.selected == index then d.selected = to
  elseif d.selected == to then d.selected = index end
  return markDirty()
end

function Rotation.setRowDisabled(index, disabled)
  local d = Rotation.draft()
  if not (d and d.entries[index]) then return false end
  -- nil rather than false, exactly as Core/UserBuilds stores it: `Schema.compile` and
  -- `Schema.exportable` both test truthiness, and `disabled = false` on every line is noise that
  -- would travel to whoever imports the build.
  d.entries[index].disabled = disabled and true or nil
  return markDirty()
end

function Rotation.removeRow(index)
  local d = Rotation.draft()
  if not (d and d.entries[index]) then return false end
  table.remove(d.entries, index)
  if d.selected == index then d.selected = nil
  elseif d.selected and d.selected > index then d.selected = d.selected - 1 end
  return markDirty()
end

function Rotation.selectRow(index)
  local d = Rotation.draft()
  if not (d and d.entries[index]) then return false end
  d.selected = index
  return true
end

-- Appending from the palette. The new line arrives with NO conditions, which means "always" -- so
-- it is put at the BOTTOM, where an unconditional line is harmless, rather than at the top where it
-- would take over the whole rotation the moment it was saved. It is selected on arrival, because
-- the next thing anyone wants is its conditions.
local function append(entry)
  local d = Rotation.draft()
  if not d then return false end
  d.entries[#d.entries + 1] = entry
  d.selected = #d.entries
  return markDirty()
end

function Rotation.appendSpell(key)
  if type(key) ~= "string" then return false end
  return append{ spell = key }
end

function Rotation.appendItem(slot)
  if type(slot) ~= "number" then return false end
  return append{ item = slot }
end

-- ---------------------------------------------------------------- Builder tab: the conditions pane

-- The selected line's conditions as typed rows, or nil when nothing editable is selected.
-- `model.complex` means the stored shape is deeper than one all/any level; the pane then shows it
-- in words and offers no controls (owner decision, 2026-09-05 -- editing nested rows is v1.1).
function Rotation.paneModel()
  local d = draft
  local entry = d and d.selected and d.entries[d.selected]
  if not entry then return nil end
  return ns.Conditions.toRows(entry.when), entry
end

-- Writes typed rows back onto the selected line. The only writer: every setter below goes through
-- it, so there is one place where a `when` list is built and one place that marks the draft dirty.
local function writePane(model, entry)
  entry.when = ns.Conditions.fromRows(model.match, model.rows)
  return markDirty()
end

function Rotation.setMatch(match)
  local model, entry = Rotation.paneModel()
  if not model or model.complex then return false end
  model.match = (match == "any") and "any" or "all"
  return writePane(model, entry)
end

-- A row built for a field the player has just chosen: the field's default operator, and the first
-- value the pack offers, so a freshly added condition is a legal one rather than a blank that
-- reports an error before it has been touched.
local function defaultRow(kind, negated)
  local row = ns.Conditions.blankRow(kind)
  if not row then return nil end
  local field = ns.Conditions.field(kind)
  if field.keySource then row.key = (ns.Conditions.keys(kind, pack()) or {})[1] end
  if field.slotAt then row.slot = ns.Palette.TRINKET_SLOTS[1] end
  row.negated = negated and true or nil
  return row
end

function Rotation.addCondition(kind)
  local model, entry = Rotation.paneModel()
  if not model or model.complex then return false end
  local row = defaultRow(kind or "in_combat")
  if not row then return false end
  model.rows[#model.rows + 1] = row
  return writePane(model, entry)
end

function Rotation.removeCondition(at)
  local model, entry = Rotation.paneModel()
  if not model or model.complex or not model.rows[at] then return false end
  table.remove(model.rows, at)
  return writePane(model, entry)
end

-- One setter for the whole pane rather than six near-identical ones. `kind` and `category` REPLACE
-- the row instead of editing it: an operator or a key carried over from the previous field is a
-- qualifier the new field does not have, and `Conditions.fromRows` would write a condition the
-- compiler rejects while the dropdowns still looked right.
local FIELDS_SET_DIRECTLY = { key = true, slot = true, op = true, value = true, negated = true }

function Rotation.setCondition(at, field, value)
  local model, entry = Rotation.paneModel()
  if not model or model.complex then return false end
  local row = model.rows[at]
  if not row then return false end

  if field == "category" then
    for _, cat in ipairs(ns.Conditions.CATEGORIES) do
      if cat.id == value then
        model.rows[at] = defaultRow(cat.fields[1], row.negated)
        return writePane(model, entry)
      end
    end
    return false
  elseif field == "kind" then
    local fresh = defaultRow(value, row.negated)
    if not fresh then return false end
    model.rows[at] = fresh
  elseif FIELDS_SET_DIRECTLY[field] then
    row[field] = value
  else
    return false
  end
  return writePane(model, entry)
end

-- ---------------------------------------------------------------- Builder tab: F36 diagnostics

-- What is wrong with this rotation that the compiler will not tell you (F36, ADR-0015 §2 "F36
-- diagnostics render at the foot of the Builder").
--
-- WARNINGS, never errors: none of these stops a Save, and none of them is about right now. They are
-- the two questions an editor cannot answer by looking -- "can this line ever fire?" and "does this
-- line still name something that exists?" -- and Core/Diagnostics answers both from the build
-- alone, so neither can be wrong about a situation nobody thought to check.
--
-- Read from the DRAFT while one is open, so a warning appears the moment an edit creates it rather
-- than after Save; a template has no draft and is diagnosed as it ships, which is a real question
-- about a template too.
function Rotation.diagnosticLines()
  local entries = builderEntries()
  if not entries then return {} end
  local build = { entries = entries }
  local lines = {}

  for _, row in ipairs(ns.Diagnostics.shadowed(build)) do
    local name = actionName(entries[row.index])
    if row.alwaysOn then
      lines[#lines + 1] = string.format(
        L["Line %d (%s) can never fire: line %d does the same thing and nothing gates it."],
        row.index, name, row.by)
    else
      lines[#lines + 1] = string.format(
        L["Line %d (%s) can never fire: line %d does the same thing whenever this line could."],
        row.index, name, row.by)
    end
  end

  for _, row in ipairs(ns.Diagnostics.unknown(build, wordCtx())) do
    lines[#lines + 1] = string.format(
      L["Line %d names %s, which your class data no longer has."], row.index, tostring(row.key))
  end
  return lines
end

-- ---------------------------------------------------------------- Rotations tab: F35 parent diff

-- How your rotation differs from the template it came from, row by row (F35, ADR-0010).
--
-- Said only once the template has actually moved on, which is the moment ADR-0010 asks for a diff
-- and never a rebase: the user's edits win, so the addon's whole job here is to let them READ what
-- is different and decide.
--
-- The wording is careful about a claim it cannot make. This compares your rotation with the
-- template AS IT IS NOW -- not "what changed since you forked", because a fork records which
-- VERSION it came from (`derivedAt`) and never its contents, so that question has no answer here.
function Rotation.parentDiffLines()
  local p = pack()
  local key = activeKey()
  local build, origin, fork = findBuild(p, key)
  if origin ~= "fork" or not (build and fork and fork.derivedFrom) then return {} end
  local parent = p and p.builds and p.builds[fork.derivedFrom]
  if not parent then return {} end

  local diff = ns.Diagnostics.compare(build, parent)

  local function names(rows)
    local parts = {}
    for _, row in ipairs(rows) do
      local name = actionName(row)
      if row.label then name = string.format("%s (%s)", name, row.label) end
      parts[#parts + 1] = name
    end
    return table.concat(parts, ", ")
  end

  local lines = {}
  if #diff.onlyTheirs > 0 then
    lines[#lines + 1] = string.format(L["The template has lines yours does not: %s."],
                                      names(diff.onlyTheirs))
  end
  if #diff.onlyMine > 0 then
    lines[#lines + 1] = string.format(L["Yours has lines the template does not: %s."],
                                      names(diff.onlyMine))
  end
  if #diff.changed > 0 then
    lines[#lines + 1] = string.format(L["Different conditions on: %s."], names(diff.changed))
  end
  if #diff.moved > 0 then
    lines[#lines + 1] = string.format(L["In a different order: %s."], names(diff.moved))
  end
  return lines
end

-- ---------------------------------------------------------------- Builder tab: live status
--
-- ADR-0015 (2026-09-04 amendment), colours reassigned 2026-09-07 (D73, owner ruling on the in-game
-- round -- this closes the question R1 deliberately left open, reversing the meaning below rather
-- than amending it): GREY now means "cannot happen on this character" (nothing you do right now
-- changes it -- switched off, or gated until you engrave/equip something) and AMBER means "waiting
-- on a condition" (it CAN fire, just not this instant -- on cooldown, target too high, etc). Only
-- the grey states are meant to sit still; amber is expected to come and go as conditions change, so
-- rows flickering between firing and amber mid-fight is the rotation working, not a bug.
--
-- Texture dots, not glyphs. The client's font draws U+25CF and friends as identical empty boxes,
-- which is how a status column once shipped as a row of squares (tasks/lessons.md, 2026-09-04) --
-- ASCII markers (`>>` `!!` `..` `--` `++`) were the fallback while that could not be verified from
-- a client. It has been, since: `Interface\COMMON\Indicator-Green/-Yellow/-Gray/-Red` are all
-- referenced by Details on this exact Classic Era install (Details/functions/coach.lua,
-- Details/frames/window_custom.lua, Details/Libs/DF/panel.lua), and this very list already embeds
-- `|T...|t` spell-icon textures three lines below (tasks/lessons.md, 2026-09-07 -- the constraint
-- was on CHARACTERS the font draws, not on textures, which render where a glyph does not). `colour`
-- now wraps the TEXT after the dot rather than the dot itself: a texture escape carries its own
-- colour and needs no `|cff.../|r` wrapper.
Rotation.MARKS = {
  firing   = { mark = "|TInterface\\COMMON\\Indicator-Green:12|t",  colour = "|cff40c057" },
  blocked  = { mark = "|TInterface\\COMMON\\Indicator-Gray:12|t",   colour = "|cff9AA0A6" },
  waiting  = { mark = "|TInterface\\COMMON\\Indicator-Yellow:12|t", colour = "|cffE8A33D" },
  off      = { mark = "|TInterface\\COMMON\\Indicator-Gray:12|t",   colour = "|cff9AA0A6" },
  unsaved  = { mark = "|TInterface\\COMMON\\Indicator-Gray:12|t",   colour = "|cff9AA0A6" },
}

-- Why a line that CAN fire for this character is not firing. The compiled per-condition tests are
-- the authority -- Schema builds one per top-level condition precisely so a rejection can be
-- explained -- and the spell itself is the answer when every condition passes.
--
-- "waiting for:" is not decoration. `Conditions.describe` writes a condition in the voice of it
-- being MET ("Vengeance is up", "mana at least 40%"), because that is the voice the equipment
-- announcement needs -- so printing one bare here would tell the player the opposite of what is
-- happening. One phrase in two voices makes one of them a lie (tasks/lessons.md, 2026-09-04).
local function waitingReason(entry, state, ctx, hasQueue)
  local nothingOnScreen = not hasQueue and L["the queue is hidden right now"] or nil
  if not (entry and state) then return nothingOnScreen or L["waiting its turn"] end
  for ci = 1, #(entry.conditions or {}) do
    local ok, passed = pcall(entry.conditions[ci].test, state, 0)
    if ok and not passed then
      return string.format(L["waiting for: %s"],
                           ns.Conditions.describe(entry.when and entry.when[ci], ctx))
    end
  end
  if entry.spell then
    local ok, remaining = pcall(state.cooldown, state, entry.spell)
    if ok and type(remaining) == "number" and remaining > 0 then
      return string.format(L["on cooldown (%.1f s)"], remaining)
    end
    local readable, usable = pcall(state.usable, state, entry.spell)
    if readable and usable == false then return L["not usable right now"] end
  end
  -- Every condition passes and the spell is ready, so the only remaining explanation is the queue
  -- itself -- and when there is no queue at all, saying "a line above it is firing" would be a
  -- claim about a display that is not on screen.
  return nothingOnScreen or L["a line above it is firing"]
end

-- Rotation.rowStatuses() -> one status per row of the list, in list order.
--
-- Computed against the SAVED rotation through each row's `src`, because that is the one that is
-- running. A row is mapped to its compiled entry through `compiled.entries[i].index`, never by
-- ordinal: `Schema.compile` drops disabled entries, so one switched-off line above would put every
-- status below it one row out.
function Rotation.rowStatuses()
  local out = {}
  local rows = Rotation.listRows()
  local compiled, gates = shownGates()
  local queue = shownQueue()
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  local ctx = wordCtx()

  local compiledAt, slotAt = {}, {}
  for i, entry in ipairs((compiled and compiled.entries) or {}) do compiledAt[entry.index] = i end
  for slot, shown in ipairs(queue or {}) do
    local index = shown.entry and shown.entry.index
    -- The first slot wins: one line can legitimately appear twice in a five-deep queue, and
    -- "firing now, slot 4" for a line that is also slot 1 is the less useful of the two answers.
    if index and not slotAt[index] then slotAt[index] = slot end
  end

  for i, row in ipairs(rows) do
    local src = row.src
    local at = src and compiledAt[src]
    if not src then
      out[i] = { state = "unsaved", text = L["not saved yet"] }
    elseif not compiled then
      -- No compiled build at all -- no pack for this class, or a build that failed to compile.
      -- Answering "off" here (which is what a missing compiled entry means when there IS a build)
      -- would tell the player their line is switched off when nothing of the sort has happened.
      out[i] = { state = "waiting", text = waitingReason(nil, state, ctx, queue ~= nil) }
    elseif not at then
      -- No compiled entry at all: the SAVED line is switched off, whatever the draft's toggle says.
      out[i] = { state = "off", text = L["switched off in the saved rotation"] }
    elseif slotAt[src] then
      out[i] = { state = "firing", text = string.format(L["firing now (slot %d)"], slotAt[src]) }
    elseif gates[at] and gates[at].active == false then
      out[i] = { state = "blocked",
                 text = string.format(L["not active for you: %s"],
                                      table.concat(gates[at].reasons, ", ")) }
    else
      out[i] = { state = "waiting",
                 text = waitingReason(compiled.entries[at], state, ctx, queue ~= nil) }
    end
  end
  return out
end

-- ---------------------------------------------------------------- Builder tab: the queue mirror

-- What the display is showing right now, said in the panel. ADR-0015's amendment asks for the strip
-- to be mirrored at the top of the Builder so the list and the queue are seen together; this is the
-- text half of that, which is all an AceConfig description can be.
--
-- A hidden queue is a real answer, not a missing one. "The queue is hidden right now" plus the
-- reason is what stops an empty panel reading as a broken addon.
function Rotation.mirrorLines()
  local lines = {}
  local queue = shownQueue()
  if not queue or #queue == 0 then
    lines[#lines + 1] = L["The queue is hidden right now (no target, out of combat)."]
  else
    local parts = {}
    for i, shown in ipairs(queue) do
      local icon = shown.spell and ns.Display.spellIcon and ns.Display.spellIcon(shown.spell)
      parts[#parts + 1] = string.format("%s%d. %s",
        icon and ("|T" .. tostring(icon) .. ":0|t ") or "", i, actionName(shown))
    end
    lines[#lines + 1] = table.concat(parts, "   ")
  end

  local context = Rotation.contextLine()
  if context then lines[#lines + 1] = context end
  lines[#lines + 1] = string.format(L["%s firing now   %s not active for you   %s waiting   %s off   %s unsaved"],
    Rotation.MARKS.firing.mark, Rotation.MARKS.blocked.mark, Rotation.MARKS.waiting.mark,
    Rotation.MARKS.off.mark, Rotation.MARKS.unsaved.mark)
  lines[#lines + 1] = L["Status is as of the last time the queue changed."]
  return lines
end

-- The handful of state readings that explain why the queue looks the way it does. Every one is
-- pcall'd: the panel asking a question the adapter cannot answer must never be the thing that
-- errors, and a client with no target answers nil for three of the four.
function Rotation.contextLine()
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  if not state then return nil end
  -- No type check on `fn`: `pcall` already answers false for a nil accessor, so a separate guard
  -- would be a line that cannot fail. An adapter that does not implement a reading and one that
  -- throws on it are the same answer here -- leave that part of the line out.
  local function ask(fn, ...)
    local ok, value = pcall(fn, state, ...)
    if ok then return value end
  end

  local parts = {}
  local hasTarget = ask(state.targetExists) == true
  parts[#parts + 1] = hasTarget and L["target: yes"] or L["target: no"]
  -- Branched rather than `hasTarget and ask(...) or nil`: the reading is a number that can be 0,
  -- and while 0 is truthy in Lua today, this is the idiom that has silently turned a real value
  -- into "not asked" four times in this repo. Asking only when there IS a target is the point.
  local hp
  if hasTarget then hp = ask(state.targetHPPct) end
  if type(hp) == "number" then parts[#parts + 1] = string.format(L["target HP %d%%"], hp) end
  local enemies = ask(state.enemies)
  if type(enemies) == "number" then parts[#parts + 1] = string.format(L["enemies %d"], enemies) end
  -- Not through `ask`: `power` answers current AND maximum, and a helper that returns one value
  -- truncates the pair to the first -- so the cap would always arrive nil and the mana reading
  -- would never be printed. luacheck has caught this exact truncation twice in this file.
  local readable, mana, cap = pcall(state.power, state, "MANA")
  if readable and type(mana) == "number" and type(cap) == "number" and cap > 0 then
    parts[#parts + 1] = string.format(L["mana %d%%"], math.floor(mana / cap * 100 + 0.5))
  end
  return table.concat(parts, "   ")
end

-- ---------------------------------------------------------------- Builder tab: live refresh

-- Registered with Display as the renderer "builder" (Core/Init.lua). Renderers fire only when the
-- QUEUE CHANGES, which is exactly the moment the status column stops being true -- so there is no
-- timer here, and the panel says so in as many words ("as of the last time the queue changed").
--
-- Three guards, because `AceConfigRegistry:NotifyChange` rebuilds the entire options table:
--   * `isIdle` -- the Builder is on screen, is the visible tab, and nobody is typing into it.
--   * 2 s since the last rebuild -- in combat the queue changes several times a second, and
--     rebuilding the panel at that rate is both expensive and unreadable.
--   * 3 s since the last EDIT -- the panel already rebuilds on every `set`, so refreshing on top of
--     someone who is still working is pure interference.
Rotation.NOTIFY_INTERVAL = 2
Rotation.EDIT_QUIET = 3

local lastNotify = 0 -- mutants: equivalent deletion only makes it a global; luacheck catches that

-- Replaceable, so a spec can drive onQueueChanged without AceConfigDialog, and so the predicate
-- lives where it can see the panel rather than being re-derived here.
function Rotation.isIdle()
  if not (ns.Options and ns.Options.builderIdle) then return false end
  return ns.Options.builderIdle() == true
end

function Rotation.notifyChange()
  local registry = LibStub and LibStub("AceConfigRegistry-3.0", true)
  if not registry then return false end
  registry:NotifyChange("Elmira")
  return true
end

function Rotation.onQueueChanged()
  if not Rotation.isIdle() then return false end
  local at = now()
  if at - lastNotify < Rotation.NOTIFY_INTERVAL then return false end
  if draft and (at - (draft.lastEditAt or 0)) < Rotation.EDIT_QUIET then return false end
  lastNotify = at
  return Rotation.notifyChange()
end

-- ---------------------------------------------------------------- Builder tab: the rotation list

-- The rows of the rotation you are editing, in priority order -- which IS the rotation: the first
-- entry that passes is the suggestion (F1), so the order is the thing being edited, not decoration.
--
-- Reads the DRAFT when there is one, and the stored build otherwise. A template is read-only
-- (ADR-0005, hard rule 7), so its rows render without controls and with the Customize banner.
-- `src` is the position the row holds in the SAVED rotation, or nil for a row that has been added
-- and not yet saved -- it is what the status column is computed through.
function Rotation.listRows()
  -- `activeKey()` and `draft.key` are the same key by construction: the draft is created for the
  -- active rotation and dropped the moment that changes.
  local d = Rotation.draft()
  local key = activeKey()
  local entries = builderEntries()
  if not entries then return {}, key, false end

  local rows = {}
  for i, entry in ipairs(entries) do
    -- Branched, never `d and entry.src or i`: an APPENDED draft row has no `src`, and that idiom
    -- would fall through to `i` and claim it is saved line i -- the status column would then point
    -- at whatever line happens to sit there. The one shape of that idiom that silently never works
    -- (tasks/lessons.md).
    local src = i
    if d then src = entry.src end
    rows[#rows + 1] = {
      index = i,
      src = src,
      spell = entry.spell,
      item = entry.item,
      label = actionName(entry),
      note = entry.label,
      summary = Rotation.conditionSummary(entry),
      disabled = entry.disabled and true or false,
      first = i == 1,
      last = i == #entries,
    }
  end
  return rows, key, d ~= nil
end

-- One line saying what an entry waits for, in words. Delegated to Core/Conditions so the pane, the
-- list and the status hover all phrase a condition the same way -- the count this used to return
-- ("2 conditions") said the same thing about every row that had two, which distinguished nothing.
function Rotation.conditionSummary(entry)
  return ns.Conditions.summary(entry and entry.when, wordCtx())
end

-- No nil-status guard: `rowStatuses` answers exactly one entry per row of `listRows`, and listArgs
-- walks that same list -- so a check here could not fail.
local function statusArgsFor(row, status)
  local look = Rotation.MARKS[status.state] or Rotation.MARKS.waiting
  -- The row's own line shows the author's NOTE when it has one and the condition summary
  -- otherwise, so the summary belongs here only in the first case -- printing it in both would
  -- repeat it on every unlabelled row. Branched, not `row.note and row.summary or ""`: that idiom
  -- has silently produced the wrong value four times in this repo.
  local trailer = ""
  if row.note then trailer = row.summary end
  return {
    type = "description", fontSize = "medium", order = 9, width = "full",
    name = string.format("%s %s%s|r  |cff9AA0A6%s|r", look.mark, look.colour, status.text, trailer),
  }
end

local function listArgs()
  local rows, _, editable = Rotation.listRows()
  if #rows == 0 then
    return { none = { type = "description", fontSize = "medium", order = 1, width = "full",
                      name = L["This rotation has no lines yet."] } }
  end

  local statuses = Rotation.rowStatuses()
  local selected = draft and draft.selected
  local args = {}
  for _, row in ipairs(rows) do
    local i = row.index
    local group = { type = "group", inline = true, order = i, name = "", args = {} }
    local icon = row.spell and ns.Display and ns.Display.spellIcon
      and ns.Display.spellIcon(row.spell)
    local prefix = icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
    local colour = row.disabled and "|cff9AA0A6" or "|cffFFFFFF"
    local pointer = (selected == i) and "|cffC08CF0>|r " or ""

    group.args.what = {
      type = "description", fontSize = "medium", order = 1, width = 1.0,
      name = string.format("%s%s%s%s|r  |cff9AA0A6%s|r", pointer, prefix, colour, row.label,
                           row.note or row.summary),
    }
    -- Edit, enable, arrows, remove: only on a fork. On a template they are absent rather than
    -- present-and-dead, because a control that silently does nothing is worse than one not offered.
    if editable then
      group.args.edit = {
        type = "execute", order = 2, width = 0.4, name = L["Edit"],
        desc = L["Show this line's conditions below."],
        func = function() Rotation.selectRow(i) end,
      }
      group.args.on = {
        type = "toggle", order = 3, width = 0.45, name = L["On"],
        get = function() return not row.disabled end,
        set = function(_, v) Rotation.setRowDisabled(i, not v) end,
      }
      group.args.up = {
        type = "execute", order = 4, width = 0.3, name = L["Up"], disabled = row.first,
        func = function() Rotation.moveRow(i, -1) end,
      }
      group.args.down = {
        type = "execute", order = 5, width = 0.3, name = L["Down"], disabled = row.last,
        func = function() Rotation.moveRow(i, 1) end,
      }
      -- The counterpart to click-to-append. Without it a mis-clicked palette icon can only be
      -- undone by discarding every other edit in the draft.
      group.args.remove = {
        type = "execute", order = 6, width = 0.5, name = L["Remove"],
        desc = L["Takes this line out of the draft. Discard puts it back."],
        func = function() Rotation.removeRow(i) end,
      }
    end
    group.args.status = statusArgsFor(row, statuses[i])
    args["r" .. i] = group
  end
  return args
end

-- ---------------------------------------------------------------- Builder tab: pane args

local function keyChoices(kind)
  local choices = {}
  local field = ns.Conditions.field(kind)
  local source = field and field.keySource
  for _, key in ipairs(ns.Conditions.keys(kind, pack()) or {}) do
    -- Only the spell-shaped sources get a client name; a mode, a creature type or a power kind IS
    -- its own label, and running "AoE" through the spell lookup would answer "AoE" the long way.
    if source == "spells" or source == "seals" or source == "runes" or source == "castables" then
      choices[key] = Rotation.spellLabel(key)
    else
      choices[key] = key
    end
  end
  return choices
end

local function conditionArgs(model)
  local args = {}
  for at, row in ipairs(model.rows) do
    local field = ns.Conditions.field(row.kind)
    if field then
      local op = ns.Conditions.op(field, row.op) or field.ops[1]
      local group = { type = "group", inline = true, order = at,
                      name = ns.Conditions.describe(
                        ns.Conditions.fromRows("all", { row })[1], wordCtx()), args = {} }

      local categories, fields = {}, {}
      for _, cat in ipairs(ns.Conditions.CATEGORIES) do categories[cat.id] = L[cat.label] end
      local catId = ns.Conditions.categoryOf(row.kind)
      for _, cat in ipairs(ns.Conditions.CATEGORIES) do
        if cat.id == catId then
          for _, kind in ipairs(cat.fields) do fields[kind] = L[ns.Conditions.field(kind).label] end
        end
      end

      group.args.category = {
        type = "select", order = 1, width = 0.8, name = L["Category"], values = categories,
        get = function() return catId end,
        set = function(_, v) Rotation.setCondition(at, "category", v) end,
      }
      group.args.field = {
        type = "select", order = 2, width = 1.0, name = L["Field"], values = fields,
        get = function() return row.kind end,
        set = function(_, v) Rotation.setCondition(at, "kind", v) end,
      }
      group.args.negated = {
        type = "toggle", order = 3, width = 0.5, name = L["not"],
        desc = L["Passes when this condition does NOT hold."],
        get = function() return row.negated == true end,
        set = function(_, v) Rotation.setCondition(at, "negated", v and true or nil) end,
      }
      group.args.remove = {
        type = "execute", order = 4, width = 0.5, name = L["Remove"],
        func = function() Rotation.removeCondition(at) end,
      }
      if #field.ops > 1 then
        local ops = {}
        for _, one in ipairs(field.ops) do ops[one.id] = L[one.label] end
        group.args.op = {
          type = "select", order = 5, width = 1.0, name = L["Test"], values = ops,
          get = function() return op.id end,
          set = function(_, v) Rotation.setCondition(at, "op", v) end,
        }
      end
      if field.slotAt then
        local slots = {}
        for _, slot in ipairs(ns.Palette.EQUIPMENT_SLOTS) do
          -- AceConfig select keys must be strings; a numeric slot comes back from the widget as
          -- one and would never compare equal to the number the row holds.
          slots[tostring(slot)] = L[SLOT_LABELS[slot] or ("Slot " .. slot)]
        end
        group.args.slot = {
          type = "select", order = 6, width = 0.9, name = L["Slot"], values = slots,
          get = function() return tostring(row.slot or "") end,
          set = function(_, v) Rotation.setCondition(at, "slot", tonumber(v)) end,
        }
      end
      if field.keySource then
        group.args.key = {
          type = "select", order = 7, width = 1.1, name = L["Value"], values = keyChoices(row.kind),
          get = function() return row.key end,
          set = function(_, v) Rotation.setCondition(at, "key", v) end,
        }
      end
      if op.arg == "number" then
        group.args.amount = {
          type = "input", order = 8, width = 0.6, name = L[op.unit or "Amount"],
          get = function() return tostring(row.value or "") end,
          set = function(_, v) Rotation.setCondition(at, "value", tonumber(v) or 0) end,
        }
      end
      args["c" .. at] = group
    end
  end
  return args
end

local function paneArgs()
  local model, entry = Rotation.paneModel()
  if not model then return nil end
  local name = actionName(entry)

  local args = {}
  if model.complex then
    -- Nested conditions are shown, never edited (owner decision, 2026-09-05; editing them is v1.1).
    -- Read-only is not the same as hidden: the "why" of a line is its conditions, and a template's
    -- cleverest rows are exactly the ones that nest.
    local whole = { "all" }
    for i, cond in ipairs(entry.when or {}) do whole[i + 1] = cond end
    args.words = {
      type = "description", order = 1, width = "full", fontSize = "medium",
      name = ns.Conditions.describe(whole, wordCtx()),
    }
    args.note = {
      type = "description", fontSize = "medium", order = 2, width = "full",
      name = L["This line's conditions are nested more deeply than the editor draws, so they are "
              .. "shown here rather than offered for editing. They run exactly as written."],
    }
  else
    args.match = {
      type = "select", order = 1, width = 1.0, name = L["This line fires when"],
      values = { all = L["every condition passes"], any = L["any condition passes"] },
      get = function() return model.match end,
      set = function(_, v) Rotation.setMatch(v) end,
    }
    args.conditions = { type = "group", inline = true, order = 2, name = "",
                        args = conditionArgs(model) }
    local adds = {}
    for _, cat in ipairs(ns.Conditions.CATEGORIES) do adds[cat.fields[1]] = L[cat.label] end
    args.add = {
      type = "select", order = 3, width = 1.2, name = L["Add a condition"],
      desc = L["Adds a condition from this group; change the exact field on the new row."],
      values = adds,
      get = function() return nil end,
      set = function(_, v) Rotation.addCondition(v) end,
    }
  end
  return { type = "group", inline = true, order = 5,
           name = string.format(L["Conditions - %s"], name), args = args }
end

-- ---------------------------------------------------------------- Builder tab: the draft header

local function editArgs()
  local d = Rotation.draft()
  if not d then return nil end
  local problems = Rotation.problems()
  local args = {
    state = {
      type = "description", order = 1, width = 1.4, fontSize = "medium",
      name = d.dirty
        and string.format(L["Editing %s - unsaved changes"], Rotation.displayName(d.key))
        or string.format(L["Editing %s - saved"], Rotation.displayName(d.key)),
    },
    save = {
      type = "execute", order = 2, width = 0.7, name = L["Save"],
      desc = L["Writes the draft to your rotation and repaints the display."],
      disabled = (not d.dirty) or #problems > 0,
      func = function() Rotation.save() end,
    },
    discard = {
      type = "execute", order = 3, width = 0.7, name = L["Discard"],
      desc = L["Throws the draft away and goes back to your saved rotation."],
      disabled = not d.dirty,
      func = function() Rotation.discard() end,
    },
  }
  for i, line in ipairs(problems) do
    args["p" .. i] = { type = "description", fontSize = "medium", order = 3 + i, width = "full",
                       name = "|cffE8A33D" .. line .. "|r" }
  end
  return { type = "group", inline = true, order = 3, name = "", args = args }
end

-- The foot of the Builder (ADR-0015 §2). Absent entirely when there is nothing to say: an empty
-- "Checks" box every time you open the panel teaches you to stop reading it.
local function diagnosticArgs()
  local lines = Rotation.diagnosticLines()
  if #lines == 0 then return nil end
  local args = {}
  for i, line in ipairs(lines) do
    args["d" .. i] = { type = "description", fontSize = "medium", order = i, width = "full",
                       name = "|cffE8A33D" .. line .. "|r" }
  end
  return { type = "group", inline = true, order = 9, name = L["Checks"], args = args }
end

local function mirrorArgs()
  local args = {}
  for i, line in ipairs(Rotation.mirrorLines()) do
    args["m" .. i] = { type = "description", fontSize = "medium", order = i, width = "full",
                       name = line }
  end
  return args
end

local function builderArgs()
  local _, _, editable = Rotation.listRows()
  return {
    -- The strip, mirrored at the top of the Builder, so the list and the queue are seen together
    -- (ADR-0015 amendment). It is first because it is the thing being explained: the status column
    -- below only means anything against the queue that is actually on screen.
    mirror = { type = "group", inline = true, order = 1, name = L["Right now"],
               args = mirrorArgs() },
    intro = {
      type = "description", order = 2, width = "full", fontSize = "medium",
      name = editable
        and L["Your rotation, top to bottom: the first line that can fire is the one suggested."]
        or L["This is a template, so it cannot be edited. Customize it on the Rotations tab to get a copy that can."],
    },
    editing = editArgs(),
    list = { type = "group", inline = true, order = 4, name = L["Rotation"], args = listArgs() },
    pane = paneArgs(),
    search = {
      type = "input", order = 6, width = "full", name = L["Search"],
      get = function() return Rotation.search() end,
      set = function(_, v) Rotation.setSearch(v) end,
    },
    spells = { type = "group", inline = true, order = 7, name = L["Spells"],
               args = spellPaletteArgs(editable) },
    items = { type = "group", inline = true, order = 8, name = L["Items"],
              args = itemPaletteArgs(editable) },
    checks = diagnosticArgs(),
  }
end

-- ---------------------------------------------------------------- Share tab

-- The state lives in Options.lua, where it already was; this reads it through the accessors rather
-- than holding a second copy. `Options.exchangeText()` had no caller outside the suite until now,
-- which in this repo is a bug report, not a spare function.
local function shareArgs()
  return {
    text = {
      type = "input", multiline = 8, width = "full", order = 1, name = L["Build string"],
      desc = L["Paste an ELM1: string to import it as one of your builds. /elm export fills this box with the active build."],
      get = function() return ns.Options and ns.Options.exchangeText() or "" end,
      set = function(_, value) if ns.Options then ns.Options.importText(value) end end,
    },
    note = {
      type = "description", fontSize = "medium", order = 2,
      name = function() return ns.Options and ns.Options.exchangeNote() or "" end,
    },
  }
end

-- ---------------------------------------------------------------- the tree pages (D30-D36)
--
-- The whole left-hand nav is ONE AceConfig tree (AceConfigDialog-3.0.lua:1721-1751: a group whose
-- `childGroups` is "tree" and whose parent is ALSO a tree, which the addon's own root already is,
-- gets no widget of its own -- it becomes a NODE, and `BuildGroups`/`BuildSubGroups`
-- (AceConfigDialog-3.0.lua:1005-1071) recurse into any child group that does not say
-- `childGroups = "tab"`, which is the default). So the fork groups below live INSIDE their parent
-- template's own `.args`, one Lua table nested inside another, and that nesting IS the tree the
-- player sees -- no separate widget-building code of our own is needed for it.

-- "wowhead.com" from a full guide URL, for the source line -- the reader does not need the whole
-- path, only which site to trust.
local function sourceHost(url)
  if type(url) ~= "string" then return "" end
  return (url:match("^%a+://([^/]+)/?") or url):gsub("^www%.", "")
end

-- ok/failing/unknown, the same D43 texture dots as `Rotation.MARKS` (green/amber/grey) rather than
-- a second, ASCII marker style on the same page -- `nil` ("could not tell") is deliberately not
-- red, for the same reason the old wizard's checkLine never turned one red -- a tooltip scan that
-- came back empty is not a fact about the character. The texture carries its own colour, so no
-- `Colors.wrap` here (unlike the still-ASCII `+`/`!`/`?` this replaces).
local function needMark(ok)
  if ok == true then return "|TInterface\\COMMON\\Indicator-Green:12|t" end
  if ok == false then return "|TInterface\\COMMON\\Indicator-Yellow:12|t" end
  return "|TInterface\\COMMON\\Indicator-Gray:12|t"
end

-- "Exodin" or "Exodin  · in use" (D32/D33/D36's name field). A muted dot, not a repeat of the word
-- "Use": the button beside it (or its absence, once this IS the one running) already says that.
local function nameWithBadge(text, active)
  if not active then return text end
  return text .. "  " .. ns.Colors.wrap(ns.Colors.MUTED, "· " .. L["in use"])
end

-- D30/D48. A playstyle the catalog lists but the pack cannot run -- no build has shipped under that
-- key yet -- is SHOWN, muted, wherever its name appears, and its page says why in words.
-- `disabled = true` on the group would have been the obvious flag and is exactly the wrong one: it
-- hides the page, and the page is the answer to the question the muted name asks.
local function templateLabel(row)
  if row.available then return row.playstyle end
  return ns.Colors.wrap(ns.Colors.MUTED, row.playstyle)
end

-- The words. Not "you may not have this" -- rule 8 forbids a hard gate and there is no requirement
-- to meet here: the rotation itself does not exist yet, which is a fact about Elmira, not about the
-- character. Everything the CHARACTER is missing is a `needs` row below, which explains itself.
local function unavailableReason(row)
  if row.available then return nil end
  return L["Not in Elmira yet: no rotation has shipped for this playstyle, so using it puts nothing on screen."]
end

-- D34: no button at all on the rotation already running -- there is nothing left for it to do.
-- Otherwise a `L["Use"]` execute, `confirm`ed (never disabled: `requires` is advisory, hard rule 8,
-- and disabling this button would be a real gate on a character that has never been able to be
-- gated) when this row's own requirements are not met, naming the first failing one.
local function useButtonArgs(order, key, active, checks, blocked)
  if active then return nil end
  -- D48: `blocked` is the "there is no rotation behind this name" case, which is not a requirement
  -- the character fails but reads to the player as the same kind of warning -- so it takes the same
  -- confirm path, and takes precedence over a failing check, being the more fundamental problem.
  local failing = blocked ~= nil
    or (ns.Detect and ns.Detect.hasFailures and ns.Detect.hasFailures(checks or {})) or false
  local reason = blocked
  if failing and not reason then
    for _, check in ipairs(checks or {}) do
      if check.ok == false then reason = check.text; break end
    end
  end
  return {
    type = "execute", order = order, width = 0.8,
    name = failing and L["Use this anyway"] or L["Use"],
    desc = reason,
    -- `confirm` as a STRING is a HANDLER METHOD NAME to AceConfigDialog (AceConfigDialog-3.0.lua:
    -- 771-782), not literal text -- passing the reason there would error looking up a method that
    -- does not exist. The boolean + `confirmText` pair is what shows the reason itself.
    confirm = failing or nil,
    confirmText = reason,
    func = function()
      local ok, err = Rotation.use(key)
      if not ok then announceFailure(err) end
    end,
  }
end

-- Navigates the OPEN standalone dialog to a child of the Rotations tree, the same SelectGroup path
-- `Options.Open("rotation", key)` uses -- never a second `Open`, which would replace the window's
-- root and hide the left menu (the exact bug D20 fixed).
local function navigateTo(key)
  return function()
    if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
      ns.Options.dialog:SelectGroup("Elmira", "rotation", key)
    end
  end
end

-- "Level 60 Paladin, holding a two-hander. Pick how you want to play:" -- the exact sentence the
-- old wizard opened with (Wizard.lua's own former heading), reused rather than re-derived so the
-- wording a player has already seen once does not quietly change on them.
local function detectionLine(detection)
  local class = (detection and detection.class) or "?"
  local level = (detection and detection.level) or "?"
  local weapon = (detection and detection.weapon and detection.weapon.type) or L["unknown"]
  return string.format(L["Level %s %s, holding a %s. Pick how you want to play:"],
    tostring(level), tostring(class), tostring(weapon))
end

-- D32's inline card, made to actually READ as a card (D69, 2026-09-07 owner feedback: "not like
-- cards... too much text coming after each other"). AceGUI's InlineGroup already draws a bordered
-- pane (AceGUIContainer-InlineGroup.lua:78-81) -- the missing piece was the group's own `name`,
-- which was always `""`, leaving the 17px title strip empty (InlineGroup.lua:72-76, 79) so a column
-- of them read as one wall of text with no separation at all. The playstyle name now IS the card's
-- title, so the row that used to spell it out again as a clickable label (D32's original `args.name`)
-- would just repeat the heading -- cut, and replaced by a small `L["Open"]` execute that keeps the
-- same navigation (D32's requirement) without carrying the name a second time.
--
-- D70: `row.difficulty` joins the meta line. D71: the meta line no longer ends in the source host --
-- "updated 2026-08-30 · wowhead" read as if the WOWHEAD PAGE were updated that day, when the date is
-- ours (when Elmira's catalog entry was last checked). Role/difficulty/updated stay together; the
-- source gets its own unambiguous line plus a button that opens the full URL in a copyable popup
-- (WoW cannot open a link itself) -- reusing the D35/D61/D67 StaticPopup layer, never a second one.
local function templateCard(row, order)
  local a, args = 0, {}
  a = a + 1
  args.open = { type = "execute", order = a, width = 0.6, name = L["Open"], func = navigateTo(row.build) }
  local use = useButtonArgs(a + 1, row.build, row.active, row.checks, unavailableReason(row))
  if use then a = a + 1; args.use = use end

  a = a + 1
  args.summary = { type = "description", order = a, width = "full", fontSize = "medium",
                   name = row.summary or "" }

  local bits = {}
  if row.difficulty then bits[#bits + 1] = string.format(L["difficulty: %s"], tostring(row.difficulty)) end
  if row.recommended then bits[#bits + 1] = L["recommended"] end
  if row.experimental then bits[#bits + 1] = L["experimental"] end
  if row.updated then bits[#bits + 1] = string.format(L["updated %s"], tostring(row.updated)) end
  a = a + 1
  args.meta = { type = "description", order = a, width = "full", fontSize = "medium",
                name = ns.Colors.wrap(ns.Colors.MUTED, table.concat(bits, " · ")) }

  if row.source then
    a = a + 1
    args.source = { type = "description", order = a, width = 1.6, fontSize = "medium",
      name = ns.Colors.wrap(ns.Colors.MUTED, string.format(L["Source: %s"], sourceHost(row.source))) }
    a = a + 1
    args.link = { type = "execute", order = a, width = 0.6, name = L["Copy link"],
      desc = L["Shows the full web address in a box you can select and copy."],
      func = function() Rotation.openSourcePopup(row.source) end }
  end

  return { type = "group", inline = true, order = order,
           name = nameWithBadge(templateLabel(row), row.active), args = args }
end

-- D33's header row: name (gold, badged) · in use/Use · Copy and edit.
local function templateHeaderArgs(row)
  local a, args = 0, {}
  a = a + 1
  -- Gold for a playstyle that runs, muted for one that cannot yet -- `templateLabel` carries its
  -- own colour, so the highlight is only applied to the ones it left plain.
  args.name = { type = "description", order = a, width = 1.4, fontSize = "medium",
                name = row.available and ns.Colors.wrap(ns.Colors.HIGHLIGHT,
                                                        nameWithBadge(row.playstyle, row.active))
                    or nameWithBadge(templateLabel(row), row.active) }
  local use = useButtonArgs(a + 1, row.build, row.active, row.checks, unavailableReason(row))
  if use then a = a + 1; args.use = use end
  a = a + 1
  args.copy = { type = "execute", order = a, width = 1.0, name = L["Copy and edit"],
                desc = L["Makes your own editable copy of this template, under a name you choose."],
                func = function() Rotation.openCopyPopup(row.build, row.playstyle) end }
  return { type = "group", inline = true, order = 1, name = "", args = args }
end

-- D33's explanation: the catalog's own summary/notes, a muted difficulty/updated line, then the
-- source on its own line with a Copy link button -- the SAME split `templateCard` got (D71,
-- 2026-09-07): this page is the one the card's own Open button lands on, so leaving it concatenated
-- ("updated 2026-08-30 · wowhead", read as if the WOWHEAD PAGE were updated that day) would mean the
-- fix only half-landed and the owner hits the other half on the very next click. D70's difficulty
-- joins the meta line here too, reusing the exact same strings as the card so there is one wording
-- for both, not two -- the page has more room than a card, but difficulty is the only card field
-- worth repeating here: recommended/experimental are catalog-sort hints already reflected by this
-- playstyle's position in the tree, not new information a detail page needs to restate.
local function templateExplainArgs(row, order)
  local a, args = 0, {}
  local blocked = unavailableReason(row)
  if blocked then a = a + 1; args.blocked = { type = "description", order = a, width = "full",
    fontSize = "medium", name = ns.Colors.wrap(ns.Colors.MUTED, blocked) } end
  if row.summary then a = a + 1; args.summary = { type = "description", order = a, width = "full",
    fontSize = "medium", name = row.summary } end
  if row.notes then a = a + 1; args.notes = { type = "description", order = a, width = "full",
    fontSize = "medium", name = row.notes } end

  local bits = {}
  if row.difficulty then bits[#bits + 1] = string.format(L["difficulty: %s"], tostring(row.difficulty)) end
  if row.updated then bits[#bits + 1] = string.format(L["updated %s"], tostring(row.updated)) end
  a = a + 1
  args.meta = { type = "description", order = a, width = "full", fontSize = "medium",
                name = ns.Colors.wrap(ns.Colors.MUTED, table.concat(bits, " · ")) }

  if row.source then
    a = a + 1
    args.source = { type = "description", order = a, width = 1.6, fontSize = "medium",
      name = ns.Colors.wrap(ns.Colors.MUTED, string.format(L["Source: %s"], sourceHost(row.source))) }
    a = a + 1
    args.link = { type = "execute", order = a, width = 0.6, name = L["Copy link"],
      desc = L["Shows the full web address in a box you can select and copy."],
      func = function() Rotation.openSourcePopup(row.source) end }
  end

  return { type = "group", inline = true, order = order, name = "", args = args }
end

-- D33's "What this rotation needs": one row per Detect.check result, then the rune shopping list
-- (ADR-0013 §2) exactly as the old wizard worded it.
local function needsArgs(row)
  local a, args = 0, {}
  for _, check in ipairs(row.checks or {}) do
    a = a + 1
    args["n" .. a] = { type = "description", order = a, width = "full", fontSize = "medium",
                        name = needMark(check.ok) .. " " .. check.text }
  end
  if row.runesToEngrave and #row.runesToEngrave > 0 then
    a = a + 1
    args.shopping = { type = "description", order = a, width = "full", fontSize = "medium",
      name = ns.Colors.wrap(ns.Colors.BRAND, string.format(
        L["Engrave first: %s. The Rune Broker in every starting zone sells runes for 1c."],
        table.concat(row.runesToEngrave, ", "))) }
  end
  if a == 0 then
    -- "ready to go" is a claim about the CHARACTER, and it is still true here -- but printing it
    -- under a page that has just said there is no rotation to run reads as a contradiction.
    args.none = { type = "description", order = 1, width = "full", fontSize = "medium",
                  name = row.available and L["Nothing extra needed -- this rotation is ready to go."]
                                        or L["Nothing extra needed from you."] }
  end
  return args
end

-- D33/D36's "Rotation, top to bottom": the SAME gate evaluation the Builder's own live status
-- column runs (Rotation.rowStatuses, Core/Gates.evaluate), generalised to whichever key is being
-- VIEWED rather than only the active build -- no new evaluation path, only a new key to run it
-- against. Three states, not the Builder's five: a page you are only looking at cannot know
-- moment-to-moment truth ("target below 20%"), only whether a line is gated off FOR THIS CHARACTER
-- (grey, D73: "cannot happen" -- gated off is exactly that, until you change something about the
-- character) or fine (green) or switched off (also grey, the same "cannot happen" bucket) -- the
-- same MARKS the Builder's own status column reads, kept consistent rather than inverted between
-- the two pages. There is no amber on this page: "waiting on a condition" is a moment-to-moment
-- truth this read-only view does not track.
function Rotation.lineRows(key)
  local p = pack()
  local build = findBuild(p, key)
  if not (build and build.entries) then return {} end
  -- D80, same cause as D79's `wordCtx`: an un-merged ctx here made `compileBuild` drop a
  -- registry-key entry, so `compiledAt[i]` stayed nil and a saved registry line read `off` --
  -- grey, which after D73 means "cannot happen on this character" about a line that can.
  local spells = (p and ns.Spells and ns.Spells.merged and ns.Spells.merged(p)) or (p and p.spells)
  local ctx = { spells = spells, sets = p and p.sets, souls = p and p.souls,
                bonuses = p and p.bonuses }
  local compiled = ns.compileBuild and ns.compileBuild(build, ctx)
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  -- Only `capabilities` matters here: `Gates.evaluate`'s `active` verdict reads nothing else from
  -- its context argument, and this page never reads a gate's `.reasons` text (the mark alone is the
  -- whole story on a read-only page) -- so the pack tables that build THAT text would be dead
  -- weight here, unlike in `Display.gateContext`, which the Builder's live column still needs them for.
  local gates = (compiled and ns.Gates and state)
    and ns.Gates.evaluate(compiled, state,
      { capabilities = ns.Adapter and ns.Adapter.capabilities and ns.Adapter.capabilities() })
    or {}

  local compiledAt, byIndex = {}, {}
  if compiled then
    for i, entry in ipairs(compiled.entries) do compiledAt[entry.index] = i end
  end
  for _, g in ipairs(gates) do byIndex[g.index] = g end

  local out = {}
  for i, entry in ipairs(build.entries) do
    local mark -- mutants: equivalent deletion only makes it a global; luacheck catches that
    local at = compiledAt[i]
    if entry.disabled or not at then
      mark = "off"
    elseif byIndex[at] and byIndex[at].active == false then
      mark = "blocked"
    else
      mark = "firing"
    end
    out[#out + 1] = { index = i, mark = mark, label = actionName(entry), spell = entry.spell,
                       summary = Rotation.conditionSummary(entry) }
  end
  return out
end

local function lineRowsArgs(key)
  local rows = Rotation.lineRows(key)
  if #rows == 0 then
    return { none = { type = "description", order = 1, width = "full", fontSize = "medium",
                       name = L["This rotation has no lines yet."] } }
  end
  local args = {}
  for i, row in ipairs(rows) do
    local look = Rotation.MARKS[row.mark]
    -- D72: the spell's icon before its name, resolved through the ADAPTER (Display.spellIcon,
    -- already used the same way by the Builder's own listArgs and by mirrorLines) -- Core/this
    -- module never calls the WoW API directly. No icon (unresolved spell, or an item line, which
    -- carries no `spell` at all) renders with no texture and no gap of its own: `prefix` is "" and
    -- the format string does not leave a second space behind for it.
    local icon = row.spell and ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(row.spell)
    local prefix = icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
    args["l" .. i] = { type = "description", order = i, width = "full", fontSize = "medium",
      name = string.format("%d %s %s%s%s|r  |cff9AA0A6%s|r", i, look.mark, prefix, look.colour,
                           row.label, row.summary) }
  end
  return args
end

-- D36's header: name (brand, badged) · copied from <template>/yours · in use/Use · Rename · Delete.
local function forkHeaderArgs(row)
  local a, args = 0, {}
  a = a + 1
  args.name = { type = "description", order = a, width = 1.2, fontSize = "medium",
                name = ns.Colors.wrap(ns.Colors.BRAND, nameWithBadge(row.name, row.active)) }
  a = a + 1
  local from = row.derivedFrom
    and string.format(L["copied from %s"], Rotation.displayName(row.derivedFrom)) or L["yours"]
  args.from = { type = "description", order = a, width = 1.0, fontSize = "medium",
                name = ns.Colors.wrap(ns.Colors.MUTED, from) }
  local use = useButtonArgs(a + 1, row.build, row.active, {})
  if use then a = a + 1; args.use = use end
  a = a + 1
  args.rename = { type = "execute", order = a, width = 0.7, name = L["Rename"],
    func = function() Rotation.openRenamePopup(row.build, row.name) end }
  a = a + 1
  args.delete = { type = "execute", order = a, width = 0.7, name = L["Delete"],
    confirm = true, confirmText = L["Delete this rotation? This cannot be undone."],
    func = function() Rotation.remove(row.build) end }
  return { type = "group", inline = true, order = 1, name = "", args = args }
end

-- D36: the fork itself as a tree node/page. `order` is a caller-assigned position so a template's
-- own forks sort after that template's other content and a no-template fork sorts after every
-- template on the root page (D30's ordering rule).
local function forkPageGroup(row, order)
  local args = {}
  args.header = forkHeaderArgs(row)

  -- ADR-0010: a diff, never a rebase, shown only once the template has actually moved on since
  -- this fork was taken -- the same staleness gate the addon has always used, and, like
  -- `parentDiffLines` itself, only ever said about the fork that IS running (D36 "stays as today").
  if row.active and row.derivedFrom then
    local _, _, fork = findBuild(pack(), row.build)
    local updated = fork and Rotation.templateUpdatedAt(row.derivedFrom)
    if updated and fork.derivedAt and tostring(updated) > tostring(fork.derivedAt) then
      local dargs = {
        banner = { type = "description", order = 1, width = "full", fontSize = "medium",
          name = string.format(L["%s has been updated since you forked it (%s, yours is from %s)."],
                               Rotation.displayName(row.derivedFrom), tostring(updated),
                               tostring(fork.derivedAt)) },
      }
      for i, line in ipairs(Rotation.parentDiffLines()) do
        dargs["d" .. i] = { type = "description", order = i + 1, width = "full", fontSize = "medium",
                             name = line }
      end
      args.stale = { type = "group", inline = true, order = 2, name = "", args = dargs }
    end
  end

  args.lines = { type = "group", inline = true, order = 3, name = L["Rotation, top to bottom"],
                 args = lineRowsArgs(row.build) }
  args.edit = { type = "execute", order = 4, name = L["Edit"],
    desc = L["Opens this rotation in the Builder."],
    -- D44: activating this fork can fail (no profile, a stale key). Navigating to the Builder
    -- anyway would silently open it on whatever rotation happened to be active before, so a
    -- failure here must say why AND stop -- matching Rotation.customize (:175).
    func = function()
      if not row.active then
        local ok, err = Rotation.use(row.build)
        if not ok then announceFailure(err); return end
      end
      if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
        ns.Options.dialog:SelectGroup("Elmira", "rotation", "builder")
      end
    end }
  return { type = "group", order = order, name = row.name, args = args }
end

-- D33: the template itself as a tree node/page, with its own forks nested inside `args` -- which is
-- what makes them a nested tree node rather than a second thing on this page (see the header note
-- above this section).
local function templatePageGroup(row, order, forksHere)
  local args = {}
  args.header = templateHeaderArgs(row)
  args.about = templateExplainArgs(row, 2)
  args.needs = { type = "group", inline = true, order = 3, name = L["What this rotation needs"],
                 args = needsArgs(row) }
  args.lines = { type = "group", inline = true, order = 4, name = L["Rotation, top to bottom"],
                 args = lineRowsArgs(row.build) }
  for i, forkRow in ipairs(forksHere) do
    args[forkRow.build] = forkPageGroup(forkRow, 1000 + i)
  end
  return { type = "group", order = order, name = templateLabel(row), args = args }
end

-- D30: the tree's own args -- intro/detection/New rotation, the root page's inline cards, then the
-- navigable pages (templates in catalog order, their forks nested inside them, then no-template
-- forks, then Builder and Share last).
local function rotationTreeArgs()
  local args, a = {}, 0
  local detection = ns.Wizard and ns.Wizard.detection and ns.Wizard.detection()

  a = a + 1
  args.detection = { type = "description", order = a, width = "full", fontSize = "medium",
                      name = detectionLine(detection) }
  a = a + 1
  args.newRotation = { type = "execute", order = a, name = L["New rotation"],
    desc = L["Starts empty; add lines from your own spellbook in the Builder."],
    func = function() Rotation.openNewRotationPopup() end }

  local rows = Rotation.templateRows()
  local byParent = {}
  for _, forkRow in ipairs(Rotation.forkRows()) do
    local parent = Rotation.rootParent(forkRow.build) or ""
    byParent[parent] = byParent[parent] or {}
    byParent[parent][#byParent[parent] + 1] = forkRow
  end

  -- The pack's own `class`, not `detection.class`: this line names what the CATALOG is for, and a
  -- class with a data pack but no readable detection (Adapter/Detect not wired, or a spec that
  -- fakes only `Wizard.choices`) must not say "?" about a class it plainly knows.
  local p = pack()
  if #rows == 0 then
    a = a + 1
    local className = (p and p.class) or (detection and detection.class) or L["your class"]
    args.noPack = { type = "description", order = a, width = "full", fontSize = "medium",
      name = string.format(
        L["No playstyles for %s yet. Build your own: New rotation, then add spells from your spellbook."],
        className) }
  else
    a = a + 1
    local className = (p and p.class) or (detection and detection.class) or "?"
    local phase = rows[1] and rows[1].phase
    args.header = { type = "description", order = a, width = "full", fontSize = "medium",
      name = phase and string.format(L["Playstyles for %s · %s"], className, tostring(phase))
                    or string.format(L["Playstyles for %s"], className) }
    for i, row in ipairs(rows) do
      a = a + 1
      args["card" .. i] = templateCard(row, a)
    end
  end

  for i, row in ipairs(rows) do
    args[row.build] = templatePageGroup(row, 1000 + i, byParent[row.build] or {})
  end
  local afterTemplates = 1000 + #rows
  for i, row in ipairs(byParent[""] or {}) do
    args[row.build] = forkPageGroup(row, afterTemplates + i)
  end

  args.builder = { type = "group", order = 9000, name = L["Builder"], args = builderArgs() }
  args.share = { type = "group", order = 9001, name = L["Share"], args = shareArgs() }
  return args
end

-- ---------------------------------------------------------------- the section

function Rotation.group()
  return {
    type = "group", order = 0, name = L["Rotations"], childGroups = "tree",
    args = rotationTreeArgs(),
  }
end

ns.Rotation = Rotation
return Rotation
