-- Elmira_Paladin/Register.lua — hands the data pack to core. Nothing else in this module touches core.
local ADDON, ns = ...
local API = Elmira and Elmira.API
if not API or API.version < 1 then return end
local D = ns.Data and ns.Data.SoD
if not D then return end -- data pack not present yet (M0 stub / M2 restores Data/ from docs/staging/)
API.RegisterDataPack{ class = "PALADIN", flavor = "SoD", spells = D.Spells, sets = D.Sets, souls = D.Souls,
                      bonuses = D.Bonuses, builds = D.Builds, catalog = D.Catalog, advice = D.Advice }
