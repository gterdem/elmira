-- Elmira/Display/Queue.lua — the suggestion strip (PRD F5).
--
-- N icons: slot 1 is what to press now, the rest are what the simulation projects after it. Plain
-- frames only — never a secure template, never SetAttribute, never a protected call (hard rule 1).
-- This addon displays; it does not press anything, and nothing here may become able to.
--
-- The frame is movable and its anchor persists, because the setup wizard is M4: without `/elm lock`
-- M3 would ship a strip you can see and cannot move.
--
-- ADR-0015 §3: the strip NEVER glows. It says "this one" with size and opacity and says "something
-- changed" with motion; the single attention signal belongs to the action bar, where the hand
-- already is. What the sizes and the motions ARE lives in Core/Transition.lua -- this file only
-- applies them to frames.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Queue = {}
local container, buttons, ghosts = nil, {}, {}
local MAX_SLOTS = 5     -- PRD F5: 1-5, default 3

-- PE9-D1/D3: both labels drawn ON an icon are OUTLINED and sized from the slot they sit on.
-- Outline first: it is what makes text survive over arbitrary spell art, which is why every action
-- bar in the game outlines its hotkeys. Proportional second: slot 1 is 30% larger than the rest
-- (Core/Transition.LAYOUT.firstScale), so a fixed font object made the keybind proportionally the
-- SMALLEST label on the biggest icon -- backwards from the hierarchy the sizes exist to carry.
-- No font-size slider: `container:SetScale` already grows the whole strip, and this file's history
-- has the "two sliders both labelled Scale" scar.
local KEYBIND_RATIO = 0.30
local WAIT_RATIO = 0.28
local MIN_FONT = 8
-- What "one global cooldown" is when `gcdDuration` answers 0, which it does whenever nothing is
-- currently showing a GCD-length cooldown -- i.e. most of the time out of combat.
local FALLBACK_GCD = 1.5

-- What the strip remembers between renders.
--
-- `rendered` is what it last PAINTED, as {spell, item} rows -- the input to the next transition
-- plan. A snapshot rather than the queue table itself: Simulation reuses its tables between ticks,
-- so holding the reference would compare a queue against itself and animate nothing, forever.
--
-- `pendingCast` is the spell the player just cast, parked by Queue.noteCast until the next render
-- consumes it. One render, one pop: a cast left lying around pops an unrelated icon later.
-- `lastKey` is which build `rendered` belongs to. Display/Overlay.lua:216 carries the same guard for
-- the same reason: switching profile, fork or build means every icon on screen belonged to another
-- rotation, and sliding the new one's suggestions in from the old one's slots is a lie about what
-- moved. It is also why deleting the declaration below is invisible to the suite: the three would
-- become globals leaking between specs, but the key guard nils `rendered` on the first render of
-- every one of them, so no test can tell the two apart. luacheck is the gate that can.
local rendered, pendingCast, lastKey -- mutants: equivalent deletion only makes these globals
local pendingCastAt = nil -- mutants: equivalent deletion only makes it a global

-- D38: whether the placeholder is on screen right now, so its own click handler can answer without
-- asking the frame -- which a parent that is itself about to hide can misreport.
local placeholderShown = false -- mutants: equivalent deletion only makes it a global; luacheck catches that

-- How long a cast stays armed while the queue has not moved. `noteCast` forces a recompute so the
-- pop lands with the press, but that render usually happens BEFORE the spell's cooldown registers,
-- so the queue is still identical and there is nothing to pop. Clearing the cast there -- which is
-- what shipped -- meant the real change a fraction of a second later was drawn as an ordinary
-- shift, and the pop was never seen. Held instead, and spent when it is used.
--
-- One GCD is the bound: past that the queue moved for some other reason and this cast is stale.
Queue.CAST_WINDOW = 1.5

local function profile()
  return (ns.db and ns.db.profile) or ns.DB.defaults.profile
end

-- The three settings PE9-D4 added, read through one place each so a missing key (a profile that
-- predates them) reads as the default rather than as "off". The value STRINGS are shared with
-- Options/Options.lua's WAIT_LABELS / KEYBIND_LABELS, which is where they are named for humans.
local function waitMode(p) return p.waits or "gcd" end
local function keybindMode(p) return p.keybinds or "first" end

-- PE10. The three shape settings, each read through one place so a profile that predates them
-- reads as what shipped rather than as zero. Core/Transition owns what the values MEAN.
local function growOf(p) return ns.Transition.growth(p.grow) end
local function gapOf(p) return ns.Transition.spacing(p.spacing) end
local function depthOf(p) return math.max(1, math.min(MAX_SLOTS, p.depth or 3)) end

-- Re-fonts one label to the slot it sits on. The FILE comes from the fontstring's own template, so
-- a locale whose client ships a different default (zhCN, koKR) keeps its own glyphs; the client's
-- STANDARD_TEXT_FONT is the fallback for the same reason, rather than a hardcoded FRIZQT path.
local function sizeFont(fs, px)
  if not (fs and fs.SetFont and fs.GetFont) then return false end
  local file = fs:GetFont() or STANDARD_TEXT_FONT
  if not file then return false end
  local size = math.floor(px + 0.5)
  if size < MIN_FONT then size = MIN_FONT end
  fs:SetFont(file, size, "OUTLINE")
  return true
end

-- PE9-D1. One decimal below ten seconds, whole seconds above: "2.4s" is a number you act on,
-- "12.4s" is one you read as noise. math.floor rather than "%d" on a float, which Lua 5.1 truncates
-- silently and later versions reject outright.
function Queue.formatWait(seconds)
  if seconds >= 10 then return string.format("%ds", math.floor(seconds)) end
  return string.format("%.1fs", seconds)
end

-- PE9-D2. `usable` is IsUsableSpell, which answers false for out of mana AND for out of range; the
-- adapter's second return separates them. Only the RESOURCE case dims: a melee player running at a
-- target is out of range for a second or two every pull, and an icon strobing through that is worse
-- than no signal at all.
local function resourceBlocked(slot)
  if not (slot and slot.spell) then return false end
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  if not (state and state.usable) then return false end
  local ok, noResource = state:usable(slot.spell)
  return ok ~= true and noResource == true
end

-- Drop every captured countdown. Called wherever the strip leaves the screen, for the same reason
-- `rendered` is dropped there: coming back must look like arriving, and a target time captured
-- before a fight ended is a number about a cast that is never going to happen.
local function forgetWaits()
  for i = 1, MAX_SLOTS do
    local b = buttons[i]
    if b then b.waitUntil = nil end
  end
