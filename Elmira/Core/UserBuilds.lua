-- Elmira/Core/UserBuilds.lua — forks: builds the user owns (ADR-0010). Today they arrive by import
-- string; M5e's editor adds fork-and-name. They live account-wide in `db.global.userBuilds`, keyed
-- `USER_<slug>` so they can never collide with, or be mistaken for, a shipped key, and each records
-- `derivedFrom`/`derivedAt` so a later release of the parent can be noticed and never silently
-- rebased over the user's edit.
--
-- Pure Lua. The store is `ns.db.global.userBuilds` when AceDB is up; nothing here touches the WoW API.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local UserBuilds = {}
UserBuilds.PREFIX = "USER_"

local function store()
  local db = ns.db
  return db and db.global and db.global.userBuilds
end

function UserBuilds.isForkKey(key)
  return type(key) == "string" and key:sub(1, #UserBuilds.PREFIX) == UserBuilds.PREFIX
end

-- The one lookup every consumer goes through: a shipped build first, then a fork of this class.
-- Returns build, origin ("pack" | "fork"), and the fork record when it is one.
function UserBuilds.find(pack, key)
  if type(key) ~= "string" then return nil end -- mutants: equivalent a non-string key misses both lookups below
  if pack and pack.builds and pack.builds[key] then return pack.builds[key], "pack" end
  local s = store()
  local fork = s and s[key]
  if fork and type(fork.build) == "table" and (pack == nil or fork.class == pack.class) then
    return fork.build, "fork", fork
  end
  return nil -- mutants: equivalent Lua returns nil implicitly at the end of a function
end

-- Sorted fork keys for this class (db.global is shared across characters, so class-tag filtering
-- is what keeps a mage from being offered a paladin's fork).
function UserBuilds.list(pack)
  local out = {}
  local s = store()
  if not s then return out end
  for key, fork in pairs(s) do
    if type(fork) == "table" and (pack == nil or fork.class == pack.class) then out[#out + 1] = key end
  end
  table.sort(out)
  return out
end

-- "My exodin (v2)" -> "USER_MY_EXODIN_V2". Namespaced, upper-case, bounded, never empty.
function UserBuilds.slug(name)
  local base = tostring(name or ""):upper():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if base == "" then base = "BUILD" end
  if #base > 24 then base = base:sub(1, 24):gsub("_+$", "") end
  return UserBuilds.PREFIX .. base
end

local function uniqueKey(s, base)
  if not s[base] then return base end
  local n = 2
  while s[base .. "_" .. n] do n = n + 1 end
  return base .. "_" .. n
end

-- Exported because Options/Rotation.lua's stale-parent banner must ask the SAME question this
-- file answers when it writes `derivedAt`. A second copy over there drifts the first time either
-- moves, and the symptom is a banner that silently stops appearing.
local function catalogUpdated(pack, buildKey)
  local list = pack and pack.catalog and pack.class and pack.catalog[pack.class]
  for _, entry in ipairs(list or {}) do
    if entry.build == buildKey then return entry.updated end
  end
  return nil -- mutants: equivalent Lua returns nil implicitly at the end of a function
end

UserBuilds.catalogUpdated = catalogUpdated

local function ctxFor(pack)
  return { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
end

-- UserBuilds.importString(str, pack, opts) -> key | nil, reason
-- opts.name: the fork's display name (defaults to the imported build's own); opts.today: a
-- "YYYY-MM-DD" string from the adapter (Core does not read the clock). The imported build's `key`
-- becomes the fork key: Schema errors then name the fork, not the shipped build it came from.
function UserBuilds.importString(str, pack, opts)
  opts = opts or {}
  if not (pack and pack.class) then return nil, "no data pack for your class" end
  local s = store()
  if not s then return nil, "saved variables are not loaded" end
  if not ns.Serialize then return nil, "serializer is not loaded" end
  local build, err = ns.Serialize.decode(str, ctxFor(pack))
  if not build then return nil, err end
  if build.class and build.class ~= pack.class then
    return nil, string.format("that build is for %s, not %s", tostring(build.class), tostring(pack.class))
  end

  local parent = (pack.builds and pack.builds[build.key]) and build.key or nil
  local key = uniqueKey(s, UserBuilds.slug(opts.name or build.name or build.key))
  local name = opts.name or build.name or key
  build.key = key
  build.name = name
  s[key] = {
    build = build, class = pack.class, name = name,
    derivedFrom = parent, derivedAt = parent and catalogUpdated(pack, parent) or nil,
    importedAt = opts.today,
  }
  return key
end

-- A fork is a COPY, all the way down. `Classes/<Class>.lua` builds are one shared table per
-- session: a fork holding a reference into one would edit the shipped template for every character
-- on the account, and the edit would vanish on reload with no sign it had ever been made.
-- Cycles are tracked because a hand-written build could contain one, and a stack overflow at login
-- is a worse bug than any it would be guarding against.
local function deepCopy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do out[deepCopy(k, seen)] = deepCopy(x, seen) end
  return out
end

-- UserBuilds.fork(pack, templateKey, opts) -> key | nil, reason
--
-- ADR-0015 §2: Customize forks the template AND activates the fork in the same click. Hekili's
-- copy-then-forget -- where the copy must be separately activated and users keep playing the
-- original -- is the failure this is designed against, so the two halves must not come apart.
-- Functions survive the copy on purpose: a shipped build gated by a `custom` condition keeps
-- working when forked. Export is where `custom` gets dropped, and Schema.exportable owns that rule.
function UserBuilds.fork(pack, templateKey, opts)
  opts = opts or {}
  local s = store()
  if not s then return nil, "no saved variables" end
  local source = pack and pack.builds and pack.builds[templateKey]
  if not source then return nil, "unknown template " .. tostring(templateKey) end

  local name = opts.name or ((source.name or templateKey) .. " (mine)")
  local key = uniqueKey(s, UserBuilds.slug(name))
  local build = deepCopy(source)
  build.key, build.name = key, name
  s[key] = {
    build = build, class = pack.class, name = name,
    -- ADR-0010: provenance is the whole point of a fork over a copy. `derivedAt` records WHICH
    -- version of the parent this came from, so a later release can be noticed and offered as a diff.
    derivedFrom = templateKey, derivedAt = catalogUpdated(pack, templateKey),
    importedAt = opts.today,
  }
  return key
end

-- The two edits the Builder's list makes. Both refuse anything that is not one of the user's own
-- rotations: a template is read-only (ADR-0005, hard rule 7), and the panel must not be the one
-- place that can quietly write to one.
-- Through `find`, which is the one lookup that knows a fork belongs to a CLASS. db.global is shared
-- across every character on the account, so without that check these would happily reorder a
-- paladin's rotation from a mage. Templates are refused as a consequence: `find` reports them as
-- origin "pack", and a template is read-only (ADR-0005, hard rule 7).
local function entriesOf(pack, key)
  local build, origin = UserBuilds.find(pack, key)
  if origin ~= "fork" then return nil, "not one of your rotations" end
  if not (build and build.entries) then return nil, "that rotation has no lines" end
  return build.entries, nil
end

-- UserBuilds.moveEntry(pack, key, index, delta) -> true | false, reason
-- Priority order IS the rotation (F1: the first passing entry is the suggestion), so moving a row
-- is the single most consequential edit the Builder offers.
function UserBuilds.moveEntry(pack, key, index, delta)
  local entries, err = entriesOf(pack, key)
  if not entries then return false, err end
  local to = (tonumber(index) or 0) + (tonumber(delta) or 0)
  if not entries[index] or not entries[to] then return false, "out of range" end
  entries[index], entries[to] = entries[to], entries[index]
  return true
end

-- UserBuilds.setEntryDisabled(pack, key, index, disabled) -> true | false, reason
-- Cleared to nil rather than stored as false: `Schema.compile` and `Schema.exportable` both test
-- truthiness, and an exported build carrying `disabled = false` on every line is noise that would
-- travel to whoever imports it.
function UserBuilds.setEntryDisabled(pack, key, index, disabled)
  local entries, err = entriesOf(pack, key)
  if not entries then return false, err end
  if not entries[index] then return false, "out of range" end
  entries[index].disabled = disabled and true or nil
  return true
end

-- UserBuilds.exportKey(pack, key) -> string | nil, reason
function UserBuilds.exportKey(pack, key)
  local build = UserBuilds.find(pack, key)
  if not build then return nil, string.format("no build %q", tostring(key)) end
  if not ns.Serialize then return nil, "serializer is not loaded" end
  return ns.Serialize.encode(build)
end

function UserBuilds.remove(key)
  local s = store()
  if not (s and s[key]) then return false end
  s[key] = nil
  return true
end

ns.UserBuilds = UserBuilds
return UserBuilds
