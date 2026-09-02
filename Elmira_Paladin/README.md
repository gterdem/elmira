# Elmira_Paladin

Class data pack for Paladin (`LoadOnDemand`, `X-Elmira-Class: PALADIN`). Register.lua hands the pack
to `Elmira.API.RegisterDataPack` — everything else is Lua data, no logic.

```
Data/Spells.lua           -- symbolic key -> {id, src, cost, cooldown, rune, seal}
Data/Sets.lua             -- item-set item IDs + bonus spell IDs per threshold, per spec
Data/Souls.lua            -- shoulder souls -> bonus keys granted, + the Bonuses table
Data/Catalog.lua          -- shipped, dated playstyles the setup wizard offers
Data/Advice/Paladin.lua   -- soul/rune/weapon recommendations per build
Data/Builds/*.lua         -- one file per shipped build (Exodin first)
```

Data files load **before** `Register.lua` in the TOC: Register reads `ns.Data.SoD` at file scope and
returns early if it is absent, so anything listed after it would load but never reach core.

## Rules that are easy to get wrong here

**Every ID carries a `src` URL.** `make lint` fails if any unverified-ID placeholder marker is left
in this directory. (Written without the literal token here on purpose: the check is a line-based
grep, so prose quoting the marker trips it too.)

**`cost` and `cooldown` are fallbacks, never truth.** The client knows the real values for the rank
and gear the character actually has, and Season of Discovery is tuned by server-side hotfix — a
shipped number can be wrong by 2.5x (Exorcism reads 15 s on Wowhead and 6 s in game). `state`
supplies the live value; these exist only for when it cannot.

**`RUNE_*` entries hold the ABILITY id, not the teach-spell id.** Rune detection matches
`C_Engraving.GetRuneForEquipmentSlot(slot).learnedAbilitySpellIDs`, which returns the ability the
rune teaches. A teach id here compares false against every slot, so `rune()` silently reports "not
engraved" for a rune the player is wearing, with no error anywhere. Two entries are confirmed
against the live client (Hallowed Ground, Rebuke) and one was supplied from it (Wrath); the rest came
from Wowhead and are re-checked by `/elm debug dump`.

**Souls are read from the shoulder TOOLTIP**, matching `short`, never from the item link — the
link's enchant field is empty even when a soul is equipped. This makes v1 soul detection enUS-only,
a known limitation.

**Absent means absent.** An unknown ID is omitted, never written as `0`: a zero is a real ID that a
scan can never match, so it fails silently instead of visibly.

## Deliberately not here yet

Protection and Shockadin abilities, the four unused seals, `DIVINE_FAVOR_BUFF`, tank souls and
`PALADIN_T1_T2_CORE_FORGED` return at M5 with the builds that need them. An entry with no ID and no
source is a TODO written as data, so it is not shipped.

Record shapes are documented inline above and enforced by `tests/spec/data_sourcing_spec.lua`, which
runs against these files directly — that spec is the authority on what a valid entry looks like.
