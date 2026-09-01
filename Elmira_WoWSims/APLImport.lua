-- Elmira_WoWSims/APLImport.lua — registers a build-importer stub. Real APL translation lands at M8.
local ADDON = ...
local API = Elmira and Elmira.API
if not API or API.version < 1 then return end

API.RegisterBuildImporter{
  name = "WoWSims APL",
  prefix = "WSAPL1:",
  parse = function() return nil, "not implemented until M8" end,
}
