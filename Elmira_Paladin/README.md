# Elmira_Paladin

Class data pack for Paladin (`LoadOnDemand`, `X-Elmira-Class: PALADIN`). Register.lua hands the pack
to `Elmira.API.RegisterDataPack` — everything else is Lua data, no logic.

At M0 this module is a **stub**: only `Register.lua` ships, guarded to no-op until `Data/` exists.
Expected shape, restored at M2 once every ID is verified against Wowhead:

```
Data/Spells.lua           -- symbolic key -> {id, src, cost, proc}
Data/Sets.lua             -- item-set item IDs + bonus spell IDs per threshold, per spec
Data/Souls.lua            -- shoulder soul enchant IDs -> bonus keys granted
Data/Catalog.lua          -- shipped, dated playstyles the setup wizard offers
Data/Advice/Paladin.lua   -- soul/rune/weapon recommendations per build
Data/Builds/*.lua         -- one file per shipped build (Exodin first)
```

See `docs/02-CONDITION-SCHEMA.md` and `docs/03-DATA-SOURCING.md` in the private workspace for the
exact record shapes and ID-sourcing rules.
