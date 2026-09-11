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
-- what the add panel is currently holding -- `pickSpellbookId` for the left half, and the
-- WeakAuras-style trigger box's own three (AT5-D3): what is TYPED and what it last RESOLVED to,
-- kept apart so a second Enter on an unchanged, already-resolved box reads as "register it" rather
-- than "resolve it again".
local pickSpellbookId, typedText, resolvedID, resolvedName, resolvedSource =
  nil, "", nil, nil, nil -- mutants: equivalent globals; luacheck catches it

-- I1a: item rows are 17px (`AceGUIWidget-DropDown-Items.lua:161`); 14 is the ceiling that still
-- sits inside the row against `GameFontNormalSmall`.
local SPELLBOOK_ICON_SIZE = 14
-- The longest label that still fits the dropdown's row at its widest (relWidth 0.47 of the page).
local SPELLBOOK_LABEL_MAX = 40

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
      -- AT6-D7: the id after the name, in brackets. Two entries in a spellbook can read exactly the
      -- same ("Holy Light" at six ranks, a rune's version of a spell beside the trainer's), and the
      -- id is the only thing on the row that tells the player which one they are about to add.
      -- The SORT still goes by name alone (below), so adding it does not reshuffle the list.
      local label = string.format("%s (%d)", entry.name, entry.id)
      -- AceGUI's pullout rows are 17px with a word-wrapping label anchored top-to-bottom
      -- (AceGUIWidget-DropDown-Items.lua:161-168): a label wider than the row wraps to a second,
      -- clipped line and the first line -- icon included -- rides up (owner, in game: "Greater
      -- Blessing of Salvation" sat higher than its neighbours). Shorten the NAME, never the id.
      if #label > SPELLBOOK_LABEL_MAX then
        local room = SPELLBOOK_LABEL_MAX - #string.format(" (%d)", entry.id) - 1
        label = string.format("%s\226\128\166 (%d)", entry.name:sub(1, math.max(room, 8)), entry.id)
      end
      out[key] = icon and string.format("|T%s:%d|t %s", icon, SPELLBOOK_ICON_SIZE, label) or label
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

-- AT5-D3, and the one write path for both ways of confirming a resolved box (the Add button and a
-- second Enter): stores the resolution the box is already showing, never re-parses the display
-- text, so "20930 (Holy Shock)" itself is never asked to resolve as a name.
local function clearTyped()
  typedText, resolvedID, resolvedName, resolvedSource = "", nil, nil, nil
end

local function addResolvedTyped()
  if not (resolvedID and resolvedName) then return end -- mutants: equivalent nothing to add yet
  -- AT7-D1: same arbiter as the spellbook Add above, for the same reason.
  local key = ns.Spells.add(store(), { id = resolvedID, name = resolvedName, source = resolvedSource },
    ns.Adapter and ns.Adapter.spellIDByName)
  clearTyped()
  if key then navigateToSpell(key) end
end

local function addArgs(order)
  local values, sorting = spellbookChoices()
  return {
    type = "group", inline = true, order = order, name = L["Add an ability"],
    args = {
      -- Five controls share ONE row: `width = "relative"` with relWidths summing to exactly 1.0 is
      -- the only shape AceGUI's Flow scales (AceGUI-3.0.lua:709-711). Panels cannot share a row;
      -- controls can, which is why this is one inline group rather than the three it replaces.
      pick = {
        type = "select", order = 1, width = "relative", relWidth = 0.47,
        name = L["From your spellbook"], values = values, sorting = sorting,
        get = function() return pickSpellbookId end,
        set = function(_, v) pickSpellbookId = v end,
      },
      addPick = {
        type = "execute", order = 2, width = "relative", relWidth = 0.11, name = L["Add"],
        desc = L["Registers the selected spell, or selects it if it is already registered."],
        func = function()
          local id = tonumber(pickSpellbookId)
          local name -- mutants: equivalent deleting the declaration only makes it a global; luacheck catches it
          for _, entry in ipairs((ns.Adapter and ns.Adapter.spellbookEntries and ns.Adapter.spellbookEntries()) or {}) do
            if entry.id == id then name = entry.name; break end
          end
          if not (id and name) then return end -- mutants: equivalent Spells.add's own id/name check refuses just as silently
          -- AT7-D1: the arbiter for a name-dedup's rank update, so picking a rank of an ability
          -- already registered under a different id raises the stored id rather than sitting stale.
          local key = ns.Spells.add(store(), { id = id, name = name, source = "spellbook" },
            ns.Adapter and ns.Adapter.spellIDByName)
          if key then pickSpellbookId = nil; navigateToSpell(key) end
        end,
      },
      -- AT5-D3: WeakAuras' own trigger-field shape. An icon slot to the LEFT of the box, empty
      -- until something resolves -- an AceConfig `description` takes `image` for exactly this.
      icon = {
        type = "description", order = 3, width = "relative", relWidth = 0.06, name = "",
        image = function()
          if not resolvedID then return "" end
          return (ns.Display and ns.Display.spellIconByID and ns.Display.spellIconByID(resolvedID)) or ""
        end,
        imageWidth = 20, imageHeight = 20,
      },
      typed = {
        type = "input", order = 4, width = "relative", relWidth = 0.24, name = L["Spell ID or name"],
        desc = L["Only resolves a name this character has learned or seen; anything else is refused, not stored."],
        get = function() return typedText end,
        -- An `input`'s `set` fires on Enter (AT5-D3). The FIRST Enter only resolves: the box is
        -- rewritten to "<id> (<name>)" and the icon appears, nothing is added yet. Junk clears the
        -- box and the icon in silence -- no "Not found" message any more. A SECOND Enter, on that
        -- same resolved text unchanged, is the trigger field's own confirm and does what Add does.
        set = function(_, v)
          v = v or ""
          if resolvedID and v == typedText then
            addResolvedTyped()
            return
          end
          local id, name, source = SpellsPage.resolveTyped(v)
          if id and name then
            resolvedID, resolvedName, resolvedSource = id, name, source
            typedText = string.format("%d (%s)", id, name)
          else
            clearTyped()
          end
        end,
      },
      addTyped = {
        type = "execute", order = 5, width = "relative", relWidth = 0.12, name = L["Add"],
        desc = L["Registers the resolved spell, or selects it if it is already registered."],
        func = function() addResolvedTyped() end,
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

-- ---------------------------------------------------------------- AT9-D3: the buff-only controls

-- The moments that can only ever fire for an ability that puts a buff ON YOU, on either tab. Both
-- are read out of `state:buff(key)`, so on Exorcism they are a tick box the player can set that
-- will never once do anything -- which is this project's characteristic silent failure dressed up
-- as a feature.
local BUFF_EVENTS = { active = true, expiring = true }

-- HIDDEN, not greyed (owner, amending AT9-D3): a control that is on the page but dead still has to
-- be read, understood and dismissed every time the player scans the tab, and there is nothing they
-- can do to it. One line at the foot of the Texture tab says what brings them back.
--
-- `AbilitySettings.hasBuff` is the pack's flag OR what this character has been seen to have, so a
-- shipped seal shows its buff moments before the first pull and a spell the player added themselves
-- shows them the first time they cast it.
local function buffUnknown(key)
  return function()
    local A = AS()
    return not (A and A.hasBuff(key))
  end
end

-- AT8-D1: the "about to run out" warning threshold is per ability now and never inherited --
-- `general.expiringSeconds` joined `AbilitySettings`'s `OWN` table, so it is always this ability's
-- own value regardless of what "Same as All abilities" says on its General tab. One field, read and
-- written by both the Sound tab and the Texture tab -- the two that actually have an "about to run
-- out" moment -- so changing it on one shows on the other. All abilities no longer carries a copy
-- of its own (there is nothing left for a per-ability copy to inherit).
--
-- AT8-D2: the slider belongs to the tab's own "about to expire" moment -- no other gate -- and sits
-- directly under that moment's own control, indented: a bare gap (`args`' other new key) shares its
-- row, relWidth 0.06 then 0.94, so the checkbox above and the slider read as one control without
-- the label text itself carrying any indent marks.
--
-- AT9-D3/D4 (owner): HIDDEN rather than greyed, and the gap goes with it -- an indent left standing
-- under a checkbox with nothing beside it reads as a control that failed to draw. `hidden` covers
-- both halves of the question: the ability is not known to buff you at all, or this tab's
-- about-to-expire moment is not ticked.
local EXPIRING_GAP_WIDTH, EXPIRING_SLIDER_WIDTH = 0.06, 0.94

-- `disabled` is the Texture tab's own AT6-D1 gate ("off means off") and is passed only by that tab;
-- the Sound tab has no master switch to grey it with.
local function expiringArgs(key, args, order, hidden, disabled)
  args.expiringGap = { type = "description", order = order - 0.01, width = "relative",
                       relWidth = EXPIRING_GAP_WIDTH, name = "", hidden = hidden }
  args.expiringSeconds = {
    type = "range", order = order, name = L["Warn me about to expire"],
    width = "relative", relWidth = EXPIRING_SLIDER_WIDTH,
    min = 1, max = 15, step = 1,
    desc = L["How many seconds before the buff runs out counts as \"about to expire\"."],
    hidden = hidden, disabled = disabled,
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
-- AT9 (owner): "When its buff is about to run out" reads as "When it's about to expire" now, on
-- every tab that offers the moment.
local EVENT_LABELS = { suggested = "When it is suggested", ready = "When it comes off cooldown",
                       used = "When you use it", active = "When its buff appears",
                       expiring = "When it's about to expire" }

-- AT8-D4, verbatim (owner's wording). The Texture tab's own copy sits with its toggles below;
-- Sound's reads "a sound" where Texture reads "a flash", and drops the persistence sentence -- a
-- sound plays once, it never "stays".
local SOUND_EVENT_DESC = {
  suggested = "While the rotation has this ability in the first slot.",
  ready = "A sound when its cooldown finishes.",
  used = "A sound when you cast it.",
  active = "While the buff it puts on you is up. Only for abilities that give you a buff: seals, "
        .. "blessings, Avenging Wrath, Holy Shield.",
  expiring = "A sound when that buff has only a few seconds left. The number below says how many.",
}

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
  local unknown = buffUnknown(key)
  for i, event in ipairs((A and A.EVENTS) or {}) do
    -- AT9-D3 (owner): the two buff moments are not on the page at all for an ability nothing has
    -- ever seen buff you. The other three ask nothing of the buff and are always there.
    local buffOnly = BUFF_EVENTS[event] == true
    args[event] = {
      type = "select", order = 2 + i, name = L[EVENT_LABELS[event] or event],
      desc = L[SOUND_EVENT_DESC[event]],
      hidden = buffOnly and unknown or nil,
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
  -- AT8-D2/AT9-D4, right under "When it's about to expire": there only while a sound is actually
  -- picked for that moment -- a threshold nothing plays at is not a control, it is furniture.
  expiringArgs(key, args, 7.5, function()
    return unknown() or (effective(key, "sound").expiring or "None") == "None"
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

-- Named for humans. `Textures` is the authority on which placements exist -- it is what can actually
-- draw them -- so adding one there cannot leave an unnamed entry here. AT4-D2 took the Source and
-- Shape dropdowns off this tab entirely: the question is now a tick box ("its own icon?") and, when
-- that is off, one file path with a Choose… button beside it.
-- AT8-D3: short values now -- Nothing / Cooldown / Buff. The tooltip on the control itself (below)
-- keeps the explanation AT5-D1 put here about what each one measures.
local FILL_LABELS = { none = "Nothing", cooldown = "Cooldown", buff = "Buff" }

-- AT8-D4, verbatim (owner's wording): what each moment actually shows and, for `active`, which
-- abilities it can ever fire for at all -- said here because on this tab a texture flash or hold is
-- the whole of what the moment means.
local TEXTURE_EVENT_DESC = {
  suggested = "While the rotation has this ability in the first slot. Stays as long as that holds.",
  ready = "A flash of a second and a half when its cooldown finishes.",
  used = "A flash when you cast it.",
  active = "While the buff it puts on you is up. Stays as long as the buff lasts. Only for abilities "
        .. "that give you a buff: seals, blessings, Avenging Wrath, Holy Shield.",
  -- AT9-D1, verbatim (owner's wording): this moment is a HELD state on this tab now, not a flash --
  -- a warning that blinks once while you are watching the boss is a warning you never received.
  -- The Sound tab's copy above still reads "a sound", because a sound cannot stay.
  expiring = "Shows when that buff has only a few seconds left and stays until it is gone. The "
          .. "number below says how many.",
}

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

-- Is the Move mode running, and is it THIS texture. Read through Textures rather than kept here,
-- exactly as the strip's own button reads `Queue.isPositioning`: the mode lives with the frames it
-- moves, and the options window is not the only thing that can end it (the panel closing does,
-- through the chained OnClose).
local function movingTexture(key)
  return (ns.Textures and ns.Textures.movingKey and ns.Textures.movingKey()) == key
end

-- AT6-D1, owner: the tab is one switch and its settings. With "Show a texture for this ability"
-- unticked, everything below it is greyed -- a page whose controls all answer and change nothing is
-- how "I set it up and it never appeared" happens, and this channel ships OFF.
--
-- `disabled` rather than `hidden` on purpose: a tab that empties itself when you untick the switch
-- loses the settings the player can see they still have, and the tick box would jump up the page.
local function textureOff(key)
  local A = AS()
  return function() return not (A and A.channelOn(key, "texture")) end
end

-- How wide the Reset button at the right end of its own row is (AT6-D6, AT8-D6), and the gap that
-- pushes it there. `width = "relative"` with relWidths summing to 1.0 is the only shape AceGUI's
-- Flow layout scales to the row; only a Button fills its cell, which is why the filler is a
-- description.
local TEXTURE_RESET_WIDTH = 0.25

local function textureArgs(key)
  -- AT1-D2: per ability only -- never built for `*`, and nothing left here to inherit.
  local A = AS()
  local off = textureOff(key)
  local args = {}
  args.enabled = {
    type = "toggle", order = 2, width = "full", name = L["Show a texture for this ability"],
    -- ADR-0009 as amended by AB1-D4: the ON switch is per ability and is never inherited.
    desc = L["Never inherited: All abilities cannot switch textures on for you."],
    get = function() return effective(key, "texture").enabled == true end,
    set = function(_, v) put(key, "texture", "enabled", v) end,
  }
  -- AT8-D6 (owner): moved to the top, directly under the switch and before the own-icon toggle --
  -- where a player looks for it first, since judging a texture only makes sense once it is on
  -- screen at its real size. Left-aligned: alone on its row, unlike Reset below, nothing needs a
  -- relative width to push it anywhere.
  args.move = {
    type = "execute", order = 2.5, disabled = off,
    name = function()
      return movingTexture(key) and L["Done Moving"] or L["Move texture"]
    end,
    desc = L["Puts this texture on screen on its own and lets you drag it. Where you drop it is "
          .. "remembered as an offset from the centre of the screen."],
    func = function()
      if not ns.Textures then return end
      if movingTexture(key) then ns.Textures.StopMoveMode() else ns.Textures.StartMove(key) end
    end,
  }
  -- AT4-D2, and the whole of the source question: the ability's own spell icon, or a file. Ships
  -- ticked, because the spell icon is what a texture has always defaulted to and is what almost
  -- everybody wants -- the file field below only appears for the people who do not.
  args.ownIcon = {
    type = "toggle", order = 3, width = "full", name = L["Use this ability's own icon"],
    disabled = off,
    desc = L["Untick to draw a picture of your choosing instead -- one of Elmira's shapes, "
          .. "Blizzard's own art, or any texture file you have."],
    get = function() return sourceOf(key) == "icon" end,
    set = function(_, v)
      -- AT8-D5: the two sources share one `size` field but read differently at the same number --
      -- an icon at 200px swallows the button it sits on, a shape at 48px is a speck next to the
      -- ring drawn at its intended size. Flipping the source swaps the default too, but ONLY while
      -- `size` still holds the source it is leaving's default: a size the player actually chose is
      -- never overwritten. `restyle` runs once at the end -- not through `put` alone -- so the held
      -- preview (AT6-D5) repaints at the flipped size instead of one tick behind it.
      local from = sourceOf(key)
      if v then
        put(key, "texture", "source", "icon")
        if ns.Textures and ns.Textures.flipSize then ns.Textures.flipSize(key, from, "icon") end
      else
        put(key, "texture", "source", "path")
        if ns.Textures and ns.Textures.flipSize then ns.Textures.flipSize(key, from, "path") end
        -- The ring, so unticking the box draws something recognisable straight away instead of
        -- leaving an empty field and a texture that looks broken. Only when nothing was chosen
        -- before: a player who picked a file, ticked the box and changed their mind gets theirs
        -- back.
        if (effective(key, "texture").path or "") == "" then
          put(key, "texture", "path", (ns.Textures and ns.Textures.DEFAULT_PATH) or "")
        end
      end
      restyle()
    end,
  }
  args.path = {
    type = "input", order = 4, width = "full", name = L["Texture file"], disabled = off,
    desc = L["The picture this ability draws. Pick one with Choose…, or type any path the client "
          .. "can load, e.g. Interface\\Icons\\Spell_Holy_Excorcism. Elmira cannot check a path you "
          .. "type -- if nothing appears, the ring is drawn instead."],
    hidden = function() return sourceOf(key) == "icon" end,
    -- Never blank: an empty field is the shipped ring, which is also what gets drawn, so the field
    -- and the screen always agree.
    get = function()
      local path = effective(key, "texture").path
      if path == nil or path == "" then return (ns.Textures and ns.Textures.DEFAULT_PATH) or "" end
      return path
    end,
    set = function(_, v) put(key, "texture", "path", v or "") end,
  }
  args.choose = {
    type = "execute", order = 5, name = L["Choose…"], disabled = off,
    desc = L["Opens the texture picker on a clear screen: this window gets out of the way and the "
          .. "texture itself is left on screen, so you judge a picture at its real size where it "
          .. "will actually appear. Drag it while you are there; press Done when it is right."],
    hidden = function() return sourceOf(key) == "icon" end,
    -- AT6-D3 (owner): Choose… does what "Move This Texture" does AND opens the picker. The picker
    -- used to open OVER the configuration window, which is the one place it cannot judge a texture
    -- from -- 960x680 of panel is exactly what you are trying to see past. `StartMove` is what hides
    -- the window (through Options.BeginMove) and puts the toolbar up, so the two buttons cannot
    -- drift apart; the picker is opened AFTER it, on the clear screen it just made.
    func = function()
      if ns.Textures then ns.Textures.StartMove(key) end
      -- Open, never Toggle: the tab this button is on is not on screen once the window is hidden,
      -- so "press it again to close" has nothing to press. The toolbar's own Texture button keeps
      -- the toggle.
      if ns.TexturePanel then ns.TexturePanel.Open(key) end
    end,
  }
  -- AT4-D3: the one failure the picker adds. A path inside another addon's folder is only a file
  -- while that addon is loaded, and on a character without it the ring is drawn -- which is
  -- indistinguishable from a working setting. Nothing is reset; the path is still there for the
  -- character that has WeakAuras.
  args.needsAddon = {
    type = "description", order = 5.5, width = "full", fontSize = "medium",
    hidden = function()
      return not (ns.Textures and ns.Textures.missingAddon(effective(key, "texture")))
    end,
    name = function()
      local needs = ns.Textures and ns.Textures.missingAddon(effective(key, "texture"))
      return ns.Colors.wrap(ns.Colors.WARN, string.format(
        L["This texture needs %s, which is not installed on this character."], tostring(needs)))
    end,
  }
  -- The other one: a file that resolves to nothing at all. Said here, where it happens, because on
  -- screen it is indistinguishable from a working setting.
  args.missing = {
    type = "description", order = 6, width = "full", fontSize = "medium",
    hidden = function()
      if not ns.Textures then return true end
      -- The line above already says it, with the cause and the cure. Two warnings about one
      -- texture teach the player that warnings here are noise.
      if ns.Textures.missingAddon(effective(key, "texture")) then return true end
      return ns.Textures.texturePath(effective(key, "texture"), key) ~= nil
    end,
    name = ns.Colors.wrap(ns.Colors.WARN,
      L["Nothing to draw -- Elmira falls back to the ring. Check the file, or pick another."]),
  }
  -- AT8-D5: 16-512 now (a path texture wants room an icon never did), one step throughout --
  -- AceConfig's range widget takes a single step for its whole span, so 8 is what the decision's own
  -- fallback allows rather than a custom widget for a cosmetic slider.
  args.size = {
    type = "range", order = 7, name = L["Size"], min = 16, max = 512, step = 8, disabled = off,
    desc = L["How big the texture is, in pixels."],
    get = function() return (ns.Textures and ns.Textures.sizeOf(effective(key, "texture"))) or 48 end,
    set = function(_, v) put(key, "texture", "size", v) end,
  }
  args.color = {
    type = "color", order = 8, name = L["Colour"], hasAlpha = false, disabled = off,
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
    isPercent = true, disabled = off,
    get = function() return effective(key, "texture").alpha or 1 end,
    set = function(_, v) put(key, "texture", "alpha", v) end,
  }
  -- Owner, 2026-09-11, after asking what WeakAuras' "Glow / Opaque" means: the same two modes,
  -- under the same names, default Opaque. Additive is what aura art is drawn for; on a bright
  -- background it washes out, which the tooltip says.
  args.blend = {
    type = "select", order = 9.5, name = L["Blend mode"], disabled = off,
    desc = L["Opaque draws the texture as it is. Glow adds its light to what is behind it: black"
          .. " disappears and bright parts shine, which is what most aura art is made for -- and"
          .. " what washes out on a bright background."],
    values = { blend = L["Opaque"], add = L["Glow"] }, sorting = { "blend", "add" },
    get = function() return effective(key, "texture").blend or "blend" end,
    set = function(_, v) put(key, "texture", "blend", v) end,
  }
  -- All five of Core/Track's events, unlike the screen edge's two (AB3-D1). `suggested` and
  -- `active` SHOW the texture while the state holds; the other three flash it for a second and a
  -- half, which is why the three ADR-0009 keeps off a full-screen flash are fine here.
  local unknown = buffUnknown(key)
  for i, event in ipairs(textureList("EVENTS")) do
    -- AT9-D3 (owner): "When its buff appears" and "When it's about to expire" are the two that
    -- read the aura, so they are not on the page at all for an ability nothing has ever seen buff
    -- you. The muted line at the foot of the tab is what says so, once.
    local buffOnly = BUFF_EVENTS[event] == true
    args[event] = {
      type = "toggle", order = 9 + i, width = "full", name = L[EVENT_LABELS[event] or event],
      disabled = off,
      hidden = buffOnly and unknown or nil,
      -- AT8-D4, verbatim (owner's wording): explains what the moment actually shows, not just how
      -- long -- "active" in particular says which abilities it applies to at all.
      desc = L[TEXTURE_EVENT_DESC[event]],
      get = function() return effective(key, "texture")[event] == true end,
      set = function(_, v) put(key, "texture", event, v) end,
    }
  end
  -- AT8-D2/AT9-D4, right under "When it's about to expire": there only while that checkbox is
  -- actually ticked -- a threshold nothing uses is not a control, it is furniture.
  expiringArgs(key, args, 14.5, function()
    return unknown() or effective(key, "texture").expiring ~= true
  end, off)
  -- AT9-D4. ON by default, so a buff texture counts down out of the box. AT10-D1 (owner): HIDDEN
  -- rather than shown-but-dead now -- the countdown only ever draws while a buff moment is holding
  -- the texture (`active`/`expiring`), so on an ability nothing has ever seen buff you it is the
  -- same dead control the two buff moments themselves already are, and gets the same `hasBuff` gate.
  args.seconds = {
    type = "toggle", order = 15.5, width = "full", name = L["Show seconds left"], disabled = off,
    hidden = unknown,
    desc = L["Draws the whole seconds left of the buff in the middle of the texture, while it is on "
          .. "screen for \"when its buff appears\" or \"when it's about to expire\". The "
          .. "toolbar and this tab show 30 as a sample."],
    get = function() return effective(key, "texture").seconds == true end,
    set = function(_, v) put(key, "texture", "seconds", v) end,
  }
  -- AT5-D1/D2 (owner, seeing the swipe draw a PowerAuras-style dark box: "not clockwise or
  -- anything -- start being visible or getting invisible"). Below the five moments now, because
  -- what it pairs with only makes sense once you have read them: an opacity that follows a STATE
  -- (`suggested`/`active`) is visible long enough to fade, an INSTANT flash is not.
  --
  -- AT10-D1 (owner): the row itself is hidden unless "When it is suggested" or "When its buff
  -- appears" is ticked -- the only two moments a fade has anything to follow -- and the Buff choice
  -- is offered only once the ability is known to buff you: `active` cannot even be ticked before
  -- then, so a Buff fade could never fire either. A `buff` fill stored before the ability lost its
  -- buff flag (or shipped that way in a pack) reads back as Nothing rather than as a choice the menu
  -- no longer offers -- the same "never lied to" rule the pack fallback everywhere else follows.
  local function fillCanShow()
    local e = effective(key, "texture")
    return e.suggested == true or e.active == true
  end
  args.fill = {
    type = "select", order = 16, name = L["Fade with"], disabled = off,
    hidden = function() return not fillCanShow() end,
    values = function()
      local vals = labelled(textureList("FILLS"), FILL_LABELS)
      if unknown() then vals.buff = nil end
      return vals
    end,
    sorting = function()
      local out = {}
      for _, v in ipairs(textureList("FILLS")) do
        if v ~= "buff" or not unknown() then out[#out + 1] = v end
      end
      return out
    end,
    -- AT8-D3, verbatim (owner's wording).
    desc = L["Cooldown: faint after the cast, brightening as it recovers — pairs with "
          .. "\"when it is suggested\". Buff: full when the buff appears, fading as it runs out "
          .. "— pairs with \"when its buff appears\"."],
    get = function()
      local f = (ns.Textures and ns.Textures.fillOf(effective(key, "texture"))) or "none"
      if f == "buff" and unknown() then return "none" end
      return f
    end,
    set = function(_, v) put(key, "texture", "fill", v) end,
  }
  -- AT6-D4 took the Position dropdown with the indicator row: a texture starts at the centre of
  -- the screen and Move (now at the top of the tab, AT8-D6) is the only thing that moves it, so
  -- there is no longer a setting that can disagree with where it was dropped. AT6-D5 took the
  -- Preview button: the texture is on screen for as long as this tab is, so there is nothing left
  -- to ask for.
  --
  -- AT8-D6: Reset stays down here on its own now that Move has moved to the top -- padded from the
  -- left so it still lands flush right, the same "only a Button fills its cell" trick the row used
  -- while it shared it with Move.
  args.resetGap = {
    type = "description", order = 21, width = "relative", relWidth = 1 - TEXTURE_RESET_WIDTH, name = "",
  }
  -- AT6-D6, confirm-gated like All abilities > Glow's own reset and implemented the same way:
  -- DELETING the stored channel rather than writing the defaults into it, so "never chosen" is the
  -- state it lands in -- which is what a class pack's own defaults for this ability fall back
  -- through (AbilitySettings.effective), and what a fresh install looks like.
  args.reset = {
    type = "execute", order = 22, width = "relative", relWidth = TEXTURE_RESET_WIDTH,
    name = L["Reset"], confirm = true, disabled = off,
    desc = L["Puts the picture, size, colour, opacity, moments, fade and position back the way "
          .. "they shipped. The texture stays switched on."],
    confirmText = L["Put every texture setting for this ability back to its default?"],
    func = function()
      local S = AS()
      if not S then return end
      -- The switch at the top of the tab is not one of the settings this button resets: it is what
      -- makes them visible at all, and a Reset that greyed out the whole tab it sits on would read
      -- as the page breaking. Everything the decision enumerates is an appearance or a moment.
      local on = effective(key, "texture").enabled == true
      S.resetChannel(key, "texture")
      if on then S.set(key, "texture", "enabled", true) end
      -- AT6-D5: the held preview is standing on screen right now, so it has to show the defaults
      -- the same instant the page does.
      restyle()
    end,
  }
  -- AT9-D3 (owner), and the whole of what a hidden control is allowed to cost the player: ONE muted
  -- line, at the foot of the tab, for an ability nothing has ever seen buff you. Without it the two
  -- buff moments are simply absent and the player has no way to know they exist, let alone what
  -- would bring them back. Gone the moment the ability is learned to buff you -- which is the same
  -- moment the controls themselves appear.
  args.noBuff = {
    type = "description", order = 24, width = "full", fontSize = "medium",
    hidden = function() return not unknown() end,
    name = ns.Colors.wrap(ns.Colors.MUTED,
      L["Buff options appear once Elmira has seen this ability put a buff on you."]),
  }
  args.silent = {
    type = "description", order = 23, width = "full", fontSize = "medium",
    hidden = function()
      local e = effective(key, "texture")
      if not (A and A.channelOn(key, "texture")) then return true end
      for _, event in ipairs(textureList("EVENTS")) do
        -- AT9-D3: a buff moment that is ticked on an ability nothing has ever seen buff you is a
        -- moment that cannot happen AND a control that is not on the page -- counting it would
        -- silence this warning for exactly the ability that most needs it.
        if e[event] and not (BUFF_EVENTS[event] and unknown()) then return true end
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

-- AT8-D4, verbatim (owner's wording), rewritten for this channel exactly as the decision names:
-- "a flash" becomes "a screen-edge flash", and the persistence sentence drops -- a screen flash is
-- always an instant, never a held state.
local EDGE_EVENT_DESC = {
  suggested = "While the rotation has this ability in the first slot.",
  ready = "A screen-edge flash of a second and a half when its cooldown finishes.",
}

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
      desc = L[EDGE_EVENT_DESC[event]],
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
  -- AT8-D1: the warning threshold is per ability and never inherited now, so All abilities has
  -- nothing left to offer here -- its General tab keeps only "Only in combat". The per-ability
  -- copies live on the Sound and Texture tabs, right next to the moment they gate.
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
