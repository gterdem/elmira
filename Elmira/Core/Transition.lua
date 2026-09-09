-- Elmira/Core/Transition.lua — what the queue strip looks like, and what it does when it changes.
--
-- PURE (hard rule 3): geometry and motion PLANNING only. No frames, no AnimationGroups, no WoW API.
-- Display/Queue.lua applies what this returns; everything a reader would want to argue about --
-- how much bigger slot 1 is, how fast a shift takes, whether a new icon slid in or faded in -- is
-- decided here where a spec can fail on it.
--
-- ADR-0015 §3 is the decision this file implements. The strip used to glow slot 1 while the action
-- bar glowed the same spell at the same moment: two surfaces carrying one signal, and the strip's
-- half was the one you cannot act on. Peripheral vision reads motion and size well and lit icons
-- badly, so the strip now says "this one" with SIZE and says "something changed" with MOTION, and
-- the glow belongs to the action bar alone.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Transition = {}

-- `base` is the projected-slot size and the unit everything else is expressed in. `firstScale` is
-- the whole hierarchy: slot 1 is bigger, not brighter. The alpha ramp continues the same sentence
-- past the size step -- by slot 5 the icon is a hint, which is all a fifth-cast projection is worth.
-- PE10-D3: `gap` is the DEFAULT spacing now, not a constant -- Transition.spacing decides what a
-- profile's own value means and Transition.layout reads it from there.
Transition.LAYOUT = {
  base = 40,
  gap = 4,
  firstScale = 1.3,
  alpha = { 1, 0.7, 0.55, 0.4, 0.3 },
}

-- 150 ms: long enough to be seen at the edge of vision, short enough that the strip is settled
-- before the GCD it is describing is over. Anything slower reads as lag in the addon.
Transition.DURATION = 0.15

-- The cast confirmation. Scale only -- a colour flash here would be the glow this ADR removed.
Transition.POP_SCALE = 1.15

-- And its opposite. An icon that left for any other reason shrinks away instead: a correction must
-- not look like praise for a press that never happened.
Transition.LEAVE_SCALE = 0.8

-- How a departing icon is drawn: the size it STARTS at (as a multiple of the slot) and the factor
-- its animation scales BY. A pop starts oversized and settles back to the slot as it fades, which
-- is ADR-0015's "1.15 -> 1.0"; a leave starts true to size and shrinks.
function Transition.ghostScale(kind)
  if kind == "pop" then return Transition.POP_SCALE, 1 / Transition.POP_SCALE end
  return 1, Transition.LEAVE_SCALE
end

-- PE10-D1. Which way the queue after slot 1 goes. "right" is what shipped and stays the default;
-- the order is the order the options dropdown offers them. Growth direction is a statement about
-- where slots 2..n GO, never about where slot 1 is -- Display/Queue keeps slot 1's centre on the
-- same pixel in all four, which is the whole point of offering the choice at all.
Transition.GROW = { "right", "left", "down", "up" }
Transition.DEFAULT_GROW = "right"

-- PE10-D3. `LAYOUT.gap` is now the DEFAULT spacing rather than the only one; 0 is a legitimate
-- answer (a strip that reads as one block) so the floor is 0, not 1.
Transition.MAX_GAP = 20

-- Anything not one of the four reads as the default rather than as an error: a profile written by a
-- newer version must never leave someone with an unlayoutable strip.
function Transition.growth(grow)
  if grow == "left" or grow == "down" or grow == "up" then return grow end
  return Transition.DEFAULT_GROW
end

function Transition.spacing(gap)
  gap = tonumber(gap)
  if not gap or gap < 0 then return Transition.LAYOUT.gap end
  if gap > Transition.MAX_GAP then return Transition.MAX_GAP end
  return gap
end

-- Is this direction a column rather than a row? Asked by everything that has to choose an axis.
function Transition.isVertical(grow)
  grow = Transition.growth(grow)
  return grow == "down" or grow == "up"
end