end

-- PE10-D2. How opaque the whole strip is right now. The CONTAINER's alpha, so it multiplies the
-- per-slot ramp (Transition.LAYOUT.alpha) instead of replacing it: slot 5 stays the faintest slot
-- of a faded strip exactly as it is the faintest slot of a solid one.
--
-- 1.0 is the default and means "no change", which is why the read is a plain multiplier rather than
-- a second switch: a player who never touches the slider cannot tell this code exists.
function Queue.fadeAlpha(p)
  local a = tonumber(p.oocAlpha)
  if not a or a >= 1 then return 1 end
  if a < 0.1 then a = 0.1 end
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  if state and state.inCombat and state:inCombat() == true then return 1 end
  return a
end

-- PE10-D2, the half that is easy to get wrong. The strip only RENDERS when the queue changes, which
-- in a steady rotation is seconds apart, so a fade applied at render time alone would sit at the
-- wrong opacity until the rotation happened to move -- this project's standing failure shape.
--
-- It is repainted from paintLive instead, which Display/Driver calls on every visible tick whose
-- queue came back unchanged. No event of its own: PLAYER_REGEN_DISABLED/ENABLED are already
-- registered once each in Core/Init and both already call Display.invalidate, so a combat
-- transition reaches the next tick within 100 ms. A second RegisterEvent on either would silently
-- destroy the first (Core/Init:138 records what that cost last time).
local function paintFade()
  if container then container:SetAlpha(Queue.fadeAlpha(profile())) end
end

-- Everything the strip redraws BETWEEN queue changes. Both of these are functions of the passing
-- moment rather than of the queue, and Render only runs when the queue MOVES -- which in a steady
-- rotation is seconds apart. Without this the countdown freezes at whatever it read when the queue
-- was last computed, which looks alive and is not.
local function paintLive(now)
  for i = 1, MAX_SLOTS do
    local b = buttons[i]
    if b and b.wait then
      local left = b.waitUntil and (b.waitUntil - now) or nil
      -- Clamped at zero and silent past it: a projection that has expired is not news, and a
      -- negative countdown is a lie about a cast that should already have happened.
      b.wait:SetText((left and left > 0) and Queue.formatWait(left) or "")
    end
  end
  -- Slot 1 only: slots 2+ are projections, and "will you have mana in four seconds" is not a
  -- question the live client can answer.
  local first = buttons[1]
  if first and first.icon and first.icon.SetDesaturated then
    first.icon:SetDesaturated(resourceBlocked(first.slot) and true or false)
  end
  paintFade()
end

-- Textures are presentation, not state, so they are read here rather than added to the State
-- contract — nothing in Core ever needs to know what a spell looks like.
local function iconFor(key, item)
  if item then
    local id = GetInventoryItemID and GetInventoryItemID("player", item)
    return id and GetItemIcon and GetItemIcon(id) or nil
  end
  return ns.Display and ns.Display.spellIcon(key) or nil
end

local function spellIDFor(key)
  local pack = ns.Display and ns.Display.currentPack()
  local data = pack and pack.spells and pack.spells[key]
  return data and data.id or nil
end

-- PE10-D1's hard requirement, and the only part of it a player would ever notice going wrong:
-- CHANGING THE GROWTH DIRECTION MUST NOT MOVE SLOT 1.
--
-- The saved anchor positions the container's BOX, and the box changes shape with the direction: a
-- strip grown right is 140x52 with slot 1 at its left end, the same strip grown up is 52x140 with
-- slot 1 at its bottom. Re-placing the same box point after a flip would slide the icon the player
-- spent time putting under their character halfway across the screen -- and nothing headless would
-- have noticed, because the anchor it saved was still the anchor it read back.
--
-- So the stored anchor keeps the meaning it has always had (the container's box, grown to the
-- RIGHT) and every other direction is PLACED with the difference folded in, so slot 1's centre
-- lands on the same pixel in all four. Nothing is rewritten on disk: the compensation is derived at
-- placement time, which is also what makes it survive a profile switch or an import, where no
-- setter runs to fix anything up.
--
-- These two tables are how far a named point of a WxH box is from that box's centre, as a fraction
-- of each side. An unknown point (nil from a frame that was never placed) reads as the centre.
local ANCHOR_FX = { LEFT = 0.5, TOPLEFT = 0.5, BOTTOMLEFT = 0.5,
                    RIGHT = -0.5, TOPRIGHT = -0.5, BOTTOMRIGHT = -0.5 }
local ANCHOR_FY = { TOP = -0.5, TOPLEFT = -0.5, TOPRIGHT = -0.5,
                    BOTTOM = 0.5, BOTTOMLEFT = 0.5, BOTTOMRIGHT = 0.5 }

-- Where slot 1's centre sits relative to the container's anchor POINT, for one growth direction.
local function slotOneOffset(point, depth, grow, gap)
  local slots, width, height = ns.Transition.layout(depth, grow, gap)
  return (ANCHOR_FX[point] or 0) * width + slots[1].x,
         (ANCHOR_FY[point] or 0) * height + slots[1].y
end

-- What to add to the saved offsets when placing, and to subtract from a dragged frame's when
-- saving. Zero for "right", so a default install's anchor arithmetic is untouched.
local function anchorShift(p)
  local point = p.anchor and p.anchor.point
  local depth, gap = depthOf(p), gapOf(p)
  local rx, ry = slotOneOffset(point, depth, "right", gap)
  local gx, gy = slotOneOffset(point, depth, growOf(p), gap)
  return rx - gx, ry - gy
end

local function placeContainer()
  if not container then return end
  local p = profile()
  local a = p.anchor or {}
  local dx, dy = anchorShift(p)
  container:ClearAllPoints()
  container:SetPoint(a.point or "CENTER", UIParent, a.relPoint or "CENTER",
                     (a.x or 0) + dx, (a.y or -150) + dy)
end

local function saveAnchor()
  if not container then return end
  local point, _, relPoint, x, y = container:GetPoint()
  local p = profile()
  if p and p.anchor then
    -- The point first: `anchorShift` reads it, and the drag may have re-anchored the frame by a
    -- different corner than the one it was placed with.
    p.anchor.point, p.anchor.relPoint = point, relPoint
    local dx, dy = anchorShift(p)
    p.anchor.x, p.anchor.y = (x or 0) - dx, (y or 0) - dy
  end
end

