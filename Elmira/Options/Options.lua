-- Elmira/Options/Options.lua — the settings UI (AceConfig-3.0).
--
-- Every user-facing string goes through AceLocale (`ns.L[...]`), enUS only in v1, so a translation
-- is a data file rather than a rewrite.
--
-- ADR-0009 forbids a global "screen flash on" switch, so there isn't one anywhere in here: since
-- AB2 every cue -- glow, screen edge, sound, announcement -- is a setting on ONE ability, and this
-- page owns only what is true of the whole addon (routing, the master mute, the log).
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Options = {}
local L = ns.L

-- User-facing names for Core/Visibility's modes. They live here, not in Core: Core decides what the
-- modes mean, Options decides what they are called, and only this side goes through AceLocale.
local LABELS = {
  always = "Always",
  combat_or_target = "In combat, or when you have a target",
  combat = "In combat only",
}
-- AT2-D1: Options/Spells.lua's Glow tab offers the SAME dropdown, verbatim -- shared by reference
-- rather than by a second copy of the English so the two pages cannot say the mode differently.
-- Spells.lua loads before this file (Elmira_Vanilla.toc), but only ever reads this inside an
-- AceConfig `values` callback, which fires long after every file has loaded.
Options.VISIBILITY_LABELS = LABELS

-- PE9-D4. Same split as LABELS above: Display/Queue.lua decides what these strings DO, this side
-- decides what they are called and in what order the dropdown offers them. Loosest last in both,
-- so "Off" is always the first entry.
local WAIT_LABELS = {
  off = "Off",
  gcd = "Only when longer than a GCD",
  always = "Always",
}
local WAIT_ORDER = { "off", "gcd", "always" }
local KEYBIND_LABELS = {
  off = "Off",
  first = "On the first icon only",
  all = "On every icon",
}
local KEYBIND_ORDER = { "off", "first", "all" }

-- PE10-D1. Core/Transition.GROW is the authority on which directions exist and in what order the
-- dropdown offers them; this only names them, so a direction added there cannot appear unnamed.
local GROW_LABELS = {
  right = "Right",
  left = "Left",
  down = "Down",
  up = "Up",
}

-- AceConfig wants `values` as a map and `sorting` as a list; building both from one ordered list
-- means a mode can never appear in the dropdown without a name or in the wrong place.
local function choices(labels, order)
  local values = {}
  for _, key in ipairs(order) do values[key] = L[labels[key]] end
  return values
end

local function profile()
  return ns.db and ns.db.profile
end

-- Anything that changes HOW the queue is drawn rather than WHAT it contains has to force a repaint:
-- the driver skips rendering when the queue is unchanged, so a scale or depth change would
-- otherwise not appear until the rotation happened to move on.
local function redraw()
  if ns.Queue then ns.Queue.Layout() end
  if ns.Display then ns.Display.refresh() end
end

-- An appearance change cannot be applied to a glow that is already RUNNING: LibCustomGlow builds
-- its frames from the arguments it was started with. Tearing them down is what makes the next
-- render rebuild with the new settings; without it the panel changes and the button does not.
-- A preview in flight is restarted for the same reason -- it is the one glow no render will redraw.
local function restyle()
  if ns.Glow then ns.Glow.StopAll() end
  if Options.previewRunning() then Options.previewGlow() end
  redraw()
end


-- ============================================================ Action Bars
-- The section that answers "why is nothing glowing" without the player having to type a slash
-- command or know what a provider is. Three parts: which bar addon is in use, a preview that proves
-- the glow itself works, and a per-spell check.
--
-- Vocabulary rule for everything below: "bar addon", "button", "your action bars". Never "provider",
-- "library" or "adapter" -- those are correct in the code and meaningless in a settings panel.

local BAR_STATE = {
  active   = "Detected — in use",
  inactive = "installed, but %s is handling your bars",
  absent   = "not installed",
  fallback = "available (fallback)",
}

local BAR_BLURB = {
  ElvUI        = "Elmira is glowing buttons on your ElvUI action bars.",
  Bartender4   = "Elmira is glowing buttons on your Bartender4 action bars.",
  Dominos      = "Elmira is glowing buttons on your Dominos action bars.",
  ["Action bars"] = "Elmira is glowing buttons on your action bars.",
  Blizzard     = "Elmira is glowing buttons on the default action bars.",
}

local BAR_NAMES = { Blizzard = "Blizzard default bars" }

-- PE6-D5 (2026-09-08 owner ruling): which of the shipped mark textures stands for each bar state.
-- The ASCII `>>`/`--` this replaces was a workaround for a constraint that no longer exists: the
-- client's font has no U+25CF/U+25CB, so glyph dots rendered as identical empty squares -- but a
-- TEXTURE draws where a glyph does not, which is why PE2 shipped `Elmira/media/mark_*.tga` and the
-- Builder's status column reads them. Referenced through `Rotation.MARKS` rather than rebuilt here,
-- so the two status columns in the panel can never disagree about what green means.
--
-- `fallback` shares `waiting` with `inactive` on purpose: from the player's side both mean "these
-- bars are not the ones being glowed right now, but they could be", which is one state, not two.
local BAR_MARKS = {
  active   = "firing",
  inactive = "waiting",
  fallback = "waiting",
  absent   = "blocked",
}

-- The addon NAME keeps its white/grey treatment (D5: only the STATE words gained colour), so this
-- answers for the state half alone. Degrades to the old grey when Rotation has not loaded, because
-- a panel that renders unmarked rows is better than one that errors.
local function barMark(state)
  local marks = ns.Rotation and ns.Rotation.MARKS
  local look = marks and marks[BAR_MARKS[state] or ""]
  if not look then return "", "|cff9AA0A6" end
  return look.mark .. " ", look.colour
end

local function barRows()
  local args, order = {}, 0
  for _, r in ipairs((ns.BarProviders and type(ns.BarProviders.status) == "function" and ns.BarProviders.status()) or {}) do
    order = order + 1
    local label = L[BAR_NAMES[r.name] or r.name]
    local state = r.state == "inactive"
      and string.format(L[BAR_STATE.inactive], tostring(r.activeName))
      or L[BAR_STATE[r.state]]
    local mark, stateColour = barMark(r.state)
    local grey = (r.state == "absent") and "|cff9AA0A6" or "|cffFFFFFF"
    args["row" .. order] = {
      type = "description", fontSize = "medium", order = order, width = "full",
      name = string.format("%s%s%s|r  %s%s|r", mark, grey, label, stateColour, state),
    }
    if r.state == "active" and BAR_BLURB[r.name] then
      order = order + 1
      args["blurb" .. order] = {
        type = "description", fontSize = "medium", order = order, width = "full",
        name = "      |cff9AA0A6" .. L[BAR_BLURB[r.name]] .. "|r",
      }
    end
  end
  return args
end

-- Preview state. A previewed frame is NOT in the render loop's `nowFrames` set, so nothing in
-- Display/Glow.lua will ever clear it -- the preview has to stop itself or it burns until the next
-- StopAll. Held here so a second click, or the panel closing, can cancel an in-flight one.
local previewFrame, previewTimer, previewNote = nil, nil, ""

local function stopPreview()
  local frame, timer = previewFrame, previewTimer
  previewFrame, previewTimer = nil, nil
  -- Cancel FIRST. Without this the first click's timer is still pending when a second preview
  -- starts, and fires four seconds after click one -- killing the second preview early.
  if timer and ns.addon and ns.addon.CancelTimer then pcall(ns.addon.CancelTimer, ns.addon, timer) end
  if not (frame and ns.Glow) then return end
  -- Between lighting this button and getting here, the rotation may have moved on and the render
  -- loop may have taken the same frame -- as the real suggestion, or as the dim hint on the one
  -- after it. Stopping it then darkens a button that should be lit, and SetNowSlot still believes
  -- it is lit, so it stays dark until that suggestion changes away and back. Asking only about the
  -- NOW set was this bug with the second key added underneath it.
  if ns.Glow.isRendererFrame and ns.Glow.isRendererFrame(frame) then return end
  ns.Glow.Stop(frame)
end

-- Is a preview still lit? Only this file knows: a previewed frame is deliberately outside the
-- render loop's set, so nothing else can see it. `restyle` needs the answer to relight it with new
-- settings, because no render ever will.
-- Put every glow setting back the way it shipped. Asked for because the settings are worth playing
-- with and there was no way back: the colour picker's own Default button belongs to Blizzard's
-- frame and does not touch what we stored.
--
-- AB1-D3: this is now the All abilities > Glow reset. Deleting the stored channel rather than
-- writing the defaults into it is what restores "never chosen", which is the state a fresh install
-- is in -- and abilities inheriting from it follow in the same click.
function Options.resetGlow()
  local A = ns.AbilitySettings
  if not (A and A.resetChannel(A.ALL, "glow")) then return false end
  restyle()
  return true
end

function Options.previewRunning()
  return previewFrame ~= nil
end

-- Fires the real glow, on demand, with no combat and no rotation state. This is the single most
-- useful control in the panel: it separates "the glow is broken" from "nothing is being suggested
-- right now", which are indistinguishable to a player standing in a city and are the likeliest
-- source of a bug report that is not a bug.
--
-- AB1-D7: `key` is which ability to preview -- the Abilities page's own Glow tab passes the one
-- being edited, so what flashes is that ability's colour and style rather than the suggestion's.
-- Left out, it still means "whatever is being suggested right now", which is what the Action Bars
-- panel wants.
function Options.previewGlow(secondary, key)
  stopPreview()
  key = key or Options.checkSpell()
  local buttons = key and ns.BarGlow and ns.BarGlow.buttonsFor(key)
  local frame = buttons and buttons[1]
  if not frame then
    previewNote = L["No button to preview: the spell below is not on a bar Elmira can see."]
    return false
  end
  local style = (ns.Glow and ns.Glow.styleFor(key)) or "PROC"
  if not (ns.Glow and ns.Glow.Start(frame, style, secondary and true or false, key)) then
    previewNote = L["The glow library is not loaded, so Elmira cannot draw a glow at all."]
    return false
  end
  previewFrame = frame
  if ns.addon and ns.addon.ScheduleTimer then
    previewTimer = ns.addon:ScheduleTimer(stopPreview, 4)
    previewNote = L["Glowing that button now — look at your action bars."]
  else
    -- No timer means nothing will ever stop this. Say so rather than claiming a preview that ends:
    -- a glow the player cannot get rid of is a worse outcome than no preview.
    previewNote = L["Glowing that button now — it will stay lit until the next suggestion changes."]
  end
  return true
end

-- Which spell the per-spell check runs against. Defaults to the current top suggestion, so the
-- common case needs no typing; the dropdown exists for the more interesting one, where the spell
-- you want to ask about is precisely the one that is NOT being suggested.
local chosenSpell = nil

function Options.checkSpell()
  if chosenSpell then return chosenSpell end
  if not (ns.Display and type(ns.Display.computeQueue) == "function") then return nil end
  local ok, queue = pcall(ns.Display.computeQueue, 1)
  local slot = ok and type(queue) == "table" and queue[1]
  return slot and slot.spell or nil
end

function Options.setCheckSpell(key)
  chosenSpell = key
end

-- Symbolic keys (`HAMMER_OF_WRATH`) are how the engine names spells and are not what the player
-- calls them. Show the real name where the client can resolve one; fall back to the key rather than
-- to nothing, because a blank row is worse than an ugly one.
--
-- AB4-D4: `Display.spellName`, not a fourth copy of the lookup. The copy that was here read
-- `pack.spells` alone, so on a class with no shipped pack this list named every ability by its raw
-- key -- and the fallback then made that look deliberate.
local function spellLabel(key)
  local name = ns.Display and ns.Display.spellName and ns.Display.spellName(key)
  return name or tostring(key)
end

-- The spells the ACTIVE BUILD actually suggests, not everything in the class data.
--
-- Offering the whole pack listed passive runes ("The Art of War") which can never be on a bar, and
-- listed the same ability twice whenever two records resolved to one spell name -- Seal of
-- Martyrdom appeared under both its own key and its rune's. Neither is a question the player can
-- usefully ask: "is my spell showing" is about things the rotation tells you to press.
local function spellChoices()
  local out, seen = {}, {}
  local build = ns.Display and ns.Display.activeBuild and select(1, ns.Display.activeBuild())
  for _, entry in ipairs((build and build.entries) or {}) do
    local key = entry.spell
    if key and not out[key] then
      local label = spellLabel(key)
      -- Two keys resolving to one spell name is a duplicate to the reader even though the keys
      -- differ, so the LABEL is what has to be unique.
      if not seen[label] then
        seen[label] = true
        out[key] = label
      end
    end
  end
  local current = Options.checkSpell()
  if current and not out[current] then out[current] = spellLabel(current) end
  return out
end

local CHECK_LABELS = {
  bars    = "Bar addon detected",
  placed  = "Spell is on a bar",
  visible = "Button is visible",
  glow    = "Glow is switched on",
  showing = "Elmira is showing right now",
  spell   = "Spell is in your playstyle",
}

-- The highest-value strings in the whole panel: on failure a row has to say what to DO, in a
-- sentence, without the reader knowing anything about how Elmira works.
local CHECK_FAILED = {
  placed  = "not on any action bar — drag it onto a bar, or into a macro on one",
  visible = "on a bar you cannot see right now — check your stance, form or bar paging",
  spell   = "not part of your current playstyle, so it is never suggested",
}

-- Two different switches can leave a perfectly placed, perfectly visible button dark, and the
-- panel used to blame the same one every time -- telling people to turn on a toggle that was
-- already on. `detail` says which.
local GLOW_OFF = {
  addon = "Elmira itself is switched off — turn on \"Show the queue\"",
  -- PE6-D4.3 renamed the toggle; this sentence names it, so it moves with it. A cure that names a
  -- control the panel no longer has is worse than no cure at all.
  bars  = "switched off above — turn on \"Enable action bar glow\"",
}

-- Why the display is hidden, in the player's words. Display.shouldShow's reasons are internal.
local HIDDEN_BECAUSE = {
  ["out of combat"] = "hidden until you are in combat — that is this profile's setting",
  ["out of combat, no target"] = "hidden until you are in combat or have a target",
  ["display disabled"] = "the queue is switched off",
}

-- Turns a row's DATA into the words for it. Detail is never a sentence on the Display side, so all
-- the English -- and all the AceLocale -- lives here.
local function checkDetail(r)
  if r.label == "glow" and r.ok == false then return L[GLOW_OFF[r.detail] or GLOW_OFF.bars] end
  if r.label == "showing" and r.ok == false then
    return L[HIDDEN_BECAUSE[r.detail] or "hidden right now"]
  end
  if r.ok == false then return L[CHECK_FAILED[r.label] or ""] end
  if r.label == "bars" then
    return r.detail == "blizzard" and L["Blizzard default bars"] or tostring(r.detail)
  end
  if r.label == "placed" then
    return r.detail == 1 and L["on one button"] or string.format(L["on %d buttons"], r.detail or 0)
  end
  return r.detail and tostring(r.detail) or ""
end

-- Keyed by the row's `ok`: true, false, and nil for "not reached".
-- ASCII for the same reason as the bar list: the client's font renders U+2714/U+2718 as empty
-- boxes, so a pass and a failure looked identical apart from colour -- and colour alone is not a
-- signal. `--` for a stage that was never reached: visibly not a verdict either way.
local CHECK_MARKS = setmetatable(
  { [true] = { "OK  ", "|cff40c057" }, [false] = { "FAIL", "|cffe03131" } },
  { __index = function() return { "--  ", "|cff9AA0A6" } end })

local function checkRows()
  local key = Options.checkSpell()
  if not key then
    return { none = { type = "description", fontSize = "medium", order = 1, width = "full",
                      name = L["Nothing is being suggested right now, so there is nothing to check."] } }
  end
  local args = { header = { type = "description", fontSize = "medium", order = 0, width = "full",
                            name = string.format(L["Checking %s:"], spellLabel(key)) } }
  for i, r in ipairs((ns.BarGlow and type(ns.BarGlow.check) == "function" and ns.BarGlow.check(key)) or {}) do
    -- Glyph AND colour, never colour alone: red/green is the first thing to go for a colour-blind
    -- reader, and "—" has to be visibly different from a tick, not merely a different green.
    local look = CHECK_MARKS[r.ok]
    local mark, colour = look[1], look[2]
    args["row" .. i] = {
      type = "description", fontSize = "medium", order = i, width = "full",
      name = string.format("%s%s|r %s  |cff9AA0A6%s|r",
        colour, mark, L[CHECK_LABELS[r.label] or r.label], checkDetail(r)),
    }
  end
  return args
end

-- PE7-D1 retired the second master switch: `glow.enabled` said nothing `glow.barGlow` did not
-- already say once ADR-0015 took the queue strip out of the glow set, and two switches for one
-- effect is how a player turns the wrong one on and sees nothing. `barGlow` is now the only gate
-- (`Display/Glow.lua`, `Display/BarGlow.lua`), which is why PE6's grey-out of this very toggle is
-- gone with it: nothing sits above it any more.
--
-- What survives is the level below. The cast-after-next controls moved onto this panel (PE7-D3) and
-- they DO have a master here, so they go `disabled` when it is off -- `disabled` only, never a get()
-- that lies or a set() that writes, so turning the bar glow back on restores what the player chose.
local function barGlowOff()
  local p = profile()
  return not (p and p.glow and p.glow.barGlow)