-- Slot geometry for a given depth, direction and spacing.
--
-- `x`/`y` are each slot's CENTRE, measured from the CONTAINER'S centre. Centres rather than the
-- old left-anchored offsets because slot 1 is a different size from the rest: on a vertical strip
-- (and for the ghosts and the slides on a horizontal one) the only offset that means the same
-- thing in all four directions is the middle of the icon.
--
-- Returns the per-slot rows plus the container's width and height. The cross-axis measurement is
-- the FIRST slot's size, not `base`: sizing the container to the small icons clips the big one,
-- which is the one that matters.
function Transition.layout(depth, grow, gap)
  local L = Transition.LAYOUT
  local n = math.max(1, math.min(#L.alpha, depth or 1))
  grow = Transition.growth(grow)
  gap = Transition.spacing(gap)

  local first = L.base * L.firstScale
  -- Computed rather than accumulated: the loop that added a gap after every icon then subtracted
  -- one at the end was correct on one axis and one direction, and there are now eight combinations.
  local along = first + (n - 1) * (L.base + gap)
  local slots = {}
  local run = 0
  for i = 1, n do
    local size = (i == 1) and first or L.base
    -- How far this slot's centre is along the growth axis, from the middle of the whole strip.
    local d = run + size / 2 - along / 2
    local x, y
    if grow == "right" then x, y = d, 0
    elseif grow == "left" then x, y = -d, 0
    elseif grow == "down" then x, y = 0, -d
    else x, y = 0, d end
    slots[i] = { x = x, y = y, size = size, alpha = L.alpha[i] }
    run = run + size + gap
  end

  if Transition.isVertical(grow) then return slots, first, along end
  return slots, along, first
end

-- Where a promoted icon drops in FROM, as an offset from its own slot.
--
-- The entrance exists to read as "this arrived from outside the strip", which on the original
-- horizontal strip meant one icon height ABOVE. On a vertical strip that direction IS the growth
-- axis, so the drop would be indistinguishable from an ordinary shift. The intent is preserved
-- rather than the literal direction: always perpendicular to the axis the strip grows on.
function Transition.promoteOffset(grow, size)
  if Transition.isVertical(grow) then return -size, 0 end
  return 0, size
end

-- What a slot IS, for the purpose of "is this the same icon as before". Deliberately the same
-- notion Core/Ticker.queuesDiffer uses minus `label`: two entries that produce JUDGEMENT for
-- different reasons are a different QUEUE (worth re-rendering) but the same ICON (not worth
-- sliding). Animating a label change would make the strip twitch while nothing visibly moved.
local function identity(slot)
  if not slot then return nil end
  if slot.spell then return "s:" .. tostring(slot.spell) end
  if slot.item then return "i:" .. tostring(slot.item) end
end

local function indexOf(queue, id, upTo)
  for j = 1, upTo do
    if identity(queue[j]) == id then return j end
  end
end

-- Transition.plan(old, new, castSpell) -> { ops, leaving }
--
-- `ops[i]` describes how the icon now at slot `i` got there:
--   stay              it was already at `i`; nothing moves
--   shift  from = j   it was at `j`; slide it across
--   enter  promote    it is new. `promote` means it appeared somewhere OTHER than the tail, i.e.
--                     the rotation changed its mind (an execute came into range) rather than the
--                     simulation simply projecting one cast further. Promotions slide in from
--                     above so they read as "new"; tail arrivals only fade in, because a tail
--                     icon sliding down every GCD would be constant motion carrying no news.
--
-- `leaving` describes icons that were on screen and are not any more:
--   pop    the player CAST old slot 1 -- confirmation that the addon agreed with the press
--   leave  it dropped out for any other reason (cooldown, condition, reorder)
--
-- `castSpell` is a spell KEY (Display/Queue resolves the client's spell id first) or nil. Only slot
-- 1 can pop: a cast of something further down the queue is the player ignoring the suggestion, and
-- animating that would congratulate them for it.
function Transition.plan(old, new, castSpell)
  old, new = old or {}, new or {}
  local ops, leaving = {}, {}
  local newCount, oldCount = #new, #old

  for i = 1, newCount do
    local id = identity(new[i])
    local from = id and indexOf(old, id, oldCount) or nil
    if from == i then
      ops[i] = { kind = "stay" }
    elseif from then
      ops[i] = { kind = "shift", from = from }
    else
      ops[i] = { kind = "enter", promote = i < newCount }
    end
  end

  -- The cast pop is not "old slot 1 vanished": a spell can be cast and still be somewhere in the
  -- new queue (Crusader Strike comes straight back). What makes it a pop is that it is no longer
  -- the answer -- so the test is against the new slot 1, not against the whole queue.
  local wasFirst = identity(old[1])
  local popped = false
  if wasFirst and castSpell and old[1].spell == castSpell and identity(new[1]) ~= wasFirst then
    leaving[#leaving + 1] = { kind = "pop", from = 1, slot = old[1] }
    popped = true
  end

  for j = 1, oldCount do
    local id = identity(old[j])
    if not (j == 1 and popped) and not (id and indexOf(new, id, newCount)) then
      leaving[#leaving + 1] = { kind = "leave", from = j, slot = old[j] }
    end
  end

  -- `popped` is reported so the caller can tell a cast that was USED from one that arrived before
  -- the queue had moved. Display/Queue holds the cast until it is spent: the invalidate that
  -- follows a cast renders before the spell's cooldown lands, so the first plan after a press
  -- routinely has nothing to pop yet.
  return { ops = ops, leaving = leaving, popped = popped }
end

ns.Transition = Transition
return Transition
