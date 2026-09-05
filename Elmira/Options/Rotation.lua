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
    return { none = { type = "description", order = 1, width = "full",
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
          type = "description", order = 1, width = 1.7,
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
    return { none = { type = "description", order = 1, width = "full",
                      name = L["You have not made a rotation of your own yet."] } }
  end
  local args = {}
  for i, row in ipairs(rows) do
    local mark = row.active and "|cff40c057>>|r" or "|cff9AA0A6--|r"
    local from = row.derivedFrom
      and string.format(L["from %s"], Rotation.displayName(row.derivedFrom))
      or L["not from a template"]
    args["f" .. i] = {
      type = "description", order = i, width = "full",
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

local function spellPaletteArgs()
  local rows = Rotation.paletteSpells()
  if #rows == 0 then
    return { none = { type = "description", order = 1, width = "full",
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
    args["s" .. i] = { type = "description", order = i, width = "full", name = prefix .. body }
  end
  return args
end

local function itemPaletteArgs()
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
    args["i" .. i] = { type = "description", order = i, width = "full", name = prefix .. body }
  end
  return args
end

-- ---------------------------------------------------------------- Builder tab: the rotation list

-- The rows of the rotation you are editing, in priority order -- which IS the rotation: the first
-- entry that passes is the suggestion (F1), so the order is the thing being edited, not decoration.
--
-- Returns rows plus the key they came from and whether they can be edited. A template is read-only
-- (ADR-0005, hard rule 7), so its rows render without arrows and with the Customize banner instead.
function Rotation.listRows()
  local key = activeKey()
  local p = pack()
  local build, origin = findBuild(p, key)
  if not (build and build.entries) then return {}, key, false end
  local rows = {}
  for i, entry in ipairs(build.entries) do
    rows[#rows + 1] = {
      index = i,
      spell = entry.spell,
      item = entry.item,
      label = entry.spell and Rotation.spellLabel(entry.spell)
        or (entry.item and (L[SLOT_LABELS[entry.item] or ("Slot " .. entry.item)])) or "?",
      note = entry.label,
      disabled = entry.disabled and true or false,
      first = i == 1,
      last = i == #build.entries,
    }
  end
  return rows, key, origin == "fork"
end

-- One line saying what an entry waits for. The compiled condition labels are the authority --
-- Schema already builds one per top-level condition for the hover-why -- but the STORED build is
-- what the list shows, so this reads the raw `when` and says how many gates there are rather than
-- inventing a second description language that would drift from Schema's.
function Rotation.conditionSummary(entry)
  local n = #((entry and entry.when) or {})
  if n == 0 then return L["always"] end
  if n == 1 then return L["1 condition"] end
  return string.format(L["%d conditions"], n)
end

local function refresh()
  if ns.Display and ns.Display.refresh then ns.Display.refresh() end
end

local function listArgs()
  local rows, key, editable = Rotation.listRows()
  if #rows == 0 then
    return { none = { type = "description", order = 1, width = "full",
                      name = L["This rotation has no lines yet."] } }
  end

  local p = pack()
  local build = findBuild(p, key)
  local args = {}
  for _, row in ipairs(rows) do
    local i = row.index
    local group = { type = "group", inline = true, order = i, name = "", args = {} }
    local icon = row.spell and ns.Display and ns.Display.spellIcon
      and ns.Display.spellIcon(row.spell)
    local prefix = icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
    local colour = row.disabled and "|cff9AA0A6" or "|cffFFFFFF"

    group.args.what = {
      type = "description", order = 1, width = 1.6,
      name = string.format("%s%s%s|r  |cff9AA0A6%s|r", prefix, colour, row.label,
                           row.note or Rotation.conditionSummary(build and build.entries[i])),
    }
    -- Enable, arrows: only on a fork. On a template they are absent rather than present-and-dead,
    -- because a control that silently does nothing is worse than one that is not offered.
    if editable then
      group.args.on = {
        type = "toggle", order = 2, width = 0.5, name = L["On"],
        get = function() return not row.disabled end,
        set = function(_, v)
          ns.UserBuilds.setEntryDisabled(pack(), key, i, not v)
          refresh()
        end,
      }
      group.args.up = {
        type = "execute", order = 3, width = 0.35, name = L["Up"], disabled = row.first,
        func = function() ns.UserBuilds.moveEntry(pack(), key, i, -1); refresh() end,
      }
      group.args.down = {
        type = "execute", order = 4, width = 0.35, name = L["Down"], disabled = row.last,
        func = function() ns.UserBuilds.moveEntry(pack(), key, i, 1); refresh() end,
      }
    end
    args["r" .. i] = group
  end
  return args
end

local function builderArgs()
  local _, _, editable = Rotation.listRows()
  return {
    intro = {
      type = "description", order = 1, width = "full", fontSize = "medium",
      name = editable
        and L["Your rotation, top to bottom: the first line that can fire is the one suggested."]
        or L["This is a template, so it cannot be edited. Customize it on the Rotations tab to get a copy that can."],
    },
    list = { type = "group", inline = true, order = 2, name = L["Rotation"], args = listArgs() },
    search = {
      type = "input", order = 5, width = "full", name = L["Search"],
      get = function() return Rotation.search() end,
      set = function(_, v) Rotation.setSearch(v) end,
    },
    spells = { type = "group", inline = true, order = 6, name = L["Spells"],
               args = spellPaletteArgs() },
    items = { type = "group", inline = true, order = 7, name = L["Items"],
              args = itemPaletteArgs() },
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
      type = "description", order = 2,
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
            type = "description", order = 3, width = "full",
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
