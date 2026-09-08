-- D2 (review of 65896ad): "the PB1 popup guard is narrower than its premise. It reads
-- only Options/Rotation.lua, and a FIFTH StaticPopup_Show lives at Setup/Wizard.lua with no
-- raiseAbovePanel -- the first-run popup, so it can open behind the options window like the other
-- four did." (PB1's own history, carried across from the old `Options/Rotation.lua source (PB1)`
-- describe block this one replaces: this is the FOURTH time a popup shipped without
-- `raiseAbovePanel`, once per call site that had to remember it by hand -- twice for the naming
-- popups, once for the source popup, once for the confirm dialog -- and then a FIFTH, in a different
-- FILE, that the old single-file guard could not see at all.)
--
-- A source-level guard is unusual, but the alternative is trusting that whoever adds the SIXTH
-- popup remembers a convention four people in a row have already forgotten, in a codebase big enough
-- that "read every file" is not a real review step. This one scans the WHOLE addon rather than one
-- file, which is provable directly from the source text: `StaticPopup_Show(` may appear EXACTLY ONCE
-- across every shipped `.lua` file, and only inside `Elmira/Display/Popups.lua`. A normal
-- behavioural spec cannot pin this -- it would have to enumerate every call site by name, and would
-- say nothing about a future one nobody wrote a test for yet.
describe("Elmira source (D2): every StaticPopup_Show call site is in Display/Popups.lua", function()
  -- Comments are stripped BEFORE counting, so a comment mentioning "StaticPopup_Show(" in prose --
  -- exactly the kind of sentence this project's own comments are full of, including this file's own
  -- header above -- cannot fail the build the way the old one-file guard's regex could have. This
  -- codebase's style uses only `--` line comments (no `--[[ ]]` block comments ship today), so a
  -- single-line strip is enough.
  local function stripComments(source)
    local out = {}
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = line:match("^(.-)%-%-.*$") or line
    end
    return table.concat(out, "\n")
  end

  local function countCallSites(source)
    local count = 0
    for _ in stripComments(source):gmatch("StaticPopup_Show%(") do count = count + 1 end
    return count
  end

  it("does not count a mention of StaticPopup_Show( inside a comment", function()
    assert.equal(0, countCallSites("-- see StaticPopup_Show( for how this works\nlocal x = 1"))
  end)

  it("counts a real call site even right after a comment mentioning it", function()
    assert.equal(1, countCallSites(
      "-- calls StaticPopup_Show( below\nlocal d = StaticPopup_Show(\"X\")"))
  end)

  it("counts every call site when more than one exists", function()
    assert.equal(2, countCallSites("StaticPopup_Show(\"A\")\nStaticPopup_Show(\"B\")"))
  end)

  -- Every shipped .lua under Elmira/, excluding Elmira/Libs/ (vendored, not ours to police) -- the
  -- same enumeration style as `helper.classFiles`, which already trusts `find`/`ls` over a
  -- hand-maintained file list for exactly this reason (a list someone forgot to update is a silent
  -- gap, same shape of defect this whole guard exists to catch).
  local function shippedFiles()
    local pipe = assert(io.popen("find Elmira -name '*.lua' -not -path 'Elmira/Libs/*'"))
    local files = {}
    for line in pipe:lines() do files[#files + 1] = line end
    pipe:close()
    table.sort(files)
    return files
  end

  it("finds shipped Lua files to scan -- an empty list would make the guard below vacuous", function()
    assert.is_true(#shippedFiles() > 0)
  end)

  it("calls StaticPopup_Show from exactly one place in the whole addon, and it is Display/Popups.lua",
    function()
      local total, foundIn = 0, {}
      for _, path in ipairs(shippedFiles()) do
        local f = assert(io.open(path, "r"))
        local source = f:read("*a")
        f:close()
        local n = countCallSites(source)
        if n > 0 then
          total = total + n
          foundIn[#foundIn + 1] = path
        end
      end
      assert.equal(1, total,
        "StaticPopup_Show must be called from exactly one place in the addon -- " ..
        "Elmira/Display/Popups.lua -- so raising above the options panel is not a discipline every " ..
        "new call site has to remember on its own")
      assert.same({ "Elmira/Display/Popups.lua" }, foundIn)
    end)
end)
