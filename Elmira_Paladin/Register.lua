-- Elmira_Paladin/Register.lua — hands the data pack to core. Nothing else in this module touches core.
local ADDON, ns = ...
local API = Elmira and Elmira.API
if not API or API.version < 1 then return end
local D = ns.Data and ns.Data.SoD
-- Defensive: Data/*.lua load before this file in the TOC, so D is present in a normal install. A nil
-- here means the TOC was edited or a data file failed to load, which is worth saying out loud rather
-- than silently registering nothing (the M0 LoadWith bug was exactly this shape).
if not D then
  if Elmira and Elmira.Print then Elmira:Print("Elmira_Paladin: data files did not load; pack not registered.") end
  return
end
API.RegisterDataPack{ class = "PALADIN", flavor = "SoD", spells = D.Spells, sets = D.Sets, souls = D.Souls,
                      bonuses = D.Bonuses, builds = D.Builds, catalog = D.Catalog, advice = D.Advice }