end

local function actionBarsGroup()
  previewNote = ""
  return {
    intro = {
      type = "description", fontSize = "medium", order = 0, width = "full",
      name = L["Elmira glows the button holding your next suggested spell."],
    },
    bars = {
      type = "group", inline = true, order = 1, name = L["Bar Addons"],
      args = barRows(),
    },
    -- PE6-D4.4: the master toggle and its preview moved INTO this panel, because they are what the
    -- panel is about -- the check rows below diagnose exactly the switch that now sits above them.
    -- The pair share one row (`width = "relative"`, relWidths summing to exactly 1.0 -- AceGUI's
    -- Flow scales only that shape, AceGUI-3.0.lua:709-711) so the button reads as belonging to the
    -- toggle rather than as a third setting.
    check = {
      type = "group", inline = true, order = 2, name = L["Action bar glow"],
      args = {
        barGlow = {
          type = "toggle", order = 1, width = "relative", relWidth = 0.75,
          name = L["Enable action bar glow"],
          desc = L["Highlights the button on your bars, not just the queue icon."],
          get = function() return profile().glow.barGlow end,
          set = function(_, v)
            profile().glow.barGlow = v
            if ns.Glow then ns.Glow.StopAll() end   -- drop glows we will no longer be refreshing
            redraw()
          end,
        },
        preview = {
          type = "execute", order = 2, width = "relative", relWidth = 0.25,
          name = L["Preview Glow"],
          desc = L["Glows the button for your current suggestion for a few seconds, "
                .. "so you can see the effect without waiting for a fight."],
          func = function() Options.previewGlow() end,
        },
        previewNote = {
          type = "description", fontSize = "medium", order = 3, width = "full",
          name = function() return previewNote end,
        },

        -- PE7-D3: the cast-after-next cluster moved here from the Glow page, whole. It is a second
        -- glow ON THE BARS, so it belongs beside the switch that decides whether the bars glow at
        -- all; left behind, its three companions appeared on one page only when a toggle on another
        -- page was set. The header stays, because "the next cast" and "the cast after next" are one
        -- word apart and the toggle's name alone does not separate them.
        hintHeader = { type = "header", order = 4, name = L["The cast after next"] },
        secondary = {
          type = "toggle", order = 5, width = "full",
          name = L["Glow the next cast"],
          desc = L["A second, quieter glow on the suggestion after the current one. Off by "
                .. "default: two lit buttons compete for the same glance, which is the reason "
                .. "the queue itself stopped glowing."],
          disabled = barGlowOff,
          get = function() return profile().glow.secondary == true end,
          set = function(_, v) profile().glow.secondary = v; restyle() end,
        },
        secondaryAlpha = {
          type = "range", order = 7, name = L["How dim it is"],
          desc = L["A fraction of the main glow. Some styles drive their own brightness, so a "
                .. "value that looks clearly dimmer on one can look identical on another -- "
                .. "compare them with the two preview buttons."],
          min = 0.05, max = 1, step = 0.05,
          hidden = function() return profile().glow.secondary ~= true end,
          disabled = barGlowOff,
          get = function() return ns.Glow and ns.Glow.secondaryAlpha() or 0.35 end,
          set = function(_, v) profile().glow.secondaryAlpha = v; restyle() end,
        },
        -- The same button as the ordinary preview, so the two are directly comparable. Two
        -- different buttons would put the comparison at the mercy of where they sit.
        previewDim = {
          type = "execute", order = 8, name = L["Preview"],
          desc = L["Flashes the SAME button as the preview above, dimmed, so you can compare "
                .. "the two brightnesses without waiting for a fight."],
          hidden = function() return profile().glow.secondary ~= true end,
          disabled = barGlowOff,
          func = function() Options.previewGlow(true) end,
        },

        pick = {
          type = "select", order = 9, name = L["Test with"],
          desc = L["Defaults to whatever Elmira is suggesting right now."],
          values = spellChoices,
          get = function() return Options.checkSpell() end,
          set = function(_, v) Options.setCheckSpell(v) end,
        },
        rows = { type = "group", inline = true, order = 10, name = "", args = checkRows() },
      },
    },
  }
end

-- AB4-D2: `overlayGroup()` -- the Peripheral cues page -- is gone with the node that showed it. It
-- had been one line of signposting since AB2-D1 pointed the controls at Abilities > the ability >
-- Screen-edge, and a signpost that outlives the people who knew the old page is just another page
-- to read. Nothing has ever shipped, so there is nobody to lead there.

