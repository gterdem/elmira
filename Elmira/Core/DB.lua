-- Elmira/Core/DB.lua — AceDB defaults, dbVersion and migrations. Operates on an AceDB object
-- handed to it by Core/Init.lua; never constructs one itself. Pure Lua, dofile-able.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local DB = {}
DB.CURRENT = 2 -- SavedVariables layout version

-- `global.dbVersion` starts at 0 deliberately: AceDB omits any value equal to its default (the same
-- behaviour docs/07-INGAME-VERIFICATION-BASELINE.md §2 documents for ElvDB), so a default of 1 would
-- make "migrated" and "never touched" indistinguishable on disk. Starting at 0 gives migrate() a
-- non-default value to write, so the SavedVariables file always carries a witness that Elmira ran.
-- The same reasoning is why every profile default below uses `false`, never `nil`, as its sentinel:
-- a `nil` default is ambiguous between "unset" and "equals the default", `false` is not.
DB.defaults = {
  -- ADR-0010: the user's own builds, account-wide, keyed USER_<slug> (Core/UserBuilds.lua).
  -- The announcement log survives a reload on purpose: "what did it just tell me?" is most often
  -- asked after the chat frame has scrolled or the on-screen message has faded.
  -- `window` is the options panel's own frame: how big it is, where it sits and what scale it is
  -- drawn at. Account-wide rather than per-profile because it describes the SCREEN it is drawn on,
  -- not the character in front of it -- swapping profiles must not move the settings window.
  -- `top`/`left` are `false`, never nil, for the reason at the top of this file: `false` says "never
  -- positioned, centre it" and survives AceDB's omit-the-default rule, where nil would not.
  -- 1.2 rather than 1.0: AceConfig description rows are 12pt at best and the panel is read, not
  -- glanced at. 960x680 is the size at which the Builder's rows stop wrapping.
  global = { dbVersion = 0, userBuilds = {}, announceLog = {},
             window = { scale = 1.2, width = 960, height = 680, top = false, left = false } },
  profile = {
    enabled = true,
    depth = 3,
    locked = true,
    scale = 1.0,
    mode = "Auto",
    -- Core/Visibility.lua owns the meaning; the default is "in combat, or when you have a target".
    -- Not a boolean: "always" and "in combat only" are both things people genuinely want, and a
    -- two-state switch would have to pick which one it is not.
    visibility = "combat_or_target",
    learning = false,
    -- Two switches, deliberately: `enabled` is the whole display, `showQueue` is the strip alone.
    -- A player who watches only the action-bar glow turns the strip off and must keep glowing
    -- (ADR-0015 §3), which the single switch could not express.
    showQueue = true,
    animate = true,
    -- PE10, all three defaulted to exactly what shipped: a player who changes nothing sees the
    -- strip they had. `grow` is where slots 2..n go from slot 1 (Core/Transition.GROW);
    -- `spacing` is the pixel gap between icons, and 4 is the constant it replaces; `oocAlpha`
    -- multiplies the whole strip's opacity while you are NOT in combat, so 1 is no change.
    grow = "right",
    spacing = 4,
    oocAlpha = 1.0,
    -- PE9-D4, all three defaulted so nothing about today's screen changes except the fixes.
    -- `waits`: "off" | "gcd" | "always" -- how long until a projected slot happens, printed in its
    -- bottom-left corner. "gcd" stays quiet whenever the wait is just the next global cooldown,
    -- which is most of the time; a number that reads 1.5s forever stops being seen.
    waits = "gcd",
    -- `keybinds`: "off" | "first" | "all". "first" is what shipped -- a key to press is a fact
    -- about the cast you are making now -- but people who read the whole strip as a plan want them
    -- all, and neither answer is wrong for everyone.
    keybinds = "first",
    -- PE9-D5: the name of the rule that chose the suggestion, split out of Learning mode so it can
    -- be had at any icon count. Learning mode is now a preset that switches it on.
    showReason = false,
    -- The Builder's item palette lists trinkets only until this is on. Most characters have nothing
    -- on-use in the other slots, and a palette of empty rows teaches you to stop reading it.
    paletteAllSlots = false,
    activeBuild = false,
    -- D38: the queue strip's own nudge while nothing is chosen yet. Owner was lukewarm on it, so it
    -- ships behind this toggle rather than folded permanently into the strip.
    showPlaceholder = true,
    anchor = { point = "CENTER", relPoint = "CENTER", x = 0, y = -150 },
    -- AB1-D3: what a glow LOOKS like (style, colour, particles, frequency, thickness, pulse) is a
    -- per-ability, per-character setting now and lives in `char.abilities` through
    -- Core/AbilitySettings.lua. What is left here are the two switches that are not about any one
    -- ability: whether Elmira glows action-bar buttons at all, and the dim second glow for the cast
    -- after next.
    --
    -- `secondary` ships off: ADR-0015 exists because two things competed for one glance.
    -- `secondaryAlpha` is how dim that hint is, as a fraction of the main glow -- a setting rather
    -- than a constant because how dim "dim" needs to be depends on the style: Proc drives its own
    -- alpha animation (SetToFinalAlpha, from 1 to 1), so a value that reads clearly dimmer on Pixel
    -- can look identical there. Reported from a client, 2026-09-05. Brightness is the ONLY
    -- difference the hint is allowed to make: it has no style of its own, because a global shape
    -- for the second glow would silently overrule what was set on the ability.
    glow = { barGlow = true, secondary = false, secondaryAlpha = 0.35 },
    -- F37. `routes` starts EMPTY and Core/Announce falls back to its shipped defaults, so a category
    -- added by a later release arrives with its intended routing rather than silent -- and a user
    -- who has never opened the panel is not carrying a frozen copy of an old default set.
    --
    -- D25 (2026-09-07): there is no `chatWindow` any more -- Elmira now prints to every chat window
    -- that shows System messages (Display/Announcers.systemChatFrames), which is what "which of my
    -- tabs" actually meant; a stored index went stale the moment a tab was renamed or closed.
    announce = {
      sound = "None",
      -- D24: `sounds[key]` overrides `sound` for one category; empty until the player picks one, so
      -- every category answers with the shared sound until they do.
      sounds = {},
      screen = { font = "Friz Quadrata TT", size = 18, duration = 4,
                 anchor = { point = "TOP", relPoint = "TOP", x = 0, y = -140 } },
      -- AB1-D10: there is no `cooldownFloor` any more. A number of seconds cannot tell a tank's
      -- defensive save from a burst cooldown, which is the distinction that decides whether a line
      -- in party chat is welcome; the per-ability Announcement tab decides instead, and it ships
      -- off for every ability.
      routes = {},
    },
    dbVersion = 0,
  },
  -- D37: the first-run popup replaces the old setup wizard window. "Not now" asks again next
  -- login; `firstRunDismissed` is the one flag that stops it for good ("Don't ask again").
  -- R2 (D53): the Spells registry is PER CHARACTER, because it records what THIS character's client
  -- could resolve -- a name only this account's rogue has seen means nothing to its paladin.
  -- `[key] = { key =, id =, name =, source = "pack"|"spellbook"|"id"|"name" }`.
  -- AB1-D3: `abilities` is what every registered ability is allowed to do on screen, keyed by the
  -- SAME spell key as `spells` above but stored beside it rather than inside it -- `Spells.merged`
  -- lets a data pack overwrite a registry entry on a key collision, and settings kept in that entry
  -- would go with it. `"*"` is the All abilities row. Core/AbilitySettings.lua owns the shape.
  -- `sounds` is the master mute for every ability sound (AB1-D8), per character like the rest.
  char = { setupDone = 0, pinnedBuild = false, snoozed = {}, firstRunDismissed = false, spells = {},
           abilities = {}, sounds = { enabled = false } },
}

