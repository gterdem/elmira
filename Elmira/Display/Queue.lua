-- Elmira/Display/Queue.lua — the suggestion strip (PRD F5).
--
-- N icons: slot 1 is what to press now, the rest are what the simulation projects after it. Plain
-- frames only — never a secure template, never SetAttribute, never a protected call (hard rule 1).
-- This addon displays; it does not press anything, and nothing here may become able to.
--
-- The frame is movable and its anchor persists, because the setup wizard is M4: without `/elm lock`
-- M3 would ship a strip you can see and cannot move.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Queue = {}
local container, buttons = nil, {}
local MAX_SLOTS = 5     -- PRD F5: 1-5, default 3
local SIZE, GAP = 40, 4

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
  local pack = ns.Display and ns.Display.currentPack()
  local data = pack and pack.spells and pack.spells[key]
  if not (data and data.id and GetSpellTexture) then return nil end
  return GetSpellTexture(data.id)
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
local function showWhy(button)
  local slot = button.slot
  if not (slot and slot.spell) or not GameTooltip then return end
  local id = spellIDFor(slot.spell)
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  if id and GameTooltip.SetSpellByID then
    GameTooltip:SetSpellByID(id)
  else
    GameTooltip:SetText(tostring(slot.spell))
  end
  if slot.label then
    GameTooltip:AddLine(ns.Colors.wrap(ns.Colors.MUTED, slot.label))
  end

  local compiled = ns.Display and select(1, ns.Display.activeBuild())
  local entry = compiled and slot.index and compiled.entries and compiled.entries[slot.index]
  if entry and entry.conditions and #entry.conditions > 0 then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ns.L and ns.L["Why"] or "Why")
    local state = ns.API.GetState()
    for _, cond in ipairs(entry.conditions) do
      local ok = cond.test and cond.test(state)
      local color = ok and ns.Colors.OK or ns.Colors.BAD
      GameTooltip:AddLine("  " .. ns.Colors.wrap(color, cond.label or "?"))
    end
  end
  GameTooltip:Show()
end

local function makeButton(index, parent)
  local b = CreateFrame("Frame", nil, parent)   -- NOT a Button, and never a secure template
  b:SetSize(SIZE, SIZE)

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

  b:EnableMouse(true)   -- for the tooltip only; there is no OnClick and there must never be one
  b:SetScript("OnEnter", showWhy)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  b.index = index
  return b
end

function Queue.frame() return container end

function Queue.Create()
  if container then return container end
  local p = profile()
  container = CreateFrame("Frame", "ElmiraQueue", UIParent)
  container:SetSize(SIZE, SIZE)
  container:SetPoint(p.anchor.point or "CENTER", UIParent, p.anchor.relPoint or "CENTER",
                     p.anchor.x or 0, p.anchor.y or -150)
  container:SetScale(p.scale or 1.0)
  container:SetMovable(true)
  container:SetClampedToScreen(true)
  container:RegisterForDrag("LeftButton")
  container:SetScript("OnDragStart", function(self) if not profile().locked then self:StartMoving() end end)
  container:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); saveAnchor() end)

  -- Only visible while unlocked: something has to be draggable, and an always-on backdrop is clutter.
  container.grip = container:CreateTexture(nil, "BACKGROUND")
  container.grip:SetPoint("TOPLEFT", -2, 2)
  container.grip:SetPoint("BOTTOMRIGHT", 2, -2)
  container.grip:SetColorTexture(ns.Colors.BRAND.r, ns.Colors.BRAND.g, ns.Colors.BRAND.b, 0.25)
  container.grip:Hide()

  for i = 1, MAX_SLOTS do buttons[i] = makeButton(i, container) end
  Queue.Layout()
  return container
end

function Queue.Layout()
  if not container then return end
  local p = profile()
  local depth = math.max(1, math.min(MAX_SLOTS, p.depth or 3))
  container:SetScale(p.scale or 1.0)
  container:SetSize(SIZE * depth + GAP * (depth - 1), SIZE)
  for i = 1, MAX_SLOTS do
    local b = buttons[i]
    b:ClearAllPoints()
    if i <= depth then
      b:SetPoint("LEFT", container, "LEFT", (i - 1) * (SIZE + GAP), 0)
      -- Slot 1 is the answer; the rest are context. Size and opacity carry that, so the eye lands on
      -- the right icon without needing to read anything.
      b:SetSize(SIZE, SIZE)
      b:SetAlpha(i == 1 and 1.0 or 0.55)
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

-- Renderer. Registered with Display/Driver, so it only runs when the queue actually changed.
function Queue.Render(queue)
  if not container then return end
  local p = profile()
  if not p.enabled then container:Hide(); return end
  container:Show()

  local depth = math.max(1, math.min(MAX_SLOTS, p.depth or 3))
  local state = ns.API and ns.API.GetState()
  for i = 1, depth do
    local b, slot = buttons[i], queue and queue[i]
    b.slot = slot
    if not slot then
      b.icon:SetTexture(nil)
      b.keybind:SetText("")
      b.cd:Clear()
      b:SetAlpha(0)
    else
      b:SetAlpha(i == 1 and 1.0 or 0.55)
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

      local bind = slot.spell and ns.BarGlow and ns.BarGlow.keybindFor(slot.spell)
      b.keybind:SetText(bind or "")
    end
  end
  for i = depth + 1, MAX_SLOTS do buttons[i].slot = nil end

  -- Slot 1 only. Glowing the projected slots would make three things compete for the same eye.
  if ns.Glow then ns.Glow.SetNowSlot(buttons[1], queue and queue[1]) end
end

ns.Queue = Queue
return Queue