-- ---------------------------------------------------------------------------------------------
-- Import / Export (PRD F9). Chat truncates long messages, so this box is where a build string is
-- actually copied from (`/elm export` fills it) and pasted into (an ELM1: string imports as one of
-- the user's builds, ADR-0010). The logic lives in Core/UserBuilds.lua; this is the field.
-- ---------------------------------------------------------------------------------------------
local exchangeText, exchangeNote = "", ""

function Options.setExchangeText(str)
  exchangeText = tostring(str or "")
  exchangeNote = ""
end

function Options.exchangeText()
  return exchangeText
end

-- The one-line result under the box. Read by Options/Rotation.lua's Share tab, which owns the
-- widget while the state stays here.
function Options.exchangeNote()
  return exchangeNote
end

-- AB2-D5: the Share tab's Export button has a result to report too, and `setExchangeText` clears
-- the note on purpose (a stale "Import failed" under a freshly pasted string is worse than none).
-- One writer for both, so the two cannot drift.
function Options.noteExchange(text)
  exchangeNote = tostring(text or "")
end

-- Options.importText(str) -> true, key | false. Keeps the text in the box on failure so the user
-- can fix it, clears it on success, and leaves a one-line result under the box either way.
function Options.importText(str)
  local pack = ns.Display and ns.Display.currentPack and ns.Display.currentPack()
  if not (ns.UserBuilds and pack) then
    exchangeNote = L["Import: no data pack for your class."]
    return false
  end
  -- The second return is the count of ability settings that came WITH the rotation (AB2-D5) on
  -- success, and the failure reason otherwise.
  local key, extra = ns.UserBuilds.importString(str, pack, {
    today = ns.Adapter and ns.Adapter.today and ns.Adapter.today() or nil,
  })
  if not key then
    exchangeText = tostring(str or "")
    exchangeNote = string.format(L["Import failed: %s"], tostring(extra))
    return false
  end
  exchangeText = ""
  exchangeNote = string.format(L["Imported as %s. /elm profile %s to use it."], key, key)
  -- Said out loud: settings that arrived silently and overwrote what the player had are the worst
  -- possible surprise, and settings that did NOT arrive look identical to ones that did.
  if type(extra) == "number" and extra > 0 then
    exchangeNote = exchangeNote .. " " ..
      string.format(L["Also merged the settings of %d abilities."], extra)
  end
  if ns.Display and ns.Display.refresh then ns.Display.refresh() end
  return true, key
end

-- ============================================================ Notifications (F37, D21-D29)
-- One page, not a tab of its own (2026-09-07 Notifications pass): the whole of what used to be the
-- "Announcements" sub-page is now the content of Notifications itself. AB4-D2: it has no sub-pages
-- left either -- Peripheral cues went to the abilities that own them, and the one control the Cue
-- sounds page still had (the mute over every ability sound) is a panel on this page.
--
-- PE13-D1: the Log is the LAST thing on the page, inside a panel of its own. It used to be the
-- first, one row per message, which meant the settings below it started at a different height every
-- time the addon said something -- the page moved under the player as the log filled up. A group
-- has ONE order however many rows are inside it, so the switches now sit where they sat last time.
local LOG_LINES = 20
-- After every setting on the page (the highest of which is 67), with room left over: this number is
-- the whole point of the panel, so it is a constant rather than a literal buried in the table.
local LOG_ORDER = 90
-- How tall the copy box is. Fewer than the lines it can hold, on purpose: the widget scrolls, and a
-- box that grew with the log would put the settings above it back on the moving page PE13-D1 fixed.
local LOG_BOX_LINES = 12

-- FX1-D3. The log as plain text, newest first, one line per message with the category that carried
-- it. No colour codes: they would be copied out with the text, and "|cffE05555Warning|r" in a bug
-- report is worse than no colour at all.
--
-- A function rather than a string built into the options table, because AceConfig reads `get` again
-- on every refresh -- a captured string would freeze the box at whatever had been said when the
-- page was last rebuilt.
function Options.logText()
  local A = ns.Announce
  local rows = (A and A.log(LOG_LINES)) or {}
  local lines = {}
  for i, row in ipairs(rows) do
    local cat = A.category(row.category)
    lines[i] = string.format("%s  %s", L[(cat and cat.label) or row.category], A.plain(row.text))
  end
  return table.concat(lines, "\n")
end

-- D22: the same sentence, on every toggle in a category's row -- chat, screen, sound, party and
-- raid alike -- because what a user needs to know before flipping a switch is WHEN this kind of
-- message happens, not which pipe carries it. Verbatim from the "When it fires" column of the
-- Notifications artifact (e1fc0af9), not authored here.
--
-- AB1-D10: the `cooldown` sentence is back with its row. WHETHER a cooldown is announced is the
-- ability's own Announcement tab; this page still decides where the resulting line goes.
local WHEN_IT_FIRES = {
  cooldown = "You use an ability whose Announcement tab is switched on (Abilities > the ability > "
          .. "Announcement) -- off for every ability until you turn one on",

  rotation = "Your gear, runes or buffs change and a line in your rotation becomes usable or stops "
          .. "being usable",
  warning  = "Elmira cannot do its job: no visible bar button holds the spell, or a display "
          .. "component errored",
  status   = "First login before setup, after a catalog update, and when Learning mode rewrites "
          .. "two other settings",
}

-- One channel of one category, stored. The EFFECTIVE routing is read before anything is written:
-- creating the row first makes `A.routes` see an empty stored table and stop falling back, so
-- switching one channel on would switch every other channel for that category off. One writer for
-- the chat/screen/sound loop and for the party/raid pair (AB1-D10), so the two cannot drift.
local function setRoute(key, channel, on)
  local a = profile().announce
  local stored = a.routes[key]
  if not stored then
    stored = ns.Announce.routes(key)
    a.routes[key] = stored
  end
  stored[channel] = on
end

local function announceGroup()
  local args = {}
  local A = ns.Announce

  args.intro = {
    type = "description", order = 0, fontSize = "medium",
    name = L["Everything Elmira says out loud, and how loudly: pick a chat, a screen message, a "
          .. "sound, or nothing at all, for each kind."],
  }

  -- PE13-D1. Same keys as before, one level deeper: the rows keep their newest-first order INSIDE
  -- the panel, and the panel's own order is the fixed thing nothing can shift.
  --
  -- AT10-D2 (owner): the per-category coloured rows FX1 took out are back, above the copyable box --
  -- one heading for both. The rows are what a player actually reads (the category tells them WHY a
  -- line fired, in the colour ADR-0009's cues already use for that category); the box below stays for
  -- copying into a bug report, where the same colour codes would just be noise in the pasted text.
  local logArgs = {}
  logArgs.logHeader = {
    type = "description", order = 1, fontSize = "medium",
    name = ns.Colors.wrap(ns.Colors.MUTED,
             L["everything Elmira has said, newest first — kept whatever the routing above says"]),
  }
  local rows = (A and A.log(LOG_LINES)) or {}
  if #rows == 0 then
    logArgs.logEmpty = {
      type = "description", fontSize = "medium", order = 2,
      name = ns.Colors.wrap(ns.Colors.MUTED, L["Nothing yet."]),
    }
  end
  for i, row in ipairs(rows) do
    local cat = A.category(row.category)
    logArgs["log" .. i] = {
      type = "description", fontSize = "medium", order = 1 + i,
      name = ns.Colors.wrap(ns.Colors.MUTED, L[(cat and cat.label) or row.category]) .. "  " ..
             ns.Colors.wrap((cat and ns.Colors[cat.color]) or ns.Colors.MUTED, A.plain(row.text)),
    }
  end
  if #rows > 0 then
    logArgs.lines = {
      type = "input", multiline = LOG_BOX_LINES, width = "full", order = 1 + #rows + 1,
      name = L["Messages"],
      get = function() return Options.logText() end,
      -- Read-only. The box exists so the widget's own click-drag, Ctrl-A and Ctrl-C work on the
      -- text (FX1-D3, the owner: "I think I should be able to copy any lines I want"); storing
      -- anything typed into it would let a stray keystroke rewrite the record of what was said.
      -- AceConfig needs the key to be there, so it is a function that does nothing rather than
      -- nothing at all.
      set = function() end,
    }
  end
  logArgs.logClear = {
    type = "execute", order = 30, name = L["Clear Messages"],
    func = function() if A then A.clear() end end,
  }
  args.log = {
    type = "group", inline = true, order = LOG_ORDER, name = L["Notifications Log"],
    args = logArgs,
  }

  args.routing = {
    type = "header", order = 40, name = L["Where each kind of message goes"],
  }
  -- PE14-D3: `listed()`, not `CATEGORIES` -- one list in Core decides which kinds this page routes
  -- AND which kinds `Test Each Kind` sends, so the button cannot demonstrate a row that is not
  -- here. `cooldown` is the only one left out today, and with it go the Party/Raid toggles (it is
  -- the only shareable category) and the cooldown-length slider: announcing a long cooldown is a
  -- property of the ability, and the Abilities redesign owns it. The engine side is untouched.
  for i, cat in ipairs((A and A.listed()) or {}) do
    local channels = {}
    local when = WHEN_IT_FIRES[cat.key]
    -- The Log is not offered: it is the record, not a channel.
    --
    -- Ordered by Announce.CHANNELS rather than by pairs(), which put the toggles in a different
    -- order for every category and a different order again on another Lua build.
    local names = { chat = L["Chat"], screen = L["Screen"], sound = L["Sound"] }
    local order = 0
    for _, channel in ipairs(A.CHANNELS) do
      local label = names[channel]
      if label then
        order = order + 1
        channels[channel] = {
          type = "toggle", order = order, name = label, width = 0.7, desc = when,
          get = function() return A.routes(cat.key)[channel] == true end,
          set = function(_, v) setRoute(cat.key, channel, v) end,
        }
        if channel == "sound" then
          -- D24: which sound plays for THIS category, revealed only while its Sound toggle is on.
          channels.soundPick = {
            type = "select", order = order + 0.5, name = L["Sound"],
            desc = L["Which sound plays for this kind of message. Left alone, it uses the sound "
                  .. "below."],
            hidden = function() return A.routes(cat.key).sound ~= true end,
            values = function() return ns.Announcers and ns.Announcers.sounds() or {} end,
            get = function()
              local a = profile().announce
              local per = a.sounds and a.sounds[cat.key]
              if per and per ~= "" then return per end
              return a.sound or "None"
            end,
            set = function(_, v)
              local a = profile().announce
              a.sounds = a.sounds or {}
              a.sounds[cat.key] = v
              -- PE14-D2: hear what you just picked. The list is whatever media packs the player
              -- runs, so a name alone tells them nothing and the only other way to audition one
              -- was to go and trigger a real notification. Stored FIRST, then played through the
              -- sink itself (Announcers.sound reads the same stored value the real announcement
              -- will) rather than a second fetch-and-play written here -- one path, so what you
              -- hear now is what you will hear then. "None" is silence, and that file degrades
              -- rather than errors when LibSharedMedia is absent or the name no longer resolves.
              if ns.Announcers and ns.Announcers.sound then ns.Announcers.sound(cat) end
            end,
          }
        end
      end
    end
    -- AB1-D10: the Party/Raid pair is back with the `cooldown` row it belongs to. Gated on
    -- `shareable`, which is a property of the CATEGORY in code and not a checkbox the user can
    -- widen -- "Divine Storm is now active in my rotation" is about the player's own bars and is
    -- noise in a group. Two toggles rather than one (D22): reaching a five-man says nothing about
    -- whether it belongs in a twenty-man raid.
    if cat.shareable then
      local group = { party = L["Party"], raid = L["Raid"] }
      for _, channel in ipairs({ "party", "raid" }) do
        order = order + 1
        channels[channel] = {
          type = "toggle", order = order, name = group[channel], width = 0.7, desc = when,
          get = function() return A.routes(cat.key)[channel] == true end,
          set = function(_, v) setRoute(cat.key, channel, v) end,
        }
      end
    end
    args["cat" .. cat.key] = {
      type = "group", order = 40 + i, name = ns.Colors.wrap(ns.Colors[cat.color], L[cat.label]),
      inline = true, args = channels,
    }
  end

  args.where = { type = "header", order = 60, name = L["How they look"] }
  -- D25: no more "which of my tabs" select -- a stored index went stale the moment a tab was
  -- renamed or closed. Elmira now finds the tabs itself.
  args.chatInfo = {
    type = "description", order = 61, fontSize = "medium",
    name = L["Chat lines appear in any chat window that shows System messages."],
  }
  args.font = {
    type = "select", order = 62, name = L["Screen font"],
    values = function() return ns.Announcers and ns.Announcers.fonts() or {} end,
    get = function() return profile().announce.screen.font end,
    set = function(_, v)
      profile().announce.screen.font = v
      if ns.Announcers then ns.Announcers.ApplyFont() end
    end,
  }
  args.size = {
    type = "range", order = 63, name = L["Screen text size"], min = 10, max = 36, step = 1,
    get = function() return profile().announce.screen.size end,
    set = function(_, v)
      profile().announce.screen.size = v
      if ns.Announcers then ns.Announcers.ApplyFont() end
    end,
  }
  args.duration = {
    type = "range", order = 64, name = L["Seconds on screen"], min = 1, max = 15, step = 1,
    get = function() return profile().announce.screen.duration end,
    set = function(_, v)
      profile().announce.screen.duration = v
      if ns.Announcers then ns.Announcers.ApplyFont() end
    end,
  }
  -- PE13-D2/D3. The Queue page's "Position the Strip" and this button do the same job, so they are
  -- the same control: an execute that relabels while the mode is on, never disabled, and no lock to
  -- go and undo somewhere else first. `locked` defaults to true, so as a toggle with
  -- `disabled = positionsLocked` this was grey out of the box and sent the player to another page.
  --
  -- Move mode never writes `locked` -- not written and restored, WRITTEN NOWHERE (Announcers.lua):
  -- a /reload or a disconnect mid-drag would otherwise leave the temporary value on disk as the
  -- player's setting. An explicit lock decision still wins, because Queue.SetLocked ends this mode
  -- before it stores anything, whether it came from "Lock all positions" or /elm lock.
  local function movingNow() return (ns.Announcers and ns.Announcers.isMoving()) == true end
  args.move = {
    type = "execute", order = 66,
    name = function() return movingNow() and L["Done Moving"] or L["Move screen messages"] end,
    desc = L["Shows one sample of every kind so you can see how tall it gets, and lets you drag it. "
          .. "Press it again when it is where you want it. Your lock setting is left exactly as it "
          .. "was, and closing this window ends it too."],
    func = function()
      if not ns.Announcers then return end
      if movingNow() then ns.Announcers.StopMoving() else ns.Announcers.SetMoving(true) end
    end,
  }
  args.test = {
    type = "execute", order = 67, name = L["Test Each Kind"],
    desc = L["Sends one message of every kind, through whatever you have switched on above."],
    func = function() if A then A.test() end end,
  }
  -- AB1-D8's master mute, AB4-D2's panel. It was a sub-PAGE of this one with a single toggle on it,
  -- which is a click and a page-load to reach one checkbox; a page of its own is what a page with
  -- controls on it earns. Per CHARACTER (`db.char.sounds`), like every other ability setting, and
  -- deliberately separate from the per-category announcement sound above: this silences what the
  -- Abilities page asks for and touches nothing on this page.
  args.abilitySounds = {
    type = "group", inline = true, order = 70, name = L["Ability sounds"],
    args = {
      enabled = {
        type = "toggle", order = 1, width = "full", name = L["Play ability sounds"],
        desc = L["Off silences every sound the Abilities page asks for, without changing "
              .. "what any ability is set to."],
        get = function() return ns.Sounds ~= nil and ns.Sounds.abilitySoundsOn() end,
        set = function(_, v) ns.db.char.sounds.enabled = v end,
      },
    },
  }
  return args
end

-- ============================================================ The options window itself
--
-- AceConfigDialog hands us AceGUI's stock Frame: 700x500, a 100px drag tab floating in the middle of
-- the title bar, a Close button at the bottom right, and no memory of where it was left. This
-- section is the window's own chrome -- the size and scale it opens at, a full-width drag bar
-- carrying the version, an X where every other addon puts one, and a way back when it ends up off
-- screen or too big to reach.
--
-- Everything here re-runs after EVERY Open and has to be idempotent. AceConfigDialog pools its
-- frames and calls SetTitle/SetStatusTable on each open, so decoration applied once is undone the
-- second time -- and a button created without a guard is created again on top of the first.

-- ElvUI's floor and margin (Config.lua:664-676). The margin matters: a window resizable to exactly
-- the screen has no grab handle left on it.
local WINDOW_MIN_W, WINDOW_MIN_H, WINDOW_MARGIN = 800, 560, 50
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.9, 1.4, 0.05
-- Every one of AceGUI's three title-bar textures is file id 131080, and only the middle one is
-- exposed on the widget (`titlebg`). The two end caps are locals, so they are found by texture id
-- and told apart from the middle one by identity (AceGUIContainer-Frame.lua:223-250).
local TITLE_TEXTURE = 131080

local function windowDefaults()
  return (ns.DB and ns.DB.defaults.global.window) or {}
end

-- Account-wide (Core/DB.lua): a window's size and place belong to the screen, not the character.
local function windowDB()
  local g = ns.db and ns.db.global
  if not g then return nil end
  if not g.window then g.window = {} end
  return g.window
end

local function clampScale(v)
  if type(v) ~= "number" then return windowDefaults().scale or 1 end
  if v < SCALE_MIN then return SCALE_MIN end
  if v > SCALE_MAX then return SCALE_MAX end
  return v
end

function Options.windowScale()
  local w = windowDB()
  return clampScale(w and w.scale)
end

-- The open STANDALONE panel's AceGUI widget. The Blizzard-embedded copy is deliberately not here:
-- it is a page inside Blizzard's own window, with no frame of ours to size, move, scale or close.
local function openWidget()
  local d = Options.dialog
  return d and d.OpenFrames and d.OpenFrames.Elmira or nil
end

-- The screen, in UIParent's own units. A client that will not answer still has to get a bounded,
-- placeable window rather than an arithmetic error on the way to opening the panel.
local function screenSize()
  local maxW, maxH = 1024, 768
  if UIParent and UIParent.GetWidth then
    maxW, maxH = UIParent:GetWidth() or maxW, UIParent:GetHeight() or maxH
  end
  return maxW, maxH
end

-- The title bar's height (AceGUIContainer-Frame.lua:229). Named because the ONE thing that matters
-- about a stored position is whether that bar can still be grabbed.
local TITLE_HEIGHT = 40

-- FX1-D6. Is a stored position still on the monitor?
--
-- Clamping is gone (the owner: "you can push off many of the addon's screens, so I don't think
-- clamping was a good idea"), and this is the single guarantee clamping was carrying: a position
-- saved at another resolution, on another monitor or at another scale can put the title bar -- the
-- only handle the window has -- entirely off the screen, and the window would open there with no
-- way to reach it.
--
-- `top` is the frame's top edge measured UP FROM THE BOTTOM of the screen and `left` its left edge
-- from the left, both in the FRAME's own coordinates (AceGUIContainer-Frame.lua:151-156) -- which
-- is why the screen is divided by our scale here rather than multiplied.
function Options.positionOnScreen(top, left, width)
  local scale = Options.windowScale()
  local maxW, maxH = screenSize()
  maxW, maxH = maxW / scale, maxH / scale
  if top <= 0 then return false end                      -- the bar is at or below the bottom edge
  if top - TITLE_HEIGHT >= maxH then return false end    -- ...or entirely above the top edge
  if left >= maxW then return false end                  -- ...or off the right-hand side
  if left + (width or 0) <= 0 then return false end      -- ...or off the left-hand side
  return true
end

-- The frame we have already placed. Geometry is pushed onto a window that is being PUT on screen
-- and never onto one already on it (FX1-D7): every `execute` button makes AceConfigDialog re-Open
-- the same frame (AceConfigDialog-3.0.lua:867-872), and re-applying `db.top/left` on each of those
-- snapped a window the player had since dragged back to its last SAVED spot -- or to the centre,
-- when it had never been positioned at all. That is the owner's "whenever I hit Preview for
-- texture, the Configuration popup is centred on screen again".
--
-- Cleared on close, because AceGUI's pool can hand this same table back later and the frame it
-- hands back is one that is being put on screen again.
local placedWidget = nil -- mutants: equivalent deleting the local only makes it a global

-- Push db.global.window onto the frame that is open right now. Scale FIRST: every measurement below
-- is in the frame's own coordinates, which SetScale changes underneath them.
--
-- `force` moves a frame that is already on screen: the scale slider and the reposition button both
-- have to be seen to do something by the person looking at the window they act on.
function Options.ApplyWindow(force)
  local widget = openWidget()
  local frame = widget and widget.frame
  if not frame then return false end
  local w = windowDB() or {}
  local defaults = windowDefaults()

  frame:SetScale(Options.windowScale())

  local maxW, maxH = screenSize()
  -- SetResizeBounds replaced SetMinResize/SetMaxResize in 10.0 and Classic Era has been given it in
  -- stages, so ask the frame which one it has rather than the client which version it is.
  if frame.SetResizeBounds then
    frame:SetResizeBounds(WINDOW_MIN_W, WINDOW_MIN_H, maxW - WINDOW_MARGIN, maxH - WINDOW_MARGIN)
  elseif frame.SetMinResize then
    frame:SetMinResize(WINDOW_MIN_W, WINDOW_MIN_H)
    frame:SetMaxResize(maxW - WINDOW_MARGIN, maxH - WINDOW_MARGIN)
  end

  local status = widget.status or widget.localstatus
  if not status then return true end
  if not (force or placedWidget ~= widget) then return true end
  placedWidget = widget
  status.width = w.width or defaults.width
  status.height = w.height or defaults.height
  -- `false`, not nil, is what "never positioned" looks like on disk (Core/DB.lua), and AceGUI reads
  -- nil as "centre me" (AceGUIContainer-Frame.lua:151-157). The two spellings meet here.
  local top = (w.top ~= false) and w.top or nil
  local left = (w.left ~= false) and w.left or nil
  if top and left and not Options.positionOnScreen(top, left, status.width) then
    -- Thrown away rather than nudged back: the numbers describe a screen that is not this one, and
    -- the centre is the only place that is certainly reachable. Written back to disk too, or the
    -- next open would rediscover the same unreachable position.
    w.top, w.left = false, false
    top, left = nil, nil
  end
  status.top, status.left = top, left
  if widget.ApplyStatus then widget:ApplyStatus() end
  return true
end

-- Remember where and how big the window was left. AceGUI writes both into the status table on every
-- drag-stop, but that table is memory-only and the widget is wiped when it goes back to the pool --
-- so this is the step that makes the size survive a /reload.
function Options.SaveWindow(widget)
  widget = widget or openWidget()
  local status = widget and (widget.status or widget.localstatus)
  local db = windowDB()
  if not (status and db) then return false end
  db.width, db.height = status.width, status.height
  db.top, db.left = status.top or false, status.left or false
  return true
end

-- AT10-D4. The full path the window is on right now, walked straight out of AceConfigDialog's own
-- status tree (`GetStatusTable`, AceConfigDialog-3.0.lua:401-425 -- the same nested tables
-- `SelectGroup` writes into and `FeedGroup` reads) rather than kept separately: whatever put the
-- selection there -- a tree row, a tab, this file's own `SelectGroup` call -- agrees with what gets
-- remembered, including a stale request that only got partway before `SelectGroup`'s own walk gave
-- up (AceConfigDialog-3.0.lua:479-482) -- what comes back is where it actually landed, not where it
-- was asked to go. Capped at a depth no page in this addon reaches (Abilities is the deepest, at
-- four: list, ability, tab) so a status table that somehow looped back on itself still returns.
local MAX_REMEMBERED_DEPTH = 8
function Options.currentPath()
  local dialog = Options.dialog
  if not (dialog and dialog.GetStatusTable) then return nil end
  local path = {}
  for _ = 1, MAX_REMEMBERED_DEPTH do
    local node = dialog:GetStatusTable("Elmira", path)
    local key = node and node.groups and node.groups.selected
    if not key then break end
    path[#path + 1] = key
  end
  if #path == 0 then return nil end
  return path
end

-- AT10-D4. windowDB().lastPath is what `Options.Open` reads when it is asked for no page at all, so
-- the window reopens on the page (and, for Abilities, the list, ability and tab) it was last left
-- on -- across a `/reload` and a `/logout`, the way `SaveWindow` already carries size and position.
-- Written from the chained FeedGroup hook on every navigation, and once more from `Options.Open`
-- itself and the close chain, so a dialog stand-in that answers neither still leaves the window
-- reachable on its next Open.
function Options.rememberPath(path)
  local w = windowDB()
  if not (w and path and #path > 0) then return false end
  w.lastPath = path
  return true
end

-- The slider's setter, not just a store: a scale that only took effect on the next open would look
-- like a control that does nothing.
function Options.SetWindowScale(v)
  local db = windowDB()
  if not db then return false end
  db.scale = clampScale(v)
  -- Forget the saved position. A position is recorded in the frame's OWN coordinates, so it means a
  -- different place on screen at a different scale; re-centring is the only reading of it that is
  -- still true, and it is also what guarantees the title bar is reachable afterwards.
  db.top, db.left = false, false
  Options.ApplyWindow(true)
  return true
end

-- The way back from "I dragged it off the screen" and "I scaled it past the edge". Resets the stored
-- geometry AND pushes it onto the open frame, because the person clicking it is looking at that
-- frame; a reset that waited for the next open would read as a dead button.
function Options.ResetWindow()
  local db = windowDB()
  if not db then return false end
  local d = windowDefaults()
  db.scale, db.width, db.height = d.scale, d.width, d.height
  db.top, db.left = false, false
  Options.ApplyWindow(true)
  return true
end

-- Just "Elmira", brand-coloured. The version used to live in this same string, appended after a
-- space -- which put it on a font string (`titletext`) that AceConfigDialog rewrites on every
-- refresh, not only on Options.Open (see the range-slider path below Options.versionLine). It lives
-- on its own font string now; this is what Options.Decorate hands to widget:SetTitle.
function Options.windowTitle()
  return ns.Colors.wrap(ns.Colors.BRAND, "Elmira")
end

-- "Version: 1.2.3", or "Version: dev" in a dev tree, where the packager has never substituted the
-- TOC's @project-version@ placeholder and the adapter hands it back verbatim. Showing the
-- placeholder would put a build number on screen that no release ever had.
function Options.versionLine()
  local v = ns.Adapter and ns.Adapter.addonVersion and ns.Adapter.addonVersion()
  if type(v) ~= "string" or v == "" or v:find("project%-version") then v = "dev" end
  return string.format(L["Version: %s"], v)
end

-- ElvUI's own pattern for the same shared-pool problem (Config_SaveOldPosition /
-- Config_RestoreOldPosition, Game/Shared/General/Config.lua:998-1019): capture whatever anchors a
-- region already had before we move it, once, so Options.Undecorate can put it back byte for byte
-- rather than guessing at what AceGUI originally drew.
local function saveOriginalPoints(region)
  if not (region and region.GetNumPoints and region.GetPoint) then return nil end
  local saved = {}
  for i = 1, region:GetNumPoints() do
    saved[i] = { region:GetPoint(i) }
  end
  return saved
end

local function restoreOriginalPoints(region, saved)
  if not (region and saved and region.ClearAllPoints and region.SetPoint) then return end
  region:ClearAllPoints()
  for i = 1, #saved do
    region:SetPoint(unpack(saved[i]))
  end
end

local function decorateTitle(widget)
  local frame, titlebg = widget.frame, widget.titlebg
  if widget.SetTitle then widget:SetTitle(Options.windowTitle()) end

  if titlebg and titlebg.ClearAllPoints then
    -- Saved once per frame: the pool hands this SAME frame table to every other Ace3 addon once we
    -- let go of it (AceGUI-3.0.lua:88-113, objPools keyed on widget TYPE alone), so re-saving on a
    -- later re-open would capture OUR full-width anchors instead of AceGUI's original ones.
    if not frame.elmiraOriginalTitlebg then
      frame.elmiraOriginalTitlebg = saveOriginalPoints(titlebg)
    end
    -- AceGUI's invisible drag frame is SetAllPoints(titlebg) (AceGUIContainer-Frame.lua:230-234), so
    -- widening the TEXTURE is what makes the whole strip draggable. Until now the only grabbable
    -- part was a 100px tab in the middle, which moved as the title text changed length.
    -- The +12 keeps the header exactly where AceGUI drew it vertically (SetPoint("TOP", 0, 12)),
    -- so nothing below it has to move.
    titlebg:ClearAllPoints()
    titlebg:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 12)
    titlebg:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 12)
  end

  -- The rounded end caps are drawn to butt against a 100px middle; against a full-width one they
  -- hang off the sides of the window.
  if frame.GetRegions then
    for _, region in ipairs({ frame:GetRegions() }) do
      if region ~= titlebg and region.GetTexture and region:GetTexture() == TITLE_TEXTURE then
        region:Hide()
      end
    end
  end

  -- `titletext` is left exactly where AceGUI anchored it (TOP of titlebg,
  -- AceGUIContainer-Frame.lua:236-237): now that titlebg spans the whole window that anchor centres
  -- the name on the full-width bar on its own, so nothing here has to touch it -- or put it back.
end

-- The version, on a font string of OUR OWN that widget:SetTitle never touches (SetTitle only ever
-- writes titletext, AceGUIContainer-Frame.lua:116-117). Created once per frame and reused after
-- that -- CreateFontString on a pooled frame the next open hands back would be the second-button bug
-- M5g shipped, from the font-string side -- with the text refreshed on every Decorate, since that is
-- the only thing about it that ever changes.
local function decorateVersion(widget)
  local frame, titlebg = widget.frame, widget.titlebg
  if not frame.CreateFontString then return end
  local fs = frame.elmiraVersion
  if not fs then
    fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", titlebg or frame, "LEFT", 16, -6)
    if fs.SetJustifyH then fs:SetJustifyH("LEFT") end
    frame.elmiraVersion = fs
  end
  if fs.SetTextColor then fs:SetTextColor(ns.Colors.MUTED.r, ns.Colors.MUTED.g, ns.Colors.MUTED.b) end
  fs:SetText(Options.versionLine())
  if fs.Show then fs:Show() end
end

-- AceGUI's stock Close button is an anonymous child; ElvUI identifies it by its text
-- (Config.lua:1441-1447) and so do we. Not cached: it is a scan over a handful of children, run
-- on open and on click, and a cache on a POOLED frame is a stale pointer waiting to happen.
local function stockClose(frame)
  if not frame.GetChildren then return nil end
  for _, child in ipairs({ frame:GetChildren() }) do
    if child.GetText and child:GetText() == CLOSE then return child end
  end
end

local function tooltipScripts(button, text)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function decorateButtons(widget)
  local frame = widget.frame
  -- The stock button stays in the hierarchy and keeps its OnClick: it is what the X clicks, so
  -- AceConfigDialog's FrameOnClose still runs, still clears OpenFrames and still releases the widget
  -- to the pool. Hiding it is re-done on every open because a pooled frame may be re-shown.
  local close = stockClose(frame)
  if close and close.Hide then close:Hide() end

  if not frame.elmiraClose then
    local x = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    x:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)
    x:SetFrameLevel((frame.GetFrameLevel and frame:GetFrameLevel() or 100) + 10)
    -- Never frame:Hide() here. That skips OnClose entirely, so OpenFrames.Elmira keeps pointing at a
    -- hidden widget and the next Open reuses a frame the pool still believes is out on loan --
    -- the leak M5g shipped, from the other direction.
    x:SetScript("OnClick", function()
      local btn = stockClose(frame)
      if btn and btn.Click then btn:Click() end
    end)
    frame.elmiraClose = x
  end
  -- Re-shown on every Decorate: Options.Undecorate hides it on close so a frame the pool hands to
  -- another addon carries none of ours visibly, and this is what brings it back.
  if frame.elmiraClose.Show then frame.elmiraClose:Show() end

  if not frame.elmiraReposition then
    local b = CreateFrame("Button", nil, frame)
    b:SetWidth(20)
    b:SetHeight(20)
    b:SetPoint("RIGHT", frame.elmiraClose, "LEFT", 2, 0)
    b:SetFrameLevel((frame.GetFrameLevel and frame:GetFrameLevel() or 100) + 10)
    -- Verified present on this client: DBM-Core/modules/gui uses the same two paths on Classic Era.
    b:SetNormalTexture("Interface\\Buttons\\UI-RefreshButton")
    b:SetPushedTexture("Interface\\Buttons\\UI-RefreshButton-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    tooltipScripts(b, L["Reset the size and position of this frame."])
    b:SetScript("OnClick", function() Options.ResetWindow() end)
    frame.elmiraReposition = b
  end
  if frame.elmiraReposition.Show then frame.elmiraReposition:Show() end
end

-- FX1-D7. Where the window was dragged to, saved the moment the mouse is let go.
--
-- AceGUI writes the new size and position into its status table on drag-stop and on resize-stop
-- (`MoverSizer_OnMouseUp`, AceGUIContainer-Frame.lua:39-48) and nothing read that table until the
-- window CLOSED -- so anything that re-Opened the frame in between put it back where it had last
-- been saved, and every `execute` button re-Opens it.
--
-- HOOKED, never replaced. `HookScript` appends, so AceGUI's own handler still runs and still fills
-- in the numbers this reads a moment later; `SetScript` would take the resize itself with it (the
-- same one-handler rule that has cost this addon two outages, on the frame-script side).
--
-- The four frames carrying that handler are the title drag bar and the three sizers, and only the
-- sizers are exposed on the widget -- `title` is a local (AceGUIContainer-Frame.lua:232-234). So
-- all four are found the same way: by carrying the SAME function `sizer_se` does.
local function moverFrames(widget)
  local out = {}
  local frame = widget.frame
  local sizer = widget.sizer_se
  local mark = sizer and sizer.GetScript and sizer:GetScript("OnMouseUp")
  -- Read fresh every time, and it answers a SHORTER list from the second decoration onward: hooking
  -- appends by replacing the script pointer with a wrapper, so `sizer_se`'s handler is no longer the
  -- same function as the title bar's and only it still matches. That is exactly right -- everything
  -- this would find is already hooked, and the flag below is what keeps the one that still matches
  -- from being hooked a second time.
  if not (mark and frame.GetChildren) then return out end
  for _, child in ipairs({ frame:GetChildren() }) do
    if child.GetScript and child.HookScript and child:GetScript("OnMouseUp") == mark then
      out[#out + 1] = child
    end
  end
  return out
end

local function decorateDrag(widget)
  for _, mover in ipairs(moverFrames(widget)) do
    -- A script hook cannot be taken off again, and AceGUI's pool will hand this same frame to
    -- ElvUI or WeakAuras once we let go of it -- so the flag that stops it being installed twice
    -- has to SURVIVE Undecorate (hooking again would save the same drag twice), and the hook
    -- itself has to check that the frame being dragged is still ours before it writes. It writes
    -- nothing at all otherwise, and it draws nothing ever, so the frame the pool hands on carries
    -- no visible trace of us.
    if not mover.elmiraDragHooked then
      mover.elmiraDragHooked = true
      local frame = widget.frame
      mover:HookScript("OnMouseUp", function()
        local open = openWidget()
        if open and open.frame == frame then Options.SaveWindow(open) end
      end)
    end
  end
end

-- Everything the stock AceGUI frame does not give us, applied to whatever frame is open now.
-- Called after every Open (see Options.Open) because AceConfigDialog pools and re-titles frames --
-- and, since D13/D15, after every OTHER refresh of THIS app too (the hook installed below) so a
-- slider drag mid-session cannot leave the chrome stale. `openWidget()` is the only source of
-- `widget`, so this can only ever decorate OpenFrames.Elmira's own frame -- never a frame the pool
-- has since handed to a different addon.
function Options.Decorate()
  local widget = openWidget()
  if not (widget and widget.frame) then return false end
  -- FX2-D2. Geometry first, but never at the chrome's expense: this is the one step here that hands
  -- numbers to the CLIENT (SetScale, SetResizeBounds against whatever UIParent reports), and the
  -- chrome below depends on none of them. Unguarded, a single throw in there left the window
  -- wearing AceGUI's 100px drag tab and no version -- the reported symptom exactly -- and, worse,
  -- took `chainClose` down with it, so the next close released the frame to the shared pool still
  -- carrying our title bar and our X (the D15/M5g leak, from a new direction).
  local ok, err = pcall(Options.ApplyWindow)
  if not ok then
    ns.log("could not size or place the options window: %s", tostring(err))
  end
  decorateTitle(widget)
  decorateVersion(widget)
  decorateButtons(widget)
  decorateDrag(widget)
  return true
end

-- FX2-D3. Is the window on screen actually wearing its chrome, or is it the stock AceGUI frame?
--
-- The owner reported the two things Decorate does that you can SEE -- "lost the Version info on top
-- left" and "the only way to drag the popup is clicking the Elmira in the middle" -- and neither
-- has a diagnostic behind it, so answering "is it dressed" needed a screenshot. This reads exactly
-- those two: the title bar reaching from the window's left edge (which is what makes the whole
-- strip draggable, since AceGUI's invisible drag frame is SetAllPoints(titlebg)), and the version
-- font string being shown. `/elm debug state` prints the answer.
--
-- nil, not "stripped", when no standalone window is open: "there is nothing on screen" and "what is
-- on screen is undressed" are different answers and the caller says so differently.
local function titleSpansWindow(widget)
  local titlebg = widget.titlebg
  -- BOTH corners, not just the left one: AceGUI anchors this texture at a single point and leaves
  -- it 100px wide (AceGUIContainer-Frame.lua:226), so a bar that merely starts at the window's edge
  -- is still a tab. Two anchors is what stretches it -- and the invisible drag frame with it.
  if not (titlebg and titlebg.GetNumPoints and titlebg:GetNumPoints() == 2) then return false end
  local point, relativeTo = titlebg:GetPoint(1)
  return point == "TOPLEFT" and relativeTo == widget.frame
end

function Options.chromeState()
  local widget = openWidget()
  local frame = widget and widget.frame
  if not frame then return nil end
  local version = frame.elmiraVersion
  local shown = version ~= nil and version.IsShown ~= nil and version:IsShown()
  return (shown and titleSpansWindow(widget)) and "dressed" or "stripped"
end

-- Undoes Decorate, called from Options.Open's chained OnClose BEFORE AceConfigDialog's own
-- FrameOnClose releases the widget back to AceGUI's shared pool. The pool is keyed on widget TYPE
-- alone (AceGUI-3.0.lua:88 objPools, ~91-124 newWidget/delWidget) -- every Ace3 addon that opens a
-- standalone AceConfigDialog Frame draws from the exact same handful of instances -- and AceGUI's
-- own release (AceGUI-3.0.lua:172-198) neither restores an anchor we moved nor removes a child we
-- created. Left undone, the next addon to acquire this frame inherits our title bar, our X and our
-- version text sitting on top of theirs. ElvUI hits the identical problem and solves it the
-- identical way (Config_SaveOldPosition/Config_RestoreOldPosition,
-- Game/Shared/General/Config.lua:998-1019).
function Options.Undecorate(widget)
  if not (widget and widget.frame) then return false end
  local frame, titlebg = widget.frame, widget.titlebg
  restoreOriginalPoints(titlebg, frame.elmiraOriginalTitlebg)

  if frame.GetRegions then
    for _, region in ipairs({ frame:GetRegions() }) do
      if region ~= titlebg and region.GetTexture and region:GetTexture() == TITLE_TEXTURE then
        if region.Show then region:Show() end
      end
    end
  end

  local close = stockClose(frame)
  if close and close.Show then close:Show() end
  if frame.elmiraClose and frame.elmiraClose.Hide then frame.elmiraClose:Hide() end
  if frame.elmiraReposition and frame.elmiraReposition.Hide then frame.elmiraReposition:Hide() end
  if frame.elmiraVersion and frame.elmiraVersion.Hide then frame.elmiraVersion:Hide() end
  -- FX1-D7: this frame is going back to the pool, so whatever comes out of it next is a window
  -- being put on screen and gets the stored geometry again.
  placedWidget = nil
  return true
end

-- ============================================================ Move modes (FX1-D5)
--
-- The owner, trying to place a texture: "I can not move it around since the Configuration page is
-- too big and I can not move the configuration page out of the screen." Every Move mode puts a
-- sample on screen and asks the player to drag it -- under a 960x680 window that is very often
-- sitting exactly where they want to drop it. ElvUI answers this by closing its config entirely and
-- leaving a small toggle bar behind (ElvUI/Game/Shared/Modules/Misc/Movers); Elmira does the same,
-- except the window is HIDDEN rather than closed, so it comes back on the page, the tab and the row
-- the player was reading.
--
-- HIDDEN, NOT CLOSED, is load-bearing in both directions:
--   * AceGUI fires OnClose from the frame's OnHide script (AceGUIContainer-Frame.lua:28-30, 195),
--     so hiding the window runs our whole close chain -- which STOPS every move mode, one line
--     after one started. `hiddenForMove` is what makes that chain stand down.
--   * And because it stands down, AceConfigDialog's own FrameOnClose does not run either:
--     OpenFrames.Elmira still holds this widget, nothing else can acquire it, and the window that
--     comes back is the same one with the same content. A frame left hidden and still in OpenFrames
--     IS the M5g leak if it is never shown again -- which is why every exit from every mode ends up
--     in Options.EndMove below, and why Options.Open ends the mode instead of opening over it.

-- What a running Move mode consists of. Every one of these is a bare `local` declaration, so
-- deleting it only turns the name into a global -- which luacheck fails on and no test can see.
local moveSubject = nil   -- mutants: equivalent local-only; what is being moved, and "is a mode on"
local hiddenForMove = false -- mutants: equivalent local-only; did WE hide the panel
local moveWidget = nil    -- mutants: equivalent local-only; the widget we hid, to show that one back
local movePath = nil      -- mutants: equivalent local-only; the tree path to re-select
local moveBar = nil       -- the floating bar, created once
local closingBar = false  -- mutants: equivalent local-only; are WE hiding the bar, or is Escape

-- What is being moved, in the player's words. Tokens rather than sentences cross the Display
-- boundary: Display decides what a mode DOES, Options decides what it is called, and only this side
-- goes through AceLocale.
-- AT6-D4 removed `indicators`: the row those textures flowed along, and the Move mode that placed
-- it, are gone -- each texture is dragged on its own now.
local MOVE_SUBJECTS = {
  strip      = "the queue strip",
  messages   = "your screen messages",
  texture    = "%s's texture",
}

-- What is being moved right now ("the indicator row"), or nil when nothing is. Read by the bar's
-- own sentence and by `/elm debug state` (Core/Slash.lua), which has to be able to answer "where
-- did my configuration window go" for a player who missed the bar.
function Options.moveSubject() return moveSubject end

-- Ends every Move mode there is, whichever one is running. ONE function, shared by the Done button
-- and by the panel's close chain: a guard written twice is a guard that will be forgotten once, and
-- a mode left running holds a sample on screen that the render loop is told to leave alone.
--
-- pcall throughout, and for the same reason the close path always has: this runs from a frame's
-- OnHide and from a button, and ours must never be the reason the rest is skipped. Reported, not
-- swallowed -- failing to leave move mode leaves a mouse-eating frame across the middle of the
-- screen, which is precisely the kind of thing nobody files a bug about because it does not look
-- like an error.
local function stopMoveModes()
  if ns.Announcers then
    local ok, err = pcall(ns.Announcers.StopMoving)
    if not ok then
      ns.log("could not leave move mode: %s", tostring(err))
    end
  end
  -- PE11-D5. Positioning mode holds the strip on screen with sample icons and the render loop
  -- deliberately leaves it alone, so a panel closed mid-drag would strand it there -- visible in
  -- town, draggable while locked, with the button that ends it now behind a window the player has
  -- just shut.
  if ns.Queue and ns.Queue.StopPositioning then
    local ok, err = pcall(ns.Queue.StopPositioning)
    if not ok then
      ns.log("could not leave the strip's positioning mode: %s", tostring(err))
    end
  end
  -- AB3-D2, the third of the same guard: placing the Indicators row or dragging one texture both
  -- put a sample on screen that the render loop is told to leave alone.
  if ns.Textures and ns.Textures.StopMoveMode then
    local ok, err = pcall(ns.Textures.StopMoveMode)
    if not ok then
      ns.log("could not leave the texture move mode: %s", tostring(err))
    end
  end
end

-- Which page, tab and row the player was reading, as a path SelectGroup can be handed back.
-- AceConfigDialog stores a tree's selection as its nodes joined with \001
-- (AceConfigDialog-3.0.lua:459-474); everything deeper than the top-level tree keeps its own status
-- table and is restored by the library itself.
local function selectedPath()
  local dialog = Options.dialog
  local status = dialog and dialog.GetStatusTable and dialog:GetStatusTable("Elmira", {})
  local selected = status and status.groups and status.groups.selected
  if type(selected) ~= "string" then return nil end
  local path = {}
  for part in selected:gmatch("[^\001]+") do path[#path + 1] = part end
  return path
end

local function hidePanel()
  local widget = openWidget()
  local frame = widget and widget.frame
  if not frame then return end
  -- AT6-D5: a window that is not on screen is not showing a Texture tab, so the texture it was
  -- holding up for that tab has to go. Every Move mode comes through here, which is also how the
  -- tab's preview and a drag's sample can never both claim the same texture.
  if ns.Textures and ns.Textures.Preview then ns.Textures.Preview(nil) end
  movePath = selectedPath()
  moveWidget, hiddenForMove = widget, true
  frame:Hide()
end

-- AceConfigDialog re-Opens the whole panel the instant an `execute` button's own func returns
-- (ActivateControl, AceConfigDialog-3.0.lua:867-872) and Open ends by SHOWING the frame
-- (:1930-1933) -- so without this the button that starts a Move mode would put the window straight
-- back over the thing being moved, one frame after hiding it. Called from the refresh hook, AFTER
-- the close callback has been re-chained: a hide with AceConfigDialog's own FrameOnClose sitting
-- unchained on OnClose would release the widget to the pool instead of standing down.
local function rehideForMove()
  if not hiddenForMove then return end
  hidePanel()
end

local function showPanel()
  if not hiddenForMove then return end
  local widget, path = moveWidget, movePath
  hiddenForMove, moveWidget, movePath = false, nil, nil
  -- Never show a widget the pool may have handed on: if anything released the frame while it was
  -- hidden, opening a fresh one is the only honest answer -- putting our page back on a window that
  -- now belongs to another addon is the pool bug D15 exists to prevent, in its worst form.
  if openWidget() ~= widget then
    Options.Open(unpack(path or {}))
    return
  end
  widget.frame:Show()
  -- FX2-D3: dressed the moment it is visible, and never later. Every OTHER way this window reaches
  -- the screen goes through AceConfigDialog:Open, which the refresh hook decorates after -- this
  -- one does not, so a frame that lost its chrome while it was hidden (our own close chain fires
  -- from the frame's OnHide, and anything that hides it without `hiddenForMove` set runs
  -- Undecorate) would come back stripped, and every later Decorate would be a no-op until a real
  -- close and re-open. Cheap and idempotent, which is what Decorate has had to be since D15.
  Options.Decorate()
  local dialog = Options.dialog
  if path and #path > 0 and dialog and dialog.SelectGroup then
    dialog:SelectGroup("Elmira", unpack(path))
  end
end

-- Escape, rather than the Done button. The client's own CloseSpecialWindows hides every frame named
-- in UISpecialFrames -- which is how Escape reaches our bar at all -- and AceConfigDialog wraps that
-- same function to ALSO close every open options window a frame later
-- (AceConfigDialog-3.0.lua:1854-1860 -> CloseAll -> RefreshOnUpdate's `closeAll` sweep, :1774-1782).
-- Without this the window we are in the middle of putting back would be shut again on the next
-- OnUpdate, so Escape would read as "end the mode AND close the panel" while Done read as "end the
-- mode". `closeAllOverride` is the library's own opt-out from that sweep, set here for exactly the
-- reason its own Open sets it (:1936-1938): something is deliberately putting this window on screen
-- at the moment everything is being told to close.
local function keepPanelThroughCloseAll()
  local dialog = Options.dialog
  local frame = dialog and dialog.frame
  if frame and frame.closeAllOverride then frame.closeAllOverride.Elmira = true end
end

-- ------------------------------------------------------------ the Move TOOLBAR (AT4-D1)
--
-- Owner, 2026-09-11: "When I am moving the texture, I also want to select the texture to try
-- different stuff and also to be able to change the size, without seeing the Configuration popup;
-- in a clear screen" -- plus colour and opacity. So the bar grows a row of live controls while ONE
-- TEXTURE is being dragged: its icon and name, a Texture button (the picker window,
-- Options/TexturePanel.lua), Size, Colour, Opacity, Done. Every other Move mode keeps the bar it
-- always had, one sentence and Done -- there is nothing to adjust about a row of indicators or a
-- strip that is not already on the page.
--
-- These are PLAIN CLIENT FRAMES, not AceGUI widgets: AceGUI's are pooled across every Ace3 addon in
-- the client, and a control acquired for the length of a drag and parented into a frame of ours is
-- exactly the shape of the bug that once put Elmira's buttons on ElvUI's window. A Blizzard slider
-- is not pooled by anybody.
--
-- Every control writes the SAME `texture` channel the Texture tab writes (AbilitySettings.set) and
-- repaints through Textures.Refresh, so what the player does here is what the tab shows when the
-- window comes back -- one store, not a second copy that could drift.
local MOVE_BAR_W, MOVE_BAR_H = 380, 76      -- the plain bar: a sentence and Done
local TOOL_BAR_W, TOOL_BAR_H = 620, 130     -- and the same bar carrying a texture's controls
local TOOL_SLIDER_W, TOOL_SLIDER_H = 120, 16
local TOOL_ROW_Y = -60          -- the controls' own centre line, below the wrapped sentence
local TOOL_SWATCH = 24

local moveKey = nil          -- mutants: equivalent local-only; the ability the toolbar is bound to
local settingTools = false   -- mutants: equivalent local-only; are WE moving a slider, or the mouse

local function setTexture(field, value)
  local A = ns.AbilitySettings
  if not (A and moveKey) then return false end
  A.set(moveKey, "texture", field, value)
  -- Repaints what is already on screen -- which, during a Move mode, is the very texture being
  -- dragged. A slider whose effect only shows up on the next pull is a slider that looks broken.
  if ns.Textures then ns.Textures.Refresh() end
  return true -- mutants: equivalent both callers use `setTexture(...)` as a bare statement
end

-- The client's own colour picker, both contracts. 10.2.5 replaced the "set these fields, then show
-- it" dance with `SetupColorPickerAndShow`, and Classic Era has been carrying both; AceGUI's own
-- ColorPicker widget branches on exactly this test (AceGUIWidget-ColorPicker.lua:64), which is what
-- makes it the client's behaviour rather than a guess. `cancelFunc` puts the previous colour back,
-- so a player who opens the picker and changes their mind has changed nothing.
local function openColourPicker(r, g, b, apply)
  local picker = ColorPickerFrame
  if not picker then return false end
  local function chosen()
    local nr, ng, nb
    if picker.GetColorRGB then nr, ng, nb = picker:GetColorRGB() end
    apply(nr or r, ng or g, nb or b)
  end
  local function cancelled()
    apply(r, g, b)
  end
  if picker.SetupColorPickerAndShow then
    picker:SetupColorPickerAndShow({ swatchFunc = chosen, cancelFunc = cancelled,
                                     hasOpacity = false, r = r, g = g, b = b })
    return true -- mutants: equivalent the one caller (the swatch's OnClick) uses `openColourPicker(...)` as a bare statement
  end
  picker.func, picker.opacityFunc, picker.cancelFunc = chosen, chosen, cancelled
  picker.hasOpacity = false
  if picker.SetColorRGB then picker:SetColorRGB(r, g, b) end
  -- Hide first: the pre-10.2.5 frame reads the fields above in its OnShow, so a picker that is
  -- already up would keep the previous swatch's callbacks.
  picker:Hide()
  picker:Show()
  return true -- mutants: equivalent the one caller (the swatch's OnClick) uses `openColourPicker(...)` as a bare statement
end

-- One slider, built from the client's own options template so it looks like every other slider the
-- player has ever dragged. The template's three font strings are global children of the slider's
-- NAME -- which is why these are named frames -- and every touch of them is guarded: a client (or a
-- headless test) without the template still gets a working slider, just an unlabelled one.
local function toolSlider(bar, name, label, low, high, step, format, field)
  local slider = CreateFrame("Slider", name, bar, "OptionsSliderTemplate")
  slider:SetWidth(TOOL_SLIDER_W)
  slider:SetHeight(TOOL_SLIDER_H)
  slider:SetOrientation("HORIZONTAL")
  slider:SetMinMaxValues(low, high)
  slider:SetValueStep(step)
  if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
  local lowText, highText = _G[name .. "Low"], _G[name .. "High"]
  if lowText then lowText:SetText("") end
  if highText then highText:SetText("") end
  slider.elmiraTitle = _G[name .. "Text"]
  local function retitle(value)
    if slider.elmiraTitle then slider.elmiraTitle:SetText(string.format(format, label, value)) end
  end
  slider.elmiraRetitle = retitle
  slider:SetScript("OnValueChanged", function(_, value)
    retitle(value)
    -- `settingTools` stands this down while the toolbar is LOADING the ability's current values:
    -- SetValue fires OnValueChanged exactly as a drag does, and without the guard opening the
    -- toolbar would write its own starting numbers back over the settings it just read.
    if settingTools then return end
    setTexture(field, value)
  end)
  return slider
end

-- The bar. One line saying what is being moved and a Done button -- plus, for one texture, the
-- toolbar above (AT4-D1). It is on screen precisely because the window it stands in for was in the
-- way, so nothing goes on it that is not being adjusted right now.
local function moveBarFrame()
  if moveBar then return moveBar end
  if not CreateFrame then return nil end
  -- NAMED, because UISpecialFrames is a list of global frame names and that list is the only way
  -- the client's Escape reaches a frame of ours.
  local f = CreateFrame("Frame", "ElmiraMoveBar", UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetWidth(MOVE_BAR_W)
  f:SetHeight(MOVE_BAR_H)
  f:SetPoint("TOP", UIParent, "TOP", 0, -40)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  bg:SetColorTexture(0, 0, 0, 0.85)
  local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  -- Anchored on BOTH sides so the sentence wraps inside the bar: a font string with one horizontal
  -- anchor grows in one line and runs off the ends of a 380px frame, and the longest of these names
  -- an ability ("Moving Hammer of the Righteous's texture. Drag it...").
  text:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -10)
  text:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
  if text.SetJustifyH then text:SetJustifyH("CENTER") end
  f.elmiraText = text
  local done = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  done:SetWidth(110)
  done:SetHeight(22)
  done:SetPoint("BOTTOM", f, "BOTTOM", 0, 10)
  done:SetText(L["Done"])
  done:SetScript("OnClick", function() Options.EndMove() end)
  f.elmiraDone = done

  -- AT4-D1's toolbar, built once with the bar and shown only while a texture is being dragged.
  -- Laid out left to right off each other, so a missing width anywhere shifts the row rather than
  -- stacking two controls on one spot.
  local icon = f:CreateTexture(nil, "ARTWORK")
  icon:SetWidth(32)
  icon:SetHeight(32)
  icon:SetPoint("TOPLEFT", f, "TOPLEFT", 12, TOOL_ROW_Y + 16)
  f.elmiraIcon = icon

  local name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
  name:SetWidth(120)
  if name.SetJustifyH then name:SetJustifyH("LEFT") end
  f.elmiraName = name

  local choose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  choose:SetWidth(90)
  choose:SetHeight(22)
  choose:SetPoint("LEFT", name, "RIGHT", 8, 0)
  choose:SetText(L["Texture"])
  -- The SAME window the Texture tab's Choose… button opens (Options/TexturePanel.lua): a second
  -- picker built for the toolbar could look right and write somewhere else.
  choose:SetScript("OnClick", function()
    if ns.TexturePanel and moveKey then ns.TexturePanel.Toggle(moveKey) end
  end)
  f.elmiraChoose = choose

  -- AT8-D5: the same 16-512 range the Texture tab's own slider offers, so dragging the toolbar's
  -- can never write a size that tab would clamp back down the next time it is opened.
  local size = toolSlider(f, "ElmiraMoveBarSize", L["Size"], 16, 512, 8, "%s: %d", "size")
  size:SetPoint("LEFT", choose, "RIGHT", 20, 0)
  f.elmiraSize = size

  local swatchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  swatchLabel:SetPoint("LEFT", size, "RIGHT", 24, 10)
  swatchLabel:SetText(L["Colour"])
  f.elmiraSwatchLabel = swatchLabel

  local swatch = CreateFrame("Button", nil, f)
  swatch:SetWidth(TOOL_SWATCH)
  swatch:SetHeight(TOOL_SWATCH)
  swatch:SetPoint("LEFT", size, "RIGHT", 24, -6)
  local fill = swatch:CreateTexture(nil, "ARTWORK")
  fill:SetAllPoints(swatch)
  swatch.elmiraFill = fill
  swatch:SetScript("OnClick", function()
    local A = ns.AbilitySettings
    if not (A and moveKey) then return end
    local c = A.effective(moveKey, "texture").color or ns.Colors.HIGHLIGHT
    openColourPicker(c.r, c.g, c.b, function(r, g, b)
      setTexture("color", { r = r, g = g, b = b })
      fill:SetColorTexture(r, g, b, 1)
    end)
  end)
  f.elmiraSwatch = swatch

  local alpha = toolSlider(f, "ElmiraMoveBarAlpha", L["Opacity"], 0.05, 1, 0.05, "%s: %.2f", "alpha")
  alpha:SetPoint("LEFT", swatch, "RIGHT", 24, 0)
  f.elmiraAlpha = alpha

  -- One list, so "show the toolbar" and "hide the toolbar" can never cover different controls --
  -- a control left visible after the mode that owns it ended is a control writing to nothing.
  f.elmiraTools = { icon, name, choose, size, swatchLabel, swatch, alpha }

  f:SetScript("OnHide", function()
    if closingBar then return end
    keepPanelThroughCloseAll()
    Options.EndMove()
  end)
  if type(UISpecialFrames) == "table" then
    UISpecialFrames[#UISpecialFrames + 1] = "ElmiraMoveBar"
  end
  moveBar = f
  return f
end

-- Dress the bar for the mode that is starting: the toolbar and this ability's current size, colour
-- and opacity for a texture drag, nothing but the sentence and Done for everything else. Called on
-- every BeginMove, so the bar can never keep the last mode's controls.
local function applyToolbar(bar)
  local tools = bar.elmiraTools
  if not moveKey then
    for _, region in ipairs(tools) do region:Hide() end
    bar:SetWidth(MOVE_BAR_W)
    bar:SetHeight(MOVE_BAR_H)
    return false
  end
  local A = ns.AbilitySettings
  local e = (A and A.effective(moveKey, "texture")) or {}
  local display = ns.Display
  bar.elmiraIcon:SetTexture((display and display.spellIcon and display.spellIcon(moveKey)) or "")
  bar.elmiraName:SetText((display and display.spellName and display.spellName(moveKey)) or moveKey)
  local c = e.color or ns.Colors.HIGHLIGHT
  bar.elmiraSwatch.elmiraFill:SetColorTexture(c.r, c.g, c.b, 1)
  -- Textures.sizeOf is the same clamp the tab's own slider reads through, so the toolbar can never
  -- open showing a number the texture is not actually drawn at.
  local size = (ns.Textures and ns.Textures.sizeOf and ns.Textures.sizeOf(e)) or 48
  local alpha = math.max(0.05, math.min(1, tonumber(e.alpha) or 1))
  -- Loading, not editing: SetValue fires OnValueChanged exactly as a drag does (see toolSlider).
  settingTools = true
  bar.elmiraSize:SetValue(size)
  bar.elmiraAlpha:SetValue(alpha)
  settingTools = false
  -- The template's own label does not follow a SetValue on every client, and the toolbar's whole
  -- claim is that it shows what the texture is set to right now.
  bar.elmiraSize.elmiraRetitle(size)
  bar.elmiraAlpha.elmiraRetitle(alpha)
  for _, region in ipairs(tools) do region:Show() end
  bar:SetWidth(TOOL_BAR_W)
  bar:SetHeight(TOOL_BAR_H)
  return true -- mutants: equivalent the one caller (BeginMove) uses `applyToolbar(bar)` as a bare statement
end

-- Called by the mode itself (Display/Queue, Display/Textures, Display/Announcers), never by the
-- button that started it: /elm lock, entering combat and the panel closing all end a mode too, and
-- a bar left on screen after the mode behind it stopped is the same stranded-frame bug from the
-- other side.
function Options.BeginMove(what, key)
  local subject = MOVE_SUBJECTS[what]
  if not subject then return false end
  if what == "texture" then
    local name = (ns.Display and ns.Display.spellName and ns.Display.spellName(key)) or tostring(key)
    subject = string.format(L[subject], name)
  else
    subject = L[subject]
  end
  moveSubject = subject
  -- AT4-D1: the toolbar belongs to ONE texture being dragged. Every other mode ("Position the
  -- Indicators" included) keeps the sentence and Done, because there is nothing on the bar for them
  -- to adjust.
  moveKey = (what == "texture") and key or nil
  local bar = moveBarFrame()
  if bar then
    if bar.elmiraText then
      bar.elmiraText:SetText(
        string.format(L["Moving %s. Drag it where you want it, then press Done."], subject))
    end
    applyToolbar(bar)
    bar:Show()
  end
  hidePanel()
  return true
end

-- Ends the mode and gives the window back. Idempotent: every Stop* calls it, and so does the Done
-- button, which has to end whichever mode is running.
function Options.EndMove()
  if not moveSubject then return false end
  moveSubject = nil
  -- AT4-D2: the picker window is a child of this moment, not of the options panel -- it was opened
  -- from the toolbar and there is nothing to preview against once the drag is over. Closed as KEPT,
  -- never cancelled: the player has been looking at their choice on screen, and Done must not take
  -- it away.
  if ns.TexturePanel and ns.TexturePanel.isOpen() then ns.TexturePanel.Close(false) end
  moveKey = nil
  if moveBar then
    closingBar = true
    moveBar:Hide()
    closingBar = false
  end
  stopMoveModes()
  showPanel()
  return true
end

-- The wrapper we last installed and the callback it wraps, so re-chaining onto AceConfigDialog's
-- own OnClose lands on ITS current callback rather than on ourselves. AceConfigDialog resets OnClose
-- on EVERY Open, not only the first time a frame is created (AceConfigDialog-3.0.lua:1911's `else`
-- branch runs whether f is new or reused) -- which is also why the refresh hook below re-chains,
-- not only re-decorates: without it, the first option changed after opening the panel would
-- silently strip Options.SaveWindow and Options.Undecorate off the close path, and D15's own fix
-- would stop firing.
local ourClose, ourPrior -- mutants: equivalent deletion only makes these globals

-- CHAIN, never replace: Ace registries keep exactly one callback per event name
-- (`widget.events[name]`), and overwriting AceConfigDialog's own FrameOnClose leaked the frame on
-- every close (M5g). Shared by Options.Open and the refresh hook, since AceConfigDialog:Open resets
-- OnClose from both paths equally.
local function chainClose(dialog)
  local open = dialog and dialog.OpenFrames and dialog.OpenFrames.Elmira
  if not (open and open.SetCallback) then return end
  local prior = open.events and open.events.OnClose
  if prior == ourClose then prior = ourPrior end
  ourPrior = prior
  ourClose = function(widget, event, ...)
    -- FX1-D5: the window is HIDDEN, not closed, while a Move mode is on -- and AceGUI fires OnClose
    -- from the frame's OnHide either way (AceGUIContainer-Frame.lua:195). Standing down is the
    -- whole of the difference: every line below would undo the mode that just hid the window, and
    -- `prior` -- AceConfigDialog's FrameOnClose -- would release the widget to the pool while we
    -- still intend to show it again.
    if hiddenForMove then return end
    -- AT6-D5, first and unconditionally: the Texture tab holds its ability's texture on screen, and
    -- nothing in the fight is holding it -- so a window closed on that tab would leave it standing
    -- in the middle of the screen for the rest of the session with no control anywhere to take it
    -- off. This is the one line that ends that, on the one path every close goes through.
    if ns.Textures and ns.Textures.Preview then ns.Textures.Preview(nil) end
    -- Every Move mode, through the one function the Done button uses, so the two can never disagree
    -- about what "leave move mode" means.
    stopMoveModes()
    -- Where and how big it was left. Same pcall discipline, and for the same reason: the dialog's
    -- own cleanup below runs whatever happens here. AceGUI wipes the status table when the widget
    -- goes back to the pool, so this is the last moment the numbers exist.
    local savedOK, savedErr = pcall(Options.SaveWindow, widget)
    if not savedOK then
      -- D45 (2026-09-07 R1b): the D26 conversions this pass re-homes -- a status line, not a plain
      -- print, once Announce is loaded; falls back to the log the way they all do.
      local text = string.format(
        L["could not remember the options window's size: %s"], tostring(savedErr))
      if ns.Announce then ns.Announce.emit("status", text) else ns.log("%s", text) end
    end
    -- AT10-D4. Same discipline as the size just above: the FeedGroup hook already keeps
    -- `windowDB().lastPath` current on every navigation, but this is the last moment the dialog's
    -- own status tree -- memory-only, and wiped when the widget goes back to the pool -- can still be
    -- read at all, so closing re-syncs it once more rather than trusting the last navigation caught it.
    Options.rememberPath(Options.currentPath())
    -- BEFORE prior(): prior is AceConfigDialog's own FrameOnClose, which releases this widget back
    -- to AceGUI's pool for the next addon to acquire (D15). Undecorate has to run while the frame
    -- is still ours to put back the way we found it.
    local undecOK, undecErr = pcall(Options.Undecorate, widget)
    if not undecOK then
      ns.log("could not undo the options window's chrome: %s", tostring(undecErr))
    end
    if prior then return prior(widget, event, ...) end
  end
  open:SetCallback("OnClose", ourClose)
end

-- The slider-drag refresh calls AceConfigDialog:Open() directly on the range option's OnMouseUp
-- (AceConfigDialog-3.0.lua:856-862) -- and every OTHER option type's `set` does the same on its own
-- final branch -- re-titling the SAME pooled frame without ever going through Options.Open. Before
-- D12 that overwrote the version text living inside titletext; it also silently strips the OnClose
-- chain (see chainClose above). A post-call hook on the library's own Open, filtered to our app
-- name, is what survives every refresh path there is rather than chasing each one by hand; it
-- touches no other addon, because it is a no-op for every appName but "Elmira". Never wraps or
-- replaces Open -- hooksecurefunc runs alongside the original, after it returns.
-- Returns whether the hook is (now, or already) installed: Options.Open uses that to know whether
-- it still has to decorate and chain the close callback itself, or whether the hook -- which fires
-- synchronously as part of dialog:Open, including THIS call -- has it covered. Installing is
-- idempotent (the flag), firing is not skipped on any call, including the very first.
local function installRefreshHook(dialog)
  if not (dialog and hooksecurefunc) then return false end
  if not dialog.elmiraRefreshHooked then
    dialog.elmiraRefreshHooked = true
    hooksecurefunc(dialog, "Open", function(_, appName)
      if appName ~= "Elmira" then return end
      -- FX2-D3, the same pcall discipline the close chain has always had: ours must never be the
      -- reason the rest is skipped. `chainClose` below is what keeps AceConfigDialog's own
      -- FrameOnClose behind Options.Undecorate, and AceConfigDialog re-installs its raw callback on
      -- EVERY Open -- so a throw in Decorate that skipped this line would silently leave the close
      -- path unchained for the rest of the session, and the frame would go back to the shared pool
      -- still dressed in ours. Reported rather than swallowed: an undressed window is exactly the
      -- kind of fault nobody files, because it does not look like an error.
      local ok, err = pcall(Options.Decorate)
      if not ok then
        ns.log("could not dress the options window: %s", tostring(err))
      end
      chainClose(dialog)
      -- Last, and only while a Move mode is running: see rehideForMove.
      rehideForMove()
    end)
  end
  return true
end

-- D31. `FeedGroup` builds a TreeGroup widget only once -- at the very root (isRoot=true,
-- container == the standalone Frame, AceConfigDialog-3.0.lua:1721 "assume tree group by default" /
-- 1743-1751) -- because every group under it whose OWN `childGroups` is not "tab"/"select" recurses
-- into the SAME tree as nested nodes (`BuildGroups`/`BuildSubGroups`, ~1005-1071: `(v.childGroups or
-- "tree") == "tree"`). Every LATER click re-feeds a group's content INTO that tree widget directly
-- -- `GroupSelected` (~1559-1578) hands its own `widget` (the tree) to `FeedGroup` as `container` --
-- so `container` IS the tree on every call but the very first, and IS the standalone Frame (with the
-- tree as its one child) on that first call.
local function findTreeWidget(container)
  if not container then return nil end
  if container.type == "TreeGroup" then return container end
  if container.children then
    for _, child in ipairs(container.children) do
      if child.type == "TreeGroup" then return child end
    end
  end
  return nil -- mutants: equivalent the last statement of a function; Lua returns nil either way
end

-- AT10-D3. Depth-first, unlike `findTreeWidget` above: the Log box is nested two levels down (the
-- Notifications page's own container holds the "log" inline group, which holds the input widget
-- itself), wherever a ScrollFrame did or did not get interposed (AceConfigDialog-3.0.lua:1634-1644).
local function findWidgetByType(container, widgetType)
  if not container then return nil end
  if container.type == widgetType then return container end
  if container.children then
    for _, child in ipairs(container.children) do
      local found = findWidgetByType(child, widgetType)
      if found then return found end
    end
  end
  return nil -- mutants: equivalent the last statement of a function; Lua returns nil either way
end

-- Never mutates AceConfigDialog.tooltip (the skill reference's own warning): that table is one
-- instance shared by every Ace3 addon's options window, and clearing it here would silence the
-- tooltip everywhere, not just for us. What IS ours alone is the tree WIDGET this hook just found --
-- `EnableButtonTooltips(false)` (AceConfigDialog-3.0.lua:1724) already silences the widget's OWN
-- tooltip (`Button_OnEnter`, AceGUIContainer-TreeGroup.lua:200-213, gated on `self.enabletooltips`),
-- but `TreeOnButtonEnter` (AceConfigDialog-3.0.lua:1485-1524), registered as this SAME widget's
-- `OnButtonEnter` callback (line 1730), is a SECOND, unconditional tooltip that ignores that flag --
-- so it is the callback itself that has to go, on this one widget.
--
-- PE3-D6 (2026-09-08, owner's second look -- the tooltip was STILL covering the page): this hook
-- passed `nil` and AceGUI DROPS a non-function silently (`WidgetBase.SetCallback`,
-- AceGUI-3.0.lua:292-296, `if type(func) == "function" then`), so the D31 fix ran, changed nothing,
-- and the spec's stand-in tree accepted the nil its real counterpart refuses. A callback that does
-- nothing is the only thing AceGUI will accept in place of one that draws -- and it is still ours
-- alone, because AceGUI wipes `widget.events` on Release (AceGUI-3.0.lua:188-190), so the next
-- addon to be handed this pooled TreeGroup gets its own tooltip back.
local function noTooltip() end

-- ============================================================ the inner Abilities tree (AB1-D9)
--
-- `spells` is a TAB group whose "Abilities" child is a tree, so FeedGroup builds a SECOND TreeGroup
-- -- `(parenttype ~= "tree")`, AceConfigDialog-3.0.lua:1721 -- and hands it to us as a child of the
-- tab widget on the path {"spells","list"}. Everything below is about that widget alone. The outer
-- tree's tooltip is suppressed (PE3-D6, it covered the page); this one's is NOT, because its rows
-- carry the per-ability "Glow, Sound on · ..." summary AB1-D9(b) asks for.

-- AB1-D9(a). A tree entry carries no "greyed" flag: `UpdateButton` only ever calls SetTexture on
-- the row's icon (AceGUIContainer-TreeGroup.lua:92-95), so desaturating the abilities with nothing
-- switched on has to happen on the button itself, the way findTreeWidget already reaches the outer
-- tree's rows. Returns how many rows it marked, so a spec can tell "ran and marked nothing" from
-- "never ran".
function Options.markAbilityIcons(tree)
  local A = ns.AbilitySettings
  local buttons = tree and tree.buttons
  if not (A and buttons) then return 0 end
  local marked = 0
  for _, button in ipairs(buttons) do
    local icon, value = button.icon, button.uniquevalue
    if icon and icon.SetDesaturated and type(value) == "string" then
      -- The All abilities row is never greyed: it is what the others inherit from, so "nothing
      -- switched on" is not a thing it can be.
      icon:SetDesaturated(value ~= A.ALL and not A.anyOn(value))
      marked = marked + 1
    end
  end
  return marked
end

-- AB1-D9(d): selecting another ability keeps the tab you were on. Each ability page is its own tab
-- group with its own status table, so the Glow tab you were reading is "selected" for THAT ability
-- and nothing at all for the next one -- which drops you back on General every time you compare two
-- abilities. Copying the previous ability's `groups.selected` forward is the whole fix, and it has
-- to happen BEFORE AceConfigDialog feeds the new group, which is why this runs from a chained
-- OnGroupSelected rather than from the FeedGroup hook.
local lastAbility = nil -- mutants: equivalent deleting the local only makes it a global; luacheck catches it
function Options.keepAbilityTab(value)
  local dialog = Options.dialog
  local prev = lastAbility
  lastAbility = value
  if not (dialog and dialog.GetStatusTable and prev and value and prev ~= value) then return nil end
  local from = dialog:GetStatusTable("Elmira", { "spells", "list", prev })
  local tab = from and from.groups and from.groups.selected
  if not tab then return nil end
  local to = dialog:GetStatusTable("Elmira", { "spells", "list", value })
  to.groups = to.groups or {}
  to.groups.selected = tab
  return tab
end

-- CHAINED, never replaced (this has cost two outages): AceGUI holds ONE callback per event name, so
-- overwriting `OnGroupSelected` would silently delete AceConfigDialog's own GroupSelected and the
-- tree would stop feeding pages at all. The prior callback is kept in a WEAK-KEYED table rather than
-- on the widget: AceGUI pools TreeGroups across every Ace3 addon on the client, and `Release` wipes
-- `widget.events` (AceGUI-3.0.lua:188-190) but not fields we invent -- so we invent none.
local priorSelect = setmetatable({}, { __mode = "k" })
local function abilitySelected(widget, event, value, ...)
  Options.keepAbilityTab(value)
  local prior = priorSelect[widget]
  if prior then return prior(widget, event, value, ...) end
end

local function installAbilityTree(tree)
  local events = tree.events
  if events and events.OnGroupSelected ~= abilitySelected and tree.SetCallback then
    priorSelect[tree] = events.OnGroupSelected
    tree:SetCallback("OnGroupSelected", abilitySelected)
  end
  Options.markAbilityIcons(tree)
end

-- ------------------------------------------------------------ AT6-D5: the Texture tab's live texture
--
-- "The texture is held on screen exactly as configured and follows every change live" -- which means
-- something has to notice when the tab STOPS being the one you are reading, and there is no event
-- for that. What there is, is FeedGroup: AceConfigDialog re-feeds a group every time a tree row or a
-- tab is clicked, with the full path of what it is about to draw, so the path IS the answer to
-- "which tab is open".
--
-- The ORDER is the whole difficulty. FeedGroup recurses INTO itself -- the tab group built for one
-- ability calls FeedGroup again for that ability's selected tab (`GroupSelected` ->
-- AceConfigDialog-3.0.lua:1571) -- and a post-hook on a nested call runs BEFORE the post-hook of the
-- call that made it. So a rebuild of the whole window fires our hook deepest-first and shallowest
-- LAST, and "release the preview on any path that is not a Texture tab" would release it a moment
-- after setting it, every single time. Only two depths are ever acted on, and they agree:
--   * a FOUR-part path (`spells > list > KEY > texture`) is a tab click, and says it outright;
--   * a THREE-part path is a different ability, whose remembered tab is in the status table by the
--     time the hook runs (`Options.keepAbilityTab` put it there);
--   * a ONE- or TWO-part path under `spells` is the page or the list being rebuilt, and its own
--     children have already answered -- so it must say nothing at all;
--   * anything else with a path at all is another page entirely, and releases;
--   * the ROOT rebuild (an empty path) is the last hook of all and says nothing, for the same
--     reason the shallow `spells` ones do not.
local function previewKeyForPath(dialog, path)
  local n = path and #path or 0
  if n == 0 then return nil, false end
  if path[1] ~= "spells" then return nil, true end
  if n == 1 then return nil, false end
  if path[2] ~= "list" then return nil, true end
  if n == 2 then return nil, false end
  if n >= 4 then return (path[4] == "texture") and path[3] or nil, true end
  local status = dialog and dialog.GetStatusTable and dialog:GetStatusTable("Elmira", path)
  local tab = status and status.groups and status.groups.selected
  return (tab == "texture") and path[3] or nil, true
end

-- Returns the key it is now holding (nil for "nothing"), plus whether this path had an opinion at
-- all -- a spec cannot otherwise tell "released it" from "left it alone", which is the difference
-- the ordering above turns on.
function Options.holdTexturePreview(path)
  local key, handled = previewKeyForPath(Options.dialog, path)
  if not handled then return nil, false end
  if ns.Textures and ns.Textures.Preview then ns.Textures.Preview(key) end
  return key, true
end

local function installTreeHook(dialog)
  if not (dialog and hooksecurefunc) then return end
  if not dialog.elmiraTreeHooked then
    dialog.elmiraTreeHooked = true
    hooksecurefunc(dialog, "FeedGroup", function(self, appName, _options, container, _rootframe, path)
      if appName ~= "Elmira" then return end
      -- AT6-D5, before the tree work and outside it: this fires for every path, including the ones
      -- that carry no tree at all (another page, another tab), which is exactly when the texture
      -- being previewed has to come off screen.
      Options.holdTexturePreview(path)
      -- AT10-D4, also before the tree work: every navigation, tree row or tab alike, reaches this
      -- hook, and by the time it fires the status tree already carries the FULL selection the click
      -- just made (`SelectGroup` writes it synchronously; only the on-screen redraw is deferred) --
      -- so re-reading it here, on every fire, is self-correcting rather than a race with the order
      -- AT6-D5's own comment above describes.
      Options.rememberPath(Options.currentPath())
      -- AT10-D3: the Notifications Log's read-only box gets no Accept button -- AceGUI's own
      -- MultiLineEditBox re-enables it on every OnAcquire (widgets are pooled across every Ace3
      -- addon), so it has to be disabled again on every feed of this page, not just the first.
      if path and path[1] == "notifications" then
        local box = findWidgetByType(container, "MultiLineEditBox")
        if box and box.DisableButton then box:DisableButton(true) end
      end
      local tree = findTreeWidget(container)
      if not tree then return end
      -- The inner Abilities tree: its own hook, and emphatically NOT the outer one's -- silencing
      -- its tooltip would take the per-ability channel summary with it.
      if path and path[1] == "spells" and path[2] == "list" then
        return installAbilityTree(tree)
      end
      -- The outer tree gets ONE change and no more: its tooltip silenced. PD2 deleted the block
      -- that used to force the clicked node open as well -- it was written for the template/fork
      -- sub-pages, which are gone, and it never opened anything anyway: it wrote
      -- `GetStatusTable(app, {}).groups[uniquevalue]`, one level above the map `BuildLevel` reads
      -- (`tree.status.groups`, AceGUIContainer-TreeGroup.lua:370-385, where `tree.status` IS that
      -- `.groups` table -- AceConfigDialog-3.0.lua:1733-1738). Expansion is AceConfigDialog's to
      -- own: `SelectGroup` opens the nodes on the path it drives (:471-474), and the "+" arrow
      -- opens the rest. This widget is POOLED across every Ace3 addon on the client, so a key we
      -- invent in its status table travels to the next addon that borrows it.
      if tree.SetCallback then tree:SetCallback("OnButtonEnter", noTooltip) end
    end)
  end
end

-- The General page's read-only command list. Built from `Slash.availableEntries()`, which already
-- excludes the `unavailableNamed` placeholders (sim, history, rotdiag) -- a settings panel should
-- never advertise a command whose only output is "not available yet".
local function slashRows()
  local args = {}
  local rows = (ns.Slash and ns.Slash.availableEntries and ns.Slash.availableEntries()) or {}
  for i, r in ipairs(rows) do
    args["row" .. i] = {
      type = "description", fontSize = "medium", order = i, width = "full",
      name = string.format("|cff9AA0A6/elm %s|r  %s", r.key, tostring(r.desc)),
    }
  end
  return args
end

-- ============================================================ The Queue page
--
-- PE11. Thirteen controls in one flat list, with `Show the queue strip` at the top and `Show the
-- queue` five rows below it, was a page you had to read twice to change something once. Three
-- inline panels now -- when you see it, how big it is and where, what it tells you -- and the two
-- colliding names are gone (PE11-D1). Three sibling panels and no outer wrapper: an AceConfig
-- inline group is always the full width of the page, so nesting them inside a fourth would buy a
-- second frame edge and nothing else.
--
-- TOOLTIPS ONLY, no `description` rows (PE11-D3), and there is a hard reason as well as a taste
-- one: the tooltip is an AceGUI OnEnter/OnLeave callback (AceConfigDialog-3.0.lua:1084-1085) and a
-- `description` is drawn as a Label, which never fires either. Prose on this page could therefore
-- never carry a tooltip of its own -- it would be permanent clutter where a hover would do.

-- PE11-D4. With the strip switched off the other twelve controls still looked live and did nothing;
-- this is the third page this session with that defect (PE6's glow master, PE7's), so it is written
-- once here rather than per row. The reason a Queue row is dead right now, or nil -- in the order a
-- player would fix them.
local function queueBlocked(needsOutOfCombat)
  local p = profile() or {}
  if p.showQueue == false then
    return L["Turn \"Enable the queue strip\" on, at the top of this page, to use this."]
  end
  local fallback = ns.Visibility and ns.Visibility.DEFAULT
  if needsOutOfCombat and (p.visibility or fallback) == "combat" then
    return L["\"When to show it\" is set to combat only, so there is no out-of-combat strip to fade."]
  end
  return nil -- mutants: equivalent Lua's implicit nil return says the same thing
end

-- A row's own tooltip, plus WHY it is greyed out when it is. Both halves matter: a dead control with
-- no explanation is the same dead end as a live one that does nothing.
local function queueDesc(text, needsOutOfCombat)
  return function()
    local why = queueBlocked(needsOutOfCombat)
    if why then return text .. "|n|n" .. ns.Colors.wrap(ns.Colors.WARN, why) end
    return text
  end
end

-- Deliberately NOT the `get = function() return false end` shape a disabled row elsewhere in this
-- file uses: these rows keep their real getters, so a greyed control still shows the value that is
-- stored. Greying a toggle that reads `false` for a stored `true` tells the player their setting was
-- thrown away when it was only paused.
local function queueDisabled(needsOutOfCombat)
  return function() return queueBlocked(needsOutOfCombat) ~= nil end
end
local function stripDisabled() return queueBlocked(false) ~= nil end

-- PE11-D5. Whether the strip is in positioning mode this instant. Read through Queue rather than
-- kept here: the mode lives with the frame it moves, and the options window is not the only thing
-- that can end it (`Queue.SetLocked` does, and so does the panel closing).
local function positioningNow()
  return (ns.Queue and ns.Queue.isPositioning and ns.Queue.isPositioning()) == true
end

local function queueGroup()
  return {
    -- 1. Whether the strip is on screen at all, and how solid. The master switch first, then the
    --    two questions that only exist once it is on.
    when = {
      type = "group", inline = true, order = 1, name = L["When you see it"],
      args = {
        -- Separate from `enabled` on purpose (ADR-0015 §3). Hekili players routinely watch only
        -- the glowing button; before this the only way to lose the strip was to lose the glow too.
        -- PE11-D1: named for the switch it is ("Enable the queue strip", matching "Enable action
        -- bar glow" on General) rather than for the question the dropdown below it answers.
        showQueue = {
          type = "toggle", order = 1, name = L["Enable the queue strip"],
          -- AT2-D2: reworded to the strip alone. The action-bar glow (and the strip's own glow,
          -- D3) no longer take their visibility from this switch or from the dropdown below it --
          -- each answers to its own "Show the glow" mode on the ability's Glow tab now.
          desc = L["The row of icons showing what to press now and what comes after it. Turning it "
                .. "off hides the icons only; the action-bar glow keeps whatever schedule you gave "
                .. "it and is not affected."],
          get = function() return profile().showQueue ~= false end,
          set = function(_, v) profile().showQueue = v; redraw() end,
        },
        visibility = {
          type = "select", order = 2, width = "full", name = L["When to show it"],
          -- AT2-D2: reworded to the strip alone, for the same reason as showQueue's desc above.
          desc = queueDesc(L["Which moments the strip is on screen. Hiding it also stops the "
                .. "update loop, so a hidden queue costs nothing at all. The default keeps it out "
                .. "of your way in town and up the moment you have something to fight."]),
          disabled = stripDisabled,
          values = function()
            local out = {}
            for _, mode in ipairs(ns.Visibility.MODES) do out[mode] = L[LABELS[mode]] end
            return out
          end,
          sorting = function()
            local out = {}
            for i, mode in ipairs(ns.Visibility.MODES) do out[i] = mode end
            return out
          end,
          get = function() return profile().visibility or ns.Visibility.DEFAULT end,
          set = function(_, v)
            profile().visibility = v
            if ns.Glow then ns.Glow.StopAll() end   -- a mode change must not strand a lit button
            redraw()
          end,
        },
        -- PE10-D2. Not the same question as "When to show it" above, and the desc says so: this is
        -- for people who keep the strip up out of combat and want it quieter, not gone.
        -- PE11-D4: also dead when the strip is set to combat only, because then there is no
        -- out-of-combat strip for it to act on.
        oocAlpha = {
          type = "range", order = 3, name = L["Out-of-combat opacity"],
          min = 0.1, max = 1.0, step = 0.05, isPercent = true,
          desc = queueDesc(L["How solid the strip is while you are not fighting. It goes back to "
                .. "full the moment you enter combat. To hide it entirely out of combat, use "
                .. "\"When to show it\" above instead."], true),
          disabled = queueDisabled(true),
          get = function() return tonumber(profile().oocAlpha) or 1 end,
          set = function(_, v) profile().oocAlpha = v; redraw() end,
        },
      },
    },
    -- 2. How big it is, which way it grows, and where it sits. Most-reached-for first: the two
    --    numbers everyone changes, then the shape, then the button that puts it somewhere.
    size = {
      type = "group", inline = true, order = 2, name = L["Size and position"],
      args = {
        depth = {
          type = "range", order = 1, name = L["Casts to show"], min = 1, max = 5, step = 1,
          desc = queueDesc(L["How many casts ahead the strip shows. The first icon is what to press "
                .. "now; the rest are what the rotation projects after it. One is the whole answer "
                .. "with nothing to read past it; five is a plan."]),
          disabled = stripDisabled,
          get = function() return profile().depth end,
          set = function(_, v) profile().depth = v; redraw() end,
        },
        -- PE11-D1: "Strip scale" was named to tell it apart from the window's scale, which is on
        -- another page. In a panel called "Size and position" the qualifier is noise.
        scale = {
          type = "range", order = 2, name = L["Size"], min = 0.5, max = 2.0, step = 0.05,
          desc = queueDesc(L["How large the queue icons are drawn on your screen. If you want them "
                .. "the size of the buttons you already read, use \"Match my action bars\" below "
                .. "rather than hunting for the number."]),
          disabled = stripDisabled,
          isPercent = true,
          get = function() return profile().scale end,
          set = function(_, v) profile().scale = v; redraw() end,
        },
        -- PE10-D4. Beside the slider it writes, because that is where someone who has just
        -- dragged the slider around looking for "the same size as my bars" is looking.
        matchBars = {
          type = "execute", order = 3, name = L["Match my action bars"],
          desc = queueDesc(L["Measures a button on your action bars and sets the size above so the "
                .. "first icon is drawn the same. Needs one of the rotation's spells to be on a "
                .. "bar you can see."]),
          disabled = stripDisabled,
          func = function()
            local scale = ns.Queue.matchBarScale()
            redraw()
            -- Say what happened either way. A button that computes nothing and reports nothing is
            -- indistinguishable from one that is broken.
            local text = scale
              and string.format("Strip scale set to %d%% to match your action bars.",
                                math.floor(scale * 100 + 0.5))
              or ("Could not measure an action button — put one of this rotation's spells on "
                  .. "a bar you can see, then try again.")
            if ns.Announce then ns.Announce.emit("status", text) else ns.log("%s", text) end
          end,
        },
        -- PE10-D1. Where slots 2..n go from slot 1. Slot 1 itself stays exactly where it is in
        -- every direction, which is why this can be changed after positioning the strip.
        grow = {
          type = "select", order = 4, name = L["Direction"],
          desc = queueDesc(L["Which way the strip lays out after the first icon. The first icon "
                .. "does not move, so you can position the strip first and pick a direction "
                .. "afterwards. Down or Up suits a strip beside your character; Left suits one "
                .. "anchored to the right of the screen."]),
          disabled = stripDisabled,
          values = function() return choices(GROW_LABELS, ns.Transition.GROW) end,
          sorting = function() return ns.Transition.GROW end,
          get = function() return ns.Transition.growth(profile().grow) end,
          set = function(_, v) profile().grow = v; redraw() end,
        },
        -- PE10-D3. Zero is a real answer: some players want the strip to read as one block.
        spacing = {
          type = "range", order = 5, name = L["Spacing"],
          min = 0, max = 20, step = 1,
          desc = queueDesc(L["How many pixels apart the icons sit. Zero makes the strip read as "
                .. "one block; a wide gap makes the first icon easier to pick out of the corner "
                .. "of your eye."]),
          disabled = stripDisabled,
          get = function() return ns.Transition.spacing(profile().spacing) end,
          set = function(_, v) profile().spacing = v; redraw() end,
        },
        -- PE11-D5. The strip is hidden out of combat with no target by default, so "unlock and drag
        -- it" asked the player to drag something they cannot see. Relabelled while active rather
        -- than paired with a second button: there is one mode, so there is one control for it.
        -- AceConfigDialog re-Opens the frame after every execute (AceConfigDialog-3.0.lua:867-872),
        -- which is what makes the label change land without anything asking it to refresh.
        position = {
          type = "execute", order = 6,
          name = function()
            return positioningNow() and L["Done Positioning"] or L["Position the Strip"]
          end,
          desc = queueDesc(L["Puts the strip on screen with sample icons and lets you drag it, even "
                .. "in the moments it would normally be hidden. Press it again when the strip is "
                .. "where you want it. Nothing is saved except the position: your lock setting is "
                .. "left exactly as it was, and closing this window ends it too."]),
          disabled = stripDisabled,
          func = function()
            if positioningNow() then ns.Queue.StopPositioning() else ns.Queue.StartPositioning() end
          end,
        },
      },
    },
    -- 3. What the icons say beyond which spell they are. `animate` belongs here rather than with
    --    size: motion IS information on this strip. ADR-0015 §3 forbids it to glow, so movement is
    --    how it says "something changed" -- turning it off costs a signal, not a decoration.
    tells = {
      type = "group", inline = true, order = 3, name = L["What it tells you"],
      args = {
        -- PE9-D4. The number is drawn in the icon's bottom-left corner.
        waits = {
          type = "select", order = 1, name = L["Show waits"],
          desc = queueDesc(L["Prints how many seconds until each later suggestion happens, in the "
                .. "icon's bottom-left corner. Most of the time the answer is just the next global "
                .. "cooldown, so by default the number only appears when the wait is longer than "
                .. "that -- which is exactly when it is worth knowing."]),
          disabled = stripDisabled,
          values = function() return choices(WAIT_LABELS, WAIT_ORDER) end,
          sorting = function() return WAIT_ORDER end,
          get = function() return profile().waits or "gcd" end,
          set = function(_, v) profile().waits = v; redraw() end,
        },
        keybinds = {
          type = "select", order = 2, name = L["Keybinds"],
          desc = queueDesc(L["Prints the key each suggestion is bound to on your action bars, in "
                .. "the icon's top-right corner. Nothing appears for an ability you have not put "
                .. "on a bar. On the first icon only by default: on a later icon it is a key NOT "
                .. "to press yet."]),
          disabled = stripDisabled,
          values = function() return choices(KEYBIND_LABELS, KEYBIND_ORDER) end,
          sorting = function() return KEYBIND_ORDER end,
          get = function() return profile().keybinds or "first" end,
          set = function(_, v) profile().keybinds = v; redraw() end,
        },
        -- PE9-D5. Split out of Learning mode, which used to be the only way to see it -- and
        -- which cost you the whole lookahead to get it.
        showReason = {
          type = "toggle", order = 3, width = "full", name = L["Show the rule name"],
          desc = queueDesc(L["Writes the name of the rule that chose the first suggestion "
                .. "underneath it, so you learn why rather than memorising an order. Works at any "
                .. "number of icons; Learning mode below switches it on for you."]),
          disabled = stripDisabled,
          get = function() return profile().showReason == true end,
          set = function(_, v) profile().showReason = v; redraw() end,
        },
        animate = {
          type = "toggle", order = 4, name = L["Animate changes"],
          -- AT2-D3 amends ADR-0015 §3: the strip no longer NEVER glows, only never by default, so
          -- this no longer claims it as a fact.
          desc = queueDesc(L["Icons slide when the queue moves and pop when you cast the "
                .. "suggestion. The strip does not glow unless you turn that on below, so motion "
                .. "is normally how it says something changed: with this off, a new first "
                .. "suggestion simply appears and is easy to miss."]),
          disabled = stripDisabled,
          get = function() return profile().animate ~= false end,
          set = function(_, v) profile().animate = v; redraw() end,
        },
        -- AT2-D3: opt-in, off by default, and its own switch -- unaffected by "Enable action bar
        -- glow" on General in either direction. Lives beside `animate` rather than in the size
        -- panel: both are ways the strip says "something changed", and this is the one that used
        -- to be forbidden outright.
        stripGlow = {
          type = "toggle", order = 5, name = L["Glow the first icon on the strip"],
          desc = queueDesc(L["Puts the same glow the action bar uses on the strip's first icon "
                .. "too, in the suggested ability's own colour and style. Off by default -- the "
                .. "strip already says \"this one\" with size and motion. Follows the same \"Show "
                .. "the glow\" schedule and \"Only in combat\" guard as the bar glow (set on each "
                .. "ability's Glow tab), and is not affected by \"Enable action bar glow\" on "
                .. "General: it is its own switch."]),
          disabled = stripDisabled,
          get = function() local p = profile(); return p and p.queue and p.queue.stripGlow == true end,
          set = function(_, v)
            local p = profile()
            p.queue = p.queue or {}
            p.queue.stripGlow = v
            if ns.Glow then ns.Glow.StopAll() end
            redraw()
          end,
        },
        -- PE11-D3: the tooltip names all three settings the preset moves. A preset that rewrites
        -- controls the player can see in the same panel without saying which is how a settings
        -- page loses their trust.
        learning = {
          type = "toggle", order = 6, width = "full", name = L["Learning mode"],
          desc = queueDesc(L["Shows one suggestion at a time, larger, with the name of the rule "
                .. "that chose it. It writes three settings on this page for you: \"Casts to "
                .. "show\" to 1, \"Size\" to 140% and \"Show the rule name\" on -- and puts all "
                .. "three back the way they were when you switch it off again. Anything you change "
                .. "yourself while it is on is yours and stays. Does not turn on any screen-edge "
                .. "cues; those stay your choice."]),
          disabled = stripDisabled,
          get = function() return profile().learning end,
          set = function(_, v)
            local applied = ns.Queue.ApplyLearningPreset(v)
            redraw()
            -- Say what a preset changed. A toggle that silently rewrites three other settings the
            -- user can see in the same panel is how a settings screen loses trust.
            if applied and not applied.restored then
              -- PE9-D5's third setting is named only when the preset reports it, so the sentence
              -- stays true of what the preset did rather than of what it used to do.
              local text = string.format("Learning mode on: icons set to %d, scale to %d%%%s.",
                                         applied.depth, math.floor(applied.scale * 100),
                                         applied.showReason and ", rule names on" or "")
              if ns.Announce then ns.Announce.emit("status", text) else ns.log("%s", text) end
            elseif applied then
              -- PE12: say what came BACK too. Silently rewriting three settings is no better on the
              -- way out than on the way in. Only the ones the player left alone are named, because
              -- only those were restored -- anything they changed while learning stayed theirs.
              local parts = {}
              if applied.depth then
                parts[#parts + 1] = string.format("icons back to %d", applied.depth)
              end
              if applied.scale then
                parts[#parts + 1] = string.format("scale back to %d%%", math.floor(applied.scale * 100))
              end
              if applied.showReason ~= nil then parts[#parts + 1] = "rule names off" end
              local text = "Learning mode off: " .. table.concat(parts, ", ") .. "."
              if ns.Announce then ns.Announce.emit("status", text) else ns.log("%s", text) end
            end
          end,
        },
      },
    },
  }
end

function Options.table()
  return {
    type = "group",
    name = ns.Colors.wrap(ns.Colors.BRAND, "Elmira"),
    args = {
      -- The front page. Everything that is about ELMIRA rather than about one part of its display:
      -- the master switch, the wizard, and the settings window you are standing in.
      general = {
        type = "group", order = 1, name = L["General"], inline = false,
        args = {
          -- PE6-D1 (2026-09-08): the four front controls are ONE row, and the two lesser toggles sit
          -- PE8 (owner, 2026-09-09: "still not right aligned"). Width arithmetic CANNOT right-align a
          -- toggle. AceGUI's CheckBox anchors its box at the LEFT of whatever cell it is given
          -- (`checkbg` left, `text` LEFT-of-checkbg's-RIGHT, AceGUIWidget-CheckBox.lua:22-26,45-47),
          -- so a wider cell only adds empty space to its right -- which is exactly the gap the owner
          -- can see. A Button is the opposite: its frame fills the cell and the label centres inside
          -- it (AceGUIWidget-Button.lua:87-88), so a button IS flush with the edge it ends on.
          -- Hence the row order: the three switches (same kind of thing) sit together on the left and
          -- `Choose Your Rotation`, the only widget that can honour a right edge, ends the row.
          -- as a group against its right edge. `width = "relative"` + `relWidth` is the only shape
          -- AceGUI's Flow layout scales to the row (`framewidth = width * child.relWidth`,
          -- AceGUI-3.0.lua:709-711); left-packed defaults sized every control at a flat 170px and
          -- left the row ending wherever the fourth happened to land.
          -- SIXTEENTHS, not decimals: Flow starts a new row the instant `framewidth + usedwidth >
          -- width` (:730), so a floating-point crumb over 1.0 would drop "Lock all positions" onto a
          -- line of its own. 3/16 + 5/16 + 4/16 + 4/16 is exactly 1.0 in binary. The button gets the
          -- widest share because its label is the longest and a Button does not wrap.
          enabled = {
            type = "toggle", order = 1, width = "relative", relWidth = 0.1875,
            name = L["Enable Elmira"],
            desc = L["Turns the whole display off: no queue, no bar glow, no update loop."],
            get = function() return profile().enabled end,
            set = function(_, v)
              profile().enabled = v
              -- Disable() stops the update loop, so no later tick can reach the glow to release
              -- it: without this the bar button lit by the last suggestion stays lit forever,
              -- while the panel promises "no bar glow". Three lesser switches already do this.
              if ns.Glow then ns.Glow.StopAll() end
              -- PE11-D5, the same class of stranding: Disable() stops the ticks, and positioning
              -- mode is deliberately immune to the render loop, so a strip left mid-positioning
              -- would sit on screen under a switch that says "no queue".
              if not v and ns.Queue and ns.Queue.StopPositioning then ns.Queue.StopPositioning() end
              if v then ns.Display.Enable() else ns.Display.Disable() end
              redraw()
            end,
          },
          -- The front door (ADR-0015 SS1): lands ON the Rotation section of THIS open dialog.
          -- `Options.Open` re-uses AceConfigDialog's own already-open frame (its `Open` only
          -- creates a new one when `OpenFrames[appName]` is nil) and sets its path, so this is a
          -- SelectGroup, not a reopen.
          -- D39: "Run setup again" is gone along with the wizard window. Choosing or changing a
          -- rotation IS the Rotations tree now; this button is the only front-door needed.
          chooseRotation = {
            type = "execute", order = 4, width = "relative", relWidth = 0.3125,
            name = L["Choose Your Rotation"],
            desc = L["Jumps straight to picking or editing your rotation."],
            func = function() Options.Open("rotation") end,
          },
          minimap = {
            type = "toggle", order = 2, width = "relative", relWidth = 0.25,
            name = L["Show minimap button"],
            desc = L["Shows Elmira's launcher button on the minimap."],
            get = function()
              local m = ns.db and ns.db.global and ns.db.global.minimap
              return not (m and m.hide)
            end,
            -- Never touches LibDBIcon itself: NA:SetMinimapShown is the one seam.
            set = function(_, v)
              if ns.addon and ns.addon.SetMinimapShown then ns.addon:SetMinimapShown(v) end
            end,
          },
          locked = {
            type = "toggle", order = 3, width = "relative", relWidth = 0.25,
            name = L["Lock all positions"],
            desc = L["Locks the queue strip and the on-screen message. Same as /elm lock."],
            get = function() return (ns.Queue and ns.Queue.isLocked()) == true end,
            -- PE13-D2: ending the on-screen message's move mode used to be done HERE, so /elm lock
            -- left a mouse-eating frame across the middle of the screen that the panel would have
            -- cleared. Queue.SetLocked ends both temporary modes now, so every lock decision does.
            set = function(_, v)
              if ns.Queue then ns.Queue.SetLocked(v) end
            end,
          },
          -- PE6-D2: a plain row, not a titled box. An AceConfig inline group is ALWAYS the full
          -- width of the page, so a panel around a single slider draws a full-width frame to hold
          -- one 170px control -- pure chrome, and "Panel scale" already says what it scales.
          scale = {
            type = "range", order = 10, name = L["Panel scale"],
            -- Whole-window scale, not a font size: AceGUI row heights are fixed, so a bigger
            -- font clips inside the same 24px row. Scale is the one lever that grows the text
            -- and the rows it sits in together.
            desc = L["How large this settings window is drawn. Applies as you drag."],
            min = SCALE_MIN, max = SCALE_MAX, step = SCALE_STEP, isPercent = true,
            get = function() return Options.windowScale() end,
            set = function(_, v) Options.SetWindowScale(v) end,
          },
          -- PE6-D3: Action Bars was a top-level tree page of its own; it is one panel's worth of
          -- content and it answers a General question ("why is nothing glowing"), so it lives here.
          -- Nothing navigated to the old page: every `Options.Open` call site passes no path,
          -- "rotation" or "spells", and every `SelectGroup` names "general", "rotation" or "spells"
          -- (Core/Slash.lua, Core/Init.lua, Display/Queue.lua, Setup/Wizard.lua, Options/Spells.lua,
          -- Options/Rotation.lua), so removing the node breaks no path.
          bars = {
            type = "group", inline = true, order = 15, name = L["Action Bars"],
            args = actionBarsGroup(),
          },
          slash = {
            type = "group", inline = true, order = 20, name = L["Slash commands"],
            -- Read from ns.Slash at table-build time, not hand-copied, so this can never list a
            -- command /elm does not actually have, or omit one it just gained.
            args = slashRows(),
          },
        },
      },
      -- The strip alone (PE11). Built by queueGroup() above rather than written out here: it is
      -- three inline panels of thirteen controls, and inlining that in the middle of the page list
      -- buried General and Glow under it.
      queue = {
        -- M1a: 4 of the owner's 1-8 top-level order.
        type = "group", order = 4, name = L["Queue"], inline = false,
        args = queueGroup(),
      },
      -- PE6-D3: "Action bars" was 5 of the owner's M1a 1-8 top-level order. It is now an inline
      -- panel on General; order 5 is left unused rather than renumbered, because these numbers only
      -- have to sort and shifting them would touch four unrelated pages.
      --
      -- AB4-D2: order 6 is unused for the same reason. That was the Glow page, which AB1 emptied
      -- into Abilities > All abilities > Glow and left as one line of signposting; a top-level node
      -- whose whole content is "this moved" is a page the player still has to open to learn nothing.
      -- Whether the bars glow at all is on General > Action Bars.
      --
      -- One heading for everything that TELLS you something, as against the sections above, which
      -- are about what the display shows. D28 (2026-09-07 Notifications pass): what used to be the
      -- "Announcements" tab is now this page's own content -- `childGroups` is gone, so there is no
      -- longer a group control to pick it from -- and since AB4-D2 there are no sub-pages under it
      -- either.
      -- M1a: 7 of 8.
      notifications = {
        type = "group", order = 7, name = L["Notifications"],
        args = announceGroup(),
      },
      rotation = ns.Rotation and ns.Rotation.group() or nil,
      -- R2 (D52): directly after Rotations -- the Abilities registry (M1b: player-visible name;
      -- the group key stays `spells`) is the thing a rotation or a cue draws from, so it reads as
      -- the next section over. M1a put the two at order 2 and 3 of the owner's 1-8 top-level order.
      spells = ns.SpellsPage and ns.SpellsPage.group() or nil,
    },
  }
end

-- AceDBOptions' own profile page, plus the one sentence it cannot know to say (AB4-D2).
--
-- Everything an ability does on screen -- its glow, its texture, its screen edge, its sounds, its
-- announcement -- moved to `db.char` at AB1-D3, so this page's Copy From / Reset no longer reaches
-- any of it. That is a deliberate scope change and an invisible one: a player who copies a profile
-- to an alt and finds none of their cues followed has no way to tell that from a bug. Said here,
-- where the copying is done, with the way to actually do it.
--
-- `order = -1` puts it above AceDBOptions' own rows (its lowest is the `desc` at 1), so it is read
-- before the buttons rather than found after them.
function Options.profilesTable(AceDBOptions)
  local table_ = AceDBOptions:GetOptionsTable(ns.db)
  table_.args = table_.args or {}
  table_.args.elmiraAbilityScope = {
    type = "description", order = -1, width = "full", fontSize = "medium",
    name = L["Ability settings (glow, textures, screen edge, sounds, announcements) are per "
          .. "character and do not switch with the profile -- use Abilities > Share to copy them."],
  }
  return table_
end

function Options.Register()
  local AceConfig = LibStub and LibStub("AceConfig-3.0", true)
  local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
  if not (AceConfig and AceConfigDialog) then return false end

  -- Built fresh on open rather than once at load: the pages are derived from the registry, the
  -- active build and the character's gear, and all three can change within a session.
  AceConfig:RegisterOptionsTable("Elmira", Options.table)
  Options.frame = AceConfigDialog:AddToBlizOptions("Elmira", "Elmira")

  local AceDBOptions = LibStub("AceDBOptions-3.0", true)
  if AceDBOptions and ns.db then
    AceConfig:RegisterOptionsTable("Elmira-Profiles", Options.profilesTable(AceDBOptions))
    AceConfigDialog:AddToBlizOptions("Elmira-Profiles", L["Profiles"], "Elmira")
  end
  Options.dialog = AceConfigDialog
  return true
end

-- Is the Builder on screen, showing, and not being typed into?
--
-- The gate on the Builder's live refresh (Options/Rotation.onQueueChanged). Three separate
-- questions, and every one of them has to be true before the panel may be rebuilt underneath the
-- player:
--   * **Is the window even open?** Elmira has two: the standalone dialog, which AceConfigDialog
--     records in `OpenFrames.Elmira` while it is up, and the Blizzard-embedded panel, which is a
--     frame we hold. Refreshing a closed panel is pure cost -- it runs every time the queue
--     changes, which in combat is several times a second.
--   * **Is the Builder the visible TAB?** `AceConfigRegistry:NotifyChange` rebuilds the whole
--     options table, so refreshing while the player is reading the Rotations tab would throw away
--     their scroll position for a status column they cannot see.
--   * **Is anyone typing?** Every AceConfig `set` rebuilds the panel and an AceGUI EditBox commits
--     only on Enter, so a rebuild that lands mid-keystroke silently discards what was typed.
--
-- `groups` is nil until the tab group has been opened once, which is the state on the very first
-- render -- and indexing it is what would take the render loop down.
function Options.builderIdle()
  local dialog = Options.dialog
  if not dialog then return false end
  -- FX1-D5: a fourth question. The standalone frame is still in OpenFrames while a Move mode has it
  -- hidden, and `NotifyChange` ends in AceConfigDialog re-Opening the app -- which SHOWS the frame
  -- (AceConfigDialog-3.0.lua:1784-1788, 1930-1933). The window would pop back up over the very
  -- sample the player is dragging.
  if hiddenForMove then return false end
  local standalone = dialog.OpenFrames and dialog.OpenFrames.Elmira
  local embedded = Options.frame and Options.frame.IsVisible and Options.frame:IsVisible()
  if not (standalone or embedded) then return false end

  local status = dialog.GetStatusTable and dialog:GetStatusTable("Elmira", { "rotation" })
  local groups = status and status.groups
  if not groups or groups.selected ~= "builder" then return false end

  if ns.Adapter and ns.Adapter.typing and ns.Adapter.typing() then return false end
  return true
end

-- AB1-D1: the inner Abilities tree opens at 220px rather than AceGUI's 175 (DEFAULT_TREE_WIDTH,
-- AceGUIContainer-TreeGroup.lua) -- a spell name plus its "player added" colouring does not fit in
-- 175. Seeded into the status table BEFORE anything can feed that path, because `SetStatusTable`
-- fills `treewidth` in with the default the moment the widget is built and there is no pre-hook to
-- get in front of it. Written once and never again: the tree is user-resizable and drags its own
-- width back into this same field, which a second write would undo on the next open.
local ABILITY_TREE_WIDTH = 220
function Options.seedAbilityTree()
  local dialog = Options.dialog
  if not (dialog and dialog.GetStatusTable) then return false end
  local status = dialog:GetStatusTable("Elmira", { "spells", "list" })
  status.groups = status.groups or {}
  if status.groups.treewidth then return false end
  status.groups.treewidth = ABILITY_TREE_WIDTH
  return true
end

-- `...` is an optional path into the options table, e.g. Options.Open("rotation") to land on the
-- Rotation section. Fed to `dialog:SelectGroup` AFTER an unconditional `Open("Elmira")`, never as a
-- path on Open itself: AceConfigDialog:Open(appName, container, ...) stores that path as the
-- frame's `basepath` and feeds it as the window's ROOT (AceConfigDialog-3.0.lua ~1897-1930), which
-- replaces the whole tree -- including the left menu -- with just that one group.
function Options.Open(...)
  -- FX1-D5. Asking for the panel ends a Move mode rather than opening on top of one: the window is
  -- only hidden while a mode runs, so an Open that skipped this would put a window on screen that
  -- the mode still believes it has hidden -- and the mode's Done button would then hide it a second
  -- time with no bar left to bring it back. EndMove is a no-op when no mode is running.
  Options.EndMove()
  if not Options.dialog then Options.Register() end
  if Options.dialog then
    -- BEFORE Open, because Open reads the status table it writes into and applies it on the way up
    -- (AceConfigDialog-3.0.lua:1838). Called with the REMEMBERED size, not the shipped one: this is
    -- the only hook that gets a size onto a frame that has not been created yet.
    if Options.dialog.SetDefaultSize then
      local w = windowDB() or {}
      local d = windowDefaults()
      Options.dialog:SetDefaultSize("Elmira", w.width or d.width, w.height or d.height)
    end
    -- Installed once per dialog, not per Open, and firing on every dialog:Open from here on --
    -- including the call below, synchronously, since hooksecurefunc's post-hook runs inside the
    -- very call it wraps. That is what makes a refresh Options.Open never triggered (the range
    -- slider's OnMouseUp, AceConfigDialog-3.0.lua:856-862) still decorate and re-chain OnClose.
    local hooked = installRefreshHook(Options.dialog)
    Options.seedAbilityTree()
    -- Independent of the refresh hook above: FeedGroup fires on every navigation, not only on Open,
    -- so this one is installed unconditionally rather than gating anything on it.
    installTreeHook(Options.dialog)
    Options.dialog:Open("Elmira")
    -- SelectGroup, not a second Open with the path: it moves the SAME frame's selection onto the
    -- requested section without ever making it the window's root, so General, Queue, Rotation and
    -- the rest of the left menu stay on screen.
    --
    -- D61e (2026-09-07 in-game round, amended by AT10-D4, 2026-09-11): `/elm config` used to land on
    -- Rotations, not General, on a FRESH status table -- Rotations registered at `order = 0`,
    -- General at `order = 1`, and AceConfigDialog's tree selects the lowest-order group when nothing
    -- has been selected yet. M1a's reorder made General the lowest by itself, which made an
    -- unconditional "no path means General" redundant every open but the very first -- and it also
    -- meant "no path" could never mean anything else, so the window forgot where the player left it
    -- on every `/reload`. AT10-D4: "no path" now means `windowDB().lastPath` -- the full path this
    -- SAME chained FeedGroup hook keeps current on every navigation -- and only General when nothing
    -- has ever been remembered (a fresh install, or a database from before this). A path WITH an
    -- explicit page (`/elm config <page>`, an Edit button) still goes exactly where asked.
    local path -- mutants: equivalent deletion only makes it a global; luacheck catches that
    if select("#", ...) > 0 then
      path = { ... }
    else
      local w = windowDB()
      path = (w and w.lastPath) or { "general" }
    end
    Options.dialog:SelectGroup("Elmira", unpack(path))
    -- Read back from the dialog's own status tree when one is available: `SelectGroup`'s own walk
    -- is what makes a stale path (an ability since removed) land safely, stopping still selected at
    -- the last segment that still exists (AceConfigDialog-3.0.lua:479-482) -- so what gets
    -- remembered from here on is where it actually landed, not the broken path that was asked for.
    -- Falls back to the requested path itself against a dialog stand-in that exposes no status
    -- table at all, so the remembered path still advances rather than going stale forever.
    Options.rememberPath(Options.currentPath() or path)
    if not hooked then
      -- No hooksecurefunc on this client (never true in-game; only reachable if the global is
      -- missing entirely): the hook above never got the chance to run, so decorate and chain the
      -- close callback directly instead of leaving the panel undressed.
      Options.Decorate()
      chainClose(Options.dialog)
    end
    return true
  end
  return false
end

ns.Options = Options
return Options
