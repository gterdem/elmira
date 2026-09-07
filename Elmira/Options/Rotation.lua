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

-- ---------------------------------------------------------------- Rotations tab

-- What you are running, where it came from, and whether its parent has moved on since you forked.
-- Returned as lines rather than as one string so a spec can assert on them individually and so the
-- panel can style them separately later.
function Rotation.statusLines()
  local key, running, reason = activeState()
  if not key then return { L["No rotation is active yet."] } end
  if not running then
    -- Saying "Running:" here would be the panel's headline stating a falsehood. The key IS
    -- selected; the rotation is not going, and the reason is the only useful thing to show.
    return { string.format(L["%s is selected, but could not be loaded: %s"],
                           Rotation.displayName(key), tostring(reason or "unknown error")) }
  end

  local p = pack()
  local _, origin, fork = findBuild(p, key)
  local lines = { string.format(L["Running: %s"], Rotation.displayName(key)) }

  if origin ~= "fork" or not fork then return lines end

  local parent = fork.derivedFrom
  if not parent then
    lines[#lines + 1] = L["Yours, not derived from a template."]
    return lines
  end
  lines[#lines + 1] = string.format(L["Yours, forked from %s."], Rotation.displayName(parent))

  -- ADR-0010: detect a template that has been updated by a release since the fork was taken, and
  -- offer a diff — never an automatic rebase, because the whole point of a fork is that the user's
  -- edits win. The diff itself is F35, in a later step; saying it happened is useful on its own.
  local updated = Rotation.templateUpdatedAt(parent)
  if updated and fork.derivedAt and tostring(updated) > tostring(fork.derivedAt) then
    lines[#lines + 1] = string.format(
      L["%s has been updated since you forked it (%s, yours is from %s)."],
      Rotation.displayName(parent), tostring(updated), tostring(fork.derivedAt))
    -- ADR-0010: a diff, never a rebase. Naming the rows is what makes the banner actionable
    -- instead of merely worrying.
    for _, line in ipairs(Rotation.parentDiffLines()) do lines[#lines + 1] = line end
  end
  return lines
end

-- The catalog's `updated` date for a template key. Delegated, never re-derived: Core/UserBuilds is
-- what stamps `derivedAt` from this same answer, and two copies drift into a banner that quietly
-- stops appearing.
function Rotation.templateUpdatedAt(key)
  if not (ns.UserBuilds and ns.UserBuilds.catalogUpdated) then return nil end
  return ns.UserBuilds.catalogUpdated(pack(), key)
end

-- A key a person can read. Catalog entries carry a playstyle name; forks carry the name the user
-- typed; anything else falls back to the key, because a blank row is worse than an ugly one.
function Rotation.displayName(key)
  if type(key) ~= "string" then return "?" end
  local p = pack()
  for _, entry in ipairs((p and p.catalog and p.catalog[p.class]) or {}) do
    if entry.build == key and entry.playstyle then return entry.playstyle end
  end
  local _, origin, fork = findBuild(p, key)
  if origin == "fork" and fork and fork.name then return fork.name end
  return key
end

-- The class's catalog entries, read-only, in the order the wizard already sorts them (recommended
-- first, then newest). Reused rather than re-derived: `Wizard.choices` is the one place that knows
-- an entry is only offerable when the pack actually ships the build it names.
function Rotation.templateRows()
  if not (ns.Wizard and ns.Wizard.choices) then return {} end
  local ok, rows = pcall(ns.Wizard.choices)
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

local function statusArgs()
  local args, order = {}, 0
  for _, line in ipairs(Rotation.statusLines()) do
    order = order + 1
    args["line" .. order] = {
      type = "description", order = order, width = "full", fontSize = "medium", name = line,
    }
  end
  return args
end

-- One row per template. ASCII marks, never glyphs: the client's font has no U+25CF/U+2714 and draws
-- every one of them as the same empty box, which is how the Action Bars panel first shipped a column
-- of identical squares (Options.lua's barRows carries the same note).
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
  -- to do nothing: the copy is on the Rotations tab either way.
  if ns.Wizard and ns.Wizard.apply then
    local ok, applyErr = ns.Wizard.apply(key)
    if not ok then return false, applyErr end
  end
  if ns.Display and ns.Display.refresh then ns.Display.refresh() end
  return true, key
end

local function templateArgs()
  local rows = Rotation.templateRows()
  if #rows == 0 then
    return { none = { type = "description", fontSize = "medium", order = 1, width = "full",
                      name = L["No templates ship for your class yet."] } }
  end
  local args = {}
  for i, row in ipairs(rows) do
    local mark = row.active and "|cff40c057>>|r" or "|cff9AA0A6--|r"
    local tags = {}
    if row.difficulty then tags[#tags + 1] = tostring(row.difficulty) end
    if row.updated then tags[#tags + 1] = tostring(row.updated) end
    if row.experimental then tags[#tags + 1] = L["experimental"] end
    if not row.fits then tags[#tags + 1] = L["needs gear or runes you do not have"] end
    local build = row.build
    args["t" .. i] = {
      type = "group", inline = true, order = i, name = "",
      args = {
        what = {
          type = "description", fontSize = "medium", order = 1, width = 1.7,
          name = string.format("%s |cffFFFFFF%s|r  |cff9AA0A6%s|r", mark, row.playstyle,
                               table.concat(tags, " · ")),
        },
        customize = {
          type = "execute", order = 2, width = 0.7, name = L["Customize"],
          desc = L["Makes your own editable copy of this template and switches to it."],
          func = function() Rotation.customize(build) end,
        },
      },
    }
  end
  return args
end

local function forkArgs()
  local rows = Rotation.forkRows()
  if #rows == 0 then
    return { none = { type = "description", fontSize = "medium", order = 1, width = "full",
                      name = L["You have not made a rotation of your own yet."] } }
  end
  local args = {}
  for i, row in ipairs(rows) do
    local mark = row.active and "|cff40c057>>|r" or "|cff9AA0A6--|r"
    local from = row.derivedFrom
      and string.format(L["from %s"], Rotation.displayName(row.derivedFrom))
      or L["not from a template"]
    args["f" .. i] = {
      type = "description", fontSize = "medium", order = i, width = "full",
      name = string.format("%s |cffFFFFFF%s|r  |cff9AA0A6%s|r", mark, row.name, from),
    }
  end
  return args
end

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

-- Palette.spells is pure and takes the client-shaped parts as arguments; this is where they come
-- from. `known` is tri-state and stays that way: nil means the client cannot tell, and rendering
-- that as "you do not have it" would grey the whole palette on a flavour without engraving.
function Rotation.paletteSpells()
  if not ns.Palette then return {} end
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  local rows = ns.Palette.spells(pack(), {
    label = Rotation.spellLabel,
    known = state and state.known and function(key) return state:known(key) end or nil,
  })
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

local function spellPaletteArgs(editable)
  local rows = Rotation.paletteSpells()
  if #rows == 0 then
    return { none = { type = "description", fontSize = "medium", order = 1, width = "full",
                      name = L["Nothing matches."] } }
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
local function wordCtx()
  local p = pack()
  return { L = L, name = Rotation.spellLabel,
           spells = p and p.spells, sets = p and p.sets,
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
-- ADR-0015 (2026-09-04 amendment). Four states, and the distinction that matters is between the
-- two greys: a row whose conditions simply do not pass right now is the rotation working, while a
-- row that cannot fire for THIS character until they engrave something is news. Only the second
-- dims, or rows would flicker mid-fight and teach that the rotation is unstable.
--
-- ASCII markers, never glyphs. The client's font draws U+25CF and friends as identical empty boxes,
-- which is how a status column once shipped as a row of squares (tasks/lessons.md, 2026-09-04).
Rotation.MARKS = {
  firing   = { mark = ">>", colour = "|cff40c057" },
  blocked  = { mark = "!!", colour = "|cffE8A33D" },
  waiting  = { mark = "..", colour = "|cff9AA0A6" },
  off      = { mark = "--", colour = "|cff9AA0A6" },
  unsaved  = { mark = "++", colour = "|cff9AA0A6" },
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
    name = string.format("%s%s|r %s  |cff9AA0A6%s|r", look.colour, look.mark, status.text, trailer),
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

-- ---------------------------------------------------------------- the section

function Rotation.group()
  return {
    type = "group", order = 0, name = L["Rotation"], childGroups = "tab",
    args = {
      rotations = {
        type = "group", order = 1, name = L["Rotations"],
        args = {
          status = { type = "group", inline = true, order = 1, name = L["Right now"],
                     args = statusArgs() },
          templates = { type = "group", inline = true, order = 2, name = L["Class templates"],
                        args = templateArgs() },
          note = {
            type = "description", fontSize = "medium", order = 3, width = "full",
            name = L["Templates are read-only. Customize one to get a copy you can edit."],
          },
          mine = { type = "group", inline = true, order = 4, name = L["Your rotations"],
                   args = forkArgs() },
        },
      },
      builder = { type = "group", order = 2, name = L["Builder"], args = builderArgs() },
      share = { type = "group", order = 3, name = L["Share"], args = shareArgs() },
    },
  }
end

ns.Rotation = Rotation
return Rotation
