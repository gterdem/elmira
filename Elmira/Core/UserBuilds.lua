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

-- F1a (2026-09-07 bug round): the player's own class TOKEN, from AceDB's own `db.keys.class` --
-- computed once, at load, from `UnitClass("player")` inside the (already-loaded) AceDB-3.0 library,
-- so reading the field here is not a WoW API call of our own. Falls back to the pack's `class`
-- only for the handful of specs/callers that build a synthetic pack without ever populating
-- `db.keys` -- in real play the two always agree, since a pack is looked up BY this same token
-- (`Display.currentPack`). The bug this replaces: `pack == nil` used to mean "skip the class
-- filter entirely", so a class with no shipped pack (every class but Paladin) saw every OTHER
-- class's forks too, because the pack -- not the player -- was the only source of "which class".
local function playerClass(pack)
  local keys = ns.db and ns.db.keys
  return (keys and keys.class) or (pack and pack.class)
end

-- F1b: this character's own identity (`db.keys.char`, e.g. "Name - Realm"), also AceDB's own and
-- also not a WoW API call of ours. The only thing a private fork's `owner` field is ever compared
-- against.
local function playerChar()
  local keys = ns.db and ns.db.keys
  return keys and keys.char
end

-- A fork this (class, character) pair may see: the right class, and -- F1b -- either not marked
-- private or private to exactly this character. `db.global` is shared account-wide, so class alone
-- was always the only thing standing between a mage and a paladin's fork; privacy narrows that
-- further, to one character of that class.
local function visible(fork, class, char)
  return type(fork) == "table" and fork.class == class
    and (not fork.private or fork.owner == char)
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
  if fork and type(fork.build) == "table" and visible(fork, playerClass(pack), playerChar()) then
    return fork.build, "fork", fork
  end
  return nil -- mutants: equivalent Lua returns nil implicitly at the end of a function
end