-- Hover "why" (PRD F18). Consumes the per-condition list Schema attaches to every compiled entry —
-- built at M2 so a recording could explain a rejected suggestion, and it turns out to be exactly what
-- this tooltip needs. Passing conditions in the palette's OK colour, failing ones in BAD.
--
-- The entry comes off the SLOT, not from a lookup into the compiled build. Simulation.queue already
-- carries the entry it picked (`slot.entry`); the previous version indexed `compiled.entries` by
-- `slot.index`, a field nothing has ever set, so the Why block was unreachable in every build and
-- the tooltip silently degraded to the plain spell tooltip.
local function showWhy(button)
  local slot = button.slot
  if not (slot and (slot.spell or slot.item)) or not GameTooltip then return end
  local L = ns.L or {}
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")

  local id = slot.spell and spellIDFor(slot.spell)
  if id and GameTooltip.SetSpellByID then
    GameTooltip:SetSpellByID(id)
  elseif slot.item and GameTooltip.SetInventoryItem then
    GameTooltip:SetInventoryItem("player", slot.item)
  else
    GameTooltip:SetText(tostring(slot.spell or slot.item))
  end

  -- Which rule fired. An entry with no label still gets a line: "this is Elmira talking, and it had
  -- no special reason" is information, and a tooltip that adds nothing at all reads as broken.
  -- Not `local _, buildKey = ns.Display and ns.Display.activeBuild()`: `and` truncates a call to its
  -- first return value, so the build key would silently always be nil. The same shape as the guards
  -- that hid `ns.now` and the drag registration.
  local buildKey
  if ns.Display and ns.Display.activeBuild then
    local _, key = ns.Display.activeBuild()
    buildKey = key
  end
  GameTooltip:AddLine(ns.Colors.wrap(ns.Colors.MUTED,
    slot.label or (L["Baseline"] or "Baseline")) ..
    (buildKey and ns.Colors.wrap(ns.Colors.MUTED, "  ·  " .. buildKey) or ""))

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(L["Why"] or "Why")
  local entry = slot.entry
  local conditions = entry and entry.conditions
  if conditions and #conditions > 0 then
    local state = ns.API and ns.API.GetState()
    for _, cond in ipairs(conditions) do
      local ok = cond.test and state and cond.test(state)
      local color = ok and ns.Colors.OK or ns.Colors.BAD
      GameTooltip:AddLine("  " .. ns.Colors.wrap(color, cond.label or "?"))
    end
  else
    -- An unconditional entry is not unexplained: it is showing because everything ranked above it
    -- was rejected or on cooldown. That is the whole answer, so say it.
    GameTooltip:AddLine("  " .. ns.Colors.wrap(ns.Colors.MUTED,
      L["No conditions — nothing above it was ready."] or "No conditions — nothing above it was ready."))
  end
  GameTooltip:Show()
end

-- A Translation displaces a frame from wherever it is anchored and snaps back when it finishes,
-- which is the opposite of "arrive somewhere". So a move anchors the button at the icon's OLD home,
-- translates the difference, and re-anchors at the new one when the animation ends -- the snap-back
-- then lands exactly where the icon already is. Without the re-anchor every slide would rubber-band.
local function settle(b)
  b:ClearAllPoints()
  b:SetPoint("CENTER", container, "CENTER", b.destX or 0, b.destY or 0)
end

-- Stop() before Play() assumes Stop does NOT fire OnFinished -- if it did, the settle handler would
-- re-anchor at the old destination and the new slide would overshoot from there. The vendored
-- LibCustomGlow relies on the same contract (Libs/LibCustomGlow-1.0.lua:539 releases a frame AFTER
-- Stop(), and :619 registers OnStop and OnFinished as separate scripts). Nothing headless can pin
-- this, so it is written down rather than assumed silently.
-- PE10-D1: both ends are full points now, not an x plus a rise. A shift used to slide along x and
-- nothing else, which is the right motion for exactly one of the four growth directions.
local function slide(b, fromX, fromY, toX, toY)
  b:ClearAllPoints()
  b:SetPoint("CENTER", container, "CENTER", fromX, fromY)
  b.slideMove:SetOffset(toX - fromX, toY - fromY)
  b.slide:Stop()          -- a queue can change again mid-slide; restart from the new origin
  b.slide:Play()
end

local function fadeIn(b, toAlpha)
  b.fadeIn:SetToAlpha(toAlpha)
  b.fade:Stop()
  b.fade:Play()
end

local function makeButton(index, parent)
  local b = CreateFrame("Frame", nil, parent)   -- NOT a Button, and never a secure template
  b:SetSize(ns.Transition.LAYOUT.base, ns.Transition.LAYOUT.base)

  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints()
  b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)    -- crop the stock icon border

  b.border = b:CreateTexture(nil, "OVERLAY")
  b.border:SetPoint("TOPLEFT", -1, 1)
  b.border:SetPoint("BOTTOMRIGHT", 1, -1)
  b.border:SetColorTexture(0, 0, 0, 0)

  b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
  b.cd:SetAllPoints()
  b.cd:SetDrawEdge(false)

  -- Top-right, the corner Blizzard and ElvUI both put hotkeys in, and near-white rather than
  -- Colors.MUTED (PE9-D3): a keybind is a label to READ, not a status to play down. The outline and
  -- the size come from Queue.Layout, which is the only place that knows how big this slot is.
  b.keybind = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.keybind:SetPoint("TOPRIGHT", 1, -1)
  b.keybind:SetTextColor(ns.Colors.LABEL.r, ns.Colors.LABEL.g, ns.Colors.LABEL.b)

  -- PE9-D1: how long until this suggestion happens. Bottom-LEFT, diagonally opposite the keybind,
  -- so the two can never collide however long either gets. Deliberately NOT a cooldown sweep: that
  -- radial is the game's universal "you cannot press this", and on a suggestion icon it would read
  -- as "unavailable" when it means "coming in three seconds".
  b.wait = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.wait:SetPoint("BOTTOMLEFT", 1, 1)
  b.wait:SetTextColor(ns.Colors.MUTED.r, ns.Colors.MUTED.g, ns.Colors.MUTED.b)

  -- The name of the RULE that produced this suggestion, under the icon (PRD F15). Says "Seal
  -- expiring" rather than just showing a Judgement icon, which is the difference between memorising
  -- a sequence and learning why the sequence is what it is. PE9-D5: gated on its own setting now,
  -- not on Learning mode -- it was the valuable third of that bundle and cost the whole lookahead.
  b.reason = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.reason:SetPoint("TOP", b, "BOTTOM", 0, -2)
  b.reason:SetTextColor(ns.Colors.HIGHLIGHT.r, ns.Colors.HIGHLIGHT.g, ns.Colors.HIGHLIGHT.b)
  b.reason:Hide()

  b:EnableMouse(true)   -- for the tooltip and the drag; there is no OnClick and never must be one
  b:SetScript("OnEnter", showWhy)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  -- The icons cover the container completely, and a mouse-enabled child consumes the drag before
  -- the parent ever sees it — so registering the drag on the container alone made the strip
  -- immovable while looking, in code, exactly like a movable frame. Every button forwards instead.
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", function() Queue.StartMoving() end)
  b:SetScript("OnDragStop", function() Queue.StopMoving() end)

  -- Motion, built ONCE per button and reused. An AnimationGroup allocated per queue change would
  -- be exactly the per-render garbage docs/01 §7 exists to forbid, ten times a second.
  b.slide = b:CreateAnimationGroup()
  b.slideMove = b.slide:CreateAnimation("Translation")
  b.slideMove:SetDuration(ns.Transition.DURATION)
  b.slideMove:SetSmoothing("OUT")      -- decelerating into place; a linear slide reads as a jump
  b.slide:SetScript("OnFinished", function() settle(b) end)

  b.fade = b:CreateAnimationGroup()
  b.fadeIn = b.fade:CreateAnimation("Alpha")
  b.fadeIn:SetFromAlpha(0)
  b.fadeIn:SetDuration(ns.Transition.DURATION)

  b.index = index
  return b
