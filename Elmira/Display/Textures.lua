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

-- The shipped shapes (`tools/gen_shapes.lua` draws them). White with the shape in the alpha
-- channel, so one file tints to any colour the player picks. Ordered for the dropdown.
Textures.SHAPES = { "ring", "disc", "square", "diamond", "arrow", "star", "bar", "chevron" }
Textures.SOURCES = { "icon", "shape", "custom" }
Textures.PLACEMENTS = { "row", "centre", "custom" }
-- All five of Core/Track's events, unlike the screen edge's two: a shape the size of a coin on a
-- fixed spot is not the strobe a full-screen flash is, so the three moments ADR-0009 keeps off the
-- edge are exactly the ones this is for.
Textures.EVENTS = { "suggested", "ready", "used", "active", "expiring" }
-- Which of them are STATES rather than instants. Read by Fire and by Sync, so the two can never
-- disagree about which events have an ending to wait for.
Textures.HELD = { suggested = true, active = true }
Textures.FLASH_SECONDS = 1.5
-- AB4-D1, the owner's "growing textures": what the swipe over the texture measures. Ordered for
-- the dropdown, "none" first because it is the shipped answer.
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
-- AB4-D1. Core/Track's own memory table (`[key] = { cooldown =, cooldownFull =, remaining =,
-- duration = ... }`) as of the last Sync, and the clock reading it was taken at. Held rather than
-- passed to `Fire`, because a texture that appears the instant its event fires has to be filled in
-- that same frame and only the render loop is holding the numbers by then. One declaration for the
-- two: separately, deleting either only makes it a global, which no test can see.
local fillMemory, fillNow = nil, 0

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

-- What the swipe measures. Same shape as `placementOf`, and for the same reason: a value that
-- arrived in an import or a class pack's defaults and that this code does not understand must read
-- as the shipped answer rather than as a fill nothing can compute.
function Textures.fillOf(e)
  local fill = e and e.fill
  return oneOf(Textures.FILLS, fill) and fill or "none"
end

-- Textures.fillTiming(e, row, now) -> start, duration, reverse  (or nil)
--
-- The whole of AB4-D1's arithmetic, pure and on its own so a spec can hold it: the client animates
-- a `Cooldown` swipe itself from a START and a LENGTH, and what Core/Track reports is a REMAINING
-- and a length -- so the start is back-dated by however much has already elapsed.
--
-- `row` is one row of Track's memory. nil is a real answer and the caller clears the swipe on it:
-- an ability that is not on cooldown, a buff with no duration, or a client that has never observed
-- how long this cooldown lasts (docs/07 §9.1) has no progress to draw, and drawing a full circle
-- for it would say "just started" about something that is not running at all.
--
-- `reverse` differs between the two on purpose. A cooldown reads the way every cooldown in the game
-- reads -- the dark wedge shrinks away as the ability comes back. A buff drains the other way, so
-- the LIT part of the texture is what is left of it: a shape that shrinks as the buff runs out is
-- the thing the owner asked for ("growing textures"), and a buff drawn like a cooldown would grow
-- while the buff was disappearing.
function Textures.fillTiming(e, row, now)
  local fill = Textures.fillOf(e)
  if fill == "none" or type(row) ~= "table" then return nil end
  local remaining, duration = row.cooldown, row.cooldownFull
  if fill == "buff" then remaining, duration = row.remaining, row.duration end
  remaining, duration = tonumber(remaining) or 0, tonumber(duration) or 0
  if remaining <= 0 or duration <= 0 then return nil end
  -- A reading taken a moment after the duration was observed can exceed it (a cooldown extended by
  -- a rune, a buff refreshed to longer than the length last seen). Clamped rather than trusted: a
  -- start in the future draws an empty swipe that never moves.
  if remaining > duration then remaining = duration end
  return (tonumber(now) or 0) - (duration - remaining), duration, fill == "buff"
end

-- Where this texture sits. An unknown answer is "with the others", never nothing: a placement the
-- code does not understand would otherwise leave the frame unanchored, which draws it at the
-- bottom-left corner of the screen with no hint why.
function Textures.placementOf(e)
  local place = e and e.place
  return oneOf(Textures.PLACEMENTS, place) and place or "row"
end

-- Textures.texturePath(e, key) -> the file to draw, or nil
--
-- nil is a real answer and the panel says so: an ability whose icon this client cannot resolve, or
-- a custom path left empty. The frame falls back to the ring so the cue is still visible, but the
-- diagnostic and the Texture tab report the nil, because "you typed the path wrong" and "it is
-- working" must not look the same.
function Textures.texturePath(e, key)
  local source = (e and oneOf(Textures.SOURCES, e.source) and e.source) or "icon"
  if source == "shape" then
    local shape = (e and oneOf(Textures.SHAPES, e.shape) and e.shape) or "ring"
    return MEDIA .. "shape_" .. shape
  end
  if source == "custom" then
    local path = tostring((e and e.path) or "")
    return path ~= "" and path or nil
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
  -- AB4-D1: the progress swipe. A `Cooldown` region is the client's own radial wipe, and using it
  -- rather than drawing one means the ANIMATION is the client's too -- one SetCooldown call and it
  -- runs at the client's frame rate instead of ours at 10 Hz.
  --
  -- No capability flag (the fixed tail's "a Display module already allowed to touch frames"): every
  -- call below is made unconditionally by shared, non-retail-gated code in the addons installed on
  -- this very client -- LibActionButton-1.0 creates a `CooldownFrameTemplate` region and calls
  -- SetSwipeColor/SetDrawSwipe/SetDrawEdge/SetDrawBling on it in its button constructor, and
  -- ElvUI's Game/Shared/General/Cooldowns.lua calls SetReverse and SetHideCountdownNumbers. Read
  -- off the live 1.15 install 2026-09-09, not from memory.
  local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
  -- The two the fill cannot exist without: with no way to say how far round the sweep has got, or
  -- which way it runs, there is nothing worth keeping. Dropped WHOLE rather than half-built, so
  -- `paintFill` finds no swipe and the texture itself is untouched.
  if cd and not (cd.SetCooldown and cd.SetReverse) then cd = nil end
  f.swipe = cd
  if cd then
    -- Each of the six guarded on its own. `Cooldown` is a frame TYPE this addon had never used
    -- before AB4, and a client missing one of these would otherwise throw out of the middle of
    -- newFrame() -- taking down every indicator texture, on every ability, to lose one decoration.
    if cd.SetAllPoints then cd:SetAllPoints() end
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end  -- this is a shape, not a timer
    if cd.SetDrawBling then cd:SetDrawBling(false) end   -- the "it is ready!" starburst, on a non-button
    if cd.SetDrawEdge then cd:SetDrawEdge(false) end
    if cd.SetSwipeColor then cd:SetSwipeColor(0, 0, 0, 0.7) end
    if cd.Hide then cd:Hide() end
  end
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
  -- AB4-D1: forget this ability's swipe before the frame goes back in the pool. A frame still
  -- remembering the last start and length would let the NEXT ability's identical-looking numbers
  -- be skipped as "already pushed", and the swipe it inherited would be running to somebody else's
  -- cooldown.
  if f.swipe then
    f.fillStart, f.fillDuration, f.fillReverse = nil, nil, nil
    f.swipe:SetCooldown(0, 0)
    f.swipe:Hide()
  end
  pool[#pool + 1] = f
end

-- One texture's swipe, from Core/Track's numbers (AB4-D1).
--
-- IDEMPOTENT ON PURPOSE. This runs on every tick for every texture on screen, and `SetCooldown`
-- RESTARTS the client's animation -- calling it ten times a second would freeze the swipe at its
-- opening frame forever, which looks exactly like a fill that works and measures nothing. So the
-- start and length last pushed are remembered on the frame and a re-push only happens when they
-- genuinely move: a cooldown ticking down keeps the same start (`now - elapsed` is constant), while
-- a cooldown that was re-triggered jumps by its whole length.
local FILL_EPSILON = 0.25
local function paintFill(f, key, e)
  local cd = f.swipe
  -- No swipe on this client (newFrame dropped it): the texture still draws, it simply cannot say
  -- how much time is left. Losing a decoration must never cost the indicator itself.
  if not cd then return end
  local start, duration, reverse = Textures.fillTiming(e, fillMemory and fillMemory[key], fillNow)
  if not start then
    -- Only when there is something to clear. A frame that has never filled must not open by
    -- telling the client about a cooldown of zero.
    if f.fillDuration then
      f.fillStart, f.fillDuration, f.fillReverse = nil, nil, nil
      cd:SetCooldown(0, 0)          -- the client's own "there is no cooldown here" (start 0, len 0)
      cd:Hide()
    end
    return
  end
  if f.fillDuration == duration and f.fillReverse == reverse
     and math.abs((f.fillStart or 0) - start) < FILL_EPSILON then
    return
  end
  f.fillStart, f.fillDuration, f.fillReverse = start, duration, reverse
  cd:SetReverse(reverse)
  cd:Show()
  cd:SetCooldown(start, duration)
end

local function paint(f, key, e)
  local size = Textures.sizeOf(e)
  f:SetSize(size, size)
  -- The ring stands in for a path that resolved to nothing, so the cue is never silently invisible;
  -- `describe` and the Texture tab still report the nil, so it is never silently WRONG either.
  f.icon:SetTexture(Textures.texturePath(e, key) or (MEDIA .. "shape_ring"))
  local c = e.color
  if type(c) == "table" then
    f.icon:SetVertexColor(c.r or 1, c.g or 1, c.b or 1)
  else
    f.icon:SetVertexColor(1, 1, 1)
  end
  f:SetAlpha(math.max(0.05, math.min(1, tonumber(e.alpha) or 1)))
  paintFill(f, key, e)
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
  -- AB4-D1: the numbers a fill is drawn from, kept for `Fire` -- which shows a texture in the same
  -- frame its event happened and has no memory of its own to fill it from.
  fillMemory, fillNow = memory, now
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
  -- AB4-D1, and AFTER the layout: a fill has to follow the state every tick, not only on the ticks
  -- the SET of textures changed. `layout` runs a handful of times a fight; a buff whose swipe was
  -- painted once when it appeared and never again would sit at "just cast" while the buff ran out.
  -- Cheap by construction -- at most a few textures are ever on screen, and `paintFill` pushes
  -- nothing to the client unless the numbers really moved.
  for key, f in pairs(frames) do paintFill(f, key, A.effective(key, "texture")) end
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
      local f = frames[key]
      out.textures[#out.textures + 1] = {
        key = key, enabled = on, source = e.source, path = Textures.texturePath(e, key),
        size = Textures.sizeOf(e), place = Textures.placementOf(e), events = events,
        shownAt = shownAt[key], visible = (held[key] or flashUntil[key]) ~= nil,
        -- AB4-D1: what the swipe is SET to, and what it is actually running. The two differ in
        -- exactly the case worth reporting -- a fill picked for an ability whose cooldown or buff
        -- this client has no numbers for draws nothing, and an empty texture is how that looks.
        fill = Textures.fillOf(e), filling = (f and f.fillDuration) or nil,
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
