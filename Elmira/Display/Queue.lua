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

local function saveAnchor()
  if not container then return end
  local point, _, relPoint, x, y = container:GetPoint()
  local p = profile()
  if p and p.anchor then
    p.anchor.point, p.anchor.relPoint = point, relPoint
    p.anchor.x, p.anchor.y = x, y
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
  b:SetPoint("LEFT", container, "LEFT", b.destX or 0, 0)
end

-- Stop() before Play() assumes Stop does NOT fire OnFinished -- if it did, the settle handler would
-- re-anchor at the old destination and the new slide would overshoot from there. The vendored
-- LibCustomGlow relies on the same contract (Libs/LibCustomGlow-1.0.lua:539 releases a frame AFTER
-- Stop(), and :619 registers OnStop and OnFinished as separate scripts). Nothing headless can pin
-- this, so it is written down rather than assumed silently.
local function slide(b, fromX, toX, fromY)
  b:ClearAllPoints()
  b:SetPoint("LEFT", container, "LEFT", fromX, fromY)
  b.slideMove:SetOffset(toX - fromX, -fromY)
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

  b.keybind = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.keybind:SetPoint("TOPRIGHT", 1, -1)
  b.keybind:SetTextColor(ns.Colors.MUTED.r, ns.Colors.MUTED.g, ns.Colors.MUTED.b)

  -- Learning mode only (PRD F15): the name of the RULE that produced this suggestion, under the
  -- icon. Says "Seal expiring" rather than just showing a Judgement icon, which is the difference
  -- between memorising a sequence and learning why the sequence is what it is.
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
  ghost:SetPoint("CENTER", container, "LEFT", from.x + from.size / 2, 0)
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
local function playOp(b, op, slots, index)
  local here = slots[index]
  if op.kind == "shift" then
    local from = slots[op.from]
    if not from then return end     -- shifted in from a slot the strip no longer has
    slide(b, from.x, here.x, 0)
  elseif op.kind == "enter" then
    -- A promotion drops in from one icon height above: far enough to read as arriving from outside
    -- the strip, close enough to finish inside the 150 ms. A tail arrival only fades, because an
    -- icon sliding down every GCD is motion that carries no news.
    if op.promote then slide(b, here.x, here.x, here.size) end
    fadeIn(b, here.alpha)
  end
end

function Queue.frame() return container end

-- Public because every icon forwards its drag here. Both guard on `locked` rather than the caller
-- doing it: one place decides whether the strip may move.
function Queue.StartMoving()
  if not container or profile().locked then return false end
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
  container:SetPoint(p.anchor.point or "CENTER", UIParent, p.anchor.relPoint or "CENTER",
                     p.anchor.x or 0, p.anchor.y or -150)
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
  Queue.Layout()
  return container
end

-- PRD F15. A preset, deliberately not a mode: it writes depth and scale as real settings the user
-- can go on to change, rather than overriding them invisibly while the options still show the old
-- values. Returns what it changed so the caller can say so out loud.
function Queue.ApplyLearningPreset(on)
  local p = profile()
  p.learning = on and true or false
  if not on then return nil end
  p.depth = 1          -- one answer at a time; a queue teaches sequence, not reasoning
  p.scale = 1.4
  return { depth = 1, scale = 1.4 }
end

function Queue.Layout()
  if not container then return end
  local p = profile()
  local depth = math.max(1, math.min(MAX_SLOTS, p.depth or 3))
  local slots, width, height = ns.Transition.layout(depth)
  container:SetScale(p.scale or 1.0)
  -- Height is the FIRST slot's size, not the base: sizing the container to the small icons clips
  -- the one icon the strip exists for.
  container:SetSize(width, height)
  for i = 1, MAX_SLOTS do
    local b = buttons[i]
    b:ClearAllPoints()
    if i <= depth then
      -- Slot 1 is the answer; the rest are context. Size and opacity carry that, so the eye lands on
      -- the right icon without needing to read anything -- and without anything lighting up.
      b.destX = slots[i].x
      b:SetPoint("LEFT", container, "LEFT", slots[i].x, 0)
      b:SetSize(slots[i].size, slots[i].size)
      b:SetAlpha(slots[i].alpha)
      b:Show()
    else
      b:Hide()
    end
  end
end

function Queue.SetLocked(locked)
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
  local p = profile()
  -- `enabled` is the whole display; `showQueue` is this strip alone. Different questions: a player
  -- who watches only the action-bar glow turns the strip off and must keep glowing, which is why
  -- the bar glow is its own renderer (Display/Glow.Render) and no longer released from here.
  if not p.enabled or p.showQueue == false or visible == false then
    container:Hide()
    -- Forget what was on screen. Coming back should look like arriving, not like the icons
    -- teleported in from wherever the rotation happened to be when the strip went away.
    rendered, pendingCast, pendingCastAt = nil, nil, nil
    return
  end
  container:Show()

  -- Only a real key counts: the hidden path passes nil, which is not a build change.
  if key ~= nil and key ~= lastKey then
    lastKey, rendered = key, nil
  end

  local depth = math.max(1, math.min(MAX_SLOTS, p.depth or 3))
  local slots = ns.Transition.layout(depth)
  local plan = ns.Transition.plan(rendered, queue, pendingCast)
  -- Nothing animates on the first paint: there is no "before" for an icon to have come from.
  local animate = p.animate ~= false and rendered ~= nil
  local state = ns.API and ns.API.GetState()

  if animate then
    for _, row in ipairs(plan.leaving) do playGhost(row, slots) end
  end

  for i = 1, depth do
    local b, slot = buttons[i], queue and queue[i]
    b.slot = slot
    if not slot then
      b.icon:SetTexture(nil)
      b.keybind:SetText("")
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

      -- Slot 1 only (ADR-0015 §3): a key to press is a fact about the cast you are making now.
      -- On a projected slot it is a key NOT to press yet, which is worse than no text at all.
      local bind = i == 1 and slot.spell and ns.BarGlow and ns.BarGlow.keybindFor(slot.spell)
      b.keybind:SetText(bind or "")

      -- Only slot 1, and only while learning: a reason under every icon is a wall of text.
      if p.learning and i == 1 and slot.label then
        b.reason:SetText(slot.label)
        b.reason:Show()
      else
        b.reason:Hide()
      end

      if animate then playOp(b, plan.ops[i], slots, i) end
    end
  end
  for i = depth + 1, MAX_SLOTS do buttons[i].slot = nil end

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

ns.Queue = Queue
return Queue
