-- Elmira/Options/Options.lua — the settings UI (AceConfig-3.0).
--
-- Every user-facing string goes through AceLocale (`ns.L[...]`), enUS only in v1, so a translation
-- is a data file rather than a rewrite.
--
-- The overlay section is the interesting one. ADR-0009 forbids a global "overlay on" switch, so
-- there isn't one: the section lists the cues the ACTIVE BUILD suggests, each individually
-- opt-in-able, and a cue that cannot fire is shown disabled WITH ITS REASON rather than hidden.
-- Hiding it would leave the user wondering why a documented cue is missing; offering it would let
-- them enable something that can never fire.
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

-- Screen edges, named for humans. Overlay.EDGES is the authority on which ones exist; this only
-- names them, so adding an edge there cannot leave an unnamed entry here.
local EDGE_LABELS = { left = "Left", right = "Right", top = "Top", bottom = "Bottom" }
local function edgeChoices()
  local out = {}
  for _, e in ipairs((ns.Overlay and ns.Overlay.EDGES) or {}) do out[e] = L[EDGE_LABELS[e] or e] end
  return out
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

local function barRows()
  local args, order = {}, 0
  for _, r in ipairs((ns.BarProviders and type(ns.BarProviders.status) == "function" and ns.BarProviders.status()) or {}) do
    order = order + 1
    local label = L[BAR_NAMES[r.name] or r.name]
    local state = r.state == "inactive"
      and string.format(L[BAR_STATE.inactive], tostring(r.activeName))
      or L[BAR_STATE[r.state]]
    -- ASCII, not glyphs. The client's font has no U+25CF/U+25CB and renders both as an empty box, so
    -- the first in-game run showed a column of identical squares -- exactly the "every state looks
    -- the same" failure this list was designed to avoid, reintroduced by the decoration.
    local mark = (r.state == "active") and "|cff40c057>>|r" or "|cff9AA0A6--|r"
    local grey = (r.state == "absent") and "|cff9AA0A6" or "|cffFFFFFF"
    args["row" .. order] = {
      type = "description", order = order, width = "full",
      name = string.format("%s %s%s|r  |cff9AA0A6%s|r", mark, grey, label, state),
    }
    if r.state == "active" and BAR_BLURB[r.name] then
      order = order + 1
      args["blurb" .. order] = {
        type = "description", order = order, width = "full",
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
  -- loop may have taken the same frame for the REAL suggestion. Stopping it then darkens a button
  -- that should be lit, and SetNowSlot still believes it is lit, so it stays dark until the
  -- suggestion changes away and back.
  if ns.Glow.isNowFrame and ns.Glow.isNowFrame(frame) then return end
  ns.Glow.Stop(frame)
end

-- Fires the real glow, on demand, with no combat and no rotation state. This is the single most
-- useful control in the panel: it separates "the glow is broken" from "nothing is being suggested
-- right now", which are indistinguishable to a player standing in a city and are the likeliest
-- source of a bug report that is not a bug.
function Options.previewGlow()
  stopPreview()
  local key = Options.checkSpell()
  local buttons = key and ns.BarGlow and ns.BarGlow.buttonsFor(key)
  local frame = buttons and buttons[1]
  if not frame then
    previewNote = L["No button to preview: the spell below is not on a bar Elmira can see."]
    return false
  end
  local p = profile()
  local style = (p and p.glow and p.glow.style) or "PIXEL"
  if not (ns.Glow and ns.Glow.Start(frame, style)) then
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
local function spellLabel(key)
  local pack = ns.Display and ns.Display.currentPack and ns.Display.currentPack()
  local data = pack and pack.spells and pack.spells[key]
  local name = data and data.id and ns.BarGlow and ns.BarGlow.spellName(data.id)
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

-- Three different switches can leave a perfectly placed, perfectly visible button dark, and the
-- panel used to blame the same one every time -- telling people to turn on a toggle that was
-- already on. `detail` says which.
local GLOW_OFF = {
  addon = "Elmira itself is switched off — turn on \"Show the queue\"",
  queue = "the glow is switched off — turn on \"Glow the next cast\" under Glow",
  bars  = "switched off above — turn on \"Also glow your action bar\"",
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
    return { none = { type = "description", order = 1, width = "full",
                      name = L["Nothing is being suggested right now, so there is nothing to check."] } }
  end
  local args = { header = { type = "description", order = 0, width = "full",
                            name = string.format(L["Checking %s:"], spellLabel(key)) } }
  for i, r in ipairs((ns.BarGlow and type(ns.BarGlow.check) == "function" and ns.BarGlow.check(key)) or {}) do
    -- Glyph AND colour, never colour alone: red/green is the first thing to go for a colour-blind
    -- reader, and "—" has to be visibly different from a tick, not merely a different green.
    local look = CHECK_MARKS[r.ok]
    local mark, colour = look[1], look[2]
    args["row" .. i] = {
      type = "description", order = i, width = "full",
      name = string.format("%s%s|r %s  |cff9AA0A6%s|r",
        colour, mark, L[CHECK_LABELS[r.label] or r.label], checkDetail(r)),
    }
  end
  return args
end

local function actionBarsGroup()
  previewNote = ""
  return {
    intro = {
      type = "description", order = 0, width = "full",
      name = L["Elmira glows the button holding your next suggested spell."],
    },
    bars = {
      type = "group", inline = true, order = 1, name = L["Bar addon"],
      args = barRows(),
    },
    barGlow = {
      type = "toggle", order = 2, width = "full", name = L["Also glow your action bar"],
      desc = L["Highlights the button on your bars, not just the queue icon."],
      get = function() return profile().glow.barGlow end,
      set = function(_, v)
        profile().glow.barGlow = v
        if ns.Glow then ns.Glow.StopAll() end   -- drop glows we will no longer be refreshing
        redraw()
      end,
    },
    preview = {
      type = "execute", order = 3, name = L["Preview glow"],
      desc = L["Glows the button for your current suggestion for a few seconds, so you can see the effect without waiting for a fight."],
      func = function() Options.previewGlow() end,
    },
    previewNote = {
      type = "description", order = 4, width = "full",
      name = function() return previewNote end,
    },
    check = {
      type = "group", inline = true, order = 5, name = L["Is my spell showing?"],
      args = {
        pick = {
          type = "select", order = 0, name = L["Test with"],
          desc = L["Defaults to whatever Elmira is suggesting right now."],
          values = spellChoices,
          get = function() return Options.checkSpell() end,
          set = function(_, v) Options.setCheckSpell(v) end,
        },
        rows = { type = "group", inline = true, order = 1, name = "", args = checkRows() },
      },
    },
  }
end

local function overlayGroup()
  local args = {}
  local cues = ns.Overlay and ns.Overlay.availableCues() or {}
  if #cues == 0 then
    args.none = {
      type = "description", order = 1,
      name = L["This build suggests no peripheral cues."],
    }
    return args
  end

  args.header = {
    type = "description", order = 0,
    name = L["Screen-edge flares for the moments you are not looking at the UI. Off unless you turn one on."],
  }

  for i, cue in ipairs(cues) do
    local label = cue.reason or cue.spell or cue.key or ("cue " .. i)
    if cue.unavailable then
      args["cue" .. i] = {
        type = "toggle", order = i, width = "full",
        name = label .. "  |cff9AA0A6(" .. cue.unavailable .. ")|r",
        desc = L["This cue cannot fire yet, so it cannot be enabled."],
        disabled = true,
        get = function() return false end,
        set = function() end,
      }
    else
      -- One inline group per cue rather than a bare toggle: the owner asked for colour and edge to be
      -- adjustable on every cue, and a flare you cannot aim or recolour is one you turn off. The
      -- appearance controls are greyed out until the cue is ON, because the stored record only exists
      -- while it is (Overlay.SetOption refuses to write otherwise).
      local function enabled() return (ns.Overlay.isEnabled(cue)) end
      local function off() return not enabled() end
      -- Every appearance change previews itself. Reading a hex value tells you nothing about whether
      -- you will catch it in peripheral vision, which is the only thing this setting is for.
      local function preview()
        ns.Overlay.Flare(ns.Overlay.GetOption(cue, "edge"), ns.Overlay.GetOption(cue, "color"),
                         ns.Overlay.GetOption(cue, "intensity"))
      end

      args["cue" .. i] = {
        type = "group", inline = true, order = i, name = label,
        args = {
          enabled = {
            type = "toggle", order = 1, width = "full", name = L["Enabled"],
            desc = cue.reason,
            get = enabled,
            set = function(_, v)
              ns.Overlay.SetEnabled(cue, v)
              -- The driver only repaints when the QUEUE changes, and turning a cue on changes neither
              -- the queue nor the build. Without this the newly enabled cue waits for the rotation to
              -- move before it is ever evaluated — and if its spell is stuck at the top (an Exorcism
              -- that is not on any bar, say) that never happens and the cue looks dead. Forcing the
              -- repaint is what makes the reset inside SetEnabled actually reach the renderer.
              if ns.Display then ns.Display.refresh() end
              -- Show it once on enable. A cue the user just turned on and cannot picture is a cue they
              -- turn straight back off.
              if v then preview() end
            end,
          },
          color = {
            type = "color", order = 2, name = L["Colour"], hasAlpha = false,
            disabled = off,
            get = function()
              local c = ns.Overlay.GetOption(cue, "color") or {}
              return c[1] or 1, c[2] or 1, c[3] or 1
            end,
            set = function(_, r, g, b)
              -- Only preview what was actually stored. Flaring after a refused write shows the user
              -- a change that did not happen.
              if ns.Overlay.SetOption(cue, "color", { r, g, b }) then preview() end
            end,
          },
          edge = {
            type = "select", order = 3, name = L["Edge"],
            desc = L["Which screen edge this cue flares on."],
            values = edgeChoices, disabled = off,
            get = function() return ns.Overlay.GetOption(cue, "edge") end,
            set = function(_, v) if ns.Overlay.SetOption(cue, "edge", v) then preview() end end,
          },
          intensity = {
            type = "range", order = 4, name = L["Intensity"],
            min = 0.05, max = 1.0, step = 0.05, isPercent = true, disabled = off,
            get = function() return ns.Overlay.GetOption(cue, "intensity") end,
            set = function(_, v) if ns.Overlay.SetOption(cue, "intensity", v) then preview() end end,
          },
        },
      }
    end
  end
  return args
end

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

-- Options.importText(str) -> true, key | false. Keeps the text in the box on failure so the user
-- can fix it, clears it on success, and leaves a one-line result under the box either way.
function Options.importText(str)
  local pack = ns.Display and ns.Display.currentPack and ns.Display.currentPack()
  if not (ns.UserBuilds and pack) then
    exchangeNote = L["Import: no data pack for your class."]
    return false
  end
  local key, err = ns.UserBuilds.importString(str, pack, {
    today = ns.Adapter and ns.Adapter.today and ns.Adapter.today() or nil,
  })
  if not key then
    exchangeText = tostring(str or "")
    exchangeNote = string.format(L["Import failed: %s"], tostring(err))
    return false
  end
  exchangeText = ""
  exchangeNote = string.format(L["Imported as %s. /elm profile %s to use it."], key, key)
  if ns.Display and ns.Display.refresh then ns.Display.refresh() end
  return true, key
end

local function exchangeGroup()
  return {
    type = "group", order = 6, name = L["Import / Export"],
    args = {
      text = {
        type = "input", multiline = 8, width = "full", order = 1, name = L["Build string"],
        desc = L["Paste an ELM1: string to import it as one of your builds. /elm export fills this box with the active build."],
        get = function() return exchangeText end,
        set = function(_, value) Options.importText(value) end,
      },
      note = { type = "description", order = 2, name = function() return exchangeNote end },
    },
  }
end

function Options.table()
  return {
    type = "group",
    name = ns.Colors.wrap(ns.Colors.BRAND, "Elmira"),
    args = {
      queue = {
        type = "group", order = 1, name = L["Queue"], inline = false,
        args = {
          enabled = {
            type = "toggle", order = 1, name = L["Show the queue"],
            get = function() return profile().enabled end,
            set = function(_, v)
              profile().enabled = v
              if v then ns.Display.Enable() else ns.Display.Disable() end
              redraw()
            end,
          },
          depth = {
            type = "range", order = 2, name = L["Icons"], min = 1, max = 5, step = 1,
            desc = L["How many casts ahead to show. Slot 1 is what to press now."],
            get = function() return profile().depth end,
            set = function(_, v) profile().depth = v; redraw() end,
          },
          scale = {
            type = "range", order = 3, name = L["Scale"], min = 0.5, max = 2.0, step = 0.05,
            isPercent = true,
            get = function() return profile().scale end,
            set = function(_, v) profile().scale = v; redraw() end,
          },
          setup = {
            type = "execute", order = 0, name = L["Run setup again"],
            desc = L["Pick a playstyle for this character."],
            func = function() if ns.Wizard then ns.Wizard.Open() end end,
            hidden = function() return ns.Wizard == nil end,
          },
          visibility = {
            type = "select", order = 4, width = "full", name = L["Show the queue"],
            desc = L["When the queue and its bar glow are on screen. Hiding it also stops the "
                  .. "update loop, so a hidden queue costs nothing."],
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
          learning = {
            type = "toggle", order = 5, width = "full", name = L["Learning mode"],
            desc = L["Shows one suggestion at a time, larger, with the name of the rule that chose "
                  .. "it. Sets icons to 1 and scale to 140% — both remain yours to change afterwards. "
                  .. "Does not turn on any screen-edge cues; those stay your choice."],
            get = function() return profile().learning end,
            set = function(_, v)
              local applied = ns.Queue.ApplyLearningPreset(v)
              redraw()
              -- Say what a preset changed. A toggle that silently rewrites two other settings the
              -- user can see in the same panel is how a settings screen loses trust.
              if applied then
                ns.log("Learning mode on: icons set to %d, scale to %d%%.",
                       applied.depth, math.floor(applied.scale * 100))
              end
            end,
          },
          locked = {
            type = "toggle", order = 4, name = L["Lock position"],
            desc = L["Unlock to drag the queue. Same as /elm lock."],
            get = function() return ns.Queue.isLocked() end,
            set = function(_, v) ns.Queue.SetLocked(v) end,
          },
        },
      },
      bars = {
        type = "group", order = 2, name = L["Action bars"],
        args = actionBarsGroup(),
      },
      glow = {
        type = "group", order = 3, name = L["Glow"],
        args = {
          enabled = {
            type = "toggle", order = 1, name = L["Glow the next cast"],
            get = function() return profile().glow.enabled end,
            set = function(_, v) profile().glow.enabled = v; redraw() end,
          },
          -- "Also glow your action bar" used to live here. It moved to Action Bars, where the rest
          -- of the bar settings and the diagnostics are: a toggle whose effect is invisible without
          -- the status list next to it is where "I turned it on and nothing happened" starts.
          style = {
            type = "select", order = 3, name = L["Style"],
            -- Derived from Glow.STYLES rather than repeated: a literal here silently drifts the
            -- moment a style is added, offering a choice the renderer does not have.
            values = function()
              local names = { PIXEL = L["Pixel"], BUTTON = L["Button"], AUTOCAST = L["Autocast"] }
              local out = {}
              for key in pairs((ns.Glow and ns.Glow.STYLES) or {}) do out[key] = names[key] or key end
              return out
            end,
            get = function() return profile().glow.style end,
            set = function(_, v)
              profile().glow.style = v
              if ns.Glow then ns.Glow.StopAll() end   -- restart in the new style, don't layer them
              redraw()
            end,
          },
        },
      },
      overlay = {
        type = "group", order = 4, name = L["Peripheral cues"],
        args = overlayGroup(),
      },
      sounds = {
        type = "group", order = 5, name = L["Sounds"],
        args = {
          enabled = {
            type = "toggle", order = 1, name = L["Play cue sounds"],
            desc = L["Sounds use the same per-cue opt-in as flares."],
            get = function() return profile().sounds.enabled end,
            set = function(_, v) profile().sounds.enabled = v end,
          },
        },
      },
      exchange = exchangeGroup(),
    },
  }
end

function Options.Register()
  local AceConfig = LibStub and LibStub("AceConfig-3.0", true)
  local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
  if not (AceConfig and AceConfigDialog) then return false end

  -- Built fresh on open rather than once at load: the overlay section is derived from the ACTIVE
  -- build's suggested cues, and both the build and the character's gear can change in a session.
  AceConfig:RegisterOptionsTable("Elmira", Options.table)
  Options.frame = AceConfigDialog:AddToBlizOptions("Elmira", "Elmira")

  local AceDBOptions = LibStub("AceDBOptions-3.0", true)
  if AceDBOptions and ns.db then
    AceConfig:RegisterOptionsTable("Elmira-Profiles", AceDBOptions:GetOptionsTable(ns.db))
    AceConfigDialog:AddToBlizOptions("Elmira-Profiles", L["Profiles"], "Elmira")
  end
  Options.dialog = AceConfigDialog
  return true
end

function Options.Open()
  if not Options.dialog then Options.Register() end
  if Options.dialog then
    Options.dialog:Open("Elmira")
    return true
  end
  return false
end

ns.Options = Options
return Options