end

-- A departing icon is drawn by a GHOST, not by the button: the button belongs to a slot and has
-- already been repainted with whatever moved into it. One ghost per slot, so a queue that drops
-- three icons at once shows all three leaving.
local function makeGhost(parent)
  local g = CreateFrame("Frame", nil, parent)
  -- Under the slot buttons: for 150 ms the icon that left overlaps the one that slid into its
  -- place, and the arriving suggestion is the one the player needs to be able to read.
  g:SetFrameLevel(parent:GetFrameLevel())
  g.icon = g:CreateTexture(nil, "ARTWORK")
  g.icon:SetAllPoints()
  g.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  g:Hide()

  g.anim = g:CreateAnimationGroup()
  g.grow = g.anim:CreateAnimation("Scale")
  g.grow:SetDuration(ns.Transition.DURATION)
  g.dim = g.anim:CreateAnimation("Alpha")
  g.dim:SetFromAlpha(1)
  g.dim:SetToAlpha(0)
  g.dim:SetDuration(ns.Transition.DURATION)
  g.anim:SetScript("OnFinished", function() g:Hide() end)
  return g
end

-- One icon leaving. `pop` starts oversized and settles back as it fades -- the confirmation that
-- the addon agreed with a press; anything else shrinks away, because a correction should not
-- claim credit for a cast that never happened.
local function playGhost(row, slots)
  local from, ghost = slots[row.from], ghosts[row.from]
  -- A slot that no longer exists: the queue can shrink between renders (the depth setting, or a
  -- rotation that ran out of suggestions), and the icon that left has nowhere to leave FROM.
  if not (from and ghost and row.slot) then return end
  local startScale, animScale = ns.Transition.ghostScale(row.kind)
  local size = from.size * startScale
  ghost:SetPoint("CENTER", container, "CENTER", from.x, from.y)
  ghost:SetSize(size, size)
  ghost.icon:SetTexture(iconFor(row.slot.spell, row.slot.item))
  ghost.grow:SetScale(animScale, animScale)
  ghost:SetAlpha(1)
  ghost:Show()
  ghost.anim:Stop()
  ghost.anim:Play()
end

-- One icon arriving or moving. `stay` deliberately does nothing: an icon that did not move must not
-- twitch, or the strip is in constant motion and motion stops meaning anything.
local function playOp(b, op, slots, index, grow)
  local here = slots[index]
  if op.kind == "shift" then
    local from = slots[op.from]
    if not from then return end     -- shifted in from a slot the strip no longer has
    slide(b, from.x, from.y, here.x, here.y)
  elseif op.kind == "enter" then
    -- A promotion drops in from one icon away ACROSS the strip: far enough to read as arriving from
    -- outside it, close enough to finish inside the 150 ms, and perpendicular to the growth axis in
    -- every direction so it never looks like an ordinary shift (Transition.promoteOffset). A tail
    -- arrival only fades, because an icon sliding in every GCD is motion that carries no news.
    if op.promote then
      local dx, dy = ns.Transition.promoteOffset(grow, here.size)
      slide(b, here.x + dx, here.y + dy, here.x, here.y)
    end
    fadeIn(b, here.alpha)
  end
end

function Queue.frame() return container end

-- PE11-D5. Positioning mode: the Queue page's "Position the Strip" button puts the strip on screen
-- with a sample of icons and lets it be dragged where it would normally be hidden -- by default the
-- strip does not exist out of combat with no target, so positioning it meant finding a target dummy.
--
-- A TEMPORARY OVERRIDE, NOT A SETTING, and the distinction is the whole design: nothing here writes
-- the profile. The obvious shape -- capture `locked`, write false, put it back on exit -- loses the
-- player's lock for good the moment they /reload, disconnect or crash mid-drag, because what is on
-- disk at that instant is the temporary value. A module-local boolean instead: it starts false on
-- every load, so there is no state a reload can strand.
local positioning = false
-- Forward-declared: Queue.Layout repaints the sample when it runs during positioning, and Layout is
-- defined above the painter that knows what a sample looks like.
local paintSample
function Queue.isPositioning() return positioning end

-- Public because every icon forwards its drag here. Both guard on `locked` rather than the caller
-- doing it: one place decides whether the strip may move.
function Queue.StartMoving()
  if not container then return false end
  -- Positioning mode is the one thing that may drag a LOCKED strip. That is what it is for, and it
  -- hands the lock back untouched because it never wrote it.
  if profile().locked and not positioning then return false end
  container:StartMoving()
  return true
end

function Queue.StopMoving()
  if not container then return false end
  container:StopMovingOrSizing()
  saveAnchor()
  return true
end

