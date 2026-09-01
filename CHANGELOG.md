# Changelog
## Unreleased
- Project scaffold (kit v1, 2026-09-01).
- M0 skeleton: addon-family layout (Elmira core + Elmira_Paladin/ElvUI/ItemRack/WoWSims/Insights
  stubs), `Elmira.API` v1 registry, AceDB defaults with `dbVersion` + migrations, `/elm` slash
  (help, debug state|bars|perf, modules, version), busted + luacheck harness with the Core/Adapters
  boundary enforced by `.luacheckrc`. Interface bumped to 11509 across all TOCs. Author: Valermus.
- Fixed: `Elmira_ElvUI` and `Elmira_ItemRack` registered nothing on login. `## LoadWith:` loaded
  them alongside ElvUI/ItemRack, ahead of their own `## Dependencies: Elmira`, so their file
  scope saw a nil `Elmira` global and their guard returned. Both TOCs now rely on hard
  `Dependencies` for ordering, and the guard prints instead of returning silently.
