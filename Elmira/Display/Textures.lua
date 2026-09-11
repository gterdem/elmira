-- Elmira/Display/Textures.lua — the per-ability indicator textures (AB3-D1, AB3-D2).
--
-- The fourth thing that can answer "what now": the strip lists it, the bar glow points at it, the
-- screen edge flashes for it, and this puts a shape where the player is already looking. It exists
-- because the other three all live somewhere: the strip is wherever you dragged it, the glow is on
-- your bars, the edge is at the rim. A texture goes in the middle of the screen if that is where
-- your eyes are during a pull.
--
-- TWO KINDS OF EVENT, and the difference is the whole design (AB3-D1):
--   * `suggested` and `active` are STATES. The texture is on screen for as long as the state holds
--     and goes when it stops -- which means something has to notice that it stopped, and that is
--     `Sync` below. A "show" with no matching "hide" is a texture stuck on screen for the rest of
--     the session.
--   * `ready`, `used` and `expiring` are INSTANTS. There is no state to hold, so they FLASH for
--     `FLASH_SECONDS` and clear themselves.
-- `Fire` starts both kinds, from Display/Driver's one ability-event call, so a texture appears in
-- the same frame the sound plays rather than up to a tick later. `Sync` only ever ENDS things.
--
-- PLAIN FRAMES, NEVER SECURE (hard rule 1) and nothing gated on combat: these are non-secure frames
-- carrying no attributes, so both Move modes work mid-fight -- which is exactly when you find out
-- your texture is sitting on top of your health bar.
--
-- POOLED. One frame per texture ON SCREEN, not one per registered ability: a paladin has forty
-- keys and at most three of them are showing at once, and forty always-allocated frames is forty
-- frames the client lays out every time anything moves.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Textures = {}

local MEDIA = "Interface\\AddOns\\Elmira\\media\\"
local ALL = "*"

-- AT4-D2 (owner, 2026-09-11): TWO sources, not four. Either the ability draws its own spell icon --
-- which is what a tick box says, and what nearly everyone wants -- or it draws a FILE, and the one
-- question left is which file. The shipped shapes, the visual picker and a hand-typed path all
-- produce the same answer to that question, so they are all `path` and the difference between them
-- is only how the player arrived at it. `shape` and `custom` are gone with the dropdown that
-- offered them; there are no users to migrate, so a row still carrying one reads as `icon`.
Textures.SOURCES = { "icon", "path" }
-- What the file field holds before anyone chooses anything, and what the ring fallback draws: the
-- shipped ring (`tools/gen_shapes.lua` draws these -- white, with the shape in the alpha channel, so
-- one file tints to any colour the player picks). Exported because the Texture tab shows it as the
-- starting value the moment the icon tick box comes off.
Textures.DEFAULT_PATH = MEDIA .. "shape_ring"
Textures.PLACEMENTS = { "row", "centre", "custom" }
-- All five of Core/Track's events, unlike the screen edge's two: a shape the size of a coin on a
-- fixed spot is not the strobe a full-screen flash is, so the three moments ADR-0009 keeps off the
-- edge are exactly the ones this is for.
Textures.EVENTS = { "suggested", "ready", "used", "active", "expiring" }
-- Which of them are STATES rather than instants. Read by Fire and by Sync, so the two can never
-- disagree about which events have an ending to wait for.
Textures.HELD = { suggested = true, active = true }
Textures.FLASH_SECONDS = 1.5
-- AT5-D1, replacing AB4-D1's radial swipe: what the texture's OPACITY follows while it is on
-- screen. Ordered for the dropdown, "none" first because it is the shipped answer.
Textures.FILLS = { "none", "cooldown", "buff" }

-- The gap between textures in the row, and how far the row floats above the queue strip.
local GAP = 8
local ANCHOR_GAP = 40
-- What the anchor becomes while it is being placed: a 1x1 point cannot be grabbed with a mouse.
local GRIP_WIDTH, GRIP_HEIGHT = 160, 40

