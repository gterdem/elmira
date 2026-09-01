-- tests/spec/toc_spec.lua — TOC load-order invariants. Verified in game on 2026-09-01: `## LoadWith:`
-- does NOT set the LoadOnDemand flag on Classic Era 1.15.9 (IsAddOnLoadOnDemand returned false), but
-- it DOES hoist the module to load with its trigger addon, ahead of `## Dependencies: Elmira`. The
-- module's file scope then read a nil `Elmira` global and registered nothing, silently. Nothing else
-- in the suite can catch that — it is a property of the .toc files, not of any Lua module.

-- Discovered, not listed: a future Elmira_Bartender4 must inherit these invariants without anyone
-- remembering to edit this file. EXPECTED guards the discovery itself — a glob that silently found
-- nothing would turn every assertion below into a vacuous pass, which is the same class of silent
-- no-op this spec exists to prevent.
local EXPECTED = 5

local function modules()
  local pipe = assert(io.popen("ls -d Elmira_*/ 2>/dev/null"), "cannot enumerate module folders")
  local found = {}
  for dir in pipe:lines() do
    local name = dir:gsub("/$", "")
    local toc = name .. "/" .. name .. "_Vanilla.toc"
    local f = io.open(toc, "r")
    assert(f, name .. " has no " .. name .. "_Vanilla.toc")
    found[name] = f:read("*a")
    f:close()
  end
  pipe:close()
  local n = 0
  for _ in pairs(found) do n = n + 1 end
  assert.are.equal(EXPECTED, n) -- bump deliberately when a module is added or removed
  return found
end

describe("module TOCs", function()
  it("declares Elmira as a hard dependency of every module", function()
    for name, toc in pairs(modules()) do
      local deps = toc:match("##%s*Dependencies:%s*([^\r\n]*)") or ""
      local found = false
      for entry in deps:gmatch("[^,]+") do
        if entry:match("^%s*(.-)%s*$") == "Elmira" then found = true end
      end
      assert.is_true(found, name .. " must declare `## Dependencies: Elmira` to load after core")
    end
  end)

  it("never uses LoadWith, which loads a module ahead of its own dependencies", function()
    for name, toc in pairs(modules()) do
      assert.is_nil(toc:match("##%s*LoadWith:"),
        name .. " must not use `## LoadWith:` (see docs/08-MODULE-API.md)")
    end
  end)

  it("keeps the class pack load-on-demand so core selects it by class", function()
    assert.is_not_nil(modules()["Elmira_Paladin"]:match("##%s*LoadOnDemand:%s*1"))
  end)
end)

-- A Core file missing from the TOC is invisible to every other test here: busted loads modules by
-- path, so the suite stays green while the addon breaks in game. That is the same shape as the M0
-- LoadWith bug — correct code, never loaded — so it gets the same treatment: a test that reads the
-- real .toc bytes.
describe("core TOC", function()
  local function tocBody()
    local f = assert(io.open("Elmira/Elmira_Vanilla.toc", "r"), "missing core TOC")
    local s = f:read("*a"); f:close()
    return s
  end

  local function sourceFiles()
    local pipe = assert(io.popen("ls Elmira/Core/*.lua Elmira/Adapters/*.lua 2>/dev/null"))
    local found = {}
    for path in pipe:lines() do found[#found + 1] = path end
    pipe:close()
    assert.is_true(#found >= 6, "expected to discover Core/ and Adapters/ sources, found " .. #found)
    return found
  end

  it("lists every Core and Adapters source file", function()
    local body = tocBody()
    for _, path in ipairs(sourceFiles()) do
      -- TOC paths use backslashes: Elmira/Core/Engine.lua -> Core\Engine.lua
      local entry = path:gsub("^Elmira/", ""):gsub("/", "\\")
      assert.is_not_nil(body:match(entry:gsub("([%.%-\\])", "%%%1")),
        entry .. " is missing from Elmira_Vanilla.toc; it would never load in game")
    end
  end)

  it("loads Core/Init.lua last, since it publishes the Elmira global", function()
    local body = tocBody()
    local initAt = body:find("Core\\Init%.lua")
    assert.is_not_nil(initAt, "Core\\Init.lua missing from the TOC")
    for _, path in ipairs(sourceFiles()) do
      local entry = path:gsub("^Elmira/", ""):gsub("/", "\\")
      if entry ~= "Core\\Init.lua" then
        local at = body:find(entry:gsub("([%.%-\\])", "%%%1"))
        assert.is_true(at < initAt, entry .. " must load before Core\\Init.lua")
      end
    end
  end)
end)
