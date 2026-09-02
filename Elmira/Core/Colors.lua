-- Elmira/Core/Colors.lua — the addon's palette, in one place.
--
-- PURE: no WoW API, no frames. Colours are data, so every module (core, class packs, the ElvUI
-- provider) speaks with one visual identity instead of each picking its own literal. Before this,
-- the chat prefix used AceConsole's default `33ff99` green, which is the colour every Ace addon
-- prints in — Elmira looked like six other addons in the same chat frame.
--
-- Why lilac. It has to be legible on WoW's dark UI, and it must not read as a class colour, because
-- this addon eventually renders several classes and a brand that looks like "Warlock" is worse than
-- no brand. `C08CF0` is clear of every class colour, including the closest one (Warlock `8787ED`,
-- which is markedly bluer), and of quest yellow `FFD100` and the Ace green above.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Colors = {}

-- { r, g, b } in 0-1 floats for SetVertexColor/SetTextColor, plus `hex` for chat escape sequences.
-- Both spellings of the same value live together so they can never drift apart.
local function rgb(hex)
  local r = tonumber(hex:sub(1, 2), 16) / 255
  local g = tonumber(hex:sub(3, 4), 16) / 255
  local b = tonumber(hex:sub(5, 6), 16) / 255
  return { r = r, g = g, b = b, hex = hex }
end

Colors.BRAND     = rgb("C08CF0")  -- the addon's identity: chat prefix, options title, minimap icon
Colors.HIGHLIGHT = rgb("FFD37A")  -- the now-slot: warm, reads as "this one", pairs with the brand
Colors.MUTED     = rgb("9AA0A6")  -- keybinds, secondary labels, anything that must not compete
Colors.OK        = rgb("5CC46C")
Colors.WARN      = rgb("E8A33D")
Colors.BAD       = rgb("E5544B")

-- `|cAARRGGBB` ... `|r`. Always via this helper: a hand-written escape with the wrong number of
-- digits silently prints the code as literal text rather than erroring.
function Colors.wrap(color, text)
  local c = (type(color) == "table" and color.hex) or color or Colors.BRAND.hex
  return "|cff" .. c .. tostring(text) .. "|r"
end

-- The one prefix every Elmira message starts with, core and modules alike.
function Colors.prefix()
  return Colors.wrap(Colors.BRAND, "Elmira")
end

ns.Colors = Colors
return Colors