function Queue.Create()
  if container then return container end
  local p = profile()
  container = CreateFrame("Frame", "ElmiraQueue", UIParent)
  placeContainer()
  container:SetScale(p.scale or 1.0)
  container:SetMovable(true)
  container:SetClampedToScreen(true)
  container:EnableMouse(true)   -- without this the frame receives no drag events at all
  container:RegisterForDrag("LeftButton")
  container:SetScript("OnDragStart", Queue.StartMoving)
  container:SetScript("OnDragStop", Queue.StopMoving)

  -- Only visible while unlocked: something has to be draggable, and an always-on backdrop is clutter.
  container.grip = container:CreateTexture(nil, "BACKGROUND")
  container.grip:SetPoint("TOPLEFT", -2, 2)
  container.grip:SetPoint("BOTTOMRIGHT", 2, -2)
  container.grip:SetColorTexture(ns.Colors.BRAND.r, ns.Colors.BRAND.g, ns.Colors.BRAND.b, 0.25)
  -- Reflects the SAVED state: reloading while unlocked used to bring the strip back with no grip,
  -- so `/elm lock` had to be pressed twice to get it visible again.
  if p.locked then container.grip:Hide() else container.grip:Show() end

  for i = 1, MAX_SLOTS do buttons[i] = makeButton(i, container) end
  for i = 1, MAX_SLOTS do ghosts[i] = makeGhost(container) end

  -- D38: the strip's own nudge while nothing is chosen yet. A plain child rather than a button
  -- template -- the whole container is already mouse-enabled for the drag above, so the click is
  -- caught there instead of on a second frame that would have to be sized and layered separately.
  container.placeholder = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  container.placeholder:SetPoint("LEFT", container, "LEFT", 4, 0)
  container.placeholder:SetText(ns.L and ns.L["Elmira: no rotation yet. Click to choose."]
    or "Elmira: no rotation yet. Click to choose.")
  container.placeholder:Hide()
  container:SetScript("OnMouseUp", function(_, button)
    -- `placeholderShown` rather than `container.placeholder:IsShown()`: WidgetScript visibility can
    -- lie about a PARENT that is itself hidden, and this is the one flag Render() already computes.
    if button == "LeftButton" and placeholderShown and ns.Options then
      ns.Options.Open("rotation")
    end
  end)

  Queue.Layout()
  return container
end

-- D38: shown only while NOTHING is chosen (`profile.activeBuild` falsy, the same signal the
-- first-run popup gates on), behind its own toggle (default on), and never in combat -- a click
-- target sitting where the queue would be is not something to discover mid-pull.
local function wantsPlaceholder(p)
  if p.activeBuild then return false end
  if p.showPlaceholder == false then return false end
  local state = ns.API and ns.API.GetState and ns.API.GetState()
  return not (state and state:inCombat() == true)
end

-- PRD F15. A preset, deliberately not a mode: it writes depth and scale as real settings the user
-- can go on to change, rather than overriding them invisibly while the options still show the old
-- values. Returns what it changed so the caller can say so out loud.
-- PE9-D5: the rule name is no longer part of the MODE, it is a setting of its own that this preset
-- switches on. It was the valuable third of the bundle and the only way to get it was to give up
-- the lookahead entirely -- so the only way to see reasons in combat was to blind yourself to what
-- was coming. Learning mode itself is unchanged: still one icon, still 140%, still writes real
-- settings the user can go on to change rather than overriding them invisibly.
-- PE12 (owner, 2026-09-09): switching it back OFF now puts your settings back. A preset that only
-- goes one way makes the player pay to have looked -- they turn it on to read a few suggestions and
-- are left to remember, by hand, what their strip used to be.
--
-- The prior values live in the PROFILE, not a local: a `/reload` between switching it on and off
-- would otherwise lose them, which is the one moment the player is relying on us to remember.
--
-- The restore is conditional, and that condition is the whole design. A value is only put back if it
-- is STILL exactly what the preset wrote -- meaning the player has not touched it since. If they
-- widened the strip to 180% while learning, that is their setting now, and handing it back to the
-- pre-learning value would be this toggle overwriting a deliberate choice. Untouched settings are
-- ours to restore; changed ones are theirs to keep.
local PRESET = { depth = 1, scale = 1.4, showReason = true }

function Queue.ApplyLearningPreset(on)
  local p = profile()
  local was = p.learning == true
  p.learning = on and true or false

  if on then
    -- Only on the OFF -> ON edge. Turning it on while already on would capture the preset's own
    -- values as the "prior", quietly destroying the real ones.
    if not was then
      p.learningPrior = { depth = p.depth, scale = p.scale, showReason = p.showReason == true }
    end
    p.depth = PRESET.depth   -- one answer at a time; a queue teaches sequence, not reasoning
    p.scale = PRESET.scale
    p.showReason = PRESET.showReason
    return { depth = PRESET.depth, scale = PRESET.scale, showReason = PRESET.showReason }
  end

  local prior = p.learningPrior
  p.learningPrior = nil
  if not prior then return nil end   -- never switched on by us (a hand-edited or imported profile)

  local restored
  for key, presetValue in pairs(PRESET) do
    local current = p[key]
    if key == "showReason" then current = current == true end
    if current == presetValue and prior[key] ~= presetValue then
      p[key] = prior[key]
      restored = restored or { restored = true }
      restored[key] = prior[key]
    end
  end
  return restored
end

function Queue.Layout()
  if not container then return end
  local p = profile()
  local depth = depthOf(p)
  local slots, width, height = ns.Transition.layout(depth, growOf(p), gapOf(p))
  container:SetScale(p.scale or 1.0)
  -- The cross-axis measurement is the FIRST slot's size, not the base: sizing the container to the
  -- small icons clips the one icon the strip exists for.
  container:SetSize(width, height)
  -- PE10-D1: the box just changed shape, so where it has to be placed for slot 1 to stay put
  -- changed with it. Layout is the one thing that runs on every settings change, which makes it
  -- the only place a direction, depth or spacing change can reach the anchor.
  placeContainer()
  for i = 1, MAX_SLOTS do
    local b = buttons[i]
    b:ClearAllPoints()
    if i <= depth then
      -- Slot 1 is the answer; the rest are context. Size and opacity carry that, so the eye lands on
      -- the right icon without needing to read anything -- and without anything lighting up.
      b.destX, b.destY = slots[i].x, slots[i].y
      b:SetPoint("CENTER", container, "CENTER", slots[i].x, slots[i].y)
      b:SetSize(slots[i].size, slots[i].size)
      b:SetAlpha(slots[i].alpha)
      -- PE9-D3: here rather than in makeButton, because the slot's size is only known once depth
      -- is. Layout is the one thing that runs on every settings change, which is the only way a
      -- slot's size can move.
      sizeFont(b.keybind, slots[i].size * KEYBIND_RATIO)
      sizeFont(b.wait, slots[i].size * WAIT_RATIO)
      b:Show()
    else
      b:Hide()
    end
  end
  -- PE11-D5: the sample follows the settings, because Layout is what every settings change runs and
  -- it can reveal a slot that was hidden -- a deeper strip, a different direction. Without this,
  -- changing the size while positioning leaves blank squares in the middle of the thing being placed.
  if positioning then paintSample() end
