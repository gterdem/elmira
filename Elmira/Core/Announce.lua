-- Elmira/Core/Announce.lua — everything the addon says to the player, in one place (PRD F37).
--
-- PURE (hard rule 3): categories, routing and the log. The things that actually SPEAK — a chat
-- frame, an on-screen message frame, a sound, party chat — are sinks registered from
-- Display/Announcers.lua, which is where the WoW API is allowed to live.
--
-- Why this exists. Every message went through `ns.log` to the default chat frame, so the only
-- choices were "all of it in your main chat window" and "hack the addon". The owner's rule
-- (ADR-0015): a message about YOUR rotation is not something other people should see, a player who
-- silences chat must still be able to find out what Elmira said, and the noisiness of a rotation
-- change and of a broken-bar warning are different questions with different answers.
--
-- The Log is therefore not a channel the user can switch off. It is the record; the channels are
-- how loudly a given kind of message announces itself on the way into it.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Announce = {}

-- The kinds of thing Elmira says. Order is the order the options panel lists them.
--
-- `color` names a Core/Colors entry rather than holding one, so this file stays free of the palette
-- and a colour change happens in one place. `shareable` is the gate on party/raid: it is a property
-- of the CATEGORY, in code, not a checkbox the user can widen — "Divine Storm is now active in my
-- rotation" is about the player's own bars and is noise in a group. Only what a group might
-- actually act on can ever leave the client, and even that ships off.
-- D21 (2026-09-07 Notifications pass): `template` and `mode` are gone -- neither was ever emitted,
-- and a row nothing can fire only teaches the panel to be ignored. Keys are stable across the
-- rename (routing is stored by key, DB.lua's migration drops the two stale `routes` entries).
Announce.CATEGORIES = {
  { key = "rotation", label = "Rotation changes",      color = "HIGHLIGHT", shareable = false },
  { key = "warning",  label = "Problems",              color = "WARN",      shareable = false },
  { key = "status",   label = "Status",                color = "MUTED",     shareable = false },
  { key = "cooldown", label = "Long cooldowns used",   color = "OK",        shareable = true },
}

-- Where each kind goes before anyone changes anything. The Log is always on and is not listed.
--
-- A rotation change is the one thing worth interrupting for, so it takes the screen as well as
-- chat. Warnings and status go to chat: status carries the first-login line, which is the one
-- message every player sees and the only thing telling them the addon is working and where to
-- configure it. Routing it to the Log alone made it silent -- caught in review with every test
-- green, which is exactly the failure this project keeps shipping.
--
-- Cooldowns is the exception, and deliberately: nothing emits one yet (M5a), it is the only
-- shareable category, and a category that will end up in party chat should start silent.
--
-- `raid` (D22): party and raid are now two toggles, not one -- "cooldowns used" reaching a five-man
-- says nothing about whether it belongs in a twenty-man raid. Both ship off; only `cooldown` ever
-- shows them (Options/Options.lua gates the row on `shareable`), but every category carries the key
-- so `routes()` never hands back a table shaped differently from its neighbours.
Announce.DEFAULT_ROUTES = {
  rotation = { chat = true,  screen = true,  sound = false, party = false, raid = false },
  warning  = { chat = true,  screen = false, sound = false, party = false, raid = false },
  status   = { chat = true,  screen = false, sound = false, party = false, raid = false },
  cooldown = { chat = false, screen = false, sound = false, party = false, raid = false },
}

-- The order channels are spoken in. Fixed rather than left to `pairs`, so two runs of the same
-- announcement look the same -- and so party, the only one other people see, is last: if an earlier
-- sink is going to error, it should do so before anything has been said out loud.
Announce.CHANNELS = { "chat", "screen", "sound", "party" }

-- The log is a record, not a transcript. D27 (2026-09-07): the panel now shows the Log inline at
-- the bottom of the single Notifications page rather than as its own tab, and twenty lines is what
-- fits there without the switches above it scrolling out of reach -- so the STORE matches the
-- DISPLAY cap exactly and a dropped-lines counter nothing above it can now show is not kept either.
Announce.MAX_LOG = 20

-- How many on-screen messages may be waiting for combat to end. A fight that produces more than
-- this is already telling the player something is wrong, and dumping fifty toasts the moment they
-- stop fighting is not the way to say it. The Log keeps all of them regardless.
Announce.MAX_DEFERRED = 20

-- Session state. One declaration: `clock` alone would be an invisible mutation (a deleted `local`
-- only makes it a global), and these four are one idea -- what this module remembers between calls.
local sinks, deferred, clock = {}, {}, nil

-- Injected from Core/Init: `now` for timestamps, `inCombat` so the screen sink can be held back.
-- Both are functions, so a spec drives time and combat without a frame or a state object.
function Announce.use(t)
  if type(t) ~= "table" or type(t.now) ~= "function" then
    clock = nil
    return false
  end
  clock = t
  return true
end

function Announce.registerSink(name, fn)
  if type(name) ~= "string" or type(fn) ~= "function" then return false end
  sinks[name] = fn
  return true
end

-- Test seam, and the honest reset for a profile switch: sinks and the deferred queue belong to the
-- session, latches to the run.
function Announce.reset()
  sinks, deferred = {}, {}
end

function Announce.category(key)
  for _, cat in ipairs(Announce.CATEGORIES) do
    if cat.key == key then return cat end
  end
end

local function db()
  return ns.db
end

-- The user's routing for one category, falling back to the shipped defaults. A category with no
-- stored row is not "everything off": that is what a fresh profile looks like.
-- ALWAYS a copy. Handing back either the shipped defaults or the user's stored row invites a
-- caller to write one channel into it -- `noShare` did exactly that in review, silently turning a
-- user's party routing off for the rest of the session because one message asked not to be shared.
-- One small table per announcement is not a cost worth that class of bug.
function Announce.routes(key)
  local stored = db() and db().profile and db().profile.announce and db().profile.announce.routes
  local source = (stored and stored[key]) or Announce.DEFAULT_ROUTES[key] or {}
  local out = {}
  for name, on in pairs(source) do out[name] = on end
  return out
end

-- Strip Elmira's own colour and icon escapes. Party chat is other people's screen: an escape
-- sequence they cannot render is worse than the plain sentence.
function Announce.plain(text)
  if type(text) ~= "string" then return "" end
  local out = text:gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function record(cat, text, icon)
  local store = db() and db().global
  if not store then return nil end
  store.announceLog = store.announceLog or {}
  local row = {
    at = clock and clock.now() or 0,
    category = cat.key,
    text = text,
    icon = icon,
  }
  store.announceLog[#store.announceLog + 1] = row
  while #store.announceLog > Announce.MAX_LOG do
    table.remove(store.announceLog, 1)
  end
  return row
end

local function dispatch(cat, row, routes)
  for _, name in ipairs(Announce.CHANNELS) do
    local fn = sinks[name]
    -- "party" is one sink covering two user flags (D22): the channel fires if EITHER is on, and
    -- Display/Announcers.party (the only place group membership can be read) decides which of the
    -- two actually applies once it knows whether the player is in a party or a raid right now.
    local go = routes[name]
    if name == "party" then go = routes.party or routes.raid end
    if fn and go then
      -- One sink must not be able to silence the others: a chat frame that has gone away should
      -- not stop the screen message, and neither should stop the log, which already happened.
      pcall(fn, cat, row)
    end
  end
end

-- The shortest cooldown worth saying out loud, in seconds.
--
-- "Cooldowns used" is the one category that can reach party chat, so what counts matters: Crusader
-- Strike at 6s and Divine Storm at 10s would be a line every global cooldown, which is noise in
-- your own chat and unforgivable in anyone else's. 120s is the owner's line (2026-09-05) and for a
-- paladin it is a clean one -- it takes Avenging Wrath (180s) and Aura Mastery (120s) and leaves
-- Holy Shock (30s) and everything below alone.
Announce.COOLDOWN_FLOOR = 120

function Announce.cooldownFloor()
  local d = db()
  local stored = d and d.profile and d.profile.announce and d.profile.announce.cooldownFloor
  local n = tonumber(stored)
  if not n or n < 0 then return Announce.COOLDOWN_FLOOR end
  return n
end

-- Is this worth announcing as a cooldown? Pure, so the rule is testable without a client and lives
-- next to the category it decides for.
function Announce.worthAnnouncing(cooldown)
  local n = tonumber(cooldown)
  return n ~= nil and n >= Announce.cooldownFloor()
end

-- Announce.emit(category, text, opts) -> the logged row, or nil
--
-- opts.icon      a texture path, drawn inline by the sinks that can draw one
-- opts.noShare   never route this to party, whatever the user has switched on. For the test button:
--                a control for previewing your own settings must not put a line in a group's chat.
function Announce.emit(key, text, opts)
  opts = opts or {}
  local cat = Announce.category(key)
  if not cat or type(text) ~= "string" or text == "" then return nil end

  -- Before the database exists there is nowhere to record and no routing to read; saying it out
  -- loud is still better than swallowing it, because that is exactly when load failures happen.
  local row = record(cat, text, opts.icon)
  if not row then
    -- No database yet: nowhere to record, no routing to read, and nothing to hand a sink. Say it
    -- plainly instead -- this is exactly when load failures happen, and swallowing them would
    -- silence the messages most worth hearing.
    if ns.log then ns.log("%s", Announce.plain(text)) end
    return nil
  end

  local routes = Announce.routes(key)
  if opts.noShare then routes.party, routes.raid = false, false end
  -- The screen message waits for the fight to end. A toast at the moment a set bonus turns on is
  -- reading material dropped in front of someone mid-pull; the Log and chat already have it.
  if routes.screen and clock and clock.inCombat and clock.inCombat() then
    deferred[#deferred + 1] = { cat = cat, row = row }
    -- Oldest first, like the Log: by the time combat ends the newest are the ones still relevant.
    while #deferred > Announce.MAX_DEFERRED do table.remove(deferred, 1) end
    local rest = {}
    for name, on in pairs(routes) do
      if name ~= "screen" then rest[name] = on end
    end
    dispatch(cat, row, rest)
  else
    dispatch(cat, row, routes)
  end
  return row
end

-- Called when combat drops. Everything held back arrives in the order it was said.
function Announce.flush()
  local held = deferred
  deferred = {}
  for _, item in ipairs(held) do
    dispatch(item.cat, item.row, { screen = true })
  end
  return #held
end

function Announce.pending()
  return #deferred
end

-- Newest first, because that is the order anyone reads a log in.
function Announce.log(limit)
  local store = db() and db().global
  local rows = (store and store.announceLog) or {}
  local out = {}
  for i = #rows, 1, -1 do
    out[#out + 1] = rows[i]
    if limit and #out >= limit then break end
  end
  return out
end

function Announce.clear()
  local store = db() and db().global
  if not store then return false end
  store.announceLog = {}
  return true
end

-- One sample of every kind, so the user can see what each channel and colour looks like without
-- waiting for the game to produce one. Deliberately bypasses the combat deferral: the point is to
-- see it now.
function Announce.test()
  local held = clock
  clock = held and { now = held.now, inCombat = function() return false end } or nil
  local n = 0
  for _, cat in ipairs(Announce.CATEGORIES) do
    -- noShare: the point of the button is to see your own settings, not to put six lines in a
    -- group's chat because one category happens to be routed there.
    if Announce.emit(cat.key, "This is a " .. cat.label .. " message.", { noShare = true }) then
      n = n + 1
    end
  end
  clock = held
  return n
end

ns.Announce = Announce
return Announce
