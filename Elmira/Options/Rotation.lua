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
    args["t" .. i] = {
      type = "description", order = i, width = "full",
      name = string.format("%s |cffFFFFFF%s|r  |cff9AA0A6%s|r", mark, row.playstyle,
                           table.concat(tags, " · ")),
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
      builder = {
        type = "group", order = 2, name = L["Builder"],
        args = {
          soon = {
            type = "description", order = 1, width = "full", fontSize = "medium",
            -- Says what it will do and that it does not do it yet. The alternative -- an empty tab,
            -- or one that looks interactive and is not -- is the failure this codebase keeps
            -- producing: something that looks right and does nothing.
            name = L["The rotation editor arrives in the next step. Until then, edit a rotation by "
                  .. "exporting it from Share, changing it, and importing it back."],
          },
        },
      },
      share = { type = "group", order = 3, name = L["Share"], args = shareArgs() },
    },
  }
end

ns.Rotation = Rotation
return Rotation
