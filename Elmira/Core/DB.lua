-- Elmira/Core/DB.lua — AceDB defaults, dbVersion and migrations. Operates on an AceDB object
-- handed to it by Core/Init.lua; never constructs one itself. Pure Lua, dofile-able.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local DB = {}
DB.CURRENT = 1 -- SavedVariables layout version

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
  global = { dbVersion = 0, userBuilds = {}, announceLog = {}, announceDropped = 0 },
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
    activeBuild = false,
    anchor = { point = "CENTER", relPoint = "CENTER", x = 0, y = -150 },
    -- Every numeric here is `false`, meaning "whatever LibCustomGlow would do on its own". That is
    -- what makes a default install render exactly as it did before these controls existed; the
    -- moment the user moves a slider it becomes a real number. `color = false` means the brand's
    -- highlight. `secondary` ships off: ADR-0015 exists because two things competed for one glance.
    glow = { enabled = true, style = "PIXEL", barGlow = true, color = false,
             particles = false, frequency = false, thickness = false, speed = false,
             secondary = false },
    -- ADR-0009: the overlay has no global "on" switch. `cues` maps a cue id to the user's settings
    -- for it, so an empty table is a quiet default install, and a cue only ever exists because the
    -- user opted it in. Reshaped at M1 with no dbVersion migration: the previous
    -- `{enabled=false, intensity=0.5}` both equalled their defaults, so AceDB never wrote either key
    -- to disk, and no UI existed yet that could have changed them.
    overlay = { cues = {} },
    -- Master mute only. A cue carries its own sound name, on the same opt-in set and the same
    -- change-to trigger as its flare.
    sounds = { enabled = false },
    -- F37. `chatWindow = 0` means "wherever Elmira printed before", i.e. the default frame; a real
    -- number picks one. `routes` starts EMPTY and Core/Announce falls back to its shipped defaults,
    -- so a category added by a later release arrives with its intended routing rather than silent --
    -- and a user who has never opened the panel is not carrying a frozen copy of an old default set.
    announce = {
      chatWindow = 0,
      sound = "None",
      screen = { font = "Friz Quadrata TT", size = 18, duration = 4,
                 anchor = { point = "TOP", relPoint = "TOP", x = 0, y = -140 } },
      routes = {},
    },
    dbVersion = 0,
  },
  char = { setupDone = 0, pinnedBuild = false, snoozed = {} },
}

-- Ordered migration lists. Each entry: { version = N, apply = function(target) end }. Empty at M0;
-- later milestones append rather than rewrite, so old migrations keep running for old SavedVariables.
DB.migrations = {}
DB.profileMigrations = {}

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