local anchor                    -- the Indicators anchor: the point the row is centred on
local frames = {}               -- ability key -> the frame currently showing it
local pool = {}                 -- frames nothing is using
local held = {}                 -- ability key -> true while a held event holds for it
local flashUntil = {}           -- ability key -> when its flash ends
local shownAt = {}              -- ability key -> when it was last put on screen, for the diagnostic
local positioning = false       -- the anchor's Move mode
local moving = nil              -- the one ability whose own texture is being dragged
-- AT5-D1. Core/Track's own memory table (`[key] = { cooldown =, cooldownFull =, remaining =,
-- duration = ... }`) as of the last Sync. Held rather than passed to `Fire`, because a texture that
-- appears the instant its event fires has to fade in that same frame and only the render loop is
-- holding the numbers by then. Unlike the swipe it replaced, the fade needs no clock reading -- a
-- fraction of remaining over duration is already a fact about now, not something to back-date.
local fillMemory = nil

-- ---------------------------------------------------------------- the pure part (AB3-D2)

-- Textures.rowFlow(items, gap) -> [{ key =, x =, y =, size = }]
--
-- The row-flow layout, and the reason several textures never overlap: each one is placed to the
-- right of the last with `gap` between them, and the whole run is centred on the anchor so adding a
-- second texture pushes the first left rather than stacking on it.
--
-- Pure on purpose (its own spec): "they overlap" is invisible in a headless test unless the
-- arithmetic that separates them is something a test can hold. `items` is already ordered -- the
-- caller sorts by key, so two ticks with the same textures showing produce the same row.
function Textures.rowFlow(items, gap)
  gap = gap or GAP
  local total = 0
  for i, item in ipairs(items) do
    total = total + (item.size or 0)
    if i > 1 then total = total + gap end
  end
  local out, left = {}, -total / 2
  for _, item in ipairs(items) do
    local size = item.size or 0
    out[#out + 1] = { key = item.key, x = left + size / 2, y = 0, size = size }
    left = left + size + gap
  end
  return out
end

-- A size the client can actually draw, from a number that may have arrived in an import or a class
-- pack's defaults rather than from the slider (AB2-D3 opened both doors). The slider's own range,
-- so a value it cannot produce is clamped rather than trusted.
function Textures.sizeOf(e)
  local size = tonumber(e and e.size) or 48
  return math.max(16, math.min(256, size))
end

local function oneOf(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false -- mutants: equivalent — nil is falsy and every caller uses this only as a condition
end

-- What the fade measures. Same shape as `placementOf`, and for the same reason: a value that
-- arrived in an import or a class pack's defaults and that this code does not understand must read
-- as the shipped answer rather than as a fade nothing can compute.
function Textures.fillOf(e)
  local fill = e and e.fill
  return oneOf(Textures.FILLS, fill) and fill or "none"
end

-- Textures.fillFraction(e, row) -> a multiplier in [0, 1], or nil
--
-- AT5-D1, replacing AB4-D1's radial swipe (owner, seeing it draw a PowerAuras-style dark box: "not
-- clockwise or anything -- start being visible or getting invisible"). No clock is involved any
-- more: Core/Track's REMAINING is already a fact about now, so the ratio to the full length IS the
-- opacity multiplier, nothing to back-date the way a client-animated swipe's start had to be.
--
-- `row` is one row of Track's memory. nil is a real answer and the caller leaves the opacity alone
-- on it: an ability that is not on cooldown, a buff with no duration, or a client that has never
-- observed how long this cooldown lasts (docs/07 §9.1) has no progress to fade with.
--
-- The two directions differ on purpose, same as the swipe they replace. A buff drains as it runs
-- out, so what is left of the multiplier is what is left of the buff -- full the instant it appears,
-- fading toward the floor `paint` applies as it is about to expire. A cooldown reads the other way:
-- faint the instant it is cast, brightening back to full opacity as it comes off cooldown.
function Textures.fillFraction(e, row)
  local fill = Textures.fillOf(e)
  if fill == "none" or type(row) ~= "table" then return nil end
  local remaining, duration = row.cooldown, row.cooldownFull
  if fill == "buff" then remaining, duration = row.remaining, row.duration end
  remaining, duration = tonumber(remaining) or 0, tonumber(duration) or 0
  if remaining <= 0 or duration <= 0 then return nil end
  -- A reading taken a moment after the duration was observed can exceed it (a cooldown extended by
  -- a rune, a buff refreshed to longer than the length last seen). Clamped rather than trusted: a
  -- buff read as "more left than it can hold" must not read as MORE than full opacity.
  if remaining > duration then remaining = duration end
  local left = remaining / duration
  if fill == "buff" then return left end
  return 1 - left
end

-- Where this texture sits. An unknown answer is "with the others", never nothing: a placement the
-- code does not understand would otherwise leave the frame unanchored, which draws it at the
-- bottom-left corner of the screen with no hint why.
function Textures.placementOf(e)
  local place = e and e.place
  return oneOf(Textures.PLACEMENTS, place) and place or "row"
end

-- Textures.addonLoaded(name) -> is that addon running on this character (AT4-D2)
--
-- Through the adapter, never through the client: Display may hold frames, but `IsAddOnLoaded` is a
-- WoW API call and lives in Adapters/ behind the `addonLoaded` capability like every other one.
-- false when the adapter cannot answer, which drops the WeakAuras groups from the picker rather
-- than offering files that would draw nothing.
function Textures.addonLoaded(name)
  local A = ns.Adapter
  if not (A and A.addonLoaded) then return false end
  return A.addonLoaded(name) == true
end

-- AT4-D2: the LibSharedMedia category, built from the library the player actually runs rather than
-- from a list here -- bar textures and backgrounds from every media pack they have installed, named
-- the way LibSharedMedia names them (those names are the player's own vocabulary; generating our
-- own from the file path would make the picker disagree with every other addon they configure).
-- Both media TYPES in one category: a statusbar file and a background file are the same kind of
-- thing to an indicator, and two categories of four entries each is worse than one of eight. A
-- duplicate PATH is listed once -- packs routinely register the same file under both types.
local LSM_TYPES = { "statusbar", "background" }
local function sharedMediaTextures()
  local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
  if not lsm then return {} end
  local out, seen = {}, {}
  for _, kind in ipairs(LSM_TYPES) do
    for _, name in ipairs((lsm.List and lsm:List(kind)) or {}) do
      local path = lsm.Fetch and lsm:Fetch(kind, name)
      if path and not seen[path] then
        seen[path] = true
        out[#out + 1] = { path = path, name = name }
      end
    end
  end
  return out
end

-- The categories this character can actually see, in the order the picker's dropdown offers them:
-- the library's own fixed ones, with LibSharedMedia's live one before the two that need WeakAuras.
-- `Textures.addonLoaded` is itself the predicate the library asks with, so "is WeakAuras here" is
-- answered in one place for the picker, the tab and the diagnostic alike.
function Textures.libraryGroups()
  local lib = ns.TextureLibrary
  if not lib then return {} end
  local out, media = {}, sharedMediaTextures()
  for _, group in ipairs(lib.groups(Textures.addonLoaded)) do
    -- Before the WeakAuras pair, which are the last two the library declares; on a client without
    -- WeakAuras that is simply the end of the list.
    if group.requires and #media > 0 then
      out[#out + 1] = { key = "sharedmedia", name = "LibSharedMedia Textures", textures = media }
      media = {}
    end
    out[#out + 1] = group
  end
  if #media > 0 then
    out[#out + 1] = { key = "sharedmedia", name = "LibSharedMedia Textures", textures = media }
  end
  return out
end

-- Textures.missingAddon(e) -> the addon this setting's file needs and this character lacks, or nil
--
-- AT4-D3. The only failure the library adds over a typed path: a file that exists on the machine
-- the setting was chosen on and not on this one. nil is the normal answer.
function Textures.missingAddon(e)
  local lib = ns.TextureLibrary
  if not (lib and e and e.source == "path") then return nil end
  local needs = lib.requires(e.path)
  if needs and not Textures.addonLoaded(needs) then return needs end
  return nil
end

-- Textures.texturePath(e, key) -> the file to draw, or nil
--
-- nil is a real answer and the panel says so: an ability whose icon this client cannot resolve, or
-- a custom path left empty. The frame falls back to the ring so the cue is still visible, but the
-- diagnostic and the Texture tab report the nil, because "you typed the path wrong" and "it is
-- working" must not look the same.
function Textures.texturePath(e, key)
  local source = (e and oneOf(Textures.SOURCES, e.source) and e.source) or "icon"
  if source == "path" then
    -- AT4-D3: a path that lives inside another addon's folder is only a file while that addon is
    -- loaded. nil here is what draws the ring and what makes `/elm debug textures` and the Texture
    -- tab say WHY -- an uninstalled WeakAuras must not look like a working setting, and the stored
    -- path is never reset behind the player's back.
    if Textures.missingAddon(e) then return nil end
    local path = tostring((e and e.path) or "")
    -- An empty file field is the shipped ring, not nothing: the tab shows the same path as its own
    -- starting value, so what is drawn and what is written there agree before anything is chosen.
    return path ~= "" and path or Textures.DEFAULT_PATH
  end
  -- Through Display's one lookup (Driver.spellIcon), never GetSpellTexture from here.
  return (ns.Display and ns.Display.spellIcon and ns.Display.spellIcon(key)) or nil
end

-- ---------------------------------------------------------------- frames

local function settings(key)
  return ns.AbilitySettings.effective(key, "texture")
end

local function store()
  local db = ns.db
  return db and db.char and db.char.textures
end

-- Where the row sits when nothing has ever dragged it: above the queue strip, following it (AB3-D2).
-- Anchored to the strip's own frame rather than copied from its coordinates, so moving the strip
-- takes the indicators with it and the default keeps meaning what it says.
local function placeAnchor()
  local a = store()
  local saved = a and a.anchor
  anchor:ClearAllPoints()
  if type(saved) == "table" and saved.point then
    anchor:SetPoint(saved.point, UIParent, saved.relPoint or "CENTER", saved.x or 0, saved.y or 0)
    return
  end
  local strip = ns.Queue and ns.Queue.frame and ns.Queue.frame()
  if strip then
    anchor:SetPoint("BOTTOM", strip, "TOP", 0, ANCHOR_GAP)
    return
  end
  anchor:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

local function saveAnchor()
  local a = store()
  if not (a and anchor) then return end
  local point, _, relPoint, x, y = anchor:GetPoint()
  a.anchor = { point = point or "CENTER", relPoint = relPoint or "CENTER", x = x or 0, y = y or 0 }
end

local function onAnchorDragStart(self)
  -- Only in the Move mode, and that is the point: the row must not be draggable by accident while
  -- someone is clicking through it at a boss.
  if positioning then self:StartMoving() end
end

local function onAnchorDragStop(self)
  if not positioning then return end
  self:StopMovingOrSizing()
  saveAnchor()
end

function Textures.Create()
  if anchor then return anchor end
  anchor = CreateFrame("Frame", "ElmiraIndicators", UIParent)  -- plain frame, never secure (rule 1)
  anchor:SetSize(1, 1)
  anchor:SetMovable(true)
  anchor:SetClampedToScreen(true)
  anchor:EnableMouse(false)     -- a point in the middle of the screen must never eat a click
  anchor:RegisterForDrag("LeftButton")
  anchor:SetScript("OnDragStart", onAnchorDragStart)
  anchor:SetScript("OnDragStop", onAnchorDragStop)
  -- Visible only while the row is being placed: an always-on box around an invisible point is
  -- clutter the rest of the time.
  anchor.grip = anchor:CreateTexture(nil, "BACKGROUND")
  anchor.grip:SetAllPoints()
  anchor.grip:SetColorTexture(ns.Colors.BRAND.r, ns.Colors.BRAND.g, ns.Colors.BRAND.b, 0.35)
  anchor.grip:Hide()
  placeAnchor()
  return anchor
end

local function onTextureDragStart(self)
  if moving and frames[moving] == self then self:StartMoving() end
end

-- The offset from SCREEN CENTRE (AB3-D2), not from wherever the frame's parent happens to be: it is
-- the one reference point that survives a resolution change and a strip that moved.
local function saveOffset(key)
  local f, A = frames[key], ns.AbilitySettings
  -- GetCenter is not something every conceivable client region answers, and a frame that has never
  -- been drawn answers nil -- both would otherwise store a nil offset as if it were a position.
  if not (f and A and UIParent.GetCenter) then return end
  local cx, cy = f:GetCenter()
  local px, py = UIParent:GetCenter()
  if not (cx and cy and px and py) then return end
  -- The placement goes with the offset. Dragging a texture that was flowing with the others and
  -- leaving it set to "with the others" would store coordinates the layout then ignores -- a drag
  -- that appears to work and is undone by the next tick.
  A.set(key, "texture", "place", "custom")
  A.set(key, "texture", "x", cx - px)
  A.set(key, "texture", "y", cy - py)
end

local function onTextureDragStop(self)
  if not (moving and frames[moving] == self) then return end
  self:StopMovingOrSizing()
  saveOffset(moving)
end

local function newFrame()
  local f = CreateFrame("Frame", nil, UIParent)   -- plain frame, never secure (rule 1)
  f:SetFrameStrata("HIGH")
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(false)          -- only its own Move mode ever turns this on
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", onTextureDragStart)
  f:SetScript("OnDragStop", onTextureDragStop)
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetAllPoints()
  return f
end

local function acquire(key)
  local f = frames[key]
  if f then return f end
  f = table.remove(pool) or newFrame()
  frames[key] = f
  return f
end

-- Takes the frame it is giving back rather than looking it up: the one caller is walking `frames`
-- and already holds it, and a lookup here would need a guard for a case that cannot happen.
local function release(key, f)
  frames[key] = nil
  f:Hide()
  pool[#pool + 1] = f
end

-- Textures.alphaOf(e, row) -> the SetAlpha value for one tick (AT5-D1)
--
-- What replaces the swipe: the tab's own Opacity slider, multiplied by `fillFraction` when a fade
-- is picked and left alone (static) when it is not. Unlike the swipe, there is no restart to guard
-- against -- `SetAlpha` does not animate anything, so pushing it every tick is exactly what makes
-- the fade look continuous rather than jumping once a fight. The 0.05 floor is the same one a
-- static Opacity has always had (`paint` below used to apply it alone): a fade that reaches "zero
-- multiplier" the instant a cooldown starts must still read as "faint", not vanish outright.
local FADE_FLOOR = 0.05
function Textures.alphaOf(e, row)
  local opacity = math.max(0, math.min(1, tonumber(e and e.alpha) or 1))
  local frac = Textures.fillFraction(e, row)
  local raw = frac and (opacity * frac) or opacity
  return math.max(FADE_FLOOR, math.min(1, raw))
end

local function paint(f, key, e)
  local size = Textures.sizeOf(e)
  f:SetSize(size, size)
  -- The ring stands in for a path that resolved to nothing, so the cue is never silently invisible;
  -- `describe` and the Texture tab still report the nil, so it is never silently WRONG either.
  -- Through TextureLibrary.drawable: a Blizzard library entry is a numeric file id stored as a
  -- string, and this client draws an id only when it arrives as a NUMBER. Guarded rather than
  -- required, so the indicator still paints on a load order where the library is absent.
  local file = Textures.texturePath(e, key) or (MEDIA .. "shape_ring")
  f.icon:SetTexture(ns.TextureLibrary and ns.TextureLibrary.drawable(file) or file)
  local c = e.color
  if type(c) == "table" then
    f.icon:SetVertexColor(c.r or 1, c.g or 1, c.b or 1)
  else
    f.icon:SetVertexColor(1, 1, 1)
  end
  f:SetAlpha(Textures.alphaOf(e, fillMemory and fillMemory[key]))
end

local function placeOne(f, e, rowX)
  local place = Textures.placementOf(e)
  f:ClearAllPoints()
  if place == "centre" then
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  elseif place == "custom" then
    f:SetPoint("CENTER", UIParent, "CENTER", tonumber(e.x) or 0, tonumber(e.y) or 0)
  else
    f:SetPoint("CENTER", anchor, "CENTER", rowX or 0, 0)
  end
end

-- Everything on screen this instant, in a stable order: `pairs` has none, and two ticks showing the
-- same two textures must not swap them round in the row.
local function shownKeys()
  local out = {}
  for key in pairs(held) do out[#out + 1] = key end
  for key in pairs(flashUntil) do
    if not held[key] then out[#out + 1] = key end
  end
  table.sort(out)
  return out
end

-- One repaint of everything visible. Called after every change rather than on a timer: the set only
-- changes when an event fires or a state ends, which is a handful of times per fight, and a layout
-- pass on every one of those is cheaper than a check on every frame.
local function layout()
  Textures.Create()
  local keys = shownKeys()
  local resolved, row = {}, {}
  for _, key in ipairs(keys) do
    local e = settings(key)
    resolved[key] = e
    if Textures.placementOf(e) == "row" then
      row[#row + 1] = { key = key, size = Textures.sizeOf(e) }
    end
  end
  local at = {}
  for _, placed in ipairs(Textures.rowFlow(row, GAP)) do at[placed.key] = placed.x end
  -- Give back the frames of everything that stopped showing BEFORE acquiring: a texture that ends
  -- as another begins then reuses the same frame instead of growing the pool by one per fight.
  for key, f in pairs(frames) do
    if not resolved[key] then release(key, f) end
  end
  for _, key in ipairs(keys) do
    local f, e = acquire(key), resolved[key]
    paint(f, key, e)
    placeOne(f, e, at[key])
    f:Show()
  end
end

-- Repaint what is already on screen. The Texture tab calls this from every setter: a size or a
-- colour changed while the texture is standing there (which is exactly when someone is adjusting
-- it, and always while a Move mode is running) would otherwise not show until the cue next fired --
-- a panel that appears to do nothing.
function Textures.Refresh()
  -- Create FIRST: this is called from the options panel, which a player can open before the display
  -- has ever started, and placing an anchor that does not exist yet is an error thrown out of a
  -- settings getter -- which takes the whole page with it.
  Textures.Create()
  -- Re-places the row too: the anchor follows the queue strip until it is dragged, and a strip that
  -- moved (or a settings string that arrived with an anchor in it) has to reach the row somehow.
  -- Never while it is being placed, or a size change mid-drag would snap the row back.
  if not positioning then placeAnchor() end
  layout()
  return true
end

-- ---------------------------------------------------------------- the events

-- Textures.Fire(key, event) -> did a texture appear
--
-- Display/Driver calls this for every one of AB1-D5's five events, exactly as it calls
-- Overlay.Fire; this decides whether THIS ability's texture has anything to say about it. A held
-- event starts a texture that `Sync` will end; an instant one starts a flash that ends itself.
function Textures.Fire(key, event)
  local A = ns.AbilitySettings
  if not (A and A.channelOn(key, "texture")) then return false end
  local e = settings(key)
  if not e[event] then return false end
  local now = ns.now and ns.now() or 0
  if Textures.HELD[event] then
    held[key] = true
  else
    flashUntil[key] = now + Textures.FLASH_SECONDS
  end
  shownAt[key] = now
  layout()
  return true
end

-- Textures.Sync(nowKey, memory, now) -> did anything come off screen
--
-- The other half of a held event. `nowKey` is the ability the queue is suggesting and `memory` is
-- Core/Track's own state table (`[key] = { ready =, active =, expiring = }`), both of which the
-- driver already has; this asks them whether each showing texture's reason still holds, and expires
-- the flashes. It never SHOWS anything -- `Fire` does that, in the same frame the event happened,
-- so nothing waits up to a tick to appear.
function Textures.Sync(nowKey, memory, now)
  local A = ns.AbilitySettings
  -- A Move mode the render loop can undo is not a mode: the sample texture it puts on screen is
  -- held by neither a suggestion nor a buff, so the first Sync would take it away mid-drag.
  if not A or positioning or moving then return false end
  now = now or (ns.now and ns.now()) or 0
  -- AT5-D1: the numbers a fade is drawn from, kept for `Fire` -- which shows a texture in the same
  -- frame its event happened and has no memory of its own to fade it from.
  fillMemory = memory
  local changed = false
  for key in pairs(held) do
    local e = A.effective(key, "texture")
    local still = A.channelOn(key, "texture")
      and ((e.suggested and key == nowKey)
        or (e.active and memory and memory[key] and memory[key].active))
    if not still then held[key] = nil; changed = true end
  end
  for key, ends in pairs(flashUntil) do
    if now >= ends then flashUntil[key] = nil; changed = true end
  end
  if changed then layout() end
  -- AT5-D1, and AFTER the layout: a fade has to follow the state every tick, not only on the ticks
  -- the SET of textures changed. `layout` runs a handful of times a fight; a buff whose opacity was
  -- set once when it appeared and never again would sit at full while the buff ran out. Cheap by
  -- construction -- at most a few textures are ever on screen, and `SetAlpha` restarts nothing, so
  -- there is no idempotency to guard the way the swipe it replaced needed.
  for key, f in pairs(frames) do f:SetAlpha(Textures.alphaOf(A.effective(key, "texture"), memory and memory[key])) end
  return changed
end

-- ---------------------------------------------------------------- the two Move modes (AB3-D2)

function Textures.isPositioning() return positioning end
function Textures.movingKey() return moving end

-- The Indicators anchor's own Move mode, the Position the Strip pattern (Display/Queue.lua): a
-- TEMPORARY OVERRIDE that writes nothing but the position. It starts false on every load, so no
-- reload or disconnect can strand the addon in it.
function Textures.StartPositioning()
  Textures.Create()
  if positioning then return false end
  Textures.StopMoveMode()
  positioning = true
  anchor:SetSize(GRIP_WIDTH, GRIP_HEIGHT)
  anchor:EnableMouse(true)
  anchor.grip:Show()
  -- Something to place. The All abilities texture, drawn with its own settings: placing a row with
  -- nothing in it is placing an invisible point, which is what made the strip's own positioning
  -- mode necessary in the first place.
  held[ALL] = true
  layout()
  -- FX1-D5: the options window gets out of the way -- it is very often sitting exactly where the
  -- row is being dragged to. From HERE rather than from the button, so that every way out of the
  -- mode brings the window back (Textures.StopMoveMode below is the only one).
  if ns.Options and ns.Options.BeginMove then ns.Options.BeginMove("indicators") end
  return true
end

-- Move ONE texture (AB3-D2). Shown whether or not its channel is switched on, for the same reason
-- Overlay.TestFire flashes a switched-off edge: the question being answered is "where does this
-- go", and refusing to show it would make the mode useless in the case it is for.
function Textures.StartMove(key)
  if type(key) ~= "string" or key == "" then return false end
  Textures.StopMoveMode()
  moving = key
  held[key] = true
  layout()
  local f = frames[key]
  if f then f:EnableMouse(true) end
  -- FX1-D5, and this is the mode the owner was actually trying to use when he found the problem.
  if ns.Options and ns.Options.BeginMove then ns.Options.BeginMove("texture", key) end
  return true
end

-- Ends whichever mode is running. ONE function rather than two, because the options panel's close
-- path has to end both and a guard written twice is a guard that will be forgotten once (the strip's
-- positioning mode is stranded by exactly that).
function Textures.StopMoveMode()
  local wasPositioning, wasMoving = positioning, moving
  if not (wasPositioning or wasMoving) then return false end
  positioning, moving = false, nil
  if wasPositioning then
    held[ALL] = nil
    anchor:SetSize(1, 1)
    anchor:EnableMouse(false)
    anchor.grip:Hide()
  end
  if wasMoving then
    held[wasMoving] = nil
    local f = frames[wasMoving]
    -- Before layout(), which is what hands the frame back to the pool: a pooled frame that kept
    -- mouse input would swallow clicks from the middle of the screen the next time it was used.
    if f then f:EnableMouse(false) end
  end
  -- Whatever was genuinely holding a texture puts it back on the next Sync; what this clears is the
  -- sample the mode itself put there.
  layout()
  -- FX1-D5: both modes end here, so the options window comes back here.
  if ns.Options and ns.Options.EndMove then ns.Options.EndMove() end
  return true
end

-- ---------------------------------------------------------------- the diagnostic

-- Every ability this character could configure a texture for -- the class pack's and this
-- character's registry alike, plus any settings row imported for a spell the client cannot resolve.
-- Sorted, so `/elm debug textures` reads the same way twice in a row.
local function abilityKeys()
  local pack = ns.Display and ns.Display.currentPack and ns.Display.currentPack()
  local spells = (ns.Spells and ns.Spells.merged and ns.Spells.merged(pack))
    or (pack and pack.spells) or {}
  local seen, out = {}, {}
  for key in pairs(spells) do seen[key] = true; out[#out + 1] = key end
  local A = ns.AbilitySettings
  for _, key in ipairs((A and A.keys()) or {}) do
    if not seen[key] then out[#out + 1] = key end
  end
  table.sort(out)
  return out
end

local function known(key)
  for _, k in ipairs(abilityKeys()) do
    if k == key then return true end
  end
  return false -- mutants: equivalent — nil is falsy and the one caller uses this as a condition
end

-- What `/elm debug textures` reports. The same four indistinguishable silences the screen edge has
-- (`Overlay.describe`), plus one this channel adds: a source that resolves to no file at all.
function Textures.describe()
  local A = ns.AbilitySettings
  local out = { textures = {}, positioning = positioning, movingKey = moving }
  local a = store()
  out.anchor = (a and type(a.anchor) == "table") and a.anchor or nil
  if not A then return out end
  for _, key in ipairs(abilityKeys()) do
    local on = A.channelOn(key, "texture")
    if on or shownAt[key] then
      local e = A.effective(key, "texture")
      local events = {}
      for _, event in ipairs(Textures.EVENTS) do
        if e[event] then events[#events + 1] = event end
      end
      out.textures[#out.textures + 1] = {
        key = key, enabled = on, source = e.source, path = Textures.texturePath(e, key),
        -- AT4-D3: WHY the path above is nil, when the reason is an addon this character does not
        -- have. "You typed it wrong" and "WeakAuras is not installed here" are different problems
        -- with the same symptom, and the ring is drawn for both.
        needsAddon = Textures.missingAddon(e),
        size = Textures.sizeOf(e), place = Textures.placementOf(e), events = events,
        shownAt = shownAt[key], visible = (held[key] or flashUntil[key]) ~= nil,
        -- AT5-D1: what the fade is SET to, and its current fraction. The two differ in exactly the
        -- case worth reporting -- a fade picked for an ability whose cooldown or buff this client
        -- has no numbers for multiplies nothing, and a static opacity is how that looks.
        fill = Textures.fillOf(e), fade = Textures.fillFraction(e, fillMemory and fillMemory[key]),
      }
    end
  end
  return out
end

-- Manual test-fire: the Texture tab's Preview button and `/elm debug textures <KEY>`. Ignores
-- whether the channel is on -- what it answers is "can this draw at all", which is the one question
-- worth asking of an ability that is showing nothing.
function Textures.TestFire(key)
  local A = ns.AbilitySettings
  if not (A and type(key) == "string" and key ~= "") then
    return false, "not an ability key: " .. tostring(key)
  end
  -- Not "draw something and hope": a texture attributed to a key that names nothing answers a
  -- question nobody asked, in the one command whose job is to stop cues being misattributed. The
  -- All abilities row is allowed through by name -- it is what its own Preview button previews.
  if key ~= ALL and not known(key) then
    return false, "no ability " .. key .. " on this character"
  end
  local now = ns.now and ns.now() or 0
  flashUntil[key] = now + Textures.FLASH_SECONDS
  shownAt[key] = now
  layout()
  local label = (ns.Display and ns.Display.spellName and ns.Display.spellName(key)) or key
  if not A.channelOn(key, "texture") then
    label = label .. " (the texture is off for it — it will not appear in play)"
  end
  return true, label
end

ns.Textures = Textures
return Textures