end

-- PE11-D5. What the strip shows while it is being positioned. Real icons off the active rotation
-- when there is one -- the point of the mode is to judge how the strip SITS, and a row of blanks is
-- not the thing being placed -- and flat brand-coloured squares when there is not, rather than an
-- `Interface\Icons\...` path written from memory (Core/Init:464 records why those are unsafe here:
-- Classic Era ships a subset of retail's icons and a missing one draws nothing at all).
local function sampleKeys()
  local out = {}
  local compiled = ns.Display and ns.Display.activeBuild and ns.Display.activeBuild()
  for _, entry in ipairs((compiled and compiled.entries) or {}) do
    if type(entry.spell) == "string" then
      out[#out + 1] = entry.spell
      if #out >= MAX_SLOTS then break end
    end
  end
  return out
end

function paintSample()
  local keys = sampleKeys()
  local depth = depthOf(profile())
  for i = 1, MAX_SLOTS do
    local b = buttons[i]
    -- No `slot`: hovering a sample icon must not open a "why this suggestion" tooltip about a
    -- suggestion nothing is making. Everything else a real render draws on a slot goes with it.
    b.slot, b.waitUntil = nil, nil
    b.keybind:SetText("")
    b.wait:SetText("")
    b.reason:Hide()
    b.cd:Clear()
    if b.icon.SetDesaturated then b.icon:SetDesaturated(false) end
    if i <= depth then
      local tex = keys[i] and iconFor(keys[i], nil)
      if tex then
        b.icon:SetTexture(tex)
      else
        b.icon:SetColorTexture(ns.Colors.BRAND.r, ns.Colors.BRAND.g, ns.Colors.BRAND.b, 0.8)
      end
      b:Show()
    else
      b:Hide()
    end
  end
end

-- Enter positioning mode. Sizes and places the buttons through Queue.Layout, so the sample is the
-- real strip at the real settings -- the same icons, sizes, spacing and direction the player will
-- see in a fight.
function Queue.StartPositioning()
  if not container then Queue.Create() end
  if not container or positioning then return false end
  positioning = true
  -- The grip is the drag handle and is normally hidden while locked. Shown directly rather than
  -- through SetLocked, which would write `locked` to the profile.
  if container.grip then container.grip:Show() end
  Queue.Layout()
  paintSample()
  container.placeholder:Hide()
  placeholderShown = false
  -- Never the out-of-combat fade: you cannot place what you can barely see.
  container:SetAlpha(1)
  container:Show()
  return true
end

-- Leave it, and give the strip back to the render loop.
function Queue.StopPositioning()
  if not positioning then return false end
  positioning = false
  -- Back to whatever the SAVED lock says -- which this mode never changed.
  if container and container.grip then
    if profile().locked then container.grip:Hide() else container.grip:Show() end
  end
  -- Hidden HERE rather than left to the next render, and this is the line that keeps the mode
  -- temporary. The driver only repaints when the queue CHANGES and does not tick at all while the
  -- display is switched off, so handing the strip back without hiding it is exactly how a preview
  -- becomes a strip stuck on screen with no way to dismiss it.
  if container then container:Hide() end
  rendered, pendingCast, pendingCastAt, placeholderShown = nil, nil, nil, false
  forgetWaits()
  -- Repaint from scratch: the buttons are carrying sample art, and the next ordinary render must
  -- not animate out of a state the rotation was never in.
  if ns.Display and ns.Display.refresh then ns.Display.refresh() end
  return true
end

-- PE10-D4, "Match my action bars". Both ends of the slider on the Queue page, so a computed scale
-- can never leave the panel showing a value the slider cannot represent.
Queue.SCALE_MIN, Queue.SCALE_MAX = 0.5, 2.0

-- Every spell the strip could be showing, best candidate first: what is on screen right now, then
-- anything the active rotation can suggest. Only used to find ONE button to measure -- all the
-- buttons on a bar are the same size, so which spell answers does not matter, only that some spell
-- the player actually uses is on a visible bar.
local function measurableKeys()
  local keys, seen = {}, {}
  local function add(key)
    if type(key) == "string" and not seen[key] then
      seen[key] = true
      keys[#keys + 1] = key
    end
  end
  for _, slot in ipairs((ns.Display and ns.Display.currentQueue) and ns.Display.currentQueue() or {}) do
    add(slot.spell)
  end
  if ns.Display and ns.Display.activeBuild then
    local compiled = ns.Display.activeBuild()
    for _, entry in ipairs((compiled and compiled.entries) or {}) do add(entry.spell) end
  end
  return keys
end

-- Sets the strip's scale so slot 1's icon is drawn the same size as a real action-bar button.
--
-- Returns the scale it wrote, or nil and a reason. Nil MUST leave the setting alone: a button that
-- silently applies a made-up number is worse than one that says it could not find a bar, because
-- the player then has to undo something they cannot see the cause of.
--
-- The arithmetic is in SCREEN pixels on both sides, which is the only place the two are comparable.
-- Slot 1 is drawn at `base * firstScale` in the container's coordinates, and the container is a
-- child of UIParent, so it lands on screen at that times UIParent's effective scale times the
-- setting we are solving for.
function Queue.matchBarScale()
  local size = ns.BarGlow and ns.BarGlow.buttonSize and ns.BarGlow.buttonSize(measurableKeys())
  if not size then return nil, "no button" end
  local parent = 1
  if UIParent and type(UIParent.GetEffectiveScale) == "function" then
    local ok, s = pcall(UIParent.GetEffectiveScale, UIParent)
    if ok and type(s) == "number" and s > 0 then parent = s end
  end
  local slotOne = ns.Transition.LAYOUT.base * ns.Transition.LAYOUT.firstScale
  local scale = size / (slotOne * parent)
  -- To a whole percent, which is exactly what the slider shows (`isPercent`), so the number in the
  -- panel afterwards is the number that was applied. A third of a pixel is not worth a value the
  -- control cannot display.
  scale = math.floor(scale * 100 + 0.5) / 100
  if scale < Queue.SCALE_MIN then scale = Queue.SCALE_MIN end
  if scale > Queue.SCALE_MAX then scale = Queue.SCALE_MAX end
  profile().scale = scale
  return scale
end

function Queue.SetLocked(locked)
  -- PE11-D5: an explicit lock decision ends positioning mode, and wins. Without this, "Lock all
  -- positions" would report a locked strip that was still draggable, still on screen and still
  -- showing its grip. A no-op when nothing is being positioned, and it cannot recurse: it is the
  -- one path out of the mode that does not touch the lock.
  Queue.StopPositioning()
  -- PE13-D2: the on-screen message's move mode is the same kind of temporary override of the same
  -- lock, so the same decision ends it -- here rather than in the options panel, because /elm lock
  -- is a lock decision too and it never went near the panel. pcall because a MessageFrame missing
  -- Clear() must not be the reason the lock is not stored (Announcers.lua documents that risk).
  if ns.Announcers and ns.Announcers.StopMoving then
    local ok, err = pcall(ns.Announcers.StopMoving)
    if not ok and ns.log then
      ns.log("could not leave move mode when positions were locked: %s", tostring(err))
    end
  end
  local p = profile()
  p.locked = locked and true or false
  if container and container.grip then
    if p.locked then container.grip:Hide() else container.grip:Show() end
  end
  return p.locked
end

function Queue.isLocked() return profile().locked and true or false end

-- Which spell key an id belongs to, cached per pack. Classic gives every RANK its own spell id and
-- the pack ships one id per ability, so the id the client reports for a cast usually is NOT the
-- pack's id -- the same rank mismatch that stopped the bar glow finding buttons. Names have no rank.
local castKeys, castNames, castPack -- mutants: equivalent deletion only makes these globals
function Queue.keyForSpellID(id)
  local pack = ns.Display and ns.Display.currentPack()
  if not (pack and id) then return nil end
  if castPack ~= pack then
    castKeys = ns.spellKeyByID and ns.spellKeyByID(pack) or {}
    castNames = {}
    for key, data in pairs(pack.spells or {}) do
      local name = type(data) == "table" and data.id and GetSpellInfo and GetSpellInfo(data.id)
      if name and not castNames[name] then castNames[name] = key end
    end
    -- Only latch when the client actually answered. GetSpellInfo returns nil for a spell whose
    -- data has not streamed in yet; caching that empty index would silently drop every rank match
    -- for the rest of the session, which is the exact failure noteMissing exists to make audible.
    if next(castNames) then castPack = pack end
  end
  if castKeys[id] then return castKeys[id] end
  local name = GetSpellInfo and GetSpellInfo(id)
  return name and castNames[name] or nil
end

-- The player cast something. Called from Core/Init's UNIT_SPELLCAST_SUCCEEDED handler; the only
-- thing the strip does with it is tell a CAST apart from a PROMOTION on the next change, which is
-- the difference between "you pressed it" and "the rotation changed its mind".
function Queue.noteCast(spellID)
  -- Nothing downstream of this can be seen when the strip is hidden or still, and the invalidate
  -- below forces a recompute -- once per global cooldown, for nothing.
  local p = profile()
  if p.showQueue == false or p.animate == false then return false end
  local key = Queue.keyForSpellID(spellID)
  if not key then return false end
  pendingCast = key
  local st = ns.API and ns.API.GetState and ns.API.GetState()
  pendingCastAt = (st and st.now) and st:now() or nil
  -- The queue itself is unchanged until the cooldown lands, and the tick that notices may be up to
  -- a tenth of a second away. Marking dirty makes the pop land with the press, not after it.
  if ns.Display and ns.Display.invalidate then ns.Display.invalidate() end
  return true
end

-- Renderer. Registered with Display/Driver, so it only runs when the queue actually changed.
-- `visible` comes from Display/Driver (Core/Visibility decides it). Passed in rather than read back
-- out of Display so this stays a function of its arguments -- and so the hidden case is one line in a
-- spec instead of a fake combat state.
function Queue.Render(queue, key, visible)
  if not container then return end
  -- PE11-D5: while the strip is being positioned it is showing a SAMPLE, not the rotation. Leaving
  -- here is what stops the next tick -- including the hidden-transition paint, which is the one the
  -- driver fires when there is no target -- from pulling the strip out from under the drag.
  if positioning then return end
  local p = profile()
  -- `enabled` is the whole display; `showQueue` is this strip alone. Different questions: a player
  -- who watches only the action-bar glow turns the strip off and must keep glowing, which is why
  -- the bar glow is its own renderer (Display/Glow.Render) and no longer released from here.
  if not p.enabled or p.showQueue == false then
    container:Hide()
    -- Forget what was on screen. Coming back should look like arriving, not like the icons
    -- teleported in from wherever the rotation happened to be when the strip went away.
    rendered, pendingCast, pendingCastAt, placeholderShown = nil, nil, nil, false
    forgetWaits()
    return
  end

  -- D38: the placeholder overrides the ordinary "no target, out of combat" hiding -- that is the
  -- whole point of it -- but never overrides `enabled`/`showQueue` above, and never shows in combat.
  placeholderShown = wantsPlaceholder(p)
  if visible == false and not placeholderShown then
    container:Hide()
    rendered, pendingCast, pendingCastAt = nil, nil, nil
    forgetWaits()
    return
  end
  container:Show()

  if placeholderShown then
    -- Full opacity, never the out-of-combat fade: the placeholder only ever appears out of combat,
    -- so fading it would mean the one message asking the player to pick a rotation is the one thing
    -- the fade could hide completely.
    container:SetAlpha(1)
    container.placeholder:Show()
    for i = 1, MAX_SLOTS do buttons[i]:Hide() end
    rendered, pendingCast, pendingCastAt = nil, nil, nil
    forgetWaits()
    return
  end
  container.placeholder:Hide()

  -- Only a real key counts: the hidden path passes nil, which is not a build change.
  if key ~= nil and key ~= lastKey then
    lastKey, rendered = key, nil
  end

  local depth = depthOf(p)
  local grow = growOf(p)
  local slots = ns.Transition.layout(depth, grow, gapOf(p))
  local plan = ns.Transition.plan(rendered, queue, pendingCast)
  -- Nothing animates on the first paint: there is no "before" for an icon to have come from.
  local animate = p.animate ~= false and rendered ~= nil
  local state = ns.API and ns.API.GetState()

  -- PE9-D1. The threshold is how long a GCD LASTS, never `gcd`, which is how much of one is LEFT --
  -- the trap Adapters/Interface.lua:31 was written to warn about, and the one that made every
  -- simulated slot come back at t=0. A 0 answer means "nothing is showing a global right now",
  -- which is a reading, not a duration, so it falls back to the base 1.5.
  local waits = waitMode(p)
  local binds = keybindMode(p)
  local oneGCD = FALLBACK_GCD
  if state and state.gcdDuration then
    local d = state:gcdDuration()
    if type(d) == "number" and d > 0 then oneGCD = d end
  end

  if animate then
    for _, row in ipairs(plan.leaving) do playGhost(row, slots) end
  end

  for i = 1, depth do
    local b, slot = buttons[i], queue and queue[i]
    -- Always re-shown: the placeholder above hides every slot outright, and nothing else runs
    -- between that and the next ordinary render to bring them back (`Layout` only runs on a
    -- settings change, not on every paint).
    b:Show()
    b.slot = slot
    if not slot then
      b.icon:SetTexture(nil)
      b.keybind:SetText("")
      b.waitUntil = nil
      b.reason:Hide()
      b.cd:Clear()
      b:SetAlpha(0)
    else
      b:SetAlpha(slots[i].alpha)
      b.icon:SetTexture(iconFor(slot.spell, slot.item))

      -- Sweep. The state reports how much is LEFT and how long one LASTS; both are needed and they
      -- are different questions — conflating them stalled the simulated queue once already.
      if slot.spell and state then
        local remaining = state:cooldown(slot.spell) or 0
        local duration = state:baseCooldown(slot.spell) or 0
        if remaining > 0 and duration > 0 then
          -- SetCooldown wants the START of the cooldown; the state reports what is LEFT.
          b.cd:SetCooldown(ns.now() - (duration - remaining), duration)
        else
          b.cd:Clear()
        end
      else
        b.cd:Clear()
      end

      -- PE9-D3/D4: which slots carry a key is the player's call now. "On the first icon only" is
      -- still the default and still ADR-0015 §3's reasoning -- a key to press is a fact about the
      -- cast you are making NOW, and on a projected slot it is a key NOT to press yet. People who
      -- read the whole strip as a plan want all of them, and neither answer is wrong for everyone.
      local wantsBind = binds == "all" or (binds == "first" and i == 1)
      local bind = wantsBind and slot.spell and ns.BarGlow and ns.BarGlow.keybindFor(slot.spell)
      b.keybind:SetText(bind or "")

      -- PE9-D1. Captured as an ABSOLUTE moment (`now + slot.t`) so paintLive can count it down
      -- without recomputing anything. The "is this worth saying" decision is made once, HERE, from
      -- the projection -- not from the remaining time on each tick, or a 3s wait would silently
      -- vanish the instant it dropped under one GCD, halfway through being read.
      --
      -- Slot 1 never gets one: slot 1 is "press this now".
      --
      -- TWO DIFFERENT TIMES, and conflating them is what makes this feature noise instead of signal:
      --   * WHETHER to speak is decided by this slot's OWN GAP from the one before it -- is there a
      --     real wait here, or does this simply follow on the next global?
      --   * WHAT is shown is the time from NOW (`slot.t`, which is cumulative), because "Holy Shock
      --     in 3 seconds" is how a player thinks.
      -- Testing the CUMULATIVE time against one GCD is the trap: slot 3 of a perfectly smooth
      -- rotation sits at 3.0s, clears the 1.5s bar every single render, and reads "3.0s" forever --
      -- which is precisely the always-on countdown this design exists to avoid.
      b.waitUntil = nil
      if i > 1 and waits ~= "off" and type(slot.t) == "number" and state and state.now then
        local previous = queue[i - 1]
        local before = (previous and type(previous.t) == "number") and previous.t or 0
        local gap = slot.t - before
        if waits == "always" or gap > oneGCD then b.waitUntil = state:now() + slot.t end
      end

      -- Only slot 1: a reason under every icon is a wall of text. PE9-D5 moved the gate off
      -- Learning mode onto its own setting, which the preset now switches on.
      if p.showReason and i == 1 and slot.label then
        b.reason:SetText(slot.label)
        b.reason:Show()
      else
        b.reason:Hide()
      end

      if animate then playOp(b, plan.ops[i], slots, i, grow) end
    end
  end
  for i = depth + 1, MAX_SLOTS do buttons[i].slot, buttons[i].waitUntil = nil, nil end

  -- Paint the two live labels immediately rather than waiting for the next tick, so a fresh queue
  -- arrives with its countdown already correct instead of blank for up to a tenth of a second.
  paintLive((state and state.now) and state:now() or (ns.now and ns.now()) or 0)

  rendered = {}
  for i = 1, depth do
    local slot = queue and queue[i]
    if not slot then break end
    rendered[i] = { spell = slot.spell, item = slot.item }
  end

  -- Spend the cast only when it was actually used, or when it has gone stale. Clearing it on every
  -- render is what stopped the pop ever being drawn.
  if plan.popped then
    pendingCast, pendingCastAt = nil, nil
  elseif pendingCast and state and state.now then
    -- No clock is not a reason to hold a cast for ever, but it is a reason not to guess: without
    -- one the cast is spent immediately, which is the old behaviour and no worse than it.
    if not pendingCastAt or (state:now() - pendingCastAt) > Queue.CAST_WINDOW then
      pendingCast, pendingCastAt = nil, nil
    end
  elseif pendingCast then
    pendingCast, pendingCastAt = nil, nil
  end
end

-- Registered alongside Queue.Render (Core/Init.lua) as the strip's TICK. Display/Driver calls it on
-- every visible tick whose queue came back unchanged -- which is most of them -- so the countdown
-- keeps running between recomputations and the dimming reflects the mana you have now, not the mana
-- you had when the rotation last moved. No frame, no OnUpdate, no timer of its own: the render loop
-- is already capped at 10 Hz and a second ticker is exactly what the style rules forbid.
function Queue.Tick(now)
  if not container or not container:IsShown() or placeholderShown then return false end
  -- PE11-D5: the sample has no countdown to run and no mana to check, and paintFade would apply the
  -- out-of-combat opacity to a strip the player is trying to see well enough to drag.
  if positioning then return false end
  paintLive(now or (ns.now and ns.now()) or 0)
  return true
end

ns.Queue = Queue
return Queue
