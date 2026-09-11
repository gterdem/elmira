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
  -- AB3-D1: a texture already on screen has to pick the change up now. It is only ever on screen
  -- while the ability is being suggested or a Move mode is running, and the second of those is
  -- exactly when someone is dragging the size slider -- a slider whose effect appears three fights
  -- later is a slider that looks broken.
  if ns.Textures then ns.Textures.Refresh() end
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

-- The one write path for both halves of the filter (AB4 review). The two rows below used to assign
-- the locals themselves, which left this function with no caller outside the specs -- a function
-- only a spec calls is a bug report, and here it was the specific one where the panel and the test
-- can drift: a spec proving the predicate against a value the UI can no longer produce.
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
        set = function(_, v) SpellsPage.setFilter(v, filterShow) end,
      },
      show = {
        type = "select", order = 2, width = "relative", relWidth = 0.4, name = L["Show"],
        values = values, sorting = SHOW_ORDER,
        get = function() return filterShow end,
        set = function(_, v) SpellsPage.setFilter(filterName, v) end,
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

-- AT1-D1: the "about to run out" warning threshold. One field (`general.expiringSeconds`, which
-- still inherits from All abilities exactly as every other General field does -- nothing about
-- that moved), shown on the Sound tab and the Texture tab -- the two that actually have an "about
-- to run out" moment -- immediately after that moment's own control, and (as the inherited
-- default) on All abilities' General tab. Same field everywhere, so changing it on one shows on
-- the other. A per-ability copy is greyed while that ability is still linked to All abilities on
-- General -- exactly like "Only in combat" beside it -- AND while its own tab's moment is not live;
-- writing while linked would silently vanish into what All abilities holds, which is the one
-- failure shape this project keeps refusing to ship again.
local function expiringArgs(key, order, extraDisabled)
  return {
    type = "range", order = order, name = L["Warn me about to expire"],
    min = 1, max = 15, step = 1,
    desc = L["Only fires for an ability whose buff is actually on you -- one that never has a buff "
          .. "of its own, like Exorcism or Judgement, never sees it."],
    disabled = function()
      local A = AS()
      if A and A.inherits(key, "general") then return true end
      return extraDisabled ~= nil and extraDisabled() or false
    end,
    get = function() return effective(key, "general").expiringSeconds or 3 end,
    set = function(_, v) put(key, "general", "expiringSeconds", v) end,
  }
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
  return effective(key, "glow").style or "PROC"
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
  -- AT2-D1: which moments this ability's glow (bar and strip alike) is allowed on screen, in the
  -- SAME words and order as the Queue page's "When to show it" -- shared by reference
  -- (`Options.VISIBILITY_LABELS`) rather than a second copy of the English, so the two pages
  -- cannot drift apart. Independent of the display: a hidden strip does not silence "Always", and
  -- a shown strip does not force "In combat only".
  args.show = {
    type = "select", order = 3, width = "full", name = L["Show the glow"],
    disabled = glowDisabled(key),
    desc = L["Which moments this ability's glow is allowed on screen -- its own schedule, not the "
          .. "queue strip's. A hidden strip does not silence a glow set to Always, and a visible "
          .. "strip does not force one set to In combat only."],
    values = function()
      local out = {}
      local labels = (ns.Options and ns.Options.VISIBILITY_LABELS) or {}
      for _, mode in ipairs(ns.Visibility.MODES) do out[mode] = L[labels[mode]] end
      return out
    end,
    sorting = function()
      local out = {}
      for i, mode in ipairs(ns.Visibility.MODES) do out[i] = mode end
      return out
    end,
    get = function() return effective(key, "glow").show or ns.Visibility.DEFAULT end,
    set = function(_, v) put(key, "glow", "show", v) end,
  }
  args.style = {
    type = "select", order = 4, name = L["Style"], disabled = glowDisabled(key),
    values = function() return SpellsPage.glowStyleNames() end,
    get = function() return styleOf(key) end,
    set = function(_, v) put(key, "glow", "style", v) end,
  }
  args.color = {
    type = "color", order = 5, name = L["Colour"], hasAlpha = false, disabled = glowDisabled(key),
    desc = L["The colour of the glow on your action bar."],
    get = function()
      local c = effective(key, "glow").color or ns.Colors.HIGHLIGHT
      return c.r, c.g, c.b
    end,
    set = function(_, r, g, b) put(key, "glow", "color", { r = r, g = g, b = b }) end,
  }
  args.particles = numberRow(key, 6, L["Particles"], "particles", 1, 20, 1,
    L["How many dots or sparks travel around the button."])
  -- 0.025 rather than 0.05 so Autocast's own default of 0.125 is a step the slider can land on.
  args.frequency = numberRow(key, 7, L["Speed"], "frequency", 0.025, 2, 0.025,
    L["How fast they travel."])
  args.thickness = numberRow(key, 8, L["Thickness"], "thickness", 1, 6, 1,
    L["How heavy the outline is."])
  args.speed = numberRow(key, 9, L["Pulse length"], "speed", 0.2, 3, 0.1,
    L["How long one pulse of the proc animation lasts, in seconds."])
  args.preview = {
    type = "execute", order = 10, name = L["Preview Glow"], disabled = glowDisabled(key),
    desc = L["Flashes a button on your bars with these settings."],
    func = function() if ns.Options then ns.Options.previewGlow(false, key) end end,
  }
  if key == ALL then
    -- AB1-D3: `Options.resetGlow` is this button. Only the All abilities entry has one -- resetting
    -- a single ability is what its "Same as All abilities" toggle already does, in one click.
    args.reset = {
      type = "execute", order = 11, name = L["Reset These to Defaults"], confirm = true,
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
  -- AT1-D2: per ability only -- never built for `*`, and nothing left here to inherit.
  local args = {}
  args.enabled = {
    type = "toggle", order = 2, width = "full", name = L["Play sounds for this ability"],
    -- ADR-0009 as amended by AB1-D4: the ON switch is per ability and is never inherited, so no
    -- setting on All abilities can make every spell in the rotation start making noise.
    desc = L["Never inherited: All abilities cannot switch sounds on for you."],
    get = function() return effective(key, "sound").enabled == true end,
    set = function(_, v) put(key, "sound", "enabled", v) end,
  }
  local A = AS()
  for i, event in ipairs((A and A.EVENTS) or {}) do
    args[event] = {
      type = "select", order = 2 + i, name = L[EVENT_LABELS[event] or event],
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
  -- AT1-D1, right after "When its buff is about to run out": greyed until a sound is actually
  -- picked for that moment -- switching a threshold nothing plays at is not a live control.
  args.expiringSeconds = expiringArgs(key, 7.5, function()
    return (effective(key, "sound").expiring or "None") == "None"
  end)
  return args
end

-- AB1-D10. OFF by default for every ability, long cooldowns included (owner, 2026-09-09: "keep them
-- turned off by default"). The All abilities entry carries the WORDING only -- no on/off.
local function announceArgs(key, entry)
  -- AT1-D2: per ability only -- never built for `*`, and nothing left here to inherit.
  local args = {}
  args.enabled = {
    type = "toggle", order = 2, width = "full",
    name = string.format(L["Announce when I use %s"], (entry and entry.name) or key),
    desc = L["Where the line goes -- chat, screen, party, raid -- is set under Notifications, "
          .. "\"Long cooldowns used\"."],
    get = function() return effective(key, "announce").enabled == true end,
    set = function(_, v) put(key, "announce", "enabled", v) end,
  }
  args.duration = {
    type = "toggle", order = 3, width = "full", name = L["Include how long it lasts"],
    desc = L["\"Divine Protection used -- 10s.\" Left out when this client cannot say how long the "
          .. "effect runs for."],
    get = function() return effective(key, "announce").duration == true end,
    set = function(_, v) put(key, "announce", "duration", v) end,
  }
  return args
end

-- ---------------------------------------------------------------- AB3-D1/D2: the Texture tab

-- Named for humans. `Textures` is the authority on which sources, shapes and placements exist -- it
-- is what can actually draw them -- so adding one there cannot leave an unnamed entry here.
local SOURCE_LABELS = { icon = "This ability's icon", shape = "A shape", custom = "A file of my own" }
local SHAPE_LABELS = { ring = "Ring", disc = "Disc", square = "Square", diamond = "Diamond",
                       arrow = "Arrow", star = "Star", bar = "Bar", chevron = "Chevron" }
local PLACE_LABELS = { row = "With the other indicators", centre = "Centre of the screen",
                       custom = "Somewhere I choose" }
-- AB4-D1. Worded as what the swipe MEASURES, not as what it looks like: "radial progress" tells a
-- player nothing about which of their two timers they are about to see.
local FILL_LABELS = { none = "Nothing", cooldown = "How much cooldown is left",
                      buff = "How much of its buff is left" }

local function labelled(list, labels)
  local out = {}
  for _, v in ipairs(list or {}) do out[v] = L[labels[v] or v] end
  return out
end

local function textureList(name)
  return (ns.Textures and ns.Textures[name]) or {}
end

local function sourceOf(key)
  return effective(key, "texture").source or "icon"
end

-- Is one of the two Move modes running, and is it THIS one. Read through Textures rather than kept
-- here, exactly as the strip's own button reads `Queue.isPositioning`: the mode lives with the
-- frames it moves, and the options window is not the only thing that can end it (the panel closing
-- does, through the chained OnClose).
local function positioningIndicators()
  return (ns.Textures and ns.Textures.isPositioning and ns.Textures.isPositioning()) == true
end

local function movingTexture(key)
  return (ns.Textures and ns.Textures.movingKey and ns.Textures.movingKey()) == key
end

local function textureArgs(key)
  -- AT1-D2: per ability only -- never built for `*`, and nothing left here to inherit. "Position
  -- the Indicators" moved to All abilities > General, since this tab no longer exists there.
  local A = AS()
  local args = {}
  args.enabled = {
    type = "toggle", order = 2, width = "full", name = L["Show a texture for this ability"],
    -- ADR-0009 as amended by AB1-D4: the ON switch is per ability and is never inherited.
    desc = L["Never inherited: All abilities cannot switch textures on for you."],
    get = function() return effective(key, "texture").enabled == true end,
    set = function(_, v) put(key, "texture", "enabled", v) end,
  }
  args.source = {
    type = "select", order = 3, name = L["Show"],
    values = labelled(textureList("SOURCES"), SOURCE_LABELS),
    sorting = textureList("SOURCES"),
    desc = L["The ability's own spell icon, one of the shapes that ship with Elmira, or any "
          .. "texture file you have."],
    get = function() return sourceOf(key) end,
    set = function(_, v) put(key, "texture", "source", v) end,
  }
  args.shape = {
    type = "select", order = 4, name = L["Shape"],
    values = labelled(textureList("SHAPES"), SHAPE_LABELS),
    sorting = textureList("SHAPES"),
    -- Hidden rather than greyed: a shape picker is not "unavailable" while the source is the spell
    -- icon, it is irrelevant, and a greyed control invites the player to look for what unlocks it.
    hidden = function() return sourceOf(key) ~= "shape" end,
    get = function() return effective(key, "texture").shape or "ring" end,
    set = function(_, v) put(key, "texture", "shape", v) end,
  }
  args.path = {
    type = "input", order = 5, width = "full", name = L["Texture file"],
    desc = L["A path the client can load, e.g. Interface\\Icons\\Spell_Holy_Excorcism. Elmira "
          .. "cannot check it -- if nothing appears, the ring is drawn instead."],
    hidden = function() return sourceOf(key) ~= "custom" end,
    get = function() return effective(key, "texture").path or "" end,
    set = function(_, v) put(key, "texture", "path", v or "") end,
  }
  -- The one failure a texture has that a screen edge does not: a source that resolves to no file.
  -- Said here, where it happens, because on screen it is indistinguishable from a working setting.
  args.missing = {
    type = "description", order = 6, width = "full", fontSize = "medium",
    hidden = function()
      if not ns.Textures then return true end
      return ns.Textures.texturePath(effective(key, "texture"), key) ~= nil
    end,
    name = ns.Colors.wrap(ns.Colors.WARN,
      L["Nothing to draw -- Elmira falls back to the ring. Check the file, or pick a shape."]),
  }
  args.size = {
    type = "range", order = 7, name = L["Size"], min = 16, max = 256, step = 8,
    desc = L["How big the texture is, in pixels."],
    get = function() return (ns.Textures and ns.Textures.sizeOf(effective(key, "texture"))) or 48 end,
    set = function(_, v) put(key, "texture", "size", v) end,
  }
  args.color = {
    type = "color", order = 8, name = L["Colour"], hasAlpha = false,
    desc = L["The shipped shapes are white, so this tints them. A spell icon keeps its own art "
          .. "unless you tint it."],
    get = function()
      local c = effective(key, "texture").color or ns.Colors.HIGHLIGHT
      return c.r, c.g, c.b
    end,
    set = function(_, r, g, b) put(key, "texture", "color", { r = r, g = g, b = b }) end,
  }
  args.alpha = {
    type = "range", order = 9, name = L["Opacity"], min = 0.05, max = 1.0, step = 0.05,
    isPercent = true,
    get = function() return effective(key, "texture").alpha or 1 end,
    set = function(_, v) put(key, "texture", "alpha", v) end,
  }
  -- AB4-D1. Between the appearance controls and the moments, because that is what it is: how the
  -- texture is drawn while it is up, not another moment for it to appear at.
  args.fill = {
    type = "select", order = 9.5, name = L["Fill with"],
    values = labelled(textureList("FILLS"), FILL_LABELS),
    sorting = textureList("FILLS"),
    desc = L["Sweeps the texture round like a cooldown while it is on screen. \"How much of its "
          .. "buff is left\" drains the other way, so what is lit is what is left. Nothing is "
          .. "drawn when there is no cooldown or buff running -- and the moment this ability "
          .. "counts as about to run out is the one right below."],
    get = function() return (ns.Textures and ns.Textures.fillOf(effective(key, "texture"))) or "none" end,
    set = function(_, v) put(key, "texture", "fill", v) end,
  }
  -- All five of Core/Track's events, unlike the screen edge's two (AB3-D1). `suggested` and
  -- `active` SHOW the texture while the state holds; the other three flash it for a second and a
  -- half, which is why the three ADR-0009 keeps off a full-screen flash are fine here.
  for i, event in ipairs(textureList("EVENTS")) do
    args[event] = {
      type = "toggle", order = 9 + i, width = "full", name = L[EVENT_LABELS[event] or event],
      desc = (ns.Textures and ns.Textures.HELD[event])
        and L["Stays on screen for as long as this is true."]
        or L["Appears for a second and a half."],
      get = function() return effective(key, "texture")[event] == true end,
      set = function(_, v) put(key, "texture", event, v) end,
    }
  end
  -- AT1-D1, right after "When its buff is about to run out": greyed until that checkbox is
  -- actually ticked -- a threshold nothing uses is not a live control.
  args.expiringSeconds = expiringArgs(key, 14.5, function()
    return effective(key, "texture").expiring ~= true
  end)
  -- AB3-D2, and never inherited: dragging one ability's texture must move that one alone.
  args.place = {
    type = "select", order = 20, name = L["Position"],
    values = labelled(textureList("PLACEMENTS"), PLACE_LABELS),
    sorting = textureList("PLACEMENTS"),
    desc = L["\"With the other indicators\" flows it into the row, so several never overlap."],
    get = function() return effective(key, "texture").place or "row" end,
    set = function(_, v) put(key, "texture", "place", v) end,
  }
  args.move = {
    type = "execute", order = 21, name = function()
      return movingTexture(key) and L["Done Moving"] or L["Move This Texture"]
    end,
    desc = L["Puts this texture on screen on its own and lets you drag it. Where you drop it is "
          .. "remembered as an offset from the centre of the screen."],
    hidden = function() return (effective(key, "texture").place or "row") ~= "custom" end,
    func = function()
      if not ns.Textures then return end
      if movingTexture(key) then ns.Textures.StopMoveMode() else ns.Textures.StartMove(key) end
    end,
  }
  args.preview = {
    type = "execute", order = 22, name = L["Preview Texture"],
    desc = L["Shows it for a second and a half with these settings, whether or not it is switched on."],
    -- The SAME path `/elm debug textures <KEY>` uses: a preview drawn by a second code path can
    -- look right while the one that fires in play is broken.
    func = function() if ns.Textures then ns.Textures.TestFire(key) end end,
  }
  args.silent = {
    type = "description", order = 23, width = "full", fontSize = "medium",
    hidden = function()
      local e = effective(key, "texture")
      if not (A and A.channelOn(key, "texture")) then return true end
      for _, event in ipairs(textureList("EVENTS")) do
        if e[event] then return true end
      end
      return false
    end,
    name = ns.Colors.wrap(ns.Colors.WARN,
      L["This is switched on but appears at no moment -- tick one of the moments above."]),
  }
  return args
end

-- ---------------------------------------------------------------- AB2-D1: the Screen-edge tab

-- Named for humans. `Overlay.EDGES` is the authority on which edges exist -- it is what can actually
-- draw them -- so adding one there cannot leave an unnamed entry here.
local EDGE_LABELS = { left = "Left", right = "Right", top = "Top", bottom = "Bottom" }
local function edgeChoices()
  local out = {}
  for _, e in ipairs((ns.Overlay and ns.Overlay.EDGES) or {}) do out[e] = L[EDGE_LABELS[e] or e] end
  return out
end

-- Only two of the five events, and Overlay is the one that says so: a full-screen flash on every
-- buff that ticks down is the strobe ADR-0009 exists to prevent, and the other three are what the
-- Texture tab is for (AB3).
local EDGE_EVENT_LABELS = { suggested = "When it is suggested", ready = "When it comes off cooldown" }

local function edgeArgs(key)
  -- AT1-D2: per ability only -- never built for `*`, and nothing left here to inherit.
  local args = {}
  args.enabled = {
    type = "toggle", order = 2, width = "full", name = L["Flash the screen edge for this ability"],
    -- ADR-0009 as amended by AB1-D4/AB2-D3: the ON switch is per ability and is never inherited.
    -- A class pack may ship it on for one or two abilities; nothing else can.
    desc = L["Never inherited: All abilities cannot switch screen flashes on for you."],
    get = function() return effective(key, "edge").enabled == true end,
    set = function(_, v) put(key, "edge", "enabled", v) end,
  }
  args.edge = {
    type = "select", order = 3, name = L["Edge"], values = edgeChoices(),
    sorting = (ns.Overlay and ns.Overlay.EDGES) or nil,
    desc = L["Which screen edge this ability flashes on."],
    get = function() return effective(key, "edge").edge or "left" end,
    set = function(_, v) put(key, "edge", "edge", v) end,
  }
  args.color = {
    type = "color", order = 4, name = L["Colour"], hasAlpha = false,
    get = function()
      local c = effective(key, "edge").color or ns.Colors.HIGHLIGHT
      return c.r, c.g, c.b
    end,
    set = function(_, r, g, b) put(key, "edge", "color", { r = r, g = g, b = b }) end,
  }
  args.intensity = {
    type = "range", order = 5, name = L["Intensity"], min = 0.05, max = 1.0, step = 0.05,
    isPercent = true,
    desc = L["How bright the flash is. Reading a number tells you nothing about whether you will "
          .. "catch it out of the corner of your eye -- use Preview."],
    get = function() return effective(key, "edge").intensity or 0.5 end,
    set = function(_, v) put(key, "edge", "intensity", v) end,
  }
  local A = AS()
  for i, event in ipairs((ns.Overlay and ns.Overlay.EVENTS) or {}) do
    args[event] = {
      type = "toggle", order = 5 + i, width = "full", name = L[EDGE_EVENT_LABELS[event] or event],
      get = function() return effective(key, "edge")[event] == true end,
      set = function(_, v) put(key, "edge", event, v) end,
    }
  end
  args.preview = {
    type = "execute", order = 9, name = L["Preview Flash"],
    desc = L["Flashes the screen edge with these settings, whether or not it is switched on."],
    -- The SAME path `/elm debug cues <KEY>` uses, deliberately: a preview drawn by a second code
    -- path can look right while the one that fires in play is broken.
    func = function() if ns.Overlay then ns.Overlay.TestFire(key) end end,
  }
  -- Switched on, with neither event ticked, is a channel that can never fire -- and it looks exactly
  -- like a broken addon. Say so where it happens.
  args.silent = {
    type = "description", order = 10, width = "full", fontSize = "medium",
    hidden = function()
      local e = effective(key, "edge")
      if not (A and A.channelOn(key, "edge")) then return true end
      for _, event in ipairs((ns.Overlay and ns.Overlay.EVENTS) or {}) do
        if e[event] then return true end
      end
      return false
    end,
    name = ns.Colors.wrap(ns.Colors.WARN,
      L["This is switched on but fires on nothing -- tick one of the moments above."]),
  }
  return args
end

-- ---------------------------------------------------------------- AB1-D6: the General tab

-- SpellsPage.packReason(key, p) -> the class pack's one sentence about this ability, or nil
--
-- AB2-D2 took the build-level `visuals.cues` away, and the `reason` strings that explained them went
-- with the rest of the cue record -- except this one, which is the half a player reads rather than
-- the half the renderer used. It now sits on the pack's SPELL entry beside the defaults it explains
-- (`defaults.reason`, Core/Schema.abilityDefaultErrors), because the sentence is about the ability,
-- not about any one rotation that happens to name it.
function SpellsPage.packReason(key, p)
  local entry = p and p.spells and p.spells[key]
  local reason = entry and entry.defaults and entry.defaults.reason
  return type(reason) == "string" and reason or nil
end

-- SpellsPage.packNotes(key, p) -> [{ name =, needs = }]
--
-- What the SHIPPED class data says about this ability: which of its rotations use it and what those
-- rotations need from the character. Empty for every ability of a class with no pack, which is a
-- normal state and not an error.
function SpellsPage.packNotes(key, p)
  local out = {}
  if not (ns.Spells and ns.Spells.referencedKeys) then return out end
  for buildKey, build in pairs((p and p.builds) or {}) do
    if ns.Spells.referencedKeys(build)[key] then
      local row = { build = buildKey, needs = {} }
      row.name = (ns.Rotation and ns.Rotation.displayName and ns.Rotation.displayName(buildKey)) or buildKey
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
  local reason = SpellsPage.packReason(key, p)
  if #rows == 0 and not reason then return nil end
  local args, a = {}, 0
  if reason then
    a = a + 1
    args["r" .. a] = { type = "description", order = a, width = "full", fontSize = "medium",
                       name = reason }
  end
  for _, row in ipairs(rows) do
    a = a + 1
    args["r" .. a] = { type = "description", order = a, width = "full", fontSize = "medium",
                       name = ns.Colors.wrap(ns.Colors.HIGHLIGHT, row.name) }
    for _, need in ipairs(row.needs) do
      a = a + 1
      args["r" .. a] = { type = "description", order = a, width = "full", fontSize = "medium",
                         name = "   " .. iconPrefix(need) .. readable(need) }
    end
  end
  return { type = "group", inline = true, order = 3, name = L["What the class pack says"], args = args }
end

-- D56: a remove control exists only for a MANUALLY added entry (an automatic one is derived, never
-- owned); even then, one still referenced says so instead of a button, so the row always explains
-- itself rather than failing silently on click.
--
-- AB3-D3: it sits on the IDENTITY ROW at the top now, not under the last slider (owner,
-- 2026-09-09: "the one control that deletes things should not be the last item after a slider").
-- `width = "relative"` with the head's 0.72 summing to 1.0 is the only shape AceGUI's Flow scales
-- (AceGUI-3.0.lua:709-711), and the row ENDS with this control because a Button is the only widget
-- that fills its cell -- a toggle would hug the left of a cell three quarters of the way across.
local REMOVE_WIDTH = 0.28

local function removeArgs(entry, rotations, order)
  if entry.source == "pack" then return nil end
  local suffix = usedByText(rotations, entry.key)
  if suffix then
    return { type = "description", order = order, width = "relative", relWidth = REMOVE_WIDTH,
      fontSize = "medium",
      name = ns.Colors.wrap(ns.Colors.WARN, string.format(L["Still %s -- remove it there first."], suffix)) }
  end
  return {
    type = "execute", order = order, width = "relative", relWidth = REMOVE_WIDTH,
    name = L["Remove"], confirm = true,
    confirmText = string.format(
      L["Remove %s and its glow, texture, screen-edge, sound and announcement settings?"], entry.name),
    func = function()
      local s = store()
      -- An unresolved import row has no registry entry to remove -- only the settings that arrived
      -- with it. Without this, its Remove button is a button that does nothing.
      local ok = (s ~= nil and s[entry.key] == nil) or ns.Spells.remove(s, entry.key, rotations)
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
  -- AB3-D3: built FIRST, because whether it exists is what decides how wide the identity line
  -- beside it is. A three-quarter-width line with nothing in the last quarter is a gap the player
  -- reads as a missing control.
  local remove = entry and removeArgs(entry, rotations, 2) or nil
  if entry then
    local sourceText -- mutants: equivalent deleting the declaration only makes it a global; luacheck catches it
    if entry.source == "pack" then
      sourceText = string.format(L["from the %s pack"], (p and p.class) or "?")
    elseif entry.source == "spellbook" then sourceText = L["added from your spellbook"]
    elseif entry.source == "name" then sourceText = L["added by name"]
    elseif entry.source == "import" then sourceText = L["arrived in an import"]
    -- AB2-D5: settings with no ability behind them on THIS character. Said plainly, because every
    -- control on the page below will look like it works and nothing will ever fire.
    elseif entry.source == "unresolved" then
      sourceText = L["not on this character -- these settings arrived in an import"]
    else sourceText = L["added by ID"] end
    args.head = { type = "description", order = 1, fontSize = "medium",
      width = remove and "relative" or "full", relWidth = remove and (1 - REMOVE_WIDTH) or nil,
      name = string.format("%s%s  ·  #%s  ·  %s  ·  %s", iconPrefix(entry.key), entry.name,
        tostring(entry.id), sourceText,
        usedByText(rotations, entry.key) or L["not used by any rotation yet"]) }
    args.remove = remove
    args.pack = packSummaryArgs(entry.key, p)
  else
    args.head = { type = "description", order = 1, width = "full", fontSize = "medium",
      name = L["What every ability falls back to. Change something here and every ability still set"
            .. " to \"Same as All abilities\" follows."] }
  end
  args.inherit = inheritToggle(key, "general", 4)
  -- AT1-D3, verbatim (owner's wording): the same tooltip on every General tab, All abilities
  -- included, since the toggle guards every channel the same way regardless of key.
  args.onlyInCombat = {
    type = "toggle", order = 5, width = "full", name = L["Only in combat"],
    desc = L["Glow, Texture, Screen Edge, Sounds and Announcements will be only available in combat"],
    disabled = linked(key, "general"),
    get = function() return effective(key, "general").onlyInCombat == true end,
    set = function(_, v) put(key, "general", "onlyInCombat", v) end,
  }
  -- AT1-D1: All abilities keeps ITS OWN copy of the warning threshold here, as the inherited
  -- default -- the per-ability copies live on the Sound and Texture tabs instead, right next to the
  -- moment they gate. AT1-D2 also moves "Position the Indicators" here, since the Texture tab it
  -- used to live on no longer exists for All abilities.
  if key == ALL then
    args.expiring = expiringArgs(key, 6)
    args.anchor = {
      type = "execute", order = 7, name = function()
        return positioningIndicators() and L["Done Positioning"] or L["Position the Indicators"]
      end,
      desc = L["Puts a sample texture on screen and lets you drag the row wherever you want it. "
            .. "Press it again when it is in place. Until you do this the row floats above the "
            .. "queue strip and follows it."],
      func = function()
        if not ns.Textures then return end
        if positioningIndicators() then ns.Textures.StopMoveMode() else ns.Textures.StartPositioning() end
      end,
    }
  end
  return args
end

-- ---------------------------------------------------------------- the entries

-- AT1-D2: All abilities keeps only General and Glow -- "I don't think anyone will want to set the
-- same texture, screen edge, sound or announcement for all the abilities" (owner). The other four
-- are per-ability only and are simply never built for the `*` key.
local function tabsFor(key, entry, rotations, p)
  local args = {
    general = { type = "group", order = 1, name = L["General"], args = generalArgs(key, entry, rotations, p) },
    glow    = { type = "group", order = 2, name = L["Glow"], args = glowArgs(key) },
  }
  if key ~= ALL then
    args.texture  = { type = "group", order = 3, name = L["Texture"], args = textureArgs(key) }
    args.edge     = { type = "group", order = 4, name = L["Screen-edge"], args = edgeArgs(key) }
    args.sound    = { type = "group", order = 5, name = L["Sound"], args = soundArgs(key) }
    args.announce = { type = "group", order = 6, name = L["Announcement"], args = announceArgs(key, entry) }
  end
  return args
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

-- AB2-D5: a settings row for a spell this client cannot resolve. It still gets a full page -- the
-- settings are real and will work the moment the character learns the spell -- but the tree says so
-- in the name's colour and in the tooltip, because a row that looks like every other one and glows
-- nothing is indistinguishable from a bug.
local function unresolvedGroup(key, order)
  local A = AS()
  local info = (A and A.spellInfo(key)) or {}
  local entry = { key = key, id = info.id, name = info.name or key, source = "unresolved" }
  return {
    type = "group", order = order, childGroups = "tab",
    name = ns.Colors.wrap(ns.Colors.MUTED, entry.name),
    desc = L["not on this character"],
    hidden = function() return not SpellsPage.matches(entry) end,
    args = tabsFor(key, entry, {}, nil),
  }
end

local function listArgs()
  if ns.Rotation and ns.Rotation.syncSpells then ns.Rotation.syncSpells() end
  -- Imported rows this client CAN resolve become registry entries before the tree is built, so they
  -- appear as themselves rather than as an unresolved row that would quietly stay one forever.
  SpellsPage.adoptImported()
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
  local merged = (ns.Spells and ns.Spells.merged and ns.Spells.merged(p)) or {}
  local A = AS()
  for i, key in ipairs((A and A.keys()) or {}) do
    if not (args[key] or merged[key]) then args[key] = unresolvedGroup(key, 1000 + i) end
  end
  return args
end

-- ---------------------------------------------------------------- AB2-D5: the Share tab

-- One declaration: the tab is one idea -- what is currently in the box, what it last said, and
-- which rotation the picker is on.
local shareText, shareNote, shareRotation = "", "", nil -- mutants: equivalent globals; luacheck catches it

-- SpellsPage.bundle(keys) -> { abilities =, spells = }
--
-- `keys` is a SET (`Spells.referencedKeys`'s shape) or nil for everything stored. `spells` carries
-- the id and the readable name of every key that travels: the RECEIVING client resolves the id to
-- decide whether it can register the ability at all, and shows the name when it cannot. Neither is
-- knowable from the key alone, and neither can be asked for from Core -- which is why the bundle is
-- assembled up here rather than inside Core/AbilitySettings.
function SpellsPage.bundle(keys)
  local A = AS()
  local abilities = (A and A.export(keys)) or {}
  local merged = (ns.Spells and ns.Spells.merged and ns.Spells.merged(pack())) or {}
  local spells = {}
  for key in pairs(abilities) do
    if key ~= ALL then
      local entry, info = merged[key], A and A.spellInfo(key)
      local id = (entry and entry.id) or (info and info.id)
      -- A pack's own spell record has an id and no name (the client owns the naming), so the name
      -- is resolved the same way every other line on this page resolves one.
      if id then spells[key] = { id = id, name = (entry and entry.name) or readable(key) } end
    end
  end
  return { abilities = abilities, spells = spells }
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- Everything this character has configured, All abilities row included: the settings half of a
-- "here is my setup" string.
function SpellsPage.exportAll()
  if not ns.Serialize then shareNote = L["The import/export libraries are not loaded."]; return false end
  local b = SpellsPage.bundle(nil)
  local str, err = ns.Serialize.encodeBundle({ abilities = b.abilities, spells = b.spells })
  if not str then shareNote = tostring(err); return false end
  shareText = str
  shareNote = string.format(L["Exported the settings of %d abilities -- copy the text above."],
                            countKeys(b.abilities))
  return true
end

-- One rotation AND the settings of the abilities it names. The All abilities row deliberately does
-- NOT ride along: it is what every OTHER ability on the receiving character inherits from, and
-- overwriting it to share four spells would rewrite their whole setup.
function SpellsPage.exportRotation(buildKey)
  local p = pack()
  if not (ns.UserBuilds and ns.UserBuilds.find and ns.Spells and ns.Serialize) then
    shareNote = L["The import/export libraries are not loaded."]
    return false
  end
  local build = ns.UserBuilds.find(p, buildKey)
  if not build then shareNote = L["Pick a rotation first."]; return false end
  local b = SpellsPage.bundle(ns.Spells.referencedKeys(build))
  local str, err = ns.UserBuilds.exportKey(p, buildKey, b)
  if not str then shareNote = tostring(err); return false end
  shareText = str
  shareNote = string.format(L["Exported %s with the settings of %d of its abilities."],
                            readable(buildKey), countKeys(b.abilities))
  return true
end

-- How many keys a pasted string would write. The confirm names it, because "Import" over a setup
-- someone spent an evening on is not an action to take on a guess.
function SpellsPage.importCount(text)
  if not ns.Serialize then return 0 end
  local bundle = ns.Serialize.decodeBundle(text)
  return countKeys(bundle and bundle.abilities)
end

-- Merges by key, overwriting on a collision. A build in the string is ignored here on purpose:
-- rotations are imported on the Rotations page, and quietly creating one from the Abilities tab
-- would be a second, invisible way to acquire a rotation.
function SpellsPage.importSettings(text)
  local A = AS()
  if not (A and ns.Serialize) then
    shareNote = L["The import/export libraries are not loaded."]
    return false
  end
  local bundle, err = ns.Serialize.decodeBundle(text)
  if not bundle then shareText = tostring(text or ""); shareNote = tostring(err); return false end
  local n = A.import(bundle.abilities, bundle.spells)
  if n == 0 then
    shareText = tostring(text or "")
    shareNote = L["That string carries no ability settings."]
    return false
  end
  shareText = ""
  shareNote = string.format(L["Merged the settings of %d abilities."], n)
  restyle()
  return true, n
end

-- SpellsPage.adoptImported() -> how many imported rows became registry entries
--
-- The other half of AB2-D5's import: a settings row whose key this client CAN resolve becomes a
-- real registry entry, so the ability is configurable and usable like any other; one it cannot stays
-- settings-only and the tree shows it muted. Run from the page build rather than from the import,
-- because it is also the answer for a row imported before the character learned the spell -- and a
-- step that has to be remembered at two call sites is a step that will be forgotten at one.
function SpellsPage.adoptImported()
  local A, s = AS(), store()
  if not (A and s and ns.Spells and ns.Spells.adopt) then return 0 end
  local merged = (ns.Spells.merged and ns.Spells.merged(pack())) or {}
  local adopted = 0
  for _, key in ipairs(A.keys()) do
    local info = A.spellInfo(key)
    if info and info.id and not merged[key] then
      local name = ns.Adapter and ns.Adapter.spellNameByID and ns.Adapter.spellNameByID(info.id)
      if name and ns.Spells.adopt(s, key, info.id, name) then adopted = adopted + 1 end
    end
  end
  return adopted
end

local function rotationChoices()
  local values, sorting = {}, {}
  if not (ns.Rotation and ns.Rotation.templateRows and ns.Rotation.forkRows) then return values, sorting end
  for _, row in ipairs(ns.Rotation.templateRows()) do
    values[row.build] = ns.Rotation.displayName(row.build)
    sorting[#sorting + 1] = row.build
  end
  for _, row in ipairs(ns.Rotation.forkRows()) do
    values[row.build] = row.name
    sorting[#sorting + 1] = row.build
  end
  return values, sorting
end

local function shareArgs()
  local values, sorting = rotationChoices()
  return {
    intro = {
      type = "description", order = 1, width = "full", fontSize = "medium",
      name = L["Ability settings are per character. This is how you copy them to another character "
            .. "-- or to someone else -- without sharing a profile."],
    },
    exportAll = {
      type = "execute", order = 2, width = "relative", relWidth = 0.5,
      name = L["Export All Ability Settings"],
      desc = L["Puts a string in the box below covering every ability you have configured, "
            .. "including All abilities."],
      func = function() SpellsPage.exportAll() end,
    },
    rotation = {
      type = "select", order = 3, width = "relative", relWidth = 0.5, name = L["Rotation"],
      values = values, sorting = sorting,
      get = function() return shareRotation end,
      set = function(_, v) shareRotation = v end,
    },
    exportRotation = {
      type = "execute", order = 4, width = "relative", relWidth = 0.5,
      name = L["Export Rotation with Settings"],
      desc = L["The rotation itself plus the settings of every ability it names. Paste it on the "
            .. "Rotations page to get both."],
      func = function() SpellsPage.exportRotation(shareRotation) end,
    },
    text = {
      type = "input", multiline = 8, width = "full", order = 5, name = L["Ability settings string"],
      desc = L["Paste a string here to merge its settings into this character's."],
      confirm = function(_, value)
        local n = SpellsPage.importCount(value)
        -- No count means nothing will be overwritten, so nothing needs confirming -- the failure
        -- message under the box says why in that case.
        if n == 0 then return false end
        return string.format(L["Overwrite this character's settings for %d abilities?"], n)
      end,
      get = function() return shareText end,
      set = function(_, value) SpellsPage.importSettings(value) end,
    },
    note = {
      type = "description", order = 6, width = "full", fontSize = "medium",
      name = function() return shareNote end,
    },
  }
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
      share = { type = "group", order = 2, name = L["Share"], args = shareArgs() },
    },
  }
end

ns.SpellsPage = SpellsPage
return SpellsPage
