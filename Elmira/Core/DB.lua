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
  global = { dbVersion = 0 },
  profile = {
    enabled = true,
    depth = 3,
    locked = true,
    scale = 1.0,
    mode = "Auto",
    learning = false,
    activeBuild = false,
    anchor = { point = "CENTER", relPoint = "CENTER", x = 0, y = -150 },
    glow = { enabled = true, style = "PIXEL", barGlow = true },
    overlay = { enabled = false, intensity = 0.5 },
    sounds = { enabled = false },
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
