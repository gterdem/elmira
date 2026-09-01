Headless tests. `make test` runs busted over `tests/spec`. `fake_state.lua` implements the State
contract for Core tests; `wow_mock.lua` stubs the WoW API for adapter tests.

Every Core/Adapters module follows one pattern so it's `dofile`/`loadfile`-able outside the client:

```lua
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}
-- ...
return Module
```

Use `tests/helper.lua` to load modules in specs — `require("tests.helper")`, then:

- `helper.reset()` — starts a fresh `ns` for the spec (call in `before_each`; otherwise registry
  state leaks between specs and produces order-dependent failures).
- `helper.load(path)` — loads a module file, passing it `("Elmira", ns)` as its `...` (mirrors how
  the WoW client hands every file of one addon the same `ns` table).

```lua
local helper = require("tests.helper")
describe("...", function()
  local API
  before_each(function()
    helper.reset()
    API = helper.load("Elmira/Core/API.lua")
  end)
  it("...", function() ... end)
end)
```

Fixtures under `tests/fixtures/` mirror `Data/` with plain numeric IDs.
