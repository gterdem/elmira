-- Elmira/Options/Spells.lua — the Abilities page (R2, D52-D57; renamed from "Spells" for the
-- player at M1b, 2026-09-07 -- the module, the `spells` group key and every internal identifier
-- below are unchanged). A tree, ordered right after Rotations: one root page with the three add
-- rows, then one child page per registered entry.
--
-- Named `SpellsPage` rather than `ns.Spells`, deliberately: Core/Spells.lua already owns `ns.Spells`
-- for the pure registry (the CRUD this file drives), and Options/Rotation.lua sets the precedent for
-- an Options-layer module having its own name (`ns.Rotation`) beside the Core one it wires up
-- (`ns.Palette`). Two files sharing one filename ("Spells.lua" under Core/ and under Options/, the
-- way "Rotation.lua"/"Options.lua" do not) made picking a DIFFERENT ns key worth a comment.
--
-- Everything here is plain data and closures, like Options/Rotation.lua: a spec calls
-- `SpellsPage.group()` and drives a row's get/set directly, no AceConfig, no frame.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local SpellsPage = {}
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

local function pack()
  return ns.Display and ns.Display.currentPack and ns.Display.currentPack()
end

local function store()
  return ns.Spells and ns.Spells.store()
end

-- D52: player-added entries in BRAND colour, the same convention forks use in the Rotations tree
-- (Options/Rotation.lua's `templateLabel`/fork page name are the precedent) -- reused as a pattern,
-- not literally, since a fork's condition ("is this template runnable") and a spell entry's
-- ("did the player type this in themselves") are different questions over different data.
local function registryLabel(entry)
  if entry.source ~= "pack" then return ns.Colors.wrap(ns.Colors.BRAND, entry.name) end
  return entry.name
end

-- Every rotation this character can see -- shipped templates and their own forks alike -- paired
-- with the spell keys IT references (Core/Spells.referencedKeys), which is what both the "used by"
-- text and the removal guard read. Computed once per page build rather than once per entry: with N
-- entries and M rotations, walking each rotation once is O(M) instead of O(N*M).
local function allRotations(p)
  local out = {}
  if not (ns.Rotation and ns.Spells and ns.UserBuilds and ns.UserBuilds.find) then return out end
  for _, row in ipairs(ns.Rotation.templateRows()) do
    local build = ns.UserBuilds.find(p, row.build)
    if build then
      out[#out + 1] = { name = ns.Rotation.displayName(row.build), keys = ns.Spells.referencedKeys(build) }
    end
  end
  for _, row in ipairs(ns.Rotation.forkRows()) do
    local build = ns.UserBuilds.find(p, row.build)
    if build then out[#out + 1] = { name = row.name, keys = ns.Spells.referencedKeys(build) } end
  end
  return out
end

-- "used by A, B" or nil (never the D57 "not used by any rotation yet" fallback -- the two callers
-- want that worded differently: the root list omits the whole suffix when it's nil, the per-entry
-- page substitutes its own sentence).
local function usedByText(rotations, key)
  local used = ns.Spells.usedBy(rotations, key)
  if #used == 0 then return nil end
  return string.format(L["used by %s"], table.concat(used, ", "))
end

local function navigateToSpell(key)
  if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
    ns.Options.dialog:SelectGroup("Elmira", "spells", key)
  end
end

local function navigateToRoot()
  if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
    ns.Options.dialog:SelectGroup("Elmira", "spells")
  end
end

-- ---------------------------------------------------------------- D54: the three add rows

-- AceConfig `select` values are strings; the id round-trips through `tonumber`.
local pickSpellbookId, idText, nameText, nameError = nil, "", "", nil -- mutants: equivalent globals; luacheck catches it

-- I1a: item rows are 17px (`AceGUIWidget-DropDown-Items.lua:161`); 14 is the ceiling that still
-- sits inside the row against `GameFontNormalSmall`. One named constant so a size change is a
-- one-line edit; a judgement call for the owner to eyeball in game.
local SPELLBOOK_ICON_SIZE = 14

-- I1: `values` (id-as-string -> label) and `sorting` (id-as-string, ordered by NAME) for the
-- "From your spellbook" select. Both come from here so they can never disagree.
--
-- I1b: this is a standing bug, not just a risk the icons introduce (owner, in game: "the dropdown
-- abilities should be sorted by name as well, it is chaotic right now"). With no explicit `sorting`
-- table, AceConfigDialog hands the dropdown control `values` alone, and
-- `AceGUIWidget-DropDown.lua`'s own `SetList` (:592-606) then sorts the KEYS of that table itself
-- (`sortTbl`, :584-591: numeric compare when both keys look numeric, else `tostring`) -- and our
-- keys are `tostring(entry.id)`, so the list was always ordered by SPELL ID, never by name. Adding
-- an icon prefix to the label changes nothing about that; the fix is the same regardless: hand the
-- widget an explicit `sorting` array computed by name here, so ordering never depends on the key.
local function spellbookChoices()
  local out, rows = {}, {}
  if ns.Adapter and ns.Adapter.spellbookEntries then
    for _, entry in ipairs(ns.Adapter.spellbookEntries()) do
      local key = tostring(entry.id)
      -- I1c: resolved through the adapter (`Display.spellIconByID`), never a WoW API call from
      -- this file. No resolvable icon (or the adapter missing entirely) renders as the plain name,
      -- with no gap and no broken-texture box left behind.
      local icon = ns.Display and ns.Display.spellIconByID and ns.Display.spellIconByID(entry.id)
      out[key] = icon and string.format("|T%s:%d|t %s", icon, SPELLBOOK_ICON_SIZE, entry.name) or entry.name
      rows[#rows + 1] = { key = key, name = entry.name }
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  local sorting = {}
  for i, row in ipairs(rows) do sorting[i] = row.key end
  return out, sorting
end

local function spellbookAddArgs(order)
  local values, sorting = spellbookChoices()
  return {
    type = "group", inline = true, order = order, name = L["From your spellbook"],
    args = {
      pick = {
        type = "select", order = 1, width = 1.5, name = L["Spell"], values = values, sorting = sorting,
        get = function() return pickSpellbookId end,
        set = function(_, v) pickSpellbookId = v end,
      },
      add = {
        type = "execute", order = 2, name = L["Add"],
        desc = L["Registers the selected spell, or selects it if it is already registered."],
        func = function()
          local id = tonumber(pickSpellbookId)
          local name -- mutants: equivalent deleting the declaration only makes it a global; luacheck catches it
          for _, entry in ipairs((ns.Adapter and ns.Adapter.spellbookEntries and ns.Adapter.spellbookEntries()) or {}) do
            if entry.id == id then name = entry.name; break end
          end
          if not (id and name) then return end -- mutants: equivalent Spells.add's own id/name check refuses just as silently
          local key = ns.Spells.add(store(), { id = id, name = name, source = "spellbook" })
          if key then pickSpellbookId = nil; navigateToSpell(key) end
        end,
      },
    },
  }
end

local function idAddArgs(order)
  return {
    type = "group", inline = true, order = order, name = L["By ID"],
    args = {
      value = {
        type = "input", order = 1, width = 1.0, name = L["Spell ID"],
        get = function() return idText end,
        set = function(_, v) idText = v or "" end,
      },
      preview = {
        type = "description", order = 2, width = "full", fontSize = "medium",
        name = function()
          local id = tonumber(idText)
          if not (id and id > 0) then return "" end
          local name = ns.Adapter and ns.Adapter.spellNameByID and ns.Adapter.spellNameByID(id)
          if name then return string.format(L["Resolves to: %s"], name) end
          return ns.Colors.wrap(ns.Colors.BAD, L["Not found."])
        end,
      },
      add = {
        type = "execute", order = 3, name = L["Add"],
        func = function()
          local id = tonumber(idText)
          local name = id and ns.Adapter and ns.Adapter.spellNameByID and ns.Adapter.spellNameByID(id)
          -- D95 (2026-09-07 in-game round): the box clears after EVERY attempt, kept or refused --
          -- a "Not found" left sitting in the box read as if nothing had happened.
          idText = ""
          if not (id and name) then return end -- mutants: equivalent Spells.add's own id/name check refuses just as silently
          local key = ns.Spells.add(store(), { id = id, name = name, source = "id" })
          if key then navigateToSpell(key) end
        end,
      },
    },
  }
end

-- D54(c): the limitation is stated on the page unconditionally (`limitation`, always shown), and the
-- exact refusal text appears separately and ONLY after a failed attempt (`error`, hidden otherwise).
-- The refusal never calls `ns.Spells.add` -- nothing is stored on this path, ever.
local function nameAddArgs(order)
  return {
    type = "group", inline = true, order = order, name = L["By name"],
    args = {
      limitation = {
        type = "description", order = 1, width = "full", fontSize = "medium",
        name = ns.Colors.wrap(ns.Colors.MUTED,
          L["Only resolves a name this character has learned or seen; anything else is refused, not stored."]),
      },
      value = {
        type = "input", order = 2, width = 1.0, name = L["Spell name"],
        get = function() return nameText end,
        set = function(_, v) nameText = v or ""; nameError = nil end,
      },
      error = {
        type = "description", order = 3, width = "full", fontSize = "medium",
        hidden = function() return nameError == nil end,
        name = function() return nameError and ns.Colors.wrap(ns.Colors.BAD, nameError) or "" end,
      },
      add = {
        type = "execute", order = 4, name = L["Add"],
        func = function()
          local typed = nameText
          local id = ns.Adapter and ns.Adapter.spellIDByName and ns.Adapter.spellIDByName(typed)
          -- D95 (2026-09-07 in-game round): the box clears after EVERY attempt, kept or refused;
          -- the refusal message (nameError) is what stays visible, not the typed text.
          nameText = ""
          if not id then
            nameError = L["Not found: this character has not seen it. Try the ID."]
            return -- mutants: equivalent falling through calls Spells.add with a nil id, which
                   -- refuses on its own and never resets nameError either
          end
          local name = (ns.Adapter.spellNameByID and ns.Adapter.spellNameByID(id)) or typed
          local key = ns.Spells.add(store(), { id = id, name = name, source = "name" })
          if key then nameError = nil; navigateToSpell(key) end
        end,
      },
    },
  }
end

-- ---------------------------------------------------------------- D55/D56: the list and the guard

local function entryCard(entry, order, rotations)
  local suffix = usedByText(rotations, entry.key)
  local name = registryLabel(entry)
  if suffix then name = name .. "  " .. ns.Colors.wrap(ns.Colors.MUTED, "· " .. suffix) end
  return { type = "execute", order = order, width = "full", name = name,
           func = function() navigateToSpell(entry.key) end }
end

-- D56: a remove control exists only for a MANUALLY added entry (an automatic one is derived, never
-- owned -- see Core/Spells.remove's comment); even then, one still referenced says so instead of a
-- button, so the row always explains itself rather than failing silently on click.
local function removeArgs(entry, rotations, order)
  if entry.source == "pack" then return nil end
  local suffix = usedByText(rotations, entry.key)
  if suffix then
    return { type = "description", order = order, width = "full", fontSize = "medium",
      name = ns.Colors.wrap(ns.Colors.WARN, string.format(L["Still %s -- remove it there first."], suffix)) }
  end
  return {
    type = "execute", order = order, name = L["Remove"], confirm = true,
    confirmText = string.format(L["Remove %s from your Abilities list?"], entry.name),
    func = function()
      local ok = ns.Spells.remove(store(), entry.key, rotations)
      if ok then navigateToRoot() end
    end,
  }
end

local function entryPageGroup(entry, order, rotations)
  local sourceText -- mutants: equivalent deleting the declaration only makes it a global; luacheck catches it
  if entry.source == "pack" then
    sourceText = string.format(L["from the %s pack"], (pack() and pack().class) or "?")
  elseif entry.source == "spellbook" then sourceText = L["added from your spellbook"]
  elseif entry.source == "name" then sourceText = L["added by name"]
  else sourceText = L["added by ID"] end

  local args = {}
  args.source = { type = "description", order = 1, width = "full", fontSize = "medium",
    name = sourceText .. "  ·  " .. (usedByText(rotations, entry.key) or L["not used by any rotation yet"]) }
  args.cues = { type = "description", order = 2, width = "full", fontSize = "medium",
    name = ns.Colors.wrap(ns.Colors.MUTED, L["On-screen cues for this spell arrive in a later update."]) }
  local removeArg = removeArgs(entry, rotations, 3)
  if removeArg then args.remove = removeArg end
  return { type = "group", order = order, name = registryLabel(entry), args = args }
end

-- ---------------------------------------------------------------- the section

function SpellsPage.group()
  if ns.Rotation and ns.Rotation.syncSpells then ns.Rotation.syncSpells() end
  local p = pack()
  local rotations = allRotations(p)
  local rows = (ns.Spells and ns.Spells.list(store())) or {}

  local args, a = {}, 0
  a = a + 1
  args.intro = { type = "description", order = a, width = "full", fontSize = "medium",
    name = L["Every spell, buff or debuff a rotation or a cue can use. Abilities used by your"
      .. " rotations are listed automatically; add anything else here."] }
  a = a + 1; args.addSpellbook = spellbookAddArgs(a)
  a = a + 1; args.addId = idAddArgs(a)
  a = a + 1; args.addName = nameAddArgs(a)
  a = a + 1
  args.header = { type = "description", order = a, width = "full", fontSize = "medium",
    name = string.format(L["Registered · %d"], #rows) }
  for i, entry in ipairs(rows) do
    a = a + 1
    args["card" .. i] = entryCard(entry, a, rotations)
  end
  for i, entry in ipairs(rows) do
    args[entry.key] = entryPageGroup(entry, 1000 + i, rotations)
  end

  -- M1a: 3 of the owner's 1-8 top-level order, right after Rotations. M1b: the PLAYER-visible name
  -- is now "Abilities"; the group key stays `spells` (Options.Open("spells"), SelectGroup(...,
  -- "spells"), saved status-table entries and the module name `ns.SpellsPage` are all unchanged).
  return { type = "group", order = 3, name = L["Abilities"], childGroups = "tree", args = args }
end

ns.SpellsPage = SpellsPage
return SpellsPage
