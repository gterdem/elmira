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

-- PE4-D4 (2026-09-08 owner ruling): a button's label is coloured by what it DOES -- green commits
-- work (Save), red throws work away (Discard, Reset, Delete), purple navigates somewhere else (Add
-- from Spellbook, Copy and Edit) -- and everything else stays the default gold, the per-row
-- `Remove` emphatically included: fifteen red words down the right edge would make the least-wanted
-- action on a row the most eye-catching thing on the page.
--
-- ONLY while the button is ENABLED, which is what this function is for. AceGUI draws a Button's
-- label with `fontstring:SetText` (AceGUIWidget-Button.lua:47) and disables it through the Blizzard
-- `UIPanelButtonTemplate`'s own `Disable()`, which greys the FONT OBJECT -- and a `|cff` escape
-- inside the string wins over a font object's colour, so a disabled green Save would still read
-- green while doing nothing at all. Stripping the escape here is the only way it goes grey.
--
-- PE5-D4 (2026-09-08): every one of those choices lives in THIS TABLE and nowhere else, because the
-- owner has already said the full version may be walked back to destructive-only ("Use etc can stay
-- as is; only destructive ones can be different colored -- but let's see how your current suggestion
-- looks"). A button whose key is absent from here is drawn in the default gold, so the walk-back is
-- DELETING A LINE, not hunting call sites across two files. The card widget's own Use button reads
-- its label from `useButtonArgs` (via `templateCard`/`forkCard`), so it follows this table too.
local BUTTON_COLOURS = {
  -- Throws work away, once and globally. These stay coloured whatever else changes.
  discard = ns.Colors.BAD, reset = ns.Colors.BAD, delete = ns.Colors.BAD,
  -- PE4-D4, the Builder: commits your work / navigates you off this page.
  save = ns.Colors.OK, spellbook = ns.Colors.BRAND,
  -- PE5-D3, the Rotations detail panel -- AND THE OWNER'S LIKELY WALK-BACK. Delete the ONE line
  -- below and Use, Edit and Copy and Edit all go back to gold; nothing else needs touching.
  -- PE5 owner ruling 2026-09-08: `Use` stays GOLD. Colour is a signal only while it is rare, and
  -- Use is already the obvious thing to press -- it needs no help competing with the red ones.
  edit = ns.Colors.BRAND, copyEdit = ns.Colors.BRAND,
}

local function actionLabel(colour, text, disabled)
  if disabled or not colour then return text end
  return ns.Colors.wrap(colour, text)
end

-- PE5-D1/D2: the detail panel's header rows right-align their buttons. `width = "relative"` +
-- `relWidth` is the only shape AceGUI's Flow layout scales to the row (`framewidth = width *
-- child.relWidth`, AceGUI-3.0.lua:709-711), so a row whose relWidths sum to exactly 1.0 fills the
-- row and its last button lands on the right edge.
--
-- EIGHTHS on purpose. Flow starts a new row the moment `framewidth + usedwidth > width` (:730), so
-- a floating-point crumb over 1.0 would drop the last button -- Delete -- onto a row of its own.
-- Dyadic fractions (1/8, 1/4, 3/16) are exact in binary, and every name share below is computed as
-- `1.0 - <the buttons that are actually present>`, so the sum is exactly 1.0 by construction.
--
-- That subtraction is the point of D1/D2, not a nicety: `Use` is ABSENT on the rotation the player
-- is already running (`useButtonArgs` returns nil), which is the page they look at most, and a
-- hard-coded name width would leave a button-sized hole in the middle of exactly that row.
local BUTTON_REL = 0.125      -- Use, Edit, Rename, Delete
local WIDE_BUTTON_REL = 0.25  -- "Copy and Edit" -- the one label an eighth of the row clips
local FROM_REL = 0.1875       -- "copied from <template>", beside a fork's name

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
      -- F1b: only ever true here for a fork THIS character owns -- `UserBuilds.list` already
      -- hides a fork private to somebody else, so reaching this row at all means the viewer may
      -- also flip the toggle back off.
      private = fork and fork.private == true,
    }
  end
  return out
end

-- ---------------------------------------------------------------- PD1-D1: the shared detail area

-- Which card's detail is showing, right now. Transient UI state, like `paletteSearch`/`draft` below
-- -- NOT a DB field: `activeBuild` (Core/DB.lua) keeps meaning "the rotation in use" and nothing
-- else, and PD1-D3's own args table is rebuilt from scratch on every `Rotation.notifyChange()`, so
-- nothing living in the args could survive one. A module-local upvalue is what a plain click can
-- change without writing to a profile or surviving only until the next rebuild.
local selectedKey -- mutants: equivalent deletion only makes it a global; luacheck catches that

local function rowNamed(rows, key)
  for _, row in ipairs(rows) do
    if row.build == key then return true end
  end
  return false -- mutants: equivalent every caller only ever tests this with `and`/`or`, where
  -- Lua's implicit nil (falling off the end) and an explicit `false` read alike
end

-- The one writer. A card body click (PD1-D2) is the only caller today; never a navigation of its
-- own -- the caller still has to force AceConfigDialog's own refresh (the bare `dialog:Open` every
-- card click already performs) for the new detail to actually appear on screen.
function Rotation.select(key)
  selectedKey = key
  return true
end

-- PD1-D1: the stored key if it still names a live template or fork row, else the active rotation,
-- else the first template, else nil (no pack, no forks -- `args.noPack` already speaks to that
-- case). Checked against BOTH lists fresh on every call, never cached, so a selection surviving a
-- delete (`Rotation.remove`) or a fork going private falls back on its own the moment the row it
-- named stops existing, with no extra bookkeeping at either call site.
function Rotation.selected()
  local templates, forks = Rotation.templateRows(), Rotation.forkRows()
  if selectedKey and (rowNamed(templates, selectedKey) or rowNamed(forks, selectedKey)) then
    return selectedKey
  end
  local active = activeKey()
  if active then return active end
  if templates[1] then return templates[1].build end
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
  -- F1a (2026-09-07 bug round): `UserBuilds.find` now takes the PLAYER's own class from AceDB's
  -- `db.keys`, not the pack's, so it refuses a fork of another class correctly even with `p` nil --
  -- unlike before F1a, when a nil pack switched its class check off entirely and this function had
  -- to add its own "no pack, no pin" guard as a stopgap. That guard is gone: it would otherwise
  -- block F1c's whole point, using a rotation a class with no shipped pack just created for itself.
  if not (ns.UserBuilds and ns.UserBuilds.find and ns.UserBuilds.find(p, key)) then
    if not (p and p.builds and p.builds[key]) then return false, "unknown build " .. tostring(key) end
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

-- F1b (2026-09-07 bug round): the one plainly worded toggle on a fork's own page. Default off --
-- every character of the class sees a fork until someone marks it private, at which point only the
-- character who did so still can (`UserBuilds.setPrivate`'s own comment has the account-wide-storage
-- reasoning).
function Rotation.setPrivate(key, private)
  if not (ns.UserBuilds and ns.UserBuilds.setPrivate) then return false, "builds module is not loaded" end
  local ok, err = ns.UserBuilds.setPrivate(key, private)
  if ok then Rotation.notifyChange() end
  return ok, err
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
      string.format(fmt or L["could not set that playstyle (%s)."], tostring(err)))
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
--     the popup was always drawn behind it. Fixed by `raiseAbovePanel` (now `Display/Popups.lua`,
--     see D2 below).
--   * D61b -- the edit box was always empty: `StaticPopup_Show` clears the edit box AFTER `OnShow`
--     runs, so a prefill written from inside OnShow is wiped before the player ever sees it. Fixed
--     by `prefillNow` (also moved), applied to the RETURN VALUE of `StaticPopup_Show` -- which
--     happens after that clear -- with `OnShow`'s own prefill kept only as a fallback.
--   * D61c -- the button (and Enter) did nothing: neither dialog defined `EditBoxOnEnterPressed`
--     (Blizzard requires it for Enter to do anything at all), and every `OnAccept` discarded its
--     handler's `ok, err` -- so an empty-name refusal caused by D61b's own bug looked exactly like a
--     dead button, and there was no way to tell the two apart from in-game alone.

-- D2 (review of 65896ad): `raiseAbovePanel`, the name-addressed edit-box/button1
-- lookup and the prefill-after-clear fix all moved to `Display/Popups.lua` (`ns.Popups`), which is
-- now the ONE place in the addon `StaticPopup_Show` is called from -- a fifth call site
-- (`Setup/Wizard.lua`'s first-run popup) had shipped with none of D61-D67's fixes, because this
-- file's own guard only ever read this file. `ns.Popups.show` is the D61-D67 mechanism (D62's
-- strata+level raise, D63's other-addon-safe restore gate, D67's original-level capture, D61b's
-- prefill-after-clear); this file still owns the edit box's OWN `OnShow` fallback prefill below, and
-- `acceptOnEnter`'s D61c click-through, both of which need `ns.Popups.editBox`/`ns.Popups.button1`
-- to find the real, name-addressed widgets (D64).
local function acceptOnEnter(self)
  local parent = self:GetParent()
  local button1 = ns.Popups.button1(parent)
  if button1 then button1:Click() end
end

-- Each wrapper below keeps `Rotation`'s own return shape a plain boolean (`ns.Popups.show` answers
-- a second value too, the raised dialog, for the one caller -- Wizard's first-run popup -- that
-- needs to touch it further) -- a `local ok = ...; return ok` rather than a bare tail call, so this
-- file's public surface does not silently grow a second return value nobody here asked for.
function Rotation.openNewRotationPopup()
  local prefill = Rotation.newRotationPrefillName()
  local ok = ns.Popups.show("ELMIRA_NAME_ROTATION", nil, nil, { prefill = prefill }, prefill)
  return ok
end

function Rotation.openCopyPopup(templateKey, templateName)
  local prefill = Rotation.copyPrefillName(templateName)
  local ok = ns.Popups.show("ELMIRA_NAME_ROTATION", nil, nil,
    { prefill = prefill, templateKey = templateKey }, prefill)
  return ok
end

function Rotation.openRenamePopup(key, currentName)
  local ok = ns.Popups.show("ELMIRA_RENAME_ROTATION", currentName, nil,
    { prefill = currentName, renameKey = key }, currentName)
  return ok
end

-- D71 (2026-09-07 in-game round): "Maybe we can provide direct link for the source?" -- WoW cannot
-- open a URL, so the convention (same as the wizard's old rune links) is a popup showing the full
-- address in a selectable, pre-highlighted edit box the player copies out. SAME mechanism as the
-- three popups above -- one more StaticPopupDialogs entry through `registerPopups`, the same
-- `ns.Popups.show` -- never a second popup layer, and never the strata-only fix that left the D61
-- naming popups behind the options window twice before it was actually fixed.
function Rotation.openSourcePopup(url)
  local text = url ~= nil and tostring(url) or ""
  local ok = ns.Popups.show("ELMIRA_SHOW_SOURCE", nil, nil, { prefill = text }, text)
  return ok
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
        local box = ns.Popups.editBox(self)
        if box then
          box:SetText((data and data.prefill) or "")
          if box.HighlightText then box:HighlightText() end
        end
      end,
      OnAccept = function(self, data)
        data = data or self.data
        local box = ns.Popups.editBox(self)
        local name = box and box:GetText()
        local ok, err -- mutants: equivalent deleting the declaration only makes both globals; luacheck catches it
        if data and data.templateKey then
          ok, err = Rotation.copyAndUse(data.templateKey, name)
        else
          ok, err = Rotation.createAndUse(name)
        end
        if not ok then announceFailure(err, L["could not create that rotation (%s)."]) end
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
        local box = ns.Popups.editBox(self)
        if box then
          box:SetText((data and data.prefill) or "")
          if box.HighlightText then box:HighlightText() end
        end
      end,
      OnAccept = function(self, data)
        data = data or self.data
        if not (data and data.renameKey) then return end
        local box = ns.Popups.editBox(self)
        local name = box and box:GetText()
        local ok, err = Rotation.rename(data.renameKey, name)
        if not ok then announceFailure(err, L["could not rename that rotation (%s)."]) end
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
        local box = ns.Popups.editBox(self)
        if box then
          box:SetText((data and data.prefill) or "")
          if box.HighlightText then box:HighlightText() end
        end
      end,
    }
  end

  -- W1's `confirmThen`: the ONE popup every card-widget action with `confirm` set shows before
  -- running its `func` -- a StaticPopup, like the three above, rather than a second confirm
  -- mechanism of its own (D71's rule: reuse the layer, never grow a second one). `%s` because the
  -- confirm TEXT is per-action (it always names the failing requirement, PB3: the button itself
  -- stays plain "Use"); `data.onAccept` is `confirmThen`'s closure over the actual action, so this
  -- dialog itself never knows what it is confirming.
  if not dialogs.ELMIRA_CONFIRM then
    dialogs.ELMIRA_CONFIRM = {
      text = "%s",
      button1 = L["Confirm"], button2 = L["Cancel"],
      timeout = 0, whileDead = true, hideOnEscape = true,
      OnAccept = function(self, data)
        data = data or self.data
        if data and data.onAccept then data.onAccept() end
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

-- PE3-D5 (2026-09-08 owner ruling, in-game): one namer, so the slot dropdown, the rotation row and
-- the condition sentence cannot drift apart -- "the item in slot 13 is ready" was the sentence,
-- while the dropdown two controls away already said "Trinket 1". Handed to Core through the wording
-- ctx (`slotName`), never copied into Core: a slot number is Core's, the word for it is ours.
local function slotLabel(slot)
  local at = tonumber(slot) or slot
  return L[SLOT_LABELS[at] or ("Slot " .. tostring(slot))]
end

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
  for _, row in ipairs(rows) do row.label = slotLabel(row.slot) end
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
--
-- PE2-D3.2 (2026-09-08 owner ruling): a full sentence now, not the parenthetical fragment
-- ("engrave Aura Mastery") this used to return -- the text moved out of the button's label and into
-- its tooltip, where a fragment in brackets would read as a stray note rather than an instruction.
function Rotation.reasonText(row)
  if row.reason == "rune" and row.reasonKey then
    return string.format(L["Engrave %s to use this ability."], Rotation.spellLabel(row.reasonKey))
  end
  return L["You have not learned this ability yet."]
end

-- A palette row is a BUTTON while a draft is open and a plain line otherwise. A template has no
-- draft, so clicking one of these must not appear to do something: read-only is the whole point
-- (ADR-0005, hard rule 7), and the Customize banner above the list is where that click belongs.
--
-- Un-known rows are clickable too, deliberately. Runes cost 1c and a rotation you cannot yet run is
-- one you are about to be able to run (hard rule 8's authoring permission); the engine skips the
-- line until the spell is learned, which is exactly the right runtime behaviour.
--
-- PE2-D3.1 (2026-09-08 owner ruling): three across, not one full-width button per entry -- seventeen
-- centred rows was most of the page. An `execute` is a CONTROL, so `width = "relative"` plus
-- `relWidth` is honoured (AceConfigDialog-3.0.lua:1444-1452) exactly as it is for the header row.
-- PE2-D3.2: `why` is the parenthetical that used to be printed inside the label ("(engrave Aura
-- Mastery)"); it moves into the tooltip, above the add hint rather than instead of it -- one `desc`
-- field, two things worth saying.
local PALETTE_REL_WIDTH = 0.32

local function paletteRow(order, name, append, why)
  if not append then
    -- The inert (template) shape is a `description`, which AceConfigDialog draws as an AceGUI Label
    -- -- a widget that never fires OnEnter, so it has no tooltip to move the reason INTO. It keeps
    -- the reason in the text: moving it to a tooltip nothing can open would delete the answer, not
    -- relocate it.
    return { type = "description", fontSize = "medium", order = order,
             width = "relative", relWidth = PALETTE_REL_WIDTH,
             name = why and (name .. "  " .. ns.Colors.wrap(ns.Colors.MUTED, why)) or name }
  end
  local hint = L["Adds this to the bottom of the draft."]
  return { type = "execute", order = order, width = "relative", relWidth = PALETTE_REL_WIDTH,
           name = name, desc = why and (why .. "\n\n" .. hint) or hint, func = append }
end

-- D58's last row: navigation, not editing, so it stays clickable even on a read-only template's
-- Builder view -- unlike every other row here, which `paletteRow` ties to `editable`. "Focused on
-- the spellbook add row" is as far as AceConfig's tree can point: selecting the group puts the
-- reader on the page the row already lives on (D52's root page), which is the whole of what
-- "focused" can mean for a page with no sub-widget scroll target.
--
-- PE2-D3.4: its own row below the grid, full width and brand-coloured, because it is the one entry
-- in this list that navigates away instead of adding a line -- as the eighteenth identical button it
-- read as an ability you could click to append.
local function addFromSpellbookRow(order)
  return {
    type = "execute", order = order, width = "full",
    -- PE4-D4: through the one rule now (`actionLabel`), not a hand-written wrap. It navigates, so
    -- it is purple, and it is never disabled -- but the colour must come from the same place the
    -- other coloured buttons take theirs from or the rule drifts the first time one of them moves.
    name = actionLabel(BUTTON_COLOURS.spellbook, L["Add from Spellbook…"]),
    desc = L["Opens the Abilities page, where you can register more from your spellbook, by id or by name."],
    func = function()
      if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
        ns.Options.dialog:SelectGroup("Elmira", "spells")
      end
    end,
  }
end

-- PE2-D3.3: the search box belongs to this panel, not to the page. Sitting ABOVE the Abilities
-- group it read as searching everything on screen; inside the group it reads as what it is -- a
-- filter on the list beneath it. `order = 0` puts it first whatever the palette rows number.
--
-- PE3-D2 (2026-09-08 owner ruling, in-game): it takes the WHOLE row. At half width it left 0.5 free
-- and the first 0.32 palette button flowed up beside it -- and sat misaligned, because an AceGUI
-- EditBox carries a label above its box and a Button does not, so the two have different heights and
-- different align offsets. A full-width control ends its row in AceGUI's Flow layout
-- (AceGUI-3.0.lua:761-770, `child.width == "fill"` resets `usedwidth`), so the grid below it always
-- starts fresh -- which is the fix, rather than trying to match the two heights.
--
-- PE4-D3 (2026-09-08 owner ruling, in-game): and it only renders at all once the list is long
-- enough to need it. A class pack is ~20-30 abilities, sorted by name and now laid out three
-- across, so a filter saves nothing a glance does not -- while the box costs a permanent row plus
-- its label. A RULE, not a deletion: a bigger pack, or a player who has pulled a lot in from the
-- spellbook, gets the box back with no further work and the filter behind it untouched.
local PALETTE_SEARCH_MIN = 30

-- The UNFILTERED size of the ability palette -- the registry itself, which is what
-- `Rotation.paletteSpells` builds one row per (D58). Counting the FILTERED rows instead would take
-- the box away the moment you typed something that matched nothing, leaving no way to clear it.
function Rotation.paletteSize()
  if not ns.Spells then return 0 end
  Rotation.syncSpells()
  return #ns.Spells.list(ns.Spells.store())
end

-- nil below the threshold, so `args.search = paletteSearchRow()` simply sets no key at all.
local function paletteSearchRow()
  if Rotation.paletteSize() <= PALETTE_SEARCH_MIN then return nil end
  return {
    type = "input", order = 0, width = "full", name = L["Search"],
    desc = L["Filters the abilities below. Plain text, not a pattern."],
    get = function() return Rotation.search() end,
    set = function(_, v) Rotation.setSearch(v) end,
  }
end

local function spellPaletteArgs(editable)
  local rows = Rotation.paletteSpells()
  if #rows == 0 then
    return { search = paletteSearchRow(),
             none = { type = "description", fontSize = "medium", order = 1, width = "full",
                      name = L["Nothing matches."] },
             add = addFromSpellbookRow(2) }
  end
  local args = { search = paletteSearchRow() }
  for i, row in ipairs(rows) do
    local icon = ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(row.key)
    local prefix = icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
    -- Un-known rows are dimmed and carry the reason rather than being hidden: "why can I not add
    -- Divine Storm" is the question, and "engrave Divine Storm" is the answer to it. A nil `known`
    -- means the client cannot tell, which must not read as "you do not have it".
    -- PE2-D3.2: the reason is a tooltip now; the label is the ability's name and its icon, nothing
    -- else, so three of them fit across a row without wrapping.
    local why -- mutants: equivalent deleting the declaration only makes it a global; luacheck catches it
    local body -- mutants: equivalent deleting the declaration only makes it a global; luacheck catches it
    if row.known == false then
      why = Rotation.reasonText(row)
      body = ns.Colors.wrap(ns.Colors.MUTED, row.label)
    else
      body = string.format("|cffFFFFFF%s|r", row.label)
    end
    local key = row.key
    args["s" .. i] = paletteRow(i, prefix .. body,
      editable and function() Rotation.appendSpell(key) end or nil, why)
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
    -- PE2-D3.2: "(empty)" moves off the label and into the tooltip, the same way the spell list's
    -- "(engrave X)" does, so both grids are three names across.
    local body = row.filled
      and string.format("|cffFFFFFF%s|r", row.label)
      or ns.Colors.wrap(ns.Colors.MUTED, row.label)
    local why = (not row.filled) and L["This equipment slot is empty."] or nil
    local slot = row.slot
    args["i" .. i] = paletteRow(i, prefix .. body,
      editable and function() Rotation.appendItem(slot) end or nil, why)
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

-- R3 (D84): which panel's body is showing, right now. UI state, never part of the build -- unlike
-- `draft`, this survives a template just as well as a fork (a template's panels expand too, to show
-- a nested condition in words), so it is tracked separately rather than as a field of the draft.
-- `expandedKey` is what forgets it the moment the rotation being looked at changes -- a stale index
-- surviving a rotation switch would expand whatever line happens to sit there in the new one.
local expandedIndex, expandedKey -- mutants: equivalent deletion only makes them globals; luacheck
-- catches that -- and the pair must decline together (see `syncExpanded`), which one shared
-- declaration line is what keeps a future edit from setting one without the other.

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
  if entry.item then return slotLabel(entry.item) end
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
  return { L = L, name = Rotation.spellLabel, slotName = slotLabel,
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
  draft = nil
  Rotation.draft() -- mutants: equivalent every reader of `draft` goes through `Rotation.draft()`,
  -- which lazily rebuilds it the moment it is nil -- pre-warming it here changes nothing any caller
  -- can observe, only when the (identical) rebuild happens
  refreshDisplay()
  return true
end

-- R3 (D84): the panel that is currently expanded, forgotten the moment the rotation being looked at
-- changes -- `activeKey()`, not `d.key`, because a template has no draft to key this off at all.
local function syncExpanded()
  local key = activeKey()
  if expandedKey ~= key then expandedIndex, expandedKey = nil, key end
end

-- The header's own expand button: open if closed, close if already open. A second click on the
-- line you are already reading collapses it, which is what an accordion is for.
function Rotation.toggleExpand(index)
  syncExpanded()
  expandedIndex = (expandedIndex == index) and nil or index
  return true
end

function Rotation.isExpanded(index)
  syncExpanded()
  return expandedIndex == index
end

-- Kept as the named way to OPEN a line's body regardless of its current state (every existing
-- caller wants exactly that, never a toggle) -- `toggleExpand` is for the header button alone.
function Rotation.selectRow(index)
  local d = Rotation.draft()
  if not (d and d.entries[index]) then return false end
  syncExpanded()
  expandedIndex = index
  return true
end

-- ---------------------------------------------------------------- Builder tab: back to the template
--
-- PE4-D1 (2026-09-08 owner ruling): the shipped template this draft's fork came from, or nil when
-- there is none to go back to -- a rotation started from "New Rotation" records no `derivedFrom`
-- at all (Core/UserBuilds.create), and a `derivedFrom` naming a template this pack no longer ships
-- is the same answer. `derivedFrom` has been written since ADR-0010 and nothing has ever read it
-- back for this; the stale-parent diff is the only other reader and it compares, never restores.
local function draftTemplate(d)
  local p = pack()
  local _, origin, fork = findBuild(p, d.key)
  -- Rotation.draft() has already refused anything but a fork, and `p.builds[nil]` is nil for a fork
  -- that records no parent -- so this states the requirement rather than adding a second answer.
  if origin ~= "fork" or not (fork and fork.derivedFrom) then
    return nil -- mutants: equivalent draft() refused a non-fork already; p.builds[nil] is nil
  end
  return p and p.builds and p.builds[fork.derivedFrom]
end

-- Value equality over an authored condition tree. No cycle guard: both sides have already been
-- through `Schema.validate`, which walks the same nested `when` tables and would not have survived
-- one either. Functions (a `custom` condition) compare by identity, which is right -- a draft row
-- holds the very same closure the template does, because `UserBuilds.copy` only copies tables.
local function deepSame(x, y)
  if x == y then return true end
  if type(x) ~= "table" or type(y) ~= "table" then return false end
  for k, v in pairs(x) do if not deepSame(v, y[k]) then return false end end
  for k in pairs(y) do if x[k] == nil then return false end end
  return true
end

-- Compared over the AUTHORED whitelist alone (`UserBuilds.ENTRY_FIELDS`, the same one Save writes
-- through): a draft row also carries the Builder's own `src` bookkeeping, which a template row
-- never has, so comparing the raw tables would answer "different" for every draft ever taken and
-- Reset would never grey out.
local function entriesMatchTemplate(entries, template)
  local fields = ns.UserBuilds.ENTRY_FIELDS
  if #entries ~= #template then return false end
  for i, entry in ipairs(entries) do
    for _, field in ipairs(fields) do
      if not deepSame(entry[field], template[i][field]) then return false end
    end
  end
  return true
end

-- Rotation.canReset() -> true when there is an original to go back to AND the draft is not already
-- exactly it. Both halves grey the button rather than hiding it: a disabled button with a `desc`
-- that says why teaches, and a missing one puzzles.
function Rotation.canReset()
  local d = Rotation.draft()
  if not d then return false end
  local template = draftTemplate(d)
  if not template then return false end
  return not entriesMatchTemplate(d.entries, template.entries or {})
end

-- Rotation.resetToTemplate() -> true | false
--
-- Acts on the DRAFT, never on the stored rotation. That is the whole design: `Discard` already
-- means "throw away unsaved changes", so putting the template into the draft makes the two
-- orthogonal and makes Reset UNDOABLE -- press it, look at it, then Discard to change your mind or
-- Save to commit. Which is also why it needs no confirmation popup: nothing is destroyed until
-- Save. The fork's own name, key and `derivedFrom` are untouched -- only its lines come back.
function Rotation.resetToTemplate()
  local d = Rotation.draft()
  if not d then return false end
  local template = draftTemplate(d)
  if not template then return false end
  local entries = {}
  for i, entry in ipairs(template.entries or {}) do
    -- No `src`: these lines are not the ones the display is running, and the status column says
    -- exactly that ("not saved yet") until Save re-stamps them from what was actually stored.
    entries[i] = ns.UserBuilds.copy(entry)
  end
  d.entries = entries
  -- The open body followed a line that no longer exists at that position; leaving the index would
  -- expand whichever of the template's lines happens to sit there now. No syncExpanded() first:
  -- the next line clears the index outright, which is everything a sync could have done to it.
  expandedIndex = nil
  return markDirty()
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
  -- The expanded body follows the line it is on, not the position: moving the row you are editing
  -- must not silently switch the conditions shown to a different ability.
  syncExpanded() -- mutants: equivalent `isExpanded`, the only public reader, re-syncs on every call
  -- of its own -- so a stale `expandedIndex` this line would have left behind is corrected there
  -- before anything ever reads it; skipping this sync only changes what a value nobody yet asked
  -- for gets swapped to in the meantime.
  if expandedIndex == index then expandedIndex = to
  elseif expandedIndex == to then expandedIndex = index end
  return markDirty()
end

-- PE2-D2.1: Top/Bottom, which two unrelated addons (ItemRack, Rotation Master) independently
-- converged on alongside Up/Down. A move to an arbitrary position, NOT a loop over `moveRow`:
-- looping the swap would mark the draft dirty once per hop and drag every row it passed through one
-- place the wrong way for a frame. `table.remove` + `table.insert` moves exactly one entry and
-- shifts the block between the two positions by one, which is what the expanded-body bookkeeping
-- below mirrors.
function Rotation.moveRowTo(index, to)
  local d = Rotation.draft()
  if not d then return false end
  local entries = d.entries
  index, to = tonumber(index) or 0, tonumber(to) or 0
  if not (entries[index] and entries[to]) or index == to then return false end
  table.insert(entries, to, table.remove(entries, index))
  -- Same as moveRow above: `isExpanded` is the only public reader and re-syncs on every call, so a
  -- stale index this would have cleared is corrected before anything reads it.
  syncExpanded() -- mutants: equivalent `isExpanded`, the only public reader, re-syncs for itself
  if expandedIndex == index then
    expandedIndex = to
  elseif expandedIndex then
    -- The rows between the two positions each shifted one place towards where the entry left from.
    if index < to and expandedIndex > index and expandedIndex <= to then
      expandedIndex = expandedIndex - 1
    elseif to < index and expandedIndex >= to and expandedIndex < index then
      expandedIndex = expandedIndex + 1
    end
  end
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
  syncExpanded() -- mutants: equivalent same reasoning as `moveRow`'s own sync call above --
  -- `isExpanded` re-validates freshness on every call, so nothing downstream can observe a stale
  -- value this line would have left behind
  if expandedIndex == index then expandedIndex = nil
  elseif expandedIndex and expandedIndex > index then expandedIndex = expandedIndex - 1 end
  return markDirty()
end

-- Appending from the palette. The new line arrives with NO conditions, which means "always" -- so
-- it is put at the BOTTOM, where an unconditional line is harmless, rather than at the top where it
-- would take over the whole rotation the moment it was saved. It is expanded on arrival, because
-- the next thing anyone wants is its conditions.
local function append(entry)
  local d = Rotation.draft()
  if not d then return false end
  d.entries[#d.entries + 1] = entry
  syncExpanded()
  expandedIndex = #d.entries
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

-- D84's in-place spell select: change what a line DOES without removing it and appending a fresh
-- one, so its position AND its conditions both survive the edit. Encoded "spell:KEY"/"item:N" --
-- the same distinction `Diagnostics.actionOf` draws -- because one AceConfig select has to offer
-- both palettes at once.
-- `entry`, when given, is the line this select is FOR: its own current key is guaranteed a place
-- in `values` even when it has fallen out of the palette (an id the registry no longer carries, a
-- spell a class-data update renamed) -- the same "say what is actually there" principle
-- `Diagnostics.unknown`/D65's stopgap already apply, here so the dropdown never shows blank for a
-- line that plainly has something in it.
function Rotation.actionChoices(entry)
  -- The search box filters the palette GROUPS below, not this dropdown: what you typed to find a
  -- spell to add is not a reason to hide every other spell from a line you are already editing.
  local savedSearch = paletteSearch
  paletteSearch = ""
  local values = {}
  -- The icon travels in the LABEL, not as a separate arg: a dropdown button's text is an ordinary
  -- FontString, which renders a `|T...|t` escape exactly as any other description on this page does
  -- -- the same trick D84's header needed once the icon could no longer sit beside a plain label.
  for _, row in ipairs(Rotation.paletteSpells()) do
    local icon = ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(row.key)
    values["spell:" .. row.key] = (icon and ("|T" .. tostring(icon) .. ":0|t ") or "") .. row.label
  end
  for _, row in ipairs(Rotation.paletteItems()) do
    local icon = ns.Display and ns.Display.itemIcon and ns.Display.itemIcon(row.slot)
    values["item:" .. row.slot] = (icon and ("|T" .. tostring(icon) .. ":0|t ") or "") .. row.label
  end
  paletteSearch = savedSearch
  if entry and entry.spell and values["spell:" .. entry.spell] == nil then
    local icon = ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(entry.spell)
    values["spell:" .. entry.spell] =
      (icon and ("|T" .. tostring(icon) .. ":0|t ") or "") .. Rotation.spellLabel(entry.spell)
  end
  if entry and entry.item and values["item:" .. entry.item] == nil then
    values["item:" .. entry.item] = slotLabel(entry.item)
  end
  return values
end

local function encodeAction(entry)
  if entry.spell then return "spell:" .. entry.spell end
  if entry.item then return "item:" .. tostring(entry.item) end
  return ""
end

function Rotation.setLineAction(index, encoded)
  local d = Rotation.draft()
  local entry = d and d.entries[index]
  if not entry then return false end
  local kind, value = tostring(encoded or ""):match("^(%a+):(.+)$")
  if kind == "spell" then
    entry.spell, entry.item = value, nil
  elseif kind == "item" then
    entry.spell, entry.item = nil, tonumber(value)
  else
    return false
  end
  return markDirty()
end

-- ---------------------------------------------------------------- Builder tab: the conditions pane

-- R3 (D84): the pack as the condition editor should see it -- spell-shaped key sources (buff,
-- debuff, seal, rune, castable...) drawn from the Spells REGISTRY, not the pack's raw table, so a
-- condition can name anything the character has registered -- by id, by name or from the
-- spellbook -- exactly as D58 already lets the palette append one (D86). Only `spells` differs from
-- `pack()` itself; every other table (sets/souls/bonuses, which have no registry of their own)
-- passes through untouched.
local function mergedPack()
  local p = pack()
  if not p then return p end
  local spells = (ns.Spells and ns.Spells.merged and ns.Spells.merged(p)) or p.spells
  if spells == p.spells then return p end -- mutants: equivalent an early return here only SKIPS
  -- building a copy whose `spells` field would end up holding this exact same value anyway --
  -- every reader below asks for FIELDS, never for `p`'s own identity, so the allocated copy and `p`
  -- itself answer every one of those questions alike; this is a pure allocation-avoidance line.
  local merged = {}
  for k, v in pairs(p) do merged[k] = v end
  merged.spells = spells
  return merged
end

-- A line's conditions as typed rows, or nil when `index` names nothing in what the Builder is
-- showing (the draft's entries on a fork, the stored ones on a read-only template -- `builderEntries`
-- is the one place that answers which). `model.complex` means the stored shape is deeper than one
-- all/any level; the pane then shows it in words and offers no controls (owner decision, 2026-09-05
-- -- editing nested rows is v1.1).
function Rotation.paneModel(index)
  local entries = builderEntries()
  local entry = entries and entries[index]
  if not entry then return nil end
  return ns.Conditions.toRows(entry.when), entry
end

-- Writes typed rows back onto the entry. The only writer: every setter below goes through it, so
-- there is one place where a `when` list is built and one place that marks the draft dirty.
local function writePane(model, entry)
  entry.when = ns.Conditions.fromRows(model.match, model.rows)
  return markDirty()
end

-- Every setter below refuses OUTSIDE the draft first, before it ever asks `paneModel` for a model:
-- `paneModel` reads happily on a read-only template (the body still has to show a nested line in
-- words there), and a setter that only checked the model would go on to mutate a table nobody saves
-- -- which looks like it worked and changes nothing, this project's characteristic failure.
function Rotation.setMatch(index, match)
  if not Rotation.draft() then return false end
  local model, entry = Rotation.paneModel(index)
  if not model or model.complex then return false end
  model.match = (match == "any") and "any" or "all"
  return writePane(model, entry)
end

-- A row built for a field the player has just chosen: the field's default operator, and the first
-- value the registry offers, so a freshly added condition is a legal one rather than a blank that
-- reports an error before it has been touched.
local function defaultRow(kind, negated)
  local row = ns.Conditions.blankRow(kind)
  if not row then return nil end
  local field = ns.Conditions.field(kind)
  if field.keySource then row.key = (ns.Conditions.keys(kind, mergedPack()) or {})[1] end
  if field.slotAt then row.slot = ns.Palette.TRINKET_SLOTS[1] end
  row.negated = negated and true or nil
  return row
end

function Rotation.addCondition(index, kind)
  if not Rotation.draft() then return false end
  local model, entry = Rotation.paneModel(index)
  if not model or model.complex then return false end
  local row = defaultRow(kind or "in_combat")
  if not row then return false end
  model.rows[#model.rows + 1] = row
  return writePane(model, entry)
end

function Rotation.removeCondition(index, at)
  if not Rotation.draft() then return false end
  local model, entry = Rotation.paneModel(index)
  if not model or model.complex or not model.rows[at] then return false end
  table.remove(model.rows, at)
  return writePane(model, entry)
end

-- One setter for the whole pane rather than six near-identical ones. `kind` and `category` REPLACE
-- the row instead of editing it: an operator or a key carried over from the previous field is a
-- qualifier the new field does not have, and `Conditions.fromRows` would write a condition the
-- compiler rejects while the dropdowns still looked right.
local FIELDS_SET_DIRECTLY = { key = true, slot = true, op = true, value = true, negated = true }

function Rotation.setCondition(index, at, field, value)
  if not Rotation.draft() then return false end
  local model, entry = Rotation.paneModel(index)
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
--
-- PE2-D1 (2026-09-08 owner ruling): the Blizzard `Indicator-*` set has only four shapes, so
-- `blocked`, `off` and `unsaved` rendered as the SAME grey dot with the SAME text colour -- three
-- states the legend distinguished in words and the UI did not distinguish at all. Our own five
-- shipped shapes (`Elmira/media/mark_*.tga`, referenced through the same
-- `Interface\AddOns\Elmira\media\` prefix `Display/Overlay.lua` uses for `flare_h`) carry the SHAPE;
-- `colour` still carries the text colour. `blocked` and `wrong` deliberately share the cross shape
-- and are told apart by that text colour: red is reserved for "you have a mistake to fix" and grey
-- for "true of your character". `desc` is the state in one sentence, for any control on the row
-- that can carry a tooltip (an AceGUI Label -- what a `description` becomes -- cannot).
local MEDIA = "Interface\\AddOns\\Elmira\\media\\"
local function markTexture(file)
  return "|T" .. MEDIA .. file .. ":12|t"
end

Rotation.MARKS = {
  firing   = { mark = markTexture("mark_firing"),  colour = "|cff" .. ns.Colors.OK.hex,
               desc = L["This is what the addon is suggesting right now."] },
  waiting  = { mark = markTexture("mark_waiting"), colour = "|cff" .. ns.Colors.WARN.hex,
               desc = L["Ready to fire, waiting on a condition."] },
  blocked  = { mark = markTexture("mark_blocked"), colour = "|cff" .. ns.Colors.MUTED.hex,
               desc = L["This line can never fire for your character - engrave the rune or learn the spell."] },
  off      = { mark = markTexture("mark_off"),     colour = "|cff" .. ns.Colors.MUTED.hex,
               desc = L["You switched this line off."] },
  unsaved  = { mark = markTexture("mark_unsaved"), colour = "|cff" .. ns.Colors.BRAND.hex,
               desc = L["Changed in this draft, not saved yet."] },
  -- R3 (D87, 2026-09-07 owner ruling): a colour for the panel header alone, distinct from the five
  -- above -- "cannot be met as the rotation stands", a logic error the player should fix, not a
  -- fact about the character. `Colors.BAD` (Core/Colors.lua) is the one red already in the addon's
  -- palette, reused rather than a fresh literal.
  wrong    = { mark = markTexture("mark_wrong"),   colour = "|cff" .. ns.Colors.BAD.hex,
               desc = L["This condition can never be true as the rotation is written."] },
}

-- PE3-D1 (2026-09-08 owner ruling, in-game): the "then this" separator between the queue's spells.
-- PE2-D4.1 joined them with U+2192 and the client's font has no glyph for it, so the player read
-- "Seal of Righteousness [] Holy Shock []" -- the SAME defect the status dots were fixed for one
-- decision earlier, in the same function. `mark_next.tga` is a chevron in `Colors.MUTED` at the
-- weight of the `mark_*` status set, referenced exactly as they are: a texture draws where a font
-- glyph does not. `·` (U+00B7) stays as it is -- it is ON SCREEN in the Rotations header and so is
-- proven to draw; nothing more exotic than that is written into a user-facing string here.
Rotation.NEXT_MARK = markTexture("mark_next")

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
    -- PE2-D4 (2026-09-08 owner ruling): NO ordinals. The queue was numbered `1. 2. 3.` directly
    -- above a numbered rotation list whose numbers mean something else entirely, and the owner read
    -- "5. Consecration" against rotation line 11 and concluded the data was broken. A chevron
    -- carries "then this" without inviting the comparison. PE3-D1: that chevron is the TEXTURE
    -- above, not U+2192 -- which shipped as an empty box on the owner's client.
    local parts = {}
    for _, shown in ipairs(queue) do
      local icon = shown.spell and ns.Display.spellIcon and ns.Display.spellIcon(shown.spell)
      parts[#parts + 1] = string.format("%s%s",
        icon and ("|T" .. tostring(icon) .. ":0|t ") or "", actionName(shown))
    end
    lines[#lines + 1] = table.concat(parts, "  " .. Rotation.NEXT_MARK .. "  ")
  end

  local context = Rotation.contextLine()
  if context then lines[#lines + 1] = context end
  -- PE4-D2: a blank line, so the queue and the context that explains it read as ONE block and the
  -- key to the symbols as another. Four consecutive full-width descriptions ran together into a
  -- paragraph in which nothing said where the answer stopped and the key began.
  lines[#lines + 1] = " "
  -- PE2-D1: six states now, one shape each (`wrong` shares `blocked`'s cross and differs in the
  -- text colour it paints the sentence with, which is why its legend entry is colour-wrapped and
  -- the other five are not). No tooltip here: the legend is a `description`, which AceConfigDialog
  -- draws as an AceGUI Label -- a widget that never fires OnEnter, so a `desc` on it is dead data.
  lines[#lines + 1] = string.format(
    L["%s firing now   %s waiting   %s not active for you   %s off   %s unsaved   %s needs fixing"],
    Rotation.MARKS.firing.mark, Rotation.MARKS.waiting.mark, Rotation.MARKS.blocked.mark,
    Rotation.MARKS.off.mark, Rotation.MARKS.unsaved.mark,
    Rotation.MARKS.wrong.mark .. Rotation.MARKS.wrong.colour)
  -- PE4-D2 (2026-09-08 owner ruling, in-game): "Status is as of the last time the queue changed."
  -- is gone. It hedged about refresh timing, cost a permanent line in the most-read panel on the
  -- page, and the owner had to ask what it meant. The marks repaint on the next queue change
  -- whatever it said, so it bought the player nothing they could act on. A tooltip is not the
  -- alternative here: a `description` is drawn as an AceGUI Label, which never fires OnEnter.
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

-- One line saying what an entry waits for, in words. Delegated to Core/Conditions so the panel, the
-- list and the status hover all phrase a condition the same way -- the count this used to return
-- ("2 conditions") said the same thing about every row that had two, which distinguished nothing.
function Rotation.conditionSummary(entry)
  return ns.Conditions.summary(entry and entry.when, wordCtx())
end

-- R3 (D87): does line `index` carry a `seal`/`seal_linger` condition that no enabled line of THIS
-- build ever casts -- Core/Diagnostics' own structural answer, asked fresh each time rather than
-- cached, because a rotation this small is recomputed cheaper than it is kept correct across edits.
local function deadSealAt(entries, index)
  for _, row in ipairs((ns.Diagnostics and ns.Diagnostics.deadSeal({ entries = entries })) or {}) do
    if row.index == index then return true end
  end
  return false -- mutants: equivalent every caller only ever reads this inside `and`/`if`, where
  -- Lua's implicit nil (falling off the end) and an explicit `false` are the same answer
end

-- R3 (D87, 2026-09-07 owner ruling): the panel header's own three-state dot -- grey ("cannot happen
-- on this character"), amber ("waiting: can fire, just not this instant") or red ("cannot be met as
-- the rotation stands, a logic error to fix"), or nil when nothing is wrong at all. Explicitly NOT a
-- second evaluation of the character: `Rotation.rowStatuses()` already IS "the same evaluation the
-- queue uses" (Display's own gates and the compiled per-condition tests), and it is already a
-- worst-of-its-conditions answer by construction -- one failing condition is enough to make
-- `waitingReason` name it, one failing static gate is enough to mark the row `blocked`. This only
-- RE-BUCKETS that existing five-way answer into D87's three words, and adds the one thing rowStatuses
-- cannot know about itself: whether a condition can ever be true at all.
function Rotation.lineState(index)
  local status = Rotation.rowStatuses()[index]
  if not status then return nil end
  local entries = builderEntries()
  if entries and deadSealAt(entries, index) then return "red" end
  if status.state == "firing" then return nil end
  if status.state == "waiting" then return "amber" end
  return "grey" -- blocked / off / unsaved: all read as D73's "cannot happen right now"
end

-- PE2-D1: `lineState` answers in three words, but SIX marks exist and three of them (blocked, off,
-- unsaved) all bucket to "grey" -- so the shape is taken from `rowStatuses`' own five-way answer and
-- only the red/amber overrides come from `lineState`. Without this the three new shapes would be
-- data no screen ever draws.
local function headerMark(index)
  local st = Rotation.lineState(index)
  if st == "red" then return Rotation.MARKS.wrong end
  if st == "amber" then return Rotation.MARKS.waiting end
  if st == "grey" then
    local status = Rotation.rowStatuses()[index]
    return Rotation.MARKS[status and status.state] or Rotation.MARKS.blocked
  end
  return Rotation.MARKS.firing
end

-- R3 (D85), rewritten for PE2-D2.3/D2.4 (2026-09-08 owner ruling): the collapsed panel's sentence is
-- the CONDITION SUMMARY and nothing else. It used to read "Consecration is cast when the above is
-- not applicable and mana at least 40%." -- repeating the spell name from the dropdown immediately
-- above it and re-explaining priority ordering the page already states once at the top. Both are
-- gone; a line with no conditions now says nothing at all rather than a sentence of pure filler.
-- Dropping the verb also settles D2.4 outright: a trinket line can no longer claim to be "cast".
-- Still the SAME wording layer as everything else on this page (`Conditions.summary`/`wordCtx`) --
-- never a second vocabulary, or the read-only template pages and this editor would drift apart the
-- first time either changed. `index` is no longer a parameter: nothing left here depends on where
-- the line sits, and existing callers passing it are harmless in Lua.
function Rotation.headerSentence(entry)
  if entry.disabled then return L["Switched off."] end
  if #(entry.when or {}) == 0 then return "" end
  return Rotation.conditionSummary(entry)
end

-- ---------------------------------------------------------------- Builder tab: panel bodies

-- R3 (D86): the key select reads the SPELLS REGISTRY, not the pack's raw table -- the one concrete
-- difference from R1's condition editor -- so a condition can name anything the character has
-- registered (by id, by name, from the spellbook) exactly as the palette can already append one.
-- PE3-D3 (2026-09-08 owner ruling, in-game): NO raw programmatic key may reach the Value dropdown.
-- It listed `CRUSADER_STRIKE_150`, `HOLY_POWER_CONSUME_HOLY`, `JUDICATOR_SOUL`, `SEAL_LINGER_6S` --
-- the same defect class as the "HOLY_SHOCK known" requirement rows PE1-D6 fixed in Setup/Detect.lua,
-- in a second file. The readable words already exist in the class data and none of them had to be
-- authored: a bonus carries `note` (the sentence Core/Gates.describe already speaks a gate with), a
-- set carries `name`, a soul carries `short`. `Detect.readableName` is the LAST resort -- reused,
-- never re-implemented, so a key with no readable source still reads as words.
--
-- Only a key that is WRITTEN like one gets prettified: a mode, a weapon kind and a creature type
-- are already display words ("AoE", "Shield", "Dragonkin") and the prettifier lower-cases before it
-- re-capitalises, so it would answer "Aoe" for the first of them. `COMBO_POINTS` and `MANA` are
-- programmatic and do want it.
local function looksProgrammatic(key)
  return key:find("_", 1, true) ~= nil or key == key:upper()
end

local function prettyKey(key)
  key = tostring(key) -- mutants: equivalent every caller resolves its key out of Core/Conditions' own lists, which are strings
  if not looksProgrammatic(key) then return key end
  if ns.Detect and ns.Detect.readableName then return ns.Detect.readableName(key, nil) end
  return key
end

-- "Soul of the Judicator", from the `short` the shoulder TOOLTIP is matched against
-- (Classes/Paladin.lua's `D.Souls`). Never `SOUL_OF_THE_JUDICATOR`, and never the prettifier's
-- "Soul Of The Judicator" either -- a soul is a thing the player goes and puts on their shoulders,
-- so it has to be spelled the way the enchant is.
local function soulLabel(key, soul)
  if soul and type(soul.short) == "string" then
    return string.format(L["Soul of the %s"], soul.short)
  end
  return prettyKey(key)
end

local function isSpellShaped(source)
  return source == "spells" or source == "seals" or source == "runes" or source == "castables"
end

local function keyLabel(source, key)
  -- Only the spell-shaped sources get a client name; a mode, a creature type or a power kind IS
  -- its own label, and running "AoE" through the spell lookup would answer "AoE" the long way.
  if isSpellShaped(source) then return Rotation.spellLabel(key) end
  local p = mergedPack()
  if source == "bonuses" then
    local bonus = p and p.bonuses and p.bonuses[key]
    if bonus and type(bonus.note) == "string" then return bonus.note end
  elseif source == "sets" then
    local set = p and p.sets and p.sets[key]
    if set and type(set.name) == "string" then return set.name end
  elseif source == "souls" then
    return soulLabel(key, p and p.souls and p.souls[key])
  end
  return prettyKey(key)
end

-- Where a bonus COMES FROM, as the tooltip on the Value dropdown -- the owner's words: it should
-- say which set bonus, or the shoulder soul enchant by name, because a soul is something a player
-- can simply go and equip. Both are named when a bonus has both sources (`from` is a list, and
-- ADR-0004 is explicit that a build gates on the effect and never on which source provided it).
-- nil when there is nothing to say, so a spell-shaped key keeps its own tooltip empty rather than
-- growing a line that repeats its label.
local function keySourceText(source, key)
  local p = mergedPack()
  if source == "souls" then
    local soul = p and p.souls and p.souls[key]
    if not soul then return nil end
    return string.format(L["From: %s"], string.format(L["%s, a shoulder enchant"],
                                                      soulLabel(key, soul)))
  end
  if source ~= "bonuses" then return nil end
  local bonus = p and p.bonuses and p.bonuses[key]
  if not (bonus and type(bonus.from) == "table") then return nil end
  local parts = {}
  for _, from in ipairs(bonus.from) do
    if from.set then
      local set = p.sets and p.sets[from.set]
      parts[#parts + 1] = string.format(L["the %s set, %d pieces"],
        (set and type(set.name) == "string" and set.name) or prettyKey(from.set), from.pieces or 2)
    elseif from.soul then
      parts[#parts + 1] = string.format(L["%s, a shoulder enchant"],
        soulLabel(from.soul, p.souls and p.souls[from.soul]))
    end
  end
  if #parts == 0 then return nil end
  return string.format(L["From: %s"], table.concat(parts, L[" or "]))
end

local function keyChoices(kind)
  local choices = {}
  local field = ns.Conditions.field(kind)
  local source = field and field.keySource
  for _, key in ipairs(ns.Conditions.keys(kind, mergedPack()) or {}) do
    choices[key] = keyLabel(source, key)
  end
  return choices
end

-- Does this field's key name something the Abilities tree can open a page for -- every spell-shaped
-- source, which is exactly the set `keyChoices` above already special-cases. Function name and the
-- `spells` group key it navigates to (below) are internal and unchanged by the M1b wording rename.
local function opensInSpells(source)
  return isSpellShaped(source)
end

local function conditionArgs(model, index)
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
        set = function(_, v) Rotation.setCondition(index, at, "category", v) end,
      }
      group.args.field = {
        type = "select", order = 2, width = 1.0, name = L["Field"], values = fields,
        get = function() return row.kind end,
        set = function(_, v) Rotation.setCondition(index, at, "kind", v) end,
      }
      group.args.negated = {
        type = "toggle", order = 3, width = 0.5, name = L["not"],
        desc = L["Passes when this condition does NOT hold."],
        get = function() return row.negated == true end,
        set = function(_, v) Rotation.setCondition(index, at, "negated", v and true or nil) end,
      }
      group.args.remove = {
        type = "execute", order = 4, width = 0.5, name = L["Remove"],
        func = function() Rotation.removeCondition(index, at) end,
      }
      if #field.ops > 1 then
        local ops = {}
        for _, one in ipairs(field.ops) do ops[one.id] = L[one.label] end
        group.args.op = {
          type = "select", order = 5, width = 1.0, name = L["Test"], values = ops,
          get = function() return op.id end,
          set = function(_, v) Rotation.setCondition(index, at, "op", v) end,
        }
      end
      if field.slotAt then
        local slots = {}
        for _, slot in ipairs(ns.Palette.EQUIPMENT_SLOTS) do
          -- AceConfig select keys must be strings; a numeric slot comes back from the widget as
          -- one and would never compare equal to the number the row holds.
          slots[tostring(slot)] = slotLabel(slot)
        end
        group.args.slot = {
          type = "select", order = 6, width = 0.9, name = L["Slot"], values = slots,
          get = function() return tostring(row.slot or "") end,
          set = function(_, v) Rotation.setCondition(index, at, "slot", tonumber(v)) end,
        }
      end
      if field.keySource then
        -- PE3-D4 (2026-09-08 owner ruling, in-game): its OWN row. At 1.1 widths it landed at the end
        -- of a row of shorter controls, and its label -- an AceGUI Dropdown hangs "Value" ABOVE its
        -- box, where a toggle and a button have nothing above theirs -- drew on top of the Field
        -- dropdown of the row before it. A "full" control takes a row to itself in Flow
        -- (AceGUI-3.0.lua:761-770), which puts the label back over its own box; it is also the width
        -- PE3-D3 now needs, since a bonus's label is a whole sentence rather than a key.
        group.args.key = {
          type = "select", order = 7, width = "full", name = L["Value"],
          values = keyChoices(row.kind),
          desc = function() return keySourceText(field.keySource, row.key) end,
          get = function() return row.key end,
          set = function(_, v) Rotation.setCondition(index, at, "key", v) end,
        }
        -- D86: a link from the condition straight to that spell's own page in the Abilities tree
        -- (M1b: player-facing wording only -- the "spells" group key it selects is unchanged).
        if opensInSpells(field.keySource) then
          group.args.openSpell = {
            type = "execute", order = 7.5, width = 1.0,
            name = function()
              return row.key and string.format(L["%s in Abilities >"], Rotation.spellLabel(row.key))
                or L["in Abilities >"]
            end,
            desc = L["Opens this spell's page in the Abilities tree."],
            disabled = function() return row.key == nil end,
            func = function()
              if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
                -- AB1-D11: `spells > list > <key>` -- the entries live in an inner tree now.
                ns.Options.dialog:SelectGroup("Elmira", "spells", "list", row.key)
              end
            end,
          }
        end
      end
      if op.arg == "number" then
        group.args.amount = {
          type = "input", order = 8, width = 0.6, name = L[op.unit or "Amount"],
          get = function() return tostring(row.value or "") end,
          set = function(_, v) Rotation.setCondition(index, at, "value", tonumber(v) or 0) end,
        }
      end
      args["c" .. at] = group
    end
  end
  return args
end

-- The whole `when` list in one sentence, for a nested line (never edited, owner decision
-- 2026-09-05) and for a read-only template's body alike.
local function wholeDescribe(entry)
  local whole = { "all" }
  for i, cond in ipairs(entry.when or {}) do whole[i + 1] = cond end
  return ns.Conditions.describe(whole, wordCtx())
end

-- R3 (D84): the panel's body -- hidden until the header's expander opens it. Read-only on a
-- template (words only, no controls, matching R1's read-only page); a full editor on a fork, unless
-- the stored shape nests deeper than one all/any level, which is shown in words there too (owner
-- decision, 2026-09-05 -- editing nested rows is v1.1).
-- No nil-entry guard: `panelGroup` is the only caller, and it is only ever built for an index
-- `Rotation.listRows()` just walked -- a guard here could not fail and would be a line no test
-- can reach (tasks/lessons.md -- a guard that cannot fail is not a guard).
local function bodyArgs(index, editable)
  local model, entry = Rotation.paneModel(index)
  local args, a = {}, 0

  if not editable then
    a = a + 1
    args.words = { type = "description", order = a, width = "full", fontSize = "medium",
                   name = #model.rows == 0 and L["always"] or wholeDescribe(entry) }
    return args
  end

  a = a + 1
  args.on = {
    type = "toggle", order = a, width = 0.5, name = L["On"],
    desc = L["Switches this line off without removing it. Discard puts it back."],
    get = function() return not entry.disabled end,
    set = function(_, v) Rotation.setRowDisabled(index, not v) end,
  }

  if model.complex then
    a = a + 1
    args.words = { type = "description", order = a, width = "full", fontSize = "medium",
                   name = wholeDescribe(entry) }
    a = a + 1
    args.note = {
      type = "description", fontSize = "medium", order = a, width = "full",
      name = L["This line's conditions are nested more deeply than the editor draws, so they are "
              .. "shown here rather than offered for editing. They run exactly as written."],
    }
    return args
  end

  -- No `match`/`conditions` group at all while there are no rows: an inline group with nothing in
  -- it is empty AceConfig data (nothing a widget can draw), and "fires when every condition
  -- passes" reads oddly about a line that has none -- "always" already says that, in `words` above
  -- for a template and needing no equivalent here, since an unconditional line's sentence (D85)
  -- already says "is cast when it is ready"/"...the above is not applicable".
  if #model.rows > 0 then
    a = a + 1
    args.match = {
      type = "select", order = a, width = 1.0, name = L["This line fires when"],
      values = { all = L["every condition passes"], any = L["any condition passes"] },
      get = function() return model.match end,
      set = function(_, v) Rotation.setMatch(index, v) end,
    }
    a = a + 1
    args.conditions = { type = "group", inline = true, order = a, name = "",
                        args = conditionArgs(model, index) }
  end
  a = a + 1
  local adds = {}
  for _, cat in ipairs(ns.Conditions.CATEGORIES) do adds[cat.fields[1]] = L[cat.label] end
  args.add = {
    type = "select", order = a, width = 1.2, name = L["Add a condition"],
    desc = L["Adds a condition from this group; change the exact field on the new row."],
    values = adds,
    get = function() return nil end,
    set = function(_, v) Rotation.addCondition(index, v) end,
  }
  return args
end

-- R3 (D84): one panel per line -- a header that is always visible (expander, number, status dot,
-- the in-place spell/item select or its read-only label, the sentence, then the tools) and a body
-- (above) whose `hidden` reads the UI-only expand flag, never the build.
local function panelGroup(row, entry, editable)
  local i = row.index
  local group = { type = "group", inline = true, order = i, name = "", args = {} }
  local expanded = Rotation.isExpanded(i)
  local mark = headerMark(i)
  local pointer = expanded and "|cffC08CF0>|r " or ""

  group.args.expand = {
    type = "execute", order = 1, width = 0.25, name = expanded and "-" or "+",
    desc = expanded and L["Collapse this line."] or L["Show this line's conditions."],
    func = function() Rotation.toggleExpand(i) end,
  }
  group.args.num = { type = "description", order = 2, width = 0.2, fontSize = "medium",
                     name = tostring(i) }
  -- PE2-D1: the state's own sentence rides on the expander, the one control on the row that can
  -- actually show a tooltip -- a `description` becomes an AceGUI Label, which never fires OnEnter.
  -- `desc` is still set on the mark itself so the data travels with the widget if it ever changes.
  group.args.status = { type = "description", order = 3, width = 0.2, fontSize = "medium",
                        name = mark.mark, desc = mark.desc }
  group.args.expand.desc = group.args.expand.desc .. "\n\n" .. mark.mark .. " " .. mark.desc

  if editable then
    -- PE2-D2.2: no label. "Ability" was repeated above all fifteen dropdowns and the dropdown's own
    -- contents already say what it holds.
    group.args.spell = {
      type = "select", order = 4, width = 1.0, name = "",
      values = Rotation.actionChoices(entry),
      get = function() return encodeAction(entry) end,
      set = function(_, v) Rotation.setLineAction(i, v) end,
    }
  else
    local icon = row.spell and ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(row.spell)
    local prefix = icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
    group.args.spell = { type = "description", order = 4, width = 1.0, fontSize = "medium",
                         name = prefix .. row.label }
  end

  -- The tools: only on a fork. On a template they are absent rather than present-and-dead, because
  -- a control that silently does nothing is worse than one not offered.
  --
  -- PE2-D2.1: widths were 0.25/0.25/0.4, which AceGUI drew as `...`, `...`, `Remo...` -- controls
  -- that worked and that nobody could identify. `width` is a multiple of 170px
  -- (AceConfigDialog-3.0.lua:49), so 0.25 is 42px, less than the button's own padding leaves for a
  -- word. Top/Bottom join them: ItemRack and Rotation Master both ship the four together.
  if editable then
    group.args.top = { type = "execute", order = 5, width = 0.4, name = L["Top"], disabled = row.first,
                       desc = L["Moves this line to the top of the rotation."],
                       func = function() Rotation.moveRowTo(i, 1) end }
    group.args.up = { type = "execute", order = 6, width = 0.4, name = L["Up"], disabled = row.first,
                       desc = L["Moves this line one place up the rotation."],
                       func = function() Rotation.moveRow(i, -1) end }
    group.args.down = { type = "execute", order = 7, width = 0.4, name = L["Down"], disabled = row.last,
                         desc = L["Moves this line one place down the rotation."],
                         func = function() Rotation.moveRow(i, 1) end }
    group.args.bottom = { type = "execute", order = 8, width = 0.5, name = L["Bottom"], disabled = row.last,
                           desc = L["Moves this line to the bottom of the rotation."],
                           func = function()
                             local d = Rotation.draft()
                             if d then Rotation.moveRowTo(i, #d.entries) end
                           end }
    -- The counterpart to click-to-append. Without it a mis-clicked palette icon can only be undone
    -- by discarding every other edit in the draft.
    group.args.remove = {
      type = "execute", order = 9, width = 0.6, name = L["Remove"],
      desc = L["Takes this line out of the draft. Discard puts it back."],
      func = function() Rotation.removeRow(i) end,
    }
  end

  -- PE2-D2.3: the condition summary, and NOTHING at all when the line has no conditions -- an empty
  -- full-width description would still reserve a blank row, which is the filler this decision
  -- removes. Its own row, below the controls, because the summary is about all of them.
  local sentence = Rotation.headerSentence(entry)
  if sentence ~= "" then
    group.args.sentence = {
      type = "description", order = 20, width = "full", fontSize = "medium",
      name = pointer .. mark.colour .. sentence .. "|r",
    }
  end

  -- PE2-D2.5: a TITLED inline group, so the opened body is a bordered box that unmistakably begins
  -- below the row rather than a borderless SimpleGroup the eye reads as more of the same flow row --
  -- which is why the owner reported "the collapse button is not working" when the accordion was
  -- doing exactly what it should. The spacer above it forces the row break regardless of what the
  -- controls before it happened to leave free.
  group.args.gap = { type = "description", order = 29, width = "full", name = " ",
                     hidden = function() return not Rotation.isExpanded(i) end }
  group.args.body = {
    type = "group", inline = true, order = 30, name = L["Conditions"],
    hidden = function() return not Rotation.isExpanded(i) end,
    args = bodyArgs(i, editable),
  }
  return group
end

local function listArgs()
  local rows, _, editable = Rotation.listRows()
  if #rows == 0 then
    return { none = { type = "description", fontSize = "medium", order = 1, width = "full",
                      name = L["This rotation has no lines yet."] } }
  end
  local entries = builderEntries()
  local args = {}
  for _, row in ipairs(rows) do
    args["r" .. row.index] = panelGroup(row, entries[row.index], editable)
  end
  return args
end

-- R3 (D87): "1 line needs attention" at the top of the page -- counts RED panels only, since grey
-- and amber are both, by D73's own ruling, normal: nothing to fix and nothing but a clock ticking.
function Rotation.attentionCount()
  local entries = builderEntries()
  if not entries then return 0 end
  local n = 0
  for i in ipairs(entries) do
    if Rotation.lineState(i) == "red" then n = n + 1 end
  end
  return n
end

-- ---------------------------------------------------------------- Builder tab: the draft header

local function editArgs()
  local d = Rotation.draft()
  if not d then return nil end
  local problems = Rotation.problems()
  -- PE4-D1: every control on this row is `width = "relative"` and the four `relWidth`s sum to
  -- exactly 1.0, so the status text takes the left 40% and the three buttons sit as one group
  -- against the RIGHT edge -- the same mechanism as PE1-D1's header row, and it works for the same
  -- reason: AceConfigDialog honours relWidth on a CONTROL (:1444-1452), which all four of these are.
  local cantSave = (not d.dirty) or #problems > 0
  local cantReset = not Rotation.canReset()
  local args = {
    state = {
      type = "description", order = 1, width = "relative", relWidth = 0.4, fontSize = "medium",
      name = d.dirty
        and string.format(L["Editing %s - unsaved changes"], Rotation.displayName(d.key))
        or string.format(L["Editing %s - saved"], Rotation.displayName(d.key)),
    },
    save = {
      type = "execute", order = 2, width = "relative", relWidth = 0.2,
      name = actionLabel(BUTTON_COLOURS.save, L["Save"], cantSave),
      desc = L["Writes the draft to your rotation and repaints the display."],
      disabled = cantSave,
      func = function() Rotation.save() end,
    },
    discard = {
      type = "execute", order = 3, width = "relative", relWidth = 0.2,
      name = actionLabel(BUTTON_COLOURS.discard, L["Discard"], not d.dirty),
      desc = L["Throws the draft away and goes back to your saved rotation."],
      disabled = not d.dirty,
      func = function() Rotation.discard() end,
    },
    -- PE4-D1: no `confirm`. Reset writes the DRAFT, so Discard undoes it and nothing is destroyed
    -- until Save -- a popup here would be asking permission for something already reversible.
    reset = {
      type = "execute", order = 4, width = "relative", relWidth = 0.2,
      name = actionLabel(BUTTON_COLOURS.reset, L["Reset"], cantReset),
      desc = L["Puts the original template's lines back. Nothing is saved until you press Save."],
      disabled = cantReset,
      func = function() Rotation.resetToTemplate() end,
    },
  }
  for i, line in ipairs(problems) do
    args["p" .. i] = { type = "description", fontSize = "medium", order = 4 + i, width = "full",
                       name = "|cffE8A33D" .. line .. "|r" }
  end
  -- PE2-D4.4: order 0 -- the status line and the two buttons that act on it belong at the TOP of the
  -- page, not floating mid-page above the list where Save was easy to miss entirely.
  return { type = "group", inline = true, order = 0, name = "", args = args }
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

-- R3 (D88, the owner's decision C, 2026-09-07): compiles the DRAFT -- never touching Display's real
-- queue, never announcing, never glowing a bar -- and runs the exact same depth-N pick the display
-- would (`Core/Simulation.queue`), so the preview is what the draft would actually suggest rather
-- than a guess about it. `ns.Schema.compile` directly, not the cached `ns.compileBuild`: that cache
-- is keyed on the build TABLE's identity, and a fresh `{ entries = ... }` wrapper is built on every
-- call here, which would only ever grow the cache -- correctness over a cache hit that could never
-- have landed anyway on a table this session never sees twice.
local function draftBuildTable(d)
  local p = pack()
  return { schema = ns.Schema.VERSION, key = d.key, name = Rotation.displayName(d.key),
           class = p and p.class, entries = d.entries }
end

-- Rotation.previewQueue() -> queue | nil, reason
--
-- D94 (2026-09-07 in-game round): a half-built rotation legitimately fails to compile -- that is
-- the normal state while someone is editing -- and `Schema.compile` logs to chat on every
-- validation failure (a real diagnostic for load-time pack failures, D26). Calling it on every
-- draft change spammed "build 'USER_TEST' failed validation" two or three times per keystroke.
-- `Schema.validate` never logs, so it answers "does this compile, and why not" first; `Schema.compile`
-- only runs once validation has already passed, at which point it cannot fail and cannot log.
function Rotation.previewQueue()
  local d = draft
  if not (d and ns.Schema and ns.Schema.compile and ns.Schema.validate) then
    return nil, L["This draft does not compile."]
  end
  local built = draftBuildTable(d)
  local ctx = wordCtx()
  local valid, errors = ns.Schema.validate(built, ctx)
  if not valid then
    local first = errors and errors[1]
    return nil, (first and first.message) or L["This draft does not compile."]
  end
  local compiled = ns.Schema.compile(built, ctx)
  -- compiled cannot be nil: Schema.compile is a pure, deterministic re-run of Schema.validate above
  -- over the identical build/ctx, which just returned ok.
  if not compiled then return nil, L["This draft does not compile."] end -- mutants: equivalent see above
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  if not (state and ns.Simulation and ns.Simulation.queue) then
    return nil, L["No character to preview against right now."]
  end
  local ok, queue = pcall(ns.Simulation.queue, compiled, state, (profile().depth) or 3, {})
  if not ok then return nil, L["This draft could not be simulated."] end
  return queue
end

-- Rotation.previewLines() -> the preview strip, worded exactly like `mirrorLines` above it -- one
-- vocabulary for "what would this suggest", whether it is the saved rotation or the unsaved draft.
function Rotation.previewLines()
  if not draft then return {} end
  local queue, reason = Rotation.previewQueue()
  if not queue then
    return { string.format(L["Preview of unsaved changes: %s"], reason) }
  end
  if #queue == 0 then
    return { L["Preview of unsaved changes: nothing would be suggested."] }
  end
  local parts = {}
  for i, shown in ipairs(queue) do
    local icon = shown.spell and ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(shown.spell)
    parts[#parts + 1] = string.format("%s%d. %s",
      icon and ("|T" .. tostring(icon) .. ":0|t ") or "", i, actionName(shown))
  end
  return { string.format(L["Preview of unsaved changes: %s"], table.concat(parts, "   ")) }
end

-- PE2-D4.3: only while the draft is actually dirty. Headed "(unsaved)" next to a status line reading
-- "saved", restating the five spells "Right now" had just listed, it was three ways of saying the
-- same thing and one of them was wrong.
local function previewArgs()
  local d = Rotation.draft()
  if not (d and d.dirty) then return nil end
  local args = {}
  for i, line in ipairs(Rotation.previewLines()) do
    args["v" .. i] = { type = "description", fontSize = "medium", order = i, width = "full",
                       name = line }
  end
  return { type = "group", inline = true, order = 2, name = L["Preview (unsaved)"], args = args }
end

-- R3 (D87): "1 line needs attention" above the panels -- present only while something actually
-- needs it, the same absent-when-clean idiom `diagnosticArgs` below already uses.
local function attentionArgs(order)
  local n = Rotation.attentionCount()
  if n == 0 then return nil end
  local text = (n == 1) and L["1 line needs attention."]
    or string.format(L["%d lines need attention."], n)
  return { type = "description", order = order, width = "full", fontSize = "medium",
           name = ns.Colors.wrap(ns.Colors.BAD, text) }
end

local function builderArgs()
  local _, _, editable = Rotation.listRows()
  return {
    -- The strip, mirrored at the top of the Builder, so the list and the queue are seen together
    -- (ADR-0015 amendment). It is first because it is the thing being explained: the status column
    -- below only means anything against the queue that is actually on screen.
    mirror = { type = "group", inline = true, order = 1, name = L["Right now"],
               args = mirrorArgs() },
    -- D88: the draft's own preview, beside the live strip -- absent entirely when there is no draft
    -- (a template, or nothing active), so it never implies an edit is in progress when none is.
    preview = previewArgs(),
    intro = {
      type = "description", order = 2.5, width = "full", fontSize = "medium",
      name = editable
        and L["Your rotation, top to bottom: the first line that can fire is the one suggested."]
        or L["This is a template, so it cannot be edited. Customize it on the Rotations tab to get a copy that can."],
    },
    editing = editArgs(),
    attention = attentionArgs(3.5),
    list = { type = "group", inline = true, order = 4, name = L["Rotation"], args = listArgs() },
    -- PE2-D3.3: the page-level `search` box is gone -- it now lives inside the Abilities group, whose
    -- rows are the only thing it ever filtered.
    -- M1b: this section lists candidates FROM the Abilities registry -- wording only, the `spells`
    -- key stays (Options.builder.args.spells, tests, etc. all key off it).
    spells = { type = "group", inline = true, order = 7, name = L["Abilities"],
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
-- AB2-D5: "include ability settings". Off by default -- a rotation string is what people paste at
-- each other, and quietly sending your glow colours and sounds with it is not what "share this
-- rotation" means. On, the string carries the settings of every ability the rotation names, and the
-- receiving side applies them when it imports the rotation (Core/UserBuilds.importString).
local shareAbilities = false -- mutants: equivalent deleting the local only makes it a global; luacheck catches it

function Rotation.setShareAbilities(on) shareAbilities = on and true or false end
function Rotation.shareAbilities() return shareAbilities end

-- Rotation.exportSelected() -> true | false
--
-- The rotation-side export (AB2-D5). Fills the same box `/elm export` fills, for whichever rotation
-- the page is showing -- the one thing the Share tab could not do before was produce a string.
function Rotation.exportSelected()
  local key = Rotation.selected()
  if not (key and ns.UserBuilds and ns.Options) then return false end
  local extra = nil -- mutants: equivalent deleting the local only makes it a global; luacheck catches it
  if shareAbilities and ns.SpellsPage and ns.SpellsPage.bundle and ns.Spells then
    local build = ns.UserBuilds.find(pack(), key)
    if build then extra = ns.SpellsPage.bundle(ns.Spells.referencedKeys(build)) end
  end
  local str, err = ns.UserBuilds.exportKey(pack(), key, extra)
  if not str then
    ns.Options.setExchangeText("")
    ns.Options.noteExchange(string.format(L["Export failed: %s"], tostring(err)))
    return false
  end
  ns.Options.setExchangeText(str)
  ns.Options.noteExchange(string.format(L["Exported %s -- copy the text above."],
                                        Rotation.displayName(key)))
  return true
end

local function shareArgs()
  return {
    export = {
      type = "execute", order = 0.1, width = "relative", relWidth = 0.5,
      name = L["Export This Rotation"],
      desc = L["Puts the rotation you are looking at into the box below, as a string to copy."],
      func = function() Rotation.exportSelected() end,
    },
    abilities = {
      type = "toggle", order = 0.2, width = "relative", relWidth = 0.5,
      name = L["Include ability settings"],
      desc = L["Sends the glow, screen-edge, sound and announcement settings of every ability this "
            .. "rotation names along with it."],
      get = function() return Rotation.shareAbilities() end,
      set = function(_, v) Rotation.setShareAbilities(v) end,
    },
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

-- ---------------------------------------------------------------- the root page (D30-D36, PD1/PD2)
--
-- PD2 (2026-09-10): a playstyle's or a rotation's content is rendered exactly ONCE, in the shared
-- detail area under the cards (`detailArgs`). The per-template tree pages, and the fork pages that
-- used to nest inside them, are deleted -- so the only nodes the left-hand menu shows under
-- Rotations are Builder and Share, and everything from here to `rotationTreeArgs` builds a piece of
-- that one root page.

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
-- key yet -- is SHOWN, muted, wherever its name appears, and its detail area says why in words.
-- `disabled = true` on the card would have been the obvious flag and is exactly the wrong one: it
-- takes away the click, and the detail is the answer to the question the muted name asks.
local function mutedIfUnavailable(row, text)
  if row.available then return text end
  return ns.Colors.wrap(ns.Colors.MUTED, text)
end

local function templateLabel(row)
  return mutedIfUnavailable(row, row.playstyle)
end

-- PA10 (2026-09-08): `detection.class`/`pack.class` are the WoW class TOKEN, all caps
-- (Adapters/Vanilla.lua's `Vanilla.playerClass`, `select(2, UnitClass("player"))`) -- used verbatim
-- elsewhere as a LOOKUP key (`p.catalog[p.class]`, `UserBuilds`'s own class filter), so neither is
-- changed at the source; this is a display-only fix, applied only where a token is actually turned
-- into a sentence. A naive "upper-case the first letter" gsub alone is a no-op on an all-caps token
-- ("PALADIN" already has an upper-case first letter) -- the rest must be lowered too.
local function classDisplay(token)
  if type(token) ~= "string" or token == "" then return token end
  return token:sub(1, 1):upper() .. token:sub(2):lower()
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
--
-- PB3 (2026-09-08, owner's second look): the label used to swap to "Use this anyway" whenever
-- `failing` was true, but on a character that fails at least one check on EVERY non-active
-- playstyle (this owner's own case: no runes engraved anywhere yet), every card showed the caveat
-- wording at once, which reads as a blanket warning rather than a signal about any one row. The
-- label is plain `L["Use"]` in every case now; the confirm dialog already names the actual failing
-- requirement (`reason`, below) and is where a warning belongs -- a button label is not the place.
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
    -- PE5-D1/D2: relative, so both header rows (and only they read this width) right-align as one
    -- group. PE5-D3: green -- switching rotation is the primary positive action of this whole page,
    -- and it is what the player came here to do. Never `disabled` (hard rule 8), so the label needs
    -- no disabled case; the card widget's own Use button takes this same string.
    type = "execute", order = order, width = "relative", relWidth = BUTTON_REL,
    name = actionLabel(BUTTON_COLOURS.use, L["Use"]),
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

-- PE1-D3 ---------------------------------------------------------------------------------------
--
-- At 1200px the shared detail area starts below two rows of cards and "Your rotations", i.e. off
-- the bottom of the window -- so clicking a card appeared to do nothing at all and players never
-- found the panel. The fix is to nudge the page's own scroll bar just far enough to bring the
-- detail panel's HEADER on screen, and not one pixel further: never scroll the whole panel into
-- view, never centre it, and never move at all when the header is already visible.
--
-- The arithmetic is this pure function; the frame walking below it is thin glue. `nil` means "do
-- not move" and must reach `SetScroll` as NO CALL, not as `SetScroll(current)`.
--
-- Units: AceGUI's ScrollFrame takes 0-1000 and maps that across `content:GetHeight() -
-- scrollframe:GetHeight()` (AceGUIContainer-ScrollFrame.lua:59-76), so one scroll unit is
-- `range/1000` pixels; a HIGHER value scrolls DOWN, which moves the content up and every screen-
-- space `GetTop()` down by the same amount. `range <= 0` is the branch `SetScroll` itself special-
-- cases (offset 0, nothing scrolls), so there is nothing to do on a page shorter than its viewport.
local SCROLL_MAX = 1000

local function clampScroll(value)
  if value < 0 then return 0 end
  if value > SCROLL_MAX then return SCROLL_MAX end
  return value
end

function Rotation.detailScrollValue(m)
  local range = m.contentHeight - m.viewHeight
  if range <= 0 then return nil end
  local headerBottom = m.detailTop - m.headerHeight
  if headerBottom < m.viewBottom then
    -- Below the viewport: scroll down exactly enough to sit the header's bottom on the bottom edge.
    return clampScroll(m.scroll + (m.viewBottom - headerBottom) / range * SCROLL_MAX)
  elseif m.detailTop > m.viewTop then
    -- Above it (the player was scrolled past a tall detail panel): back up to the top edge.
    return clampScroll(m.scroll + (m.viewTop - m.detailTop) / range * SCROLL_MAX)
  end
  -- Already fully visible. Falling off the end here is deliberate: it answers nil with no statement
  -- of its own, which is what "do not move" has to mean at the call site -- no SetScroll at all.
end

-- AceConfigDialog creates exactly ONE ScrollFrame per page (AceConfigDialog-3.0.lua:1635-1646) and
-- it is the only widget of that type anywhere under the dialog's frame, so a depth-first walk of the
-- AceGUI child tree finds it without any knowledge of how many containers wrap it.
local function findScrollFrame(widget)
  if widget.type == "ScrollFrame" then return widget end
  for _, child in ipairs(widget.children or {}) do
    local found = findScrollFrame(child)
    if found then return found end
  end
end

-- `args.detail` is the LAST element on the root page (everything ordered after it is a tree
-- SUB-page, not content here -- rotationTreeArgs, and the spec that pins that ordering), so it is
-- the last child of the scroll's content; its own first child is the header row this reveals.
-- Writing the status table through the widget's own `SetScroll` is the supported path: `FixScroll`
-- re-applies `status.offset` on the next update (ScrollFrame:91), which moving `content` by hand
-- would fight.
local function scrollDetailIntoView()
  local dialog = ns.Options and ns.Options.dialog
  local root = dialog and dialog.OpenFrames and dialog.OpenFrames["Elmira"]
  local scroll = root and findScrollFrame(root)
  if not (scroll and scroll.SetScroll) then return end
  local children = scroll.children or {}
  local detail = children[#children]
  local header = detail and detail.children and detail.children[1]
  if not header then return end
  local view = scroll.scrollframe
  local top, headerBottom = detail.frame:GetTop(), header.frame:GetBottom()
  local contentHeight, viewHeight = scroll.content:GetHeight(), view:GetHeight()
  local viewTop, viewBottom = view:GetTop(), view:GetBottom()
  -- A frame the client has not laid out yet answers nil to every one of these; there is nothing to
  -- compute against, and guessing a zero would scroll the page somewhere arbitrary.
  if not (top and headerBottom and contentHeight and viewHeight and viewTop and viewBottom) then return end
  local status = scroll.status or scroll.localstatus or {}
  local value = Rotation.detailScrollValue({
    scroll = status.scrollvalue or 0, contentHeight = contentHeight, viewHeight = viewHeight,
    viewTop = viewTop, viewBottom = viewBottom, detailTop = top, headerHeight = top - headerBottom,
  })
  if value then scroll:SetScroll(value) end
end

-- PD1-D2 (2026-09-08): a card body click SELECTS the rotation for the shared detail area now,
-- rather than navigating to a separate page (the previous `navigateTo` helper this replaces is gone
-- -- PD1-D2 was its only caller, and the fork page's own Edit button, unlike this comment's own
-- predecessor once claimed, has always called `SelectGroup` directly rather than through it).
-- `dialog:Open("Elmira")` afterwards is still needed and still BARE (no path): a card's raw
-- `OnMouseUp` (CardWidget.lua) sits outside AceConfigDialog's own `ActivateControl`, which is what
-- gives every NATIVE control (an execute button, a slider) a synchronous refresh for free right
-- after its own `func` runs (PB5, 2026-09-08: without this, `Rotation.select`'s new value would sit
-- unseen until the dialog's own next unrelated redraw). Two things this must NOT do, both because
-- this file has been burned by them before:
--   * Never route through `Options.Open` (the D61e wrapper): a path-less `Options.Open()` forces
--     `SelectGroup("Elmira", "general")` when it has no path arguments of its own (D61e, so
--     `/elm config` with no path always lands on General) -- routing THIS through it would send
--     every card click to General. `ns.Options.dialog` IS AceConfigDialog itself
--     (`Options.dialog = AceConfigDialog`, Options.lua), so this calls the library directly.
--   * This is NOT the D20 "second Open with a path" bug: D20's Open call CARRIED a path, which
--     replaces the window's whole root (and the left menu with it, AceConfigDialog-3.0.lua
--     ~1897-1930). This Open call is BARE -- no path, no container -- exactly the shape the
--     range-slider/execute-button refresh already uses (Options.lua's own D13 comment), which
--     re-feeds the SAME already-selected group rather than replacing the root. The re-decorate hook
--     this triggers (`installRefreshHook`, Options.lua) is idempotent under repeated `Open` calls
--     already -- every execute-type option in this file already exercises it, once per click.
local function selectCard(key)
  return function()
    Rotation.select(key)
    local dialog = ns.Options and ns.Options.dialog
    if dialog and dialog.Open then dialog:Open("Elmira") end
    scrollDetailIntoView()
  end
end

-- PE1-D1: "Level 60 Paladin · 1H · SoD P8" -- one header row that says what this character is and
-- which phase the catalog below is for, replacing the old sentence (class named twice, plus a "Pick
-- how you want to play:" instruction the six clickable cards under it already make).
--
-- Every segment is OMITTED when it cannot be read, never printed as "?" or "unknown": the previous
-- version rendered "Level ? ?, holding a unknown" on a character the adapter had not answered for
-- yet, which states nothing and looks broken. Level and class share ONE segment so a readable level
-- with an unreadable class still reads as a sentence ("Level 60") rather than a dangling "?".
--
-- `Elmira/Setup/Wizard.lua:200` keeps the OLD sentence and its own L key: there it is the wizard's
-- opening instruction, where an instruction belongs. This line gets its own keys.
local function detectionLine(detection, phase)
  local segments = {}
  local level = detection and detection.level
  -- PA10: the class TOKEN reads as shouting ("Level 60 PALADIN"); classDisplay only ever touches a
  -- genuine token, never a fallback.
  local class = detection and detection.class and classDisplay(detection.class)
  if level and class then
    segments[#segments + 1] = string.format(L["Level %s %s"], tostring(level), tostring(class))
  elseif level then
    segments[#segments + 1] = string.format(L["Level %s"], tostring(level))
  elseif class then
    segments[#segments + 1] = tostring(class)
  end
  local weapon = detection and detection.weapon and detection.weapon.type
  if weapon then segments[#segments + 1] = tostring(weapon) end
  if phase then segments[#segments + 1] = tostring(phase) end
  return table.concat(segments, " · ")
end

-- W1 (2026-09-07, owner pass on branch try/card-widget, may be discarded): AceConfig's own inline
-- GROUPS can never share a row -- AceConfigDialog-3.0.lua:1131-1142 forces `GroupContainer.width =
-- "fill"` on every one, which is what made D69's cards (the ORIGINAL of this function, an inline
-- group per row) stack one to a line no matter how narrow each was told to be. A plain CONTROL
-- honours `width = "relative"` + `relWidth` instead (AceConfigDialog-3.0.lua:1444-1452), and a
-- `dialogControl` is created as a control (CreateControl, :1093) -- so a single custom widget
-- (Options/CardWidget.lua) is what lets three of these sit on one row. This function now BUILDS
-- the card's content as plain data (title/summary/meta/source/actions) and hands it to that widget
-- through `arg`, rather than nesting AceGUI controls of its own the way D69 did.
--
-- Wraps `useButtonArgs`'s own reason/confirm logic rather than re-deriving it (ONE place decides
-- whether a row can run) -- but resolves `confirm` into the ACTUAL popup itself before handing the
-- card its `func`, because the widget's own buttons are plain frames CardWidget.lua draws, never fed
-- through AceConfigDialog's FeedOptions loop, so AceConfigDialog's own `confirm`/`confirmText`
-- fields (read only by its internal ActivateControl, :661-829) would otherwise be silently ignored.
local function confirmThen(text, fn)
  return function()
    -- PB1: routed through `ns.Popups.show` like every other popup in the addon, so this dialog
    -- raises above the options panel too -- the exact bug the owner hit here (D-list PB1).
    if not ns.Popups.show("ELMIRA_CONFIRM", text, nil, { onAccept = fn }) then fn() end
  end
end

-- PA5 (2026-09-08, PROVISIONAL): catalog `playstyle` is one prose string today ("Exodin -- fast 2H,
-- single seal (Ret)"), so the card's short title is that string split at the FIRST em-dash and
-- trimmed. This is a stopgap until a later pass adds real catalog fields (a short name and a
-- one-line subtitle) -- when it does, this split goes away and the card reads those fields directly.
-- Splits the RAW playstyle text, never `templateLabel`'s already-muted-wrapped output: the muted
-- wrap is a `|cff..|r` colour escape, and splitting a string that already contains one at an
-- arbitrary character would sever the escape from its own closing `|r`.
local function splitPlaystyle(text)
  if type(text) ~= "string" then return text, nil end
  local short, rest = text:match("^(.-)%s*—%s*(.*)$")
  if not short or short == "" then return text, nil end
  return short, rest
end

-- PA6/PA7/PA8: difficulty as filled/empty PIPS plus a normal-weight label -- deliberately
-- uncoloured (green/amber/grey already mean something else on this page, D43's need-marks; PA6
-- is explicit that pips must not teach a second meaning with the same colours).
--
-- PA6 CORRECTION (2026-09-08, owner catch): the pips were first built as `●`/`○` characters in a
-- string, which tasks/lessons.md already recorded as a settled fact from an earlier in-game round
-- -- this client's font draws BOTH as identical empty boxes, making every difficulty tier look the
-- same. CardWidget.lua now draws the pips itself as real Texture objects (a texture renders where a
-- font glyph does not, the same reason the `|T...|t` spell icons work); this file's job shrinks to
-- handing over a plain LEVEL NUMBER and a label string, never a pre-rendered glyph string.
local DIFFICULTY_PIPS = { easy = 1, medium = 2, hard = 3 }
local DIFFICULTY_LABEL_KEY = { easy = "Easy", medium = "Medium", hard = "Hard" }

local function difficultyLabel(difficulty)
  local key = DIFFICULTY_LABEL_KEY[difficulty]
  return key and L[key] or nil
end

-- PA5/PA8: the full playstyle prose and the exact "updated" date move off the card face and into
-- its mouseover tooltip -- nil when there is nothing beyond the short title to say, so a playstyle
-- with no em-dash and no `updated` field does not get a tooltip that only repeats its own title.
local function cardTooltip(row, restOfName)
  local lines = {}
  if restOfName then lines[#lines + 1] = row.playstyle end
  if row.updated then lines[#lines + 1] = string.format(L["updated %s"], tostring(row.updated)) end
  if #lines == 0 then return nil end
  return table.concat(lines, "\n")
end

-- D70: `row.difficulty` used to join the meta line as a coloured word; PA6 moves it to its own pip
-- line instead (`arg.difficultyLevel`/`arg.difficultyLabel`). D71:
-- the meta line no longer ends in the source host -- "updated 2026-08-30 · wowhead" read as if the
-- WOWHEAD PAGE were updated that day, when the date is ours (PA8 moves the exact date to the
-- tooltip entirely; PE1-D2 then takes the phase off the card too, back up to the page header).
-- PA7: "experimental" conflated two different things -- unproven and hard to execute;
-- difficulty now carries execution, so this flag carries PROVENANCE instead.
--
-- PB4 (2026-09-08, owner correcting their own PA7 wording): "Theorycraft -- no published guide" was
-- a FALSE claim -- every `experimental` catalog entry ships a `source`, Shockadin's is a published
-- Wowhead guide (six phases stale, but it exists), and Seal twisting/stacking's `source` points at a
-- gear guide, not a rotation guide, which is a different problem than "no guide". The catalog does
-- not (yet) carry a field for how CURRENT a source is, so this flag makes no claim about a guide's
-- existence at all -- it renders as the neutral `L["Unproven"]`.
--
-- Actions are keyed (`open`/`use`), not positional: a row that skips `use` must not shift whatever
-- follows into the slot `use` would have used, which a plain array would have done silently.
-- PA4: "open" is kept as a keyed action (same `func` as always) even though the card no longer
-- draws a button for it -- CardWidget.lua wires it to the card BODY's own click instead.
local function templateCard(row, order, selectedBuild)
  local shortName, restOfName = splitPlaystyle(row.playstyle)
  local title = mutedIfUnavailable(row, shortName)
  -- PD1-D2: the card body SELECTS the rotation for the shared detail area now, rather than
  -- navigating to a separate page.
  local actions = { open = { name = L["Open"], func = selectCard(row.build) } }

  local use = useButtonArgs(1, row.build, row.active, row.checks, unavailableReason(row))
  if use then
    actions.use = { name = use.name, desc = use.desc,
                    func = use.confirm and confirmThen(use.confirmText or use.name, use.func) or use.func }
  end

  -- PE1-D2: no phase here any more -- after D1 the page header states it once, where six cards
  -- used to repeat it. What is left (recommended/Unproven) FOLDS ONTO the difficulty line, muted,
  -- so the card reads "▪▫▫ Easy · recommended" and gives the meta line back.
  local bits = {}
  if row.recommended then bits[#bits + 1] = L["recommended"] end
  if row.experimental then bits[#bits + 1] = L["Unproven"] end
  local label = difficultyLabel(row.difficulty)
  local meta = ""
  if label then
    -- The pips and the difficulty word stay normal weight; only the suffix is muted.
    if #bits > 0 then
      label = label .. ns.Colors.wrap(ns.Colors.MUTED, " · " .. table.concat(bits, " · "))
    end
  else
    -- No pips on this card (no catalog difficulty), so there is no line to fold onto: the bits stay
    -- where they were rather than being dropped to fit the layout.
    meta = ns.Colors.wrap(ns.Colors.MUTED, table.concat(bits, " · "))
  end

  -- PE1-D2: no `link` action. The detail panel's own Copy Source Link button is the one place a
  -- player copies a guide URL from, and dropping this makes every card in BOTH grids uniform --
  -- body click plus Use, nothing else. `applyButton` already skips a missing keyed action without
  -- shifting the slot beside it.

  -- Three across at the Panel's default width (relWidth 0.32, verified against
  -- AceConfigDialog-3.0.lua's own width block -- NOT verified on screen, see the PA report).
  return {
    type = "description", order = order, width = "relative", relWidth = 0.32,
    dialogControl = "ElmiraCard", fontSize = "medium",
    -- The Label CreateControl falls back to (AceConfigDialog-3.0.lua:1093-1104) if the widget never
    -- registered -- an install missing Options/CardWidget.lua must still say SOMETHING, not render
    -- an empty line where a card used to be.
    name = row.summary and row.summary ~= "" and (title .. "\n" .. row.summary) or title,
    arg = {
      title = title, summary = row.summary or "",
      difficultyLevel = DIFFICULTY_PIPS[row.difficulty], difficultyLabel = label,
      meta = meta, active = row.active == true, unavailable = not row.available,
      -- PD1-D5: the persistent-brightening state, orthogonal to active/unavailable (a card can be
      -- both selected and in use at once).
      selected = row.build == selectedBuild,
      tooltip = cardTooltip(row, restOfName), actions = actions,
    },
  }
end

-- PD1-D4: "Your rotations" -- one ElmiraCard per fork (`Rotation.forkRows()`), the SAME widget and
-- width as a template card, three across. No difficulty pips (forks carry no catalog difficulty) and
-- no `link` action -- a fork has no source URL of its own, and `applyButton` (CardWidget.lua) already
-- skips a missing action rather than shifting the slot beside it.
local function forkCard(row, order, selectedBuild)
  local actions = { open = { name = L["Open"], func = selectCard(row.build) } }
  local use = useButtonArgs(1, row.build, row.active, {})
  if use then
    actions.use = { name = use.name, desc = use.desc,
                    func = use.confirm and confirmThen(use.confirmText or use.name, use.func) or use.func }
  end
  -- The same "copied from X"/"yours" line the fork's own page header shows (`forkHeaderArgs`).
  local summary = row.derivedFrom
    and string.format(L["copied from %s"], Rotation.displayName(row.derivedFrom)) or L["yours"]
  local bits = {}
  if row.private then bits[#bits + 1] = L["Private"] end
  local meta = ns.Colors.wrap(ns.Colors.MUTED, table.concat(bits, " · "))
  return {
    type = "description", order = order, width = "relative", relWidth = 0.32,
    dialogControl = "ElmiraCard", fontSize = "medium",
    name = row.name .. "\n" .. summary,
    arg = {
      title = row.name, summary = summary, meta = meta,
      active = row.active == true, selected = row.build == selectedBuild, actions = actions,
    },
  }
end

-- D33's header row: name (gold, badged) · in use/Use · Copy and edit.
local function templateHeaderArgs(row)
  local a, args = 0, {}
  local use = useButtonArgs(2, row.build, row.active, row.checks, unavailableReason(row))
  -- PE5-D1: the name takes whatever the buttons leave. `Copy and Edit` is always there; `Use` is
  -- not, and the row it is missing from is the template the player is already running.
  local buttons = WIDE_BUTTON_REL + (use and BUTTON_REL or 0)
  a = a + 1
  -- Gold for a playstyle that runs, muted for one that cannot yet -- `templateLabel` carries its
  -- own colour, so the highlight is only applied to the ones it left plain.
  args.name = { type = "description", order = a, width = "relative", relWidth = 1.0 - buttons,
                fontSize = "medium",
                name = row.available and ns.Colors.wrap(ns.Colors.HIGHLIGHT,
                                                        nameWithBadge(row.playstyle, row.active))
                    or nameWithBadge(templateLabel(row), row.active) }
  if use then a = a + 1; args.use = use end
  a = a + 1
  -- PE4-D4: purple, because it navigates -- it takes you off this template and into your own copy.
  args.copy = { type = "execute", order = a, width = "relative", relWidth = WIDE_BUTTON_REL,
                name = actionLabel(BUTTON_COLOURS.copyEdit, L["Copy and Edit"]),
                desc = L["Makes your own editable copy of this template, under a name you choose."],
                func = function() Rotation.openCopyPopup(row.build, row.playstyle) end }
  return { type = "group", inline = true, order = 1, name = "", args = args }
end

-- D33's explanation: the catalog's own summary/notes, a muted difficulty/updated line, then the
-- source on its own line with a Copy link button -- the SAME split `templateCard` got (D71,
-- 2026-09-07): the detail area is where the card's own body click (PA4) lands, so leaving it
-- concatenated ("updated 2026-08-30 · wowhead", read as if the WOWHEAD PAGE were updated that day)
-- would mean the fix only half-landed and the owner hits the other half on the very next click.
-- D70's `difficulty: <word>` phrasing stays here as PLAIN TEXT deliberately -- PA6 (2026-09-08)
-- turns the CARD's own difficulty into pips instead, but the detail area has room for the word, and
-- rewriting it to match the card's pips is a separate, not-yet-decided owner call.
-- Recommended/experimental are catalog-sort hints already reflected by this playstyle's position
-- among the cards, not new information the detail area needs to restate.
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
    args.source = { type = "description", order = a, width = 1.4, fontSize = "medium",
      name = ns.Colors.wrap(ns.Colors.MUTED, string.format(L["Source: %s"], sourceHost(row.source))) }
    a = a + 1
    -- PE1-D7: after D2 removed the cards' own link buttons this is the ONLY copy-link button left,
    -- and D3 lands the player here, reading the button before the "Source:" label beside it -- so it
    -- says what it copies. An AceGUI button CLIPS text rather than growing, so the row is rebalanced
    -- 1.4/0.8 to fit the longer label.
    args.link = { type = "execute", order = a, width = 0.8, name = L["Copy Source Link"],
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
    -- PE1-D5: the ability's own icon before its name, the SAME mechanism `lineRowsArgs` uses one
    -- block down (D72) -- `check.key` is a spell/rune key, which `Display.spellIcon` resolves
    -- through the merged registry and the ADAPTER; this module never calls the WoW API itself and
    -- this adds no new call site of its own. A weapon/speed/set check, or any key that resolves to
    -- nothing, gets NO icon AND NO GAP: `prefix` is "" and the concatenation leaves no second space.
    local icon = check.key and ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(check.key)
    local prefix = icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
    args["n" .. a] = { type = "description", order = a, width = "full", fontSize = "medium",
                        name = needMark(check.ok) .. " " .. prefix .. check.text }
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
--
-- PE5-D2: `Edit` joins them, in the order Use · Edit · Rename · Delete -- most-wanted first,
-- destructive last. It used to sit at the very BOTTOM of the fork's page (`forkBodyArgs`), below the
-- whole rotation listing, so reaching the one button the owner most wants meant scrolling past
-- everything else on the page.
local function forkHeaderArgs(row)
  local a, args = 0, {}
  local use = useButtonArgs(3, row.build, row.active, {})
  -- PE5-D2, as in `templateHeaderArgs`: the buttons that are ACTUALLY present decide what is left
  -- for the name -- `Use` is absent on the fork already running, which is the page most looked at.
  local buttons = BUTTON_REL * 3 + (use and BUTTON_REL or 0) -- Edit, Rename, Delete (+ Use)
  a = a + 1
  args.name = { type = "description", order = a, width = "relative",
                relWidth = 1.0 - FROM_REL - buttons, fontSize = "medium",
                name = ns.Colors.wrap(ns.Colors.BRAND, nameWithBadge(row.name, row.active)) }
  a = a + 1
  local from = row.derivedFrom
    and string.format(L["copied from %s"], Rotation.displayName(row.derivedFrom)) or L["yours"]
  args.from = { type = "description", order = a, width = "relative", relWidth = FROM_REL,
                fontSize = "medium",
                name = ns.Colors.wrap(ns.Colors.MUTED, from) }
  if use then a = a + 1; args.use = use end
  a = a + 1
  -- PE5-D2/D3: purple, because it navigates -- it takes you off this page and into the Builder.
  -- D44's behaviour is unchanged by the move: it activates the fork first, and a failure to
  -- activate says why AND stops, rather than opening the Builder on a different rotation.
  args.edit = { type = "execute", order = a, width = "relative", relWidth = BUTTON_REL,
    name = actionLabel(BUTTON_COLOURS.edit, L["Edit"]),
    desc = L["Opens this rotation in the Builder."],
    func = function()
      if not row.active then
        local ok, err = Rotation.use(row.build)
        if not ok then announceFailure(err); return end
      end
      if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
        ns.Options.dialog:SelectGroup("Elmira", "rotation", "builder")
      end
    end }
  a = a + 1
  args.rename = { type = "execute", order = a, width = "relative", relWidth = BUTTON_REL,
    name = L["Rename"],
    func = function() Rotation.openRenamePopup(row.build, row.name) end }
  a = a + 1
  -- PE4-D4: red, because it throws work away once and globally -- unlike the per-row `Remove`,
  -- which stays gold: fifteen red words down the edge of the Builder would shout the one action
  -- nobody is looking for.
  args.delete = { type = "execute", order = a, width = "relative", relWidth = BUTTON_REL,
    name = actionLabel(BUTTON_COLOURS.delete, L["Delete"]),
    confirm = true, confirmText = L["Delete this rotation? This cannot be undone."],
    func = function() Rotation.remove(row.build) end }
  return { type = "group", inline = true, order = 1, name = "", args = args }
end

-- PD1-D3/PD2-D2: a fork's own content -- header, private toggle, the stale-parent diff, its lines
-- and the Edit button. `detailArgs` on the root page is its one caller: since PD2 the shared detail
-- area is the only place a fork's content is drawn at all.
local function forkBodyArgs(row)
  local args = {}
  args.header = forkHeaderArgs(row)

  -- F1b (2026-09-07 bug round, owner's decision over plain class-wide): default off, so every
  -- character of the class sees this fork until someone here says otherwise -- and seeing this row
  -- at all already means the viewer is allowed to (a fork private to someone else never appears in
  -- `forkRows`, so it has neither a card nor a detail area for anyone but its owner).
  args.private = {
    type = "toggle", order = 1.5, width = "full",
    name = L["Only this character can see this rotation"],
    desc = L["Off: every character of your class can see and use it. On: only this one can."],
    get = function() return row.private == true end,
    set = function(_, v) Rotation.setPrivate(row.build, v) end,
  }

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
  -- PE5-D2: `Edit` is NOT here any more -- it is in `forkHeaderArgs` at the top of the block, where
  -- it does not need the whole rotation listing scrolled past first. Its behaviour (D44's
  -- activate-then-navigate, and stop with a reason when activation fails) moved with it unchanged.
  return args
end

-- PD1-D3/PD2-D2: a template's own content -- header, explanation, needs and lines. `detailArgs` on
-- the root page is its one caller; the forks are not nested in here, because the root page already
-- lists them as its own "Your rotations" cards.
local function templateBodyArgs(row)
  local args = {}
  args.header = templateHeaderArgs(row)
  args.about = templateExplainArgs(row, 2)
  args.needs = { type = "group", inline = true, order = 3, name = L["What this rotation needs"],
                 args = needsArgs(row) }
  args.lines = { type = "group", inline = true, order = 4, name = L["Rotation, top to bottom"],
                 args = lineRowsArgs(row.build) }
  return args
end

-- PD1-D3: the shared detail area -- whichever card was last clicked (`Rotation.select`), the active
-- rotation, or the first template (`Rotation.selected()`'s own fallback order). PD2-D2: it is the
-- ONLY caller of `templateBodyArgs`/`forkBodyArgs`, and so the only rendering of either -- delete a
-- row from one of those builders and it leaves the addon. Returns nil when `key` names neither a
-- template nor a fork row -- in particular when `key` is nil (`Rotation.selected()` itself answered
-- nil, a class with no shipped pack and no forks), since a row's own `build` is never nil, so
-- neither loop below ever matches one -- letting the caller omit `args.detail` entirely rather than
-- render an empty box.
--
-- PE1-D4: the BOX is titled `Details`, not the build's name. `templateBodyArgs`/`forkBodyArgs`
-- already open with a header carrying that name and its "· in use" badge, so titling the box with
-- it printed the identical string twice, one line under the other. A stable landmark
-- is also the better target for D3's scroll: the thing that appears at the screen edge should be
-- something a player learns to look for, not a name that changes with every card they click.
local function detailArgs(key)
  for _, row in ipairs(Rotation.templateRows()) do
    if row.build == key then
      return { type = "group", inline = true, name = L["Details"], args = templateBodyArgs(row) }
    end
  end
  for _, row in ipairs(Rotation.forkRows()) do
    if row.build == key then
      return { type = "group", inline = true, name = L["Details"], args = forkBodyArgs(row) }
    end
  end
  return nil -- mutants: equivalent Lua returns nil implicitly at the end of a function
end

-- D30/PD2-D1: the section's own args -- intro/detection/New rotation, the cards, the shared detail
-- area, and then the only two nodes the left-hand menu still shows under Rotations: Builder and
-- Share. No playstyle and no rotation of your own is a menu entry any more.
local function rotationTreeArgs()
  local args, a = {}, 0
  local detection = ns.Wizard and ns.Wizard.detection and ns.Wizard.detection()
  local rows = Rotation.templateRows()

  -- PE1-D1: ONE header row -- the detection line and the New Rotation button side by side. Both are
  -- CONTROLS, which is the whole reason this works: AceConfigDialog honours `width = "relative"` +
  -- `relWidth` on a control (:1444-1452) and flows two of them onto one row, while an inline
  -- GROUP is forced to `width = "fill"` (:1131-1142) and could never share a line. That is also why
  -- the button cannot sit on the playstyles box's own title bar -- AceGUI draws that as part of the
  -- frame border, not as a container anything can be added to.
  a = a + 1
  args.detection = { type = "description", order = a, width = "relative", relWidth = 0.72,
                      fontSize = "medium",
                      name = detectionLine(detection, rows[1] and rows[1].phase) }
  a = a + 1
  args.newRotation = { type = "execute", order = a, width = "relative", relWidth = 0.28,
    name = L["New Rotation"],
    desc = L["Starts empty; add lines from your own spellbook in the Builder."],
    func = function() Rotation.openNewRotationPopup() end }

  local forkRowsAll = Rotation.forkRows()
  -- PD1-D1/D3/D4: the shared detail area and the "Your rotations" cards both need to know which
  -- card is currently selected -- computed once here, rather than once per card, though
  -- `Rotation.selected()` is a standalone public function any future caller may also reach for on
  -- its own.
  local selectedBuild = Rotation.selected()

  -- The pack's own `class`, not `detection.class`: this sentence names what the CATALOG is for, and
  -- a class with a data pack but no readable detection (Adapter/Detect not wired, or a spec that
  -- fakes only `Wizard.choices`) must not say "?" about a class it plainly knows. PA10: whichever
  -- source answers, `classDisplay` runs on the TOKEN only, never on the `L["your class"]` prose
  -- fallback (which classDisplay would otherwise mid-sentence-capitalise wrongly).
  local p = pack()
  if #rows == 0 then
    a = a + 1
    local className = (p and p.class and classDisplay(p.class))
      or (detection and detection.class and classDisplay(detection.class)) or L["your class"]
    args.noPack = { type = "description", order = a, width = "full", fontSize = "medium",
      name = string.format(
        L["No playstyles for %s yet. Build your own: New rotation, then add spells from your spellbook."],
        className) }
  else
    local cardArgs = {}
    for i, row in ipairs(rows) do
      cardArgs["card" .. i] = templateCard(row, i, selectedBuild)
    end
    -- PA11: a titled, bounded region for the cards, rather than a loose description line above them.
    -- AceConfigDialog feeds an inline group's own `content` through the same "Flow" layout as a root
    -- page (AceConfigDialog-3.0.lua:1634/1143), so the cards still flow/wrap exactly as before, just
    -- inside a named box now. NOTE: this does not scroll on its own -- AceConfigDialog builds ONE
    -- ScrollFrame per PAGE (:1640), and an inline group just sizes to fit its content
    -- (AceGUIContainer-InlineGroup.lua:31-33).
    -- PE1-D1: the title is the short `L["Playstyles"]` now -- the class and the phase both moved up
    -- into the merged header row, and repeating the class a third time on this box is what made the
    -- old title read as noise.
    a = a + 1
    args.playstyles = { type = "group", inline = true, order = a, name = L["Playstyles"],
                        args = cardArgs }
  end

  -- PD1-D4: "Your rotations" -- one card per fork, immediately after the playstyle cards. Omitted
  -- entirely when there are none, not rendered as an empty box (the `newRotation` execute above is
  -- already the discovery path for a class with nothing to show here yet).
  if #forkRowsAll > 0 then
    local forkCardArgs = {}
    for i, forkRow in ipairs(forkRowsAll) do
      forkCardArgs["card" .. i] = forkCard(forkRow, i, selectedBuild)
    end
    a = a + 1
    args.yourRotations = { type = "group", inline = true, order = a, name = L["Your rotations"],
                            args = forkCardArgs }
  end

  -- PD1-D3: the shared detail area, below every card grid, above Builder -- omitted entirely when
  -- `Rotation.selected()` answers nil (a class with no shipped pack and no forks; `args.noPack`
  -- above already speaks to that case).
  local detail = detailArgs(selectedBuild)
  if detail then
    a = a + 1
    detail.order = a
    args.detail = detail
  end

  args.builder = { type = "group", order = 9000, name = L["Builder"], args = builderArgs() }
  args.share = { type = "group", order = 9001, name = L["Share"], args = shareArgs() }
  return args
end

-- ---------------------------------------------------------------- the section

function Rotation.group()
  return {
    -- M1a (2026-09-07 menu-order pass): 2 of the owner's 1-8 top-level order, right after General.
    type = "group", order = 2, name = L["Rotations"], childGroups = "tree",
    args = rotationTreeArgs(),
  }
end

ns.Rotation = Rotation
return Rotation