-- Sorted fork keys for this class (db.global is shared across characters, so class-tag filtering --
-- F1a: always against the PLAYER's own class, never the pack's, since the pack is legitimately nil
-- for seven of the eight classes -- is what keeps a mage from being offered a paladin's fork).
function UserBuilds.list(pack)
  local out = {}
  local s = store()
  if not s then return out end
  local class, char = playerClass(pack), playerChar()
  for key, fork in pairs(s) do
    if visible(fork, class, char) then out[#out + 1] = key end
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

-- The name a PLAYER reads for a build key: the catalog's playstyle for a shipped build, the name
-- the user typed for a fork, and the key itself for anything else, because a blank row is worse
-- than an ugly one.
--
-- In Core rather than in Options/Rotation, where it started, because it is a pure lookup over the
-- catalog and the fork records this file already owns -- and because Display needed it too.
-- Display/Driver's gear-change announcement is the one sentence in the addon built from a storage
-- key, so while this lived in Options it either said `USER_MY_EXODIN` to the player or made Display
-- reach up into the Options layer for a string. Both are why it is here.
function UserBuilds.displayName(pack, key)
  if type(key) ~= "string" then return "?" end
  local list = pack and pack.catalog and pack.class and pack.catalog[pack.class]
  for _, entry in ipairs(list or {}) do
    if entry.build == key and entry.playstyle then return entry.playstyle end
  end
  local _, origin, fork = UserBuilds.find(pack, key)
  if origin == "fork" and fork and fork.name then return fork.name end
  return key
end

-- R2b (D75): the registry, merged UNDER the pack's own spells so a shipped key always wins a
-- collision -- see `Spells.merged`'s own comment for why the merge lives there rather than here.
-- `ns.Spells` is absent in a few specs that dofile this file on its own; falling back to the pack's
-- table alone is the pre-R2b behaviour, not a silent narrowing of it.
local function ctxFor(pack)
  local spells = ns.Spells and ns.Spells.merged and ns.Spells.merged(pack) or pack.spells
  return { spells = spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses }
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
  local bundle, err = ns.Serialize.decodeBundle(str, ctxFor(pack))
  if not bundle then return nil, err end
  local build = bundle.build
  if type(build) ~= "table" then return nil, "no build in string" end
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
  -- AB2-D5: a rotation exported WITH its abilities' settings arrives with them. Applied here, at
  -- the one place a build string is accepted, rather than at the two panels that paste one -- a
  -- second caller is a second place to forget, and settings that silently did not arrive look
  -- exactly like settings the sender never included. Returned as a count so the panel can say so.
  local A = ns.AbilitySettings
  local merged = (A and A.import(bundle.abilities, bundle.spells)) or 0
  return key, merged
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

-- Exported for the same reason `catalogUpdated` is: Options/Rotation's Builder takes a DRAFT copy
-- of a fork's lines before it edits them, and it must copy exactly as deeply as a fork does. A
-- second implementation over there would share a nested `when` table on the first day someone
-- changed one of the two, and the symptom would be a rotation that changed before Save was pressed.
UserBuilds.copy = deepCopy

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

-- UserBuilds.create(pack, name) -> key | nil, reason
--
-- D35's "New rotation": an EMPTY fork with no `derivedFrom` at all, for a player who wants to start
-- from their own spellbook rather than a catalog template. `UserBuilds.fork` deliberately REFUSES a
-- nil/unknown template (line above), so this is a second, small writer rather than a fork with the
-- guard loosened -- loosening it would let a typo'd template key silently create an untethered build
-- and call it a fork of something that does not exist.
--
-- F1c: takes the class from the same source `find`/`list` now do (F1a), not `pack.class` alone --
-- `pack` is nil for every class but Paladin, and refusing here unconditionally on that would leave
-- a "New rotation" button that creates nothing for seven classes right after F1a correctly starts
-- showing them an empty fork list of their own.
function UserBuilds.create(pack, name)
  local s = store()
  if not s then return nil, "no saved variables" end
  local class = playerClass(pack)
  if not class then return nil, "no data pack for your class" end

  local key = uniqueKey(s, UserBuilds.slug(name))
  local build = { key = key, name = name, class = class, entries = {} }
  s[key] = { build = build, class = class, name = name }
  return key
end

-- UserBuilds.setPrivate(key, private) -> true | false, reason
--
-- F1b (2026-09-07 bug round, owner's decision over plain class-wide): forks default visible to
-- every character of the class; this is the one per-fork override. The flag lives on the fork
-- record in ACCOUNT-WIDE storage (`db.global`, same as the record itself) and carries the OWNING
-- character's identity (`db.keys.char`) -- a flag kept only in the toggling character's own
-- `db.char` would be invisible to precisely the characters `find`/`list` (which read `db.global`
-- for every character of the class) need it to hide the fork from. Turning it OFF leaves `owner`
-- in place but unused (`visible` above only ever consults it while `private` is true); turning it
-- back ON reassigns `owner` to whoever did that, which is always the current viewer -- nobody else
-- can even reach this fork's page to click the toggle while it is private to someone else.
function UserBuilds.setPrivate(key, private)
  local s = store()
  local fork = s and s[key]
  if not (fork and type(fork.build) == "table") then return false, "not one of your rotations" end
  fork.private = private and true or nil
  if fork.private then fork.owner = playerChar() end
  return true
end

-- UserBuilds.rename(key, name) -> true | false, reason
--
-- The key stays stable on purpose: `SelectGroup`/`Options.Open` paths and `derivedFrom` pointers
-- from any child fork name a KEY, never a display name, so renaming must never touch it. Only the
-- record's own `name` and the build's own `name` (what `Rotation.displayName` and an export string
-- both read) change.
function UserBuilds.rename(key, name)
  local s = store()
  local fork = s and s[key]
  if not (fork and type(fork.build) == "table") then return false, "not one of your rotations" end
  if type(name) ~= "string" or name == "" then return false, "a rotation needs a name" end
  fork.name = name
  fork.build.name = name
  return true
end

-- Core/Slash.lua owns `ns.compileBuild` and caches it on the build TABLE, and the write below
-- mutates that table in place -- so without dropping the cache the display goes on running the
-- compilation it took before the save, and the panel and the queue disagree until the next
-- /reload. Invalidation lives with the WRITE rather than with the caller for the reason
-- Display/Overlay learned a milestone ago: a contract that says "remember to call Reset()" is one
-- that gets forgotten silently.
--
-- Called unguarded on purpose: `Core\Slash.lua` is loaded by the same TOC that loads this file, so
-- `ns.forgetCompiled and ...` here would turn a load-order mistake into the exact silent staleness
-- this call exists to end.
local function edited(build)
  ns.forgetCompiled(build)
  return true
end

-- The fields an entry is AUTHORED with (docs/03-BUILD-FORMAT). A WHITELIST, not a list of things to
-- strip. The Builder hangs its own bookkeeping on a draft row -- `src`, the saved position the row
-- came from -- and `Schema.compile` hangs seven more on a compiled one (`test`, `data`,
-- `conditions`, `index`, `cdVolatile`, `cost`, `cooldownSecs`, two of them closures). Either would
-- reach SavedVariables and then travel out in the next export string, because `Schema.exportable`
-- copies every field an entry has. A blacklist would have to be updated in step with two other
-- files to stay correct; this one only has to be updated when the FORMAT gains a field, and
-- userbuilds_spec fails against the shipped pack if it ever has.
local ENTRY_FIELDS = { "spell", "item", "when", "label", "hold", "disabled" }
-- Exported for the spec's drift check ALONE -- the same seam, and the same reason, as
-- `ns.__schemaConditions` in Core/Schema.lua. A whitelist can only be right if it names every field
-- the format has, and the shipped builds are the authority on that; without a handle the spec
-- cannot compare the two, and the first authored field anyone adds is silently dropped on save.
UserBuilds.ENTRY_FIELDS = ENTRY_FIELDS

-- UserBuilds.replaceEntries(pack, key, entries) -> true | false, reasons
--
-- The Builder's Save. It writes the whole line list at once rather than one edit at a time because
-- the panel edits a DRAFT: a half-applied save -- three rows written, the fourth rejected -- would
-- leave a rotation that is neither what was stored nor what is on screen, and nothing would say so.
-- So the candidate build is validated ENTIRE, through the same `Schema.validate` the shipped builds
-- pass at load, and either all of it lands or none of it does.
--
-- `reasons` is always a list, so a caller can print them without asking which shape it got.
function UserBuilds.replaceEntries(pack, key, entries)
  -- Refused rather than validated against an empty ctx: without the pack's tables `Schema.validate`
  -- cannot check a single symbolic key, so it would accept a rotation naming spells that do not
  -- exist and the failure would surface as an empty queue much later.
  if not (pack and pack.class) then return false, { "no data pack for your class" } end
  local build, origin = UserBuilds.find(pack, key)
  if origin ~= "fork" then return false, { "not one of your rotations" } end
  if type(entries) ~= "table" then return false, { "a rotation is a list of lines" } end

  local copies = {}
  for i, entry in ipairs(entries) do
    if type(entry) ~= "table" then return false, { "line " .. i .. " is not a line" } end
    local copy = {}
    -- deepCopy on the value, not a reference: the draft's `when` lists would otherwise be shared
    -- with the stored build, so the next edit to the draft would change the saved rotation before
    -- Save was pressed -- and Discard could not put it back.
    for _, field in ipairs(ENTRY_FIELDS) do copy[field] = deepCopy(entry[field]) end
    copies[i] = copy
  end

  local candidate = {}
  for k, v in pairs(build) do candidate[k] = v end
  candidate.entries = copies
  local ok, errors = ns.Schema.validate(candidate, ctxFor(pack))
  if not ok then return false, ns.Schema.errorLines(errors) end

  build.entries = copies
  return edited(build)
end

-- UserBuilds.exportKey(pack, key, extra) -> string | nil, reason
--
-- `extra` is AB2-D5's "include ability settings": `{ abilities = , spells = }`, already resolved by
-- the caller (the names in it come from the CLIENT, which Core cannot ask). Absent, this is the
-- rotation-only string `/elm export` has always produced.
function UserBuilds.exportKey(pack, key, extra)
  local build = UserBuilds.find(pack, key)
  if not build then return nil, string.format("no build %q", tostring(key)) end
  if not ns.Serialize then return nil, "serializer is not loaded" end
  if not extra then return ns.Serialize.encode(build) end
  return ns.Serialize.encodeBundle({ build = build, abilities = extra.abilities, spells = extra.spells })
end

function UserBuilds.remove(key)
  local s = store()
  if not (s and s[key]) then return false end
  s[key] = nil
  return true
end

ns.UserBuilds = UserBuilds
return UserBuilds
