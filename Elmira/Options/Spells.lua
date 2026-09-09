-- Elmira/Options/Spells.lua — the Abilities page (AB1, D1-D12; R2's D52-D57 rebuilt).
--
-- SHAPE (AB1-D1). `spells` is a TAB group with two children: "Abilities" (`list`) and "Share"
-- (`share`). `list` is itself a tree, and that inner tree exists only because its parent is a tab
-- group -- `FeedGroup`'s "assume tree group by default" branch builds a TreeGroup whenever the
-- PARENT is not one (AceConfigDialog-3.0.lua:1721), and `BuildSubGroups` refuses to recurse into a
-- tab group (:1031), which is what keeps the OUTER menu flat: one "Abilities" node, no ability
-- hanging off it. `list`'s own args -- the add panel and the filter row -- render ABOVE the inner
-- tree because `FeedOptions` runs before the child widget is added (:1653-1661).
--
-- Named `SpellsPage` rather than `ns.Spells`, deliberately: Core/Spells.lua already owns `ns.Spells`
-- for the pure registry (the CRUD this file drives), and Options/Rotation.lua sets the precedent for
-- an Options-layer module having its own name (`ns.Rotation`) beside the Core one it wires up.
--
-- Everything here is plain data and closures, like Options/Rotation.lua: a spec calls
-- `SpellsPage.group()` and drives a row's get/set directly, no AceConfig, no frame.
--
-- STANDING RULE (owner, 2026-09-09): nothing here may assume a class pack exists. Every pack read
-- is guarded, and a character with no shipped data still registers abilities from the spellbook and
-- configures every tab.
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

local function AS()
  return ns.AbilitySettings
end

-- The All abilities key. Spelled out rather than read from `AbilitySettings.ALL` so this page still
-- builds its tabs with Core not loaded at all; tests/spec/ability_settings_spec.lua pins the other
-- copy to the same string, which is the only place the two could drift.
local ALL = "*"

-- An appearance change cannot be applied to a glow that is already RUNNING: LibCustomGlow builds its
-- frames from the arguments it was started with, so tearing them down is what makes the next render
-- rebuild with the new settings. Without it the panel changes and the button does not.
local function restyle()
  if ns.Glow then ns.Glow.StopAll() end
  if ns.Display then ns.Display.refresh() end
end

local function put(key, channel, field, value)
  local A = AS()
  if A then A.set(key, channel, field, value) end
  restyle()
end

-- D52: player-added entries in BRAND colour, the same convention forks use in the Rotations tree.
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

-- "used by A, B" or nil (never a "not used by any rotation yet" fallback -- the two callers want
-- that worded differently).
local function usedByText(rotations, key)
  local used = ns.Spells.usedBy(rotations, key)
  if #used == 0 then return nil end
  return string.format(L["used by %s"], table.concat(used, ", "))
end

-- AB1-D11: the path is `spells > list > <key>` now that the entries live in an inner tree.
-- Options/Rotation.lua's "in Abilities >" link uses the same three-part path.
local function navigateToSpell(key)
  if ns.Options and ns.Options.dialog and ns.Options.dialog.SelectGroup then
    ns.Options.dialog:SelectGroup("Elmira", "spells", "list", key)
  end
end

-- ---------------------------------------------------------------- AB1-D2: one add panel

-- AceConfig `select` values are strings; the id round-trips through `tonumber`. One declaration:
-- the three are one idea -- what the add panel is currently holding.
local pickSpellbookId, typedText, typedError = nil, "", nil -- mutants: equivalent globals; luacheck catches it

-- I1a: item rows are 17px (`AceGUIWidget-DropDown-Items.lua:161`); 14 is the ceiling that still
-- sits inside the row against `GameFontNormalSmall`.
local SPELLBOOK_ICON_SIZE = 14

-- I1: `values` (id-as-string -> label) and `sorting` (id-as-string, ordered by NAME) for the
-- spellbook select. Both come from here so they can never disagree. Without an explicit `sorting`
-- table AceGUI's own DropDown sorts by the KEYS -- `tostring(entry.id)` -- so the list came out
-- ordered by spell id (owner, in game: "it is chaotic right now").
local function spellbookChoices()
  local out, rows = {}, {}
  if ns.Adapter and ns.Adapter.spellbookEntries then
    for _, entry in ipairs(ns.Adapter.spellbookEntries()) do
      local key = tostring(entry.id)
      -- I1c: resolved through the adapter (`Display.spellIconByID`), never a WoW API call from this
      -- file. No resolvable icon renders as the plain name, with no gap and no broken-texture box.
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

-- SpellsPage.resolveTyped(text) -> id, name, source
--
-- AB1-D2's one box for two things: digits resolve by ID, anything else by NAME. Pure enough to test
-- on its own, and the single place that decision is made -- the preview line and the Add button both
-- ask it, so what the preview promises is what Add stores.
function SpellsPage.resolveTyped(text)
  local A = ns.Adapter
  local typed = tostring(text or "")
  if typed == "" or not A then return nil end
  local id = tonumber(typed)
  if id then
    if not (id > 0 and A.spellNameByID) then return nil end
    local name = A.spellNameByID(id)
    if not name then return nil, nil, "id" end
    return id, name, "id"
  end
  id = A.spellIDByName and A.spellIDByName(typed)
  if not id then return nil, nil, "name" end
  return id, (A.spellNameByID and A.spellNameByID(id)) or typed, "name"
end

local function addArgs(order)
  local values, sorting = spellbookChoices()
  return {
    type = "group", inline = true, order = order, name = L["Add an ability"],
    args = {
      -- The four controls share ONE row: `width = "relative"` with relWidths summing to exactly 1.0
      -- is the only shape AceGUI's Flow scales (AceGUI-3.0.lua:709-711). Panels cannot share a row;
      -- controls can, which is why this is one inline group rather than the three it replaces.
      pick = {
        type = "select", order = 1, width = "relative", relWidth = 0.35,
        name = L["From your spellbook"], values = values, sorting = sorting,
        get = function() return pickSpellbookId end,
        set = function(_, v) pickSpellbookId = v end,
      },
      addPick = {
        type = "execute", order = 2, width = "relative", relWidth = 0.15, name = L["Add"],
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
      typed = {
        type = "input", order = 3, width = "relative", relWidth = 0.35, name = L["Spell ID or name"],
        desc = L["Only resolves a name this character has learned or seen; anything else is refused, not stored."],
        get = function() return typedText end,
        set = function(_, v) typedText = v or ""; typedError = nil end,
      },
      addTyped = {
        type = "execute", order = 4, width = "relative", relWidth = 0.15, name = L["Add"],
        func = function()
          local typed = typedText
          local id, name, source = SpellsPage.resolveTyped(typed)
          -- D95 (2026-09-07 in-game round): the box clears after EVERY attempt, kept or refused --
          -- a "Not found" left sitting in the box read as if nothing had happened. The refusal
          -- message is what stays visible, not the typed text.
          typedText = ""
          if not (id and name) then
            typedError = (source == "name") and L["Not found: this character has not seen it. Try the ID."]
              or L["Not found."]
            return -- mutants: equivalent falling through calls Spells.add with a nil id, which refuses on its own
          end
          -- No `typedError = nil` here: the only way to reach a resolvable value is to have typed
          -- into the box, and the input's own `set` clears the refusal. A second clear would be a
          -- line no path can reach, which the mutation gate is what caught.
          local key = ns.Spells.add(store(), { id = id, name = name, source = source })
          if key then navigateToSpell(key) end
        end,
      },
      preview = {
        type = "description", order = 5, width = "full", fontSize = "medium",
        name = function()
          if typedError then return ns.Colors.wrap(ns.Colors.BAD, typedError) end
          local _, name = SpellsPage.resolveTyped(typedText)
          if name then return string.format(L["Resolves to: %s"], name) end
          return ""
        end,
      },
    },
  }
end

-- ---------------------------------------------------------------- AB1-D9(c): the filter row

-- One declaration: the filter is one idea -- what the tree is currently showing.
local filterName, filterShow = "", "all" -- mutants: equivalent globals; luacheck catches it

local SHOW_LABELS = { all = "All", any = "Any configured", glow = "Glow", texture = "Texture",
                      edge = "Screen-edge", sound = "Sound", announce = "Announcement" }
local SHOW_ORDER = { "all", "any", "glow", "texture", "edge", "sound", "announce" }

-- SpellsPage.matches(entry) -> is this ability shown by the current filter
--
-- Pure and exported so the predicate is testable without a tree: the `hidden` closure on every entry
-- group is the only caller, and a filter that silently matches everything is invisible in the UI.
function SpellsPage.matches(entry)
  if filterName ~= "" and not tostring(entry.name):lower():find(filterName:lower(), 1, true) then
    return false
  end
  local A = AS()
  if filterShow == "all" or not A then return true end
  if filterShow == "any" then return A.anyOn(entry.key) end
  return A.channelOn(entry.key, filterShow)
end

function SpellsPage.setFilter(name, show)
  filterName, filterShow = name or "", show or "all"
end

local function filterArgs(order)
  local values = {}
  for _, k in ipairs(SHOW_ORDER) do values[k] = L[SHOW_LABELS[k]] end
  return {
    type = "group", inline = true, order = order, name = L["Find an ability"],
    args = {
      name = {
        type = "input", order = 1, width = "relative", relWidth = 0.6, name = L["Name contains"],
        get = function() return filterName end,
        set = function(_, v) filterName = v or "" end,
      },
      show = {
        type = "select", order = 2, width = "relative", relWidth = 0.4, name = L["Show"],
        values = values, sorting = SHOW_ORDER,
        get = function() return filterShow end,
        set = function(_, v) filterShow = v or "all" end,
      },
    },
  }
end

-- ---------------------------------------------------------------- AB1-D9(b): the tree tooltip

local CHANNEL_LABELS = { glow = "Glow", texture = "Texture", edge = "Screen-edge",
                         sound = "Sound", announce = "Announcement" }

-- "Glow, Sound on · Texture, Screen-edge, Announcement off" -- the group's `desc`, which
-- AceConfigDialog's own TreeOnButtonEnter draws when the cursor rests on the tree row.
function SpellsPage.channelSummary(key)
  local A = AS()
  if not A then return "" end
  local on, off = {}, {}
  for _, channel in ipairs(A.CUE_CHANNELS) do
    local into = A.channelOn(key, channel) and on or off
    into[#into + 1] = L[CHANNEL_LABELS[channel] or channel]
  end
  local parts = {}
  if #on > 0 then parts[#parts + 1] = string.format(L["%s on"], table.concat(on, ", ")) end
  if #off > 0 then parts[#parts + 1] = string.format(L["%s off"], table.concat(off, ", ")) end
  return table.concat(parts, " · ")
end

-- ---------------------------------------------------------------- the six tabs

-- "Same as All abilities" is the first control of every per-ability tab (AB1-D4) and never appears
-- on the All abilities entry itself -- it is what everything else inherits FROM.
local function inheritToggle(key, channel, order)
  if key == ALL then return nil end
  return {
    type = "toggle", order = order, width = "full", name = L["Same as All abilities"],
    desc = L["Use whatever the All abilities entry at the top of the list is set to."],
    get = function() local A = AS(); return not A or A.inherits(key, channel) end,
    set = function(_, v) local A = AS(); if A then A.setInherit(key, channel, v) end; restyle() end,
  }
end

-- Greyed, never lied to: a linked control keeps its real getter, so it shows the value it is
-- currently inheriting rather than a blank.
local function linked(key, channel)
  return function()
    local A = AS()
    return A ~= nil and A.inherits(key, channel)
  end
end

local function effective(key, channel)
  local A = AS()
  return (A and A.effective(key, channel)) or {}
end

-- PE7-D1's single gate, read from this side: with the bars not glowing at all, every control on the
-- Glow tab is dead, and a page that does not say so is where "I turned it on and nothing happened"
-- starts.
local function barGlowOff()
  local p = ns.db and ns.db.profile
  return not (p and p.glow and p.glow.barGlow)
end

local function glowDisabled(key)
  local off, link = barGlowOff, linked(key, "glow")
  return function() return off() or link() end
end

local function styleOf(key)
  return effective(key, "glow").style or "PIXEL"
end

-- The styles the loaded library can actually draw, named for humans. Only what is loadable: Proc
-- arrived in LibCustomGlow minor 25, and offering it against an older copy is a menu entry that
-- does nothing.
local GLOW_STYLE_NAMES = { PIXEL = "Pixel", BUTTON = "Button", AUTOCAST = "Autocast", PROC = "Proc" }

function SpellsPage.glowStyleNames()
  local out = {}
  for style in pairs((ns.Glow and ns.Glow.available()) or {}) do
    out[style] = L[GLOW_STYLE_NAMES[style] or style]
  end
  return out
end

-- A glow setting that is a NUMBER. `hidden` is driven by the style's own argument table rather than
-- by a list repeated here: a row the current style cannot use would let the user move a slider and
-- watch nothing happen, which is a panel telling a lie.
local function numberRow(key, order, name, field, minimum, maximum, step, desc)
  return {
    type = "range", order = order, name = name, desc = desc,
    min = minimum, max = maximum, step = step, disabled = glowDisabled(key),
    hidden = function() return not (ns.Glow and ns.Glow.applies(styleOf(key), field)) end,
    get = function() return (ns.Glow and ns.Glow.effective(styleOf(key), field, key)) or minimum end,
    set = function(_, v) put(key, "glow", field, v) end,
  }
end

-- AB1-D7. The Glow page's controls, verbatim, now per ability. No event checkboxes: a glow follows
-- the now-slot and nothing else.
local function glowArgs(key)
  local args = {}
  args.off = {
    type = "description", order = 0, width = "full", fontSize = "medium",
    hidden = function() return not barGlowOff() end,
    name = ns.Colors.wrap(ns.Colors.WARN,
      L["Action bar glow is off for everything -- turn it on under General > Action Bars."]),
  }
  args.inherit = inheritToggle(key, "glow", 1)
  args.enabled = {
    type = "toggle", order = 2, width = "full", name = L["Glow the button for this ability"],
    disabled = glowDisabled(key),
    get = function() return effective(key, "glow").enabled == true end,
    set = function(_, v) put(key, "glow", "enabled", v) end,
  }
  args.style = {
    type = "select", order = 3, name = L["Style"], disabled = glowDisabled(key),
    values = function() return SpellsPage.glowStyleNames() end,
    get = function() return styleOf(key) end,
    set = function(_, v) put(key, "glow", "style", v) end,
  }
  args.color = {
    type = "color", order = 4, name = L["Colour"], hasAlpha = false, disabled = glowDisabled(key),
    desc = L["The colour of the glow on your action bar."],
    get = function()
      local c = effective(key, "glow").color or ns.Colors.HIGHLIGHT
      return c.r, c.g, c.b
    end,
    set = function(_, r, g, b) put(key, "glow", "color", { r = r, g = g, b = b }) end,
  }
  args.particles = numberRow(key, 5, L["Particles"], "particles", 1, 20, 1,
    L["How many dots or sparks travel around the button."])
  -- 0.025 rather than 0.05 so Autocast's own default of 0.125 is a step the slider can land on.
  args.frequency = numberRow(key, 6, L["Speed"], "frequency", 0.025, 2, 0.025,
    L["How fast they travel."])
  args.thickness = numberRow(key, 7, L["Thickness"], "thickness", 1, 6, 1,
    L["How heavy the outline is."])
  args.speed = numberRow(key, 8, L["Pulse length"], "speed", 0.2, 3, 0.1,
    L["How long one pulse of the proc animation lasts, in seconds."])
  args.preview = {
    type = "execute", order = 9, name = L["Preview Glow"], disabled = glowDisabled(key),
    desc = L["Flashes a button on your bars with these settings."],
    func = function() if ns.Options then ns.Options.previewGlow(false, key) end end,
  }
  if key == ALL then
    -- AB1-D3: `Options.resetGlow` is this button. Only the All abilities entry has one -- resetting
    -- a single ability is what its "Same as All abilities" toggle already does, in one click.
    args.reset = {
      type = "execute", order = 10, name = L["Reset These to Defaults"], confirm = true,
      desc = L["Puts every glow setting back the way it shipped, including the colour."],
      confirmText = L["Put every glow setting back to its default?"],
      func = function() if ns.Options then ns.Options.resetGlow() end end,
    }
  end
  return args
end

-- AB1-D8. One sound per event, "None" by default, played the moment it is picked -- the list is
-- whatever media packs the player runs, so a name alone tells them nothing.
local EVENT_LABELS = { suggested = "When it is suggested", ready = "When it comes off cooldown",
                       used = "When you use it", active = "When its buff appears",
                       expiring = "When its buff is about to run out" }

local function soundArgs(key)
  local args = {}
  args.inherit = inheritToggle(key, "sound", 1)
  if key ~= ALL then
    args.enabled = {
      type = "toggle", order = 2, width = "full", name = L["Play sounds for this ability"],
      -- ADR-0009 as amended by AB1-D4: the ON switch is per ability and is never inherited, so no
      -- setting on All abilities can make every spell in the rotation start making noise.
      desc = L["Never inherited: All abilities cannot switch sounds on for you."],
      get = function() return effective(key, "sound").enabled == true end,
      set = function(_, v) put(key, "sound", "enabled", v) end,
    }
  end
  local A = AS()
  for i, event in ipairs((A and A.EVENTS) or {}) do
    args[event] = {
      type = "select", order = 2 + i, name = L[EVENT_LABELS[event] or event],
      disabled = linked(key, "sound"),
      values = function() return (ns.Sounds and ns.Sounds.list()) or { None = "None" } end,
      get = function() return effective(key, "sound")[event] or "None" end,
      set = function(_, v)
        put(key, "sound", event, v)
        -- Stored FIRST, then played through the same path the real cue uses, so what you hear now
        -- is what you will hear then.
        if ns.Sounds then ns.Sounds.play(v) end
      end,
    }
  end
  return args
end

-- AB1-D10. OFF by default for every ability, long cooldowns included (owner, 2026-09-09: "keep them
-- turned off by default"). The All abilities entry carries the WORDING only -- no on/off.
local function announceArgs(key, entry)
  local args = {}
  args.inherit = inheritToggle(key, "announce", 1)
  if key ~= ALL then
    args.enabled = {
      type = "toggle", order = 2, width = "full",
      name = string.format(L["Announce when I use %s"], (entry and entry.name) or key),
      desc = L["Where the line goes -- chat, screen, party, raid -- is set under Notifications, "
            .. "\"Long cooldowns used\"."],
      get = function() return effective(key, "announce").enabled == true end,
      set = function(_, v) put(key, "announce", "enabled", v) end,
    }
  end
  args.duration = {
    type = "toggle", order = 3, width = "full", name = L["Include how long it lasts"],
    desc = L["\"Divine Protection used -- 10s.\" Left out when this client cannot say how long the "
          .. "effect runs for."],
    disabled = linked(key, "announce"),
    get = function() return effective(key, "announce").duration == true end,
    set = function(_, v) put(key, "announce", "duration", v) end,
  }
  return args
end

-- AB1-D12: shells. One line each, no controls -- AB2 fills Screen-edge and AB3 the Texture tab.
local function shellArgs(order)
  return { soon = { type = "description", order = order, width = "full", fontSize = "medium",
                    name = ns.Colors.wrap(ns.Colors.MUTED, L["Arrives in the next pass."]) } }
end

-- ---------------------------------------------------------------- AB1-D6: the General tab

-- SpellsPage.packNotes(key, p) -> [{ name =, reasons =, needs = }]
--
-- What the SHIPPED class data says about this ability: which of its rotations use it, why its own
-- cues fire, and what those cues and rotations need from the character. Empty for every ability of
-- a class with no pack, which is a normal state and not an error.
function SpellsPage.packNotes(key, p)
  local out = {}
  if not (ns.Spells and ns.Spells.referencedKeys) then return out end
  for buildKey, build in pairs((p and p.builds) or {}) do
    if ns.Spells.referencedKeys(build)[key] then
      local row = { build = buildKey, reasons = {}, needs = {} }
      row.name = (ns.Rotation and ns.Rotation.displayName and ns.Rotation.displayName(buildKey)) or buildKey
      for _, cue in ipairs((build.visuals and build.visuals.cues) or {}) do
        if cue.spell == key or cue.key == key then
          if cue.reason then row.reasons[#row.reasons + 1] = cue.reason end
          if cue.requiresBonus then row.needs[#row.needs + 1] = cue.requiresBonus end
        end
      end
      for _, rune in ipairs((build.requires and build.requires.runes) or {}) do
        row.needs[#row.needs + 1] = rune
      end
      out[#out + 1] = row
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- The ability's icon before its name, resolved through the ADAPTER (Display.spellIcon) exactly as
-- the Rotations detail's "What this rotation needs" rows do; this module never calls the WoW API.
-- A key that resolves to nothing gets NO icon AND NO GAP.
local function iconPrefix(key)
  local icon = ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(key)
  return icon and ("|T" .. tostring(icon) .. ":0|t ") or ""
end

local function readable(key)
  return (ns.Display and ns.Display.spellName and ns.Display.spellName(key)) or key
end

local function packSummaryArgs(key, p)
  local rows = SpellsPage.packNotes(key, p)
  if #rows == 0 then return nil end
  local args, a = {}, 0
  for _, row in ipairs(rows) do
    a = a + 1
    args["r" .. a] = { type = "description", order = a, width = "full", fontSize = "medium",
                       name = ns.Colors.wrap(ns.Colors.HIGHLIGHT, row.name) }
    for _, reason in ipairs(row.reasons) do
      a = a + 1
      args["r" .. a] = { type = "description", order = a, width = "full", fontSize = "medium",
                         name = "   " .. reason }
    end
    for _, need in ipairs(row.needs) do
      a = a + 1
      args["r" .. a] = { type = "description", order = a, width = "full", fontSize = "medium",
                         name = "   " .. iconPrefix(need) .. readable(need) }
    end
  end
  return { type = "group", inline = true, order = 2, name = L["What the class pack says"], args = args }
end

-- D56: a remove control exists only for a MANUALLY added entry (an automatic one is derived, never
-- owned); even then, one still referenced says so instead of a button, so the row always explains
-- itself rather than failing silently on click.
local function removeArgs(entry, rotations, order)
  if entry.source == "pack" then return nil end
  local suffix = usedByText(rotations, entry.key)
  if suffix then
    return { type = "description", order = order, width = "full", fontSize = "medium",
      name = ns.Colors.wrap(ns.Colors.WARN, string.format(L["Still %s -- remove it there first."], suffix)) }
  end
  return {
    type = "execute", order = order, name = L["Remove"], confirm = true,
    confirmText = string.format(
      L["Remove %s and its glow, texture, screen-edge, sound and announcement settings?"], entry.name),
    func = function()
      local ok = ns.Spells.remove(store(), entry.key, rotations)
      -- The settings row goes with the registry entry, and only when the registry actually let go:
      -- clearing settings for an entry the guard refused to remove would throw away what the player
      -- configured and leave the ability sitting there.
      if not ok then return end
      local A = AS()
      if A then A.clear(entry.key) end
      navigateToSpell(ALL)
    end,
  }
end

local function generalArgs(key, entry, rotations, p)
  local args = {}
  if entry then
    local sourceText -- mutants: equivalent deleting the declaration only makes it a global; luacheck catches it
    if entry.source == "pack" then
      sourceText = string.format(L["from the %s pack"], (p and p.class) or "?")
    elseif entry.source == "spellbook" then sourceText = L["added from your spellbook"]
    elseif entry.source == "name" then sourceText = L["added by name"]
    else sourceText = L["added by ID"] end
    args.head = { type = "description", order = 1, width = "full", fontSize = "medium",
      name = string.format("%s%s  ·  #%s  ·  %s  ·  %s", iconPrefix(entry.key), entry.name,
        tostring(entry.id), sourceText,
        usedByText(rotations, entry.key) or L["not used by any rotation yet"]) }
    args.pack = packSummaryArgs(entry.key, p)
  else
    args.head = { type = "description", order = 1, width = "full", fontSize = "medium",
      name = L["What every ability falls back to. Change something here and every ability still set"
            .. " to \"Same as All abilities\" follows."] }
  end
  args.inherit = inheritToggle(key, "general", 3)
  args.onlyInCombat = {
    type = "toggle", order = 4, width = "full", name = L["Only in combat"],
    desc = L["Nothing this ability is set to do -- glow, sound, flash, announcement -- happens while "
          .. "you are out of combat."],
    disabled = linked(key, "general"),
    get = function() return effective(key, "general").onlyInCombat == true end,
    set = function(_, v) put(key, "general", "onlyInCombat", v) end,
  }
  args.expiring = {
    type = "range", order = 5, name = L["\"About to run out\" means"], min = 1, max = 15, step = 1,
    desc = L["How many seconds are left on this ability's buff when the \"about to run out\" cue fires."],
    disabled = linked(key, "general"),
    get = function() return effective(key, "general").expiringSeconds or 3 end,
    set = function(_, v) put(key, "general", "expiringSeconds", v) end,
  }
  if entry then args.remove = removeArgs(entry, rotations, 9) end
  return args
end

-- ---------------------------------------------------------------- the entries

local function tabsFor(key, entry, rotations, p)
  return {
    general  = { type = "group", order = 1, name = L["General"], args = generalArgs(key, entry, rotations, p) },
    glow     = { type = "group", order = 2, name = L["Glow"], args = glowArgs(key) },
    texture  = { type = "group", order = 3, name = L["Texture"], args = shellArgs(1) },
    edge     = { type = "group", order = 4, name = L["Screen-edge"], args = shellArgs(1) },
    sound    = { type = "group", order = 5, name = L["Sound"], args = soundArgs(key) },
    announce = { type = "group", order = 6, name = L["Announcement"], args = announceArgs(key, entry) },
  }
end

local MEDIA_ICON = "Interface\\AddOns\\Elmira\\media\\icon"

-- AB1-D4: the first node of the inner tree, and the only one that is not a registered ability.
local function allGroup()
  return { type = "group", order = 0, name = L["All abilities"], icon = MEDIA_ICON,
           childGroups = "tab", desc = L["The settings every ability starts from."],
           args = tabsFor(ALL, nil, {}, nil) }
end

-- AB1-D9(a): the tree row's icon is the ability's own spell icon, through the group's `icon` field
-- (AceConfigDialog-3.0.lua:1022). Desaturating the ones with nothing switched on happens on the
-- widget side (Options.markAbilityIcons) -- a tree entry carries no "greyed" flag of its own.
local function entryGroup(entry, order, rotations, p)
  return {
    type = "group", order = order, name = registryLabel(entry), childGroups = "tab",
    icon = ns.Display and ns.Display.spellIconByID and ns.Display.spellIconByID(entry.id) or nil,
    desc = function() return SpellsPage.channelSummary(entry.key) end,
    hidden = function() return not SpellsPage.matches(entry) end,
    args = tabsFor(entry.key, entry, rotations, p),
  }
end

local function listArgs()
  if ns.Rotation and ns.Rotation.syncSpells then ns.Rotation.syncSpells() end
  local p = pack()
  local rotations = allRotations(p)
  local rows = (ns.Spells and ns.Spells.list(store())) or {}

  local args = {}
  args.add = addArgs(1)
  args.filter = filterArgs(2)
  args[ALL] = allGroup()
  for i, entry in ipairs(rows) do
    args[entry.key] = entryGroup(entry, 10 + i, rotations, p)
  end
  return args
end

-- ---------------------------------------------------------------- the section

function SpellsPage.group()
  -- M1a: 3 of the owner's 1-8 top-level order, right after Rotations. The group key stays `spells`
  -- (Options.Open("spells"), SelectGroup(..., "spells"), saved status-table entries and the module
  -- name `ns.SpellsPage` are all unchanged); the PLAYER-visible name is "Abilities".
  return {
    type = "group", order = 3, name = L["Abilities"], childGroups = "tab",
    args = {
      list = { type = "group", order = 1, name = L["Abilities"], childGroups = "tree", args = listArgs() },
      share = {
        type = "group", order = 2, name = L["Share"],
        args = { soon = { type = "description", order = 1, width = "full", fontSize = "medium",
                          name = L["Sharing arrives in the next pass."] } },
      },
    },
  }
end

ns.SpellsPage = SpellsPage
return SpellsPage