-- Ordered migration lists. Each entry: { version = N, apply = function(target) end }. Empty at M0;
-- later milestones append rather than rewrite, so old migrations keep running for old SavedVariables.
--
-- D27 (2026-09-07 Notifications pass): the Log's cap dropped from 200 to 20 lines, matching what the
-- redesigned single Notifications page actually shows. Announce.record only trims on WRITE, so an
-- existing SavedVariables file sitting at up to 200 lines would otherwise stay that size until the
-- 181st new line finally pushed the oldest one out.
DB.migrations = {
  { version = 2, apply = function(db)
      local log = db.global and db.global.announceLog
      if type(log) ~= "table" then return end
      while #log > 20 do table.remove(log, 1) end
    end },
}

-- D21/D22 (2026-09-07 Notifications pass): `template`/`mode` never fired and are gone from
-- Announce.CATEGORIES, so a stored routing row for either is dead weight nothing will ever read
-- again. Party and raid used to be one flag (`party`, which auto-picked the channel from whatever
-- group the player happened to be in); anyone who had switched it on gets BOTH flags set, which is
-- the only way to reproduce what they already had -- their message still reaches a party OR a raid,
-- exactly as it did before there were two switches to ask about it.
DB.profileMigrations = {
  { version = 2, apply = function(profile)
      local routes = profile.announce and profile.announce.routes
      if type(routes) ~= "table" then return end
      routes.template, routes.mode = nil, nil
      for _, row in pairs(routes) do
        if type(row) == "table" and row.party then row.raid = true end
      end
    end },
}

-- Global (account-wide) migration. Runs once per login from Core/Init.lua OnInitialize.
function DB.migrate(db)
  local from = db.global.dbVersion or 0
  for _, m in ipairs(DB.migrations) do
    if m.version > from then m.apply(db) end
  end
  db.global.dbVersion = DB.CURRENT
  return from
end

-- Per-profile migration. AceDB materialises a profile only when it becomes current, so one
-- account-wide stamp cannot know whether *this* profile has been migrated — call this from
-- OnInitialize AND from the OnProfileChanged/OnProfileCopied/OnProfileReset AceDB callbacks.
function DB.migrateProfile(profile)
  local from = profile.dbVersion or 0
  for _, m in ipairs(DB.profileMigrations) do
    if m.version > from then m.apply(profile) end
  end
  profile.dbVersion = DB.CURRENT
  return from
end

ns.DB = DB
return DB
