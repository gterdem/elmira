-- tests/spec/toc_spec.lua — TOC load-order invariants. Verified in game on 2026-09-01: `## LoadWith:`
-- does NOT set the LoadOnDemand flag on Classic Era 1.15.9 (IsAddOnLoadOnDemand returned false), but
-- it DOES hoist the module to load with its trigger addon, ahead of `## Dependencies: Elmira`. The
-- module's file scope then read a nil `Elmira` global and registered nothing, silently. Nothing else
-- in the suite can catch that — it is a property of the .toc files, not of any Lua module.

-- Discovered, not listed: a future Elmira_Bartender4 must inherit these invariants without anyone
-- remembering to edit this file. EXPECTED guards the discovery itself — a glob that silently found
-- nothing would turn every assertion below into a vacuous pass, which is the same class of silent
-- no-op this spec exists to prevent.
local EXPECTED = 4

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

  -- The shipped class pack is no longer one of these folders (ADR-0011): it is
  -- Elmira/Classes/Paladin.lua inside core. What remains here are the integration modules, which
  -- hard-depend on a FOREIGN addon and so keep their own folders. An external third-party class
  -- pack still uses `## X-Elmira-Class` + LoadOnDemand; there just is not one in this repo.
  it("ships no folder-level class pack, since shipped class data lives in Elmira/Classes", function()
    for name, toc in pairs(modules()) do
      assert.is_nil(toc:match("##%s*X%-Elmira%-Class:"),
        name .. " declares X-Elmira-Class; shipped class data belongs in Elmira/Classes (ADR-0011)")
    end
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
    -- Display/ and Options/ are included deliberately: this spec's whole point is that a file the
    -- suite can dofile but the game never loads looks identical from here. That applies to a
    -- renderer just as much as to a Core module.
    -- Classes/ and Setup/ are in this list for the same reason: a Classes/Mage.lua added to the
    -- repo but not to the TOC registers nothing, in a way no other spec can see (the suite loads it
    -- by path and it works perfectly). That is the M0 LoadWith bug's exact shape.
    local pipe = assert(io.popen(
      "ls Elmira/Core/*.lua Elmira/Adapters/*.lua Elmira/Display/*.lua Elmira/Options/*.lua " ..
      "Elmira/Setup/*.lua Elmira/Classes/*.lua 2>/dev/null"))
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

-- Custom `## X-` TOC keys are metadata nothing validates: the client accepts any of them, the
-- packager ignores the ones it does not know, and a key with a typo -- or one whose reader was
-- deleted -- is indistinguishable from a working one. That is a silent no-op with a config file
-- for a body, and this repo has shipped that shape before, so every shipped key must be either
-- read by our own Lua or a key we deliberately publish for someone else to read.
describe("custom TOC keys", function()
  -- Keys consumed OUTSIDE our Lua. Each needs a reason, because "add it to the allowlist" is the
  -- easy way to defeat this test.
  local EXTERNAL = {
    ["X-License"]          = "CurseForge project metadata",
    ["X-Category"]         = "CurseForge project metadata",
    ["X-Curse-Project-ID"] = "release.sh's upload_curseforge(); without it the upload silently no-ops",
  }

  local function tocFiles()
    local pipe = assert(io.popen("ls Elmira*/*.toc 2>/dev/null"), "cannot enumerate TOC files")
    local found = {}
    for path in pipe:lines() do found[#found + 1] = path end
    pipe:close()
    assert.is_true(#found > 0, "no TOC files found; this test would pass vacuously")
    return found
  end

  local function luaSources()
    local pipe = assert(io.popen("find Elmira* -name '*.lua' -not -path '*/Libs/*' 2>/dev/null"))
    local text = {}
    for path in pipe:lines() do
      local f = io.open(path, "r")
      if f then text[#text + 1] = f:read("*a"); f:close() end
    end
    pipe:close()
    return table.concat(text, "\n")
  end

  it("gives every shipped X- key either a reader in our Lua or a documented external consumer", function()
    local sources = luaSources()
    local orphans = {}
    for _, path in ipairs(tocFiles()) do
      local f = assert(io.open(path, "r"))
      local body = f:read("*a"); f:close()
      for key in body:gmatch("##%s*(X%-[%w%-]+)%s*:") do
        if not EXTERNAL[key] and not sources:find(key, 1, true) then
          orphans[#orphans + 1] = path .. ": " .. key
        end
      end
    end
    table.sort(orphans)
    assert.same({}, orphans,
      "a TOC key nothing reads is inert; add the reader, drop the key, or document it in EXTERNAL")
  end)
end)
