-- tests/ace3.lua — loads the REAL vendored Ace3 UI stack (Elmira/Libs/) on top of
-- tests/wow_mock.lua's frames, so a spec can open the actual AceConfigDialog window and drive the
-- actual AceGUI Frame widget instead of a stand-in for one.
--
-- Why this exists: every fake of the options window agrees with the code it is testing about what
-- AceGUI does. The chrome bugs this project keeps shipping (M5g's leaked pooled frame, D15's
-- stripped title bar, FX2) all live in the seam between OUR decoration and the library's own
-- pooling, re-titling and close path -- a seam a fake cannot have, because a fake has no pool.
-- tests/spec/init_spec.lua takes the same position for AceAddon/AceDB; this is the UI half of it.
--
-- Everything below is either a client global those libraries read, or a driver for something the
-- CLIENT does on their behalf (the Escape key, the OnUpdate that runs their deferred work). None of
-- it is Elmira's behaviour.
local ace3 = {}

local WIDGET_DIR = "Elmira/Libs/AceGUI-3.0/widgets"

-- Load order matters: LibStub first, then the callback plumbing, then AceGUI and every widget it
-- registers, then the config registry and the dialog that draws it.
local CORE_LIBS = {
  "Elmira/Libs/LibStub/LibStub.lua",
  "Elmira/Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
  "Elmira/Libs/AceGUI-3.0/AceGUI-3.0.lua",
}

local CONFIG_LIBS = {
  "Elmira/Libs/AceConfig-3.0/AceConfigRegistry-3.0/AceConfigRegistry-3.0.lua",
  "Elmira/Libs/AceConfig-3.0/AceConfigDialog-3.0/AceConfigDialog-3.0.lua",
}

local function chunkFor(path)
  local chunk, err = loadfile(path)
  -- Elmira/Libs/ is gitignored and supplied by the packager, so a fresh checkout does not have it.
  -- Say that outright rather than leaving a bare "cannot open" to send the reader hunting.
  assert(chunk, "the options window's specs run on the real Ace3, which lives in the gitignored "
             .. "Elmira/Libs/. Run `make libs` once to populate it. (" .. tostring(err) .. ")")
  return chunk
end

local function widgetFiles()
  local pipe = assert(io.popen("ls " .. WIDGET_DIR .. "/*.lua 2>/dev/null"),
                      "cannot enumerate " .. WIDGET_DIR)
  local files = {}
  for line in pipe:lines() do files[#files + 1] = line end
  pipe:close()
  table.sort(files)
  assert(#files > 0, WIDGET_DIR .. " is empty -- run `make libs`")
  return files
end

-- A font object, as far as anything here is concerned: something to hand to SetFontObject that can
-- be compared by identity. Real ones are Blizzard frame objects with no behaviour these libraries
-- depend on.
local function fontObject()
  return setmetatable({}, { __index = function() return function() end end })
end

-- The client globals Ace3 reads that are not the WoW API tests/wow_mock.lua already models: button
-- labels, font objects, the sound it plays when a window closes, and the two lists the Escape key
-- works through.
local function installClientGlobals()
  _G.CLOSE, _G.ACCEPT, _G.CANCEL = "Close", "Accept", "Cancel"
  _G.OKAY, _G.NEW, _G.SAVE, _G.DELETE = "Okay", "New", "Save", "Delete"
  _G.PlaySound = function() end
  for _, name in ipairs({ "GameFontNormal", "GameFontNormalSmall", "GameFontHighlight",
                          "GameFontHighlightSmall", "GameFontHighlightLarge", "GameFontDisable",
                          "ChatFontNormal" }) do
    _G[name] = fontObject()
  end
  _G.UISpecialFrames = {}
  -- The real one hides every frame named in UISpecialFrames and answers whether it hid any.
  -- AceConfigDialog WRAPS this on its first Open (AceConfigDialog-3.0.lua:1854-1860) to also close
  -- every options window a frame later, so it has to be a real global before that first Open.
  _G.CloseSpecialWindows = function()
    local found = false
    for _, frameName in ipairs(_G.UISpecialFrames) do
      local frame = _G[frameName]
      if frame and frame.IsShown and frame:IsShown() then
        frame:Hide()
        found = true
      end
    end
    return found
  end
  -- A real appending hook, not a recorder: the library's own Open has to run and OUR post-hook has
  -- to fire from inside the very call that installs it, which is what Options.Open relies on.
  _G.hooksecurefunc = function(tbl, method, hook)
    local original = tbl[method]
    tbl[method] = function(...)
      if original then original(...) end
      return hook(...)
    end
  end
end

-- UIParent, as a shown frame rather than the bare table tests/wow_mock.lua leaves behind: AceGUI
-- parents every widget to it and reads its size, and a frame is only visible if its parents are.
local function installUIParent(width, height)
  local parent = _G.CreateFrame("Frame", "UIParent", nil)
  parent:SetSize(width or 1920, height or 1080)
  parent:Show()
  _G.UIParent = parent
  return parent
end

-- Loads a fresh copy of the whole stack. Fresh, because LibStub:NewLibrary refuses to hand back a
-- second copy of the same major/minor -- so without dropping LibStub the SECOND test in a file
-- would inherit the first test's widget pool, its OpenFrames and its hooks, and the pooling
-- behaviour these specs exist to check would be whatever the previous test left behind.
--
-- `opts.uiWidth` / `opts.uiHeight` size UIParent; everything else is fixed.
function ace3.load(opts)
  opts = opts or {}
  installClientGlobals()
  installUIParent(opts.uiWidth, opts.uiHeight)

  local mock = require("tests.wow_mock")
  -- Installed only while the libraries load: they capture `xpcall` as a file-scope upvalue for
  -- their `safecall`, and WoW's forwards the extra arguments while stock Lua 5.1's drops them.
  -- Every AceGUI callback (OnClose included) arrives through that call.
  local stockXpcall = _G.xpcall
  _G.xpcall = mock.wowXpcall
  _G.LibStub = nil
  for _, path in ipairs(CORE_LIBS) do chunkFor(path)() end
  for _, path in ipairs(widgetFiles()) do chunkFor(path)() end
  for _, path in ipairs(CONFIG_LIBS) do chunkFor(path)() end
  _G.xpcall = stockXpcall

  return {
    gui = LibStub("AceGUI-3.0"),
    registry = LibStub("AceConfigRegistry-3.0"),
    dialog = LibStub("AceConfigDialog-3.0"),
  }
end

-- One client frame, delivered to the OnUpdate script AceConfigDialog schedules its deferred work on
-- (RefreshOnUpdate, AceConfigDialog-3.0.lua:1759-1804): closing windows, the close-everything sweep
-- Escape triggers, and re-Opening an app whose table has changed all happen there, never inline.
function ace3.tick(dialog)
  local driver = dialog.frame
  local script = driver:GetScript("OnUpdate")
  if script then script(driver) end
end

-- The Escape key, as the client presses it: CloseSpecialWindows, which AceConfigDialog has wrapped.
function ace3.escape()
  return _G.CloseSpecialWindows()
end

return ace3
