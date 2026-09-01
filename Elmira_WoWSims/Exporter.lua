-- Elmira_WoWSims/Exporter.lua — registers an exporter stub. Real export format lands at M5c.
local ADDON = ...
local API = Elmira and Elmira.API
if not API or API.version < 1 then return end

API.RegisterExporter{
  name = "WoWSims",
  export = function() return nil, "not implemented until M5c" end,
}
