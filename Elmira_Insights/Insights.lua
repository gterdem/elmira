-- Elmira_Insights/Insights.lua — registers a meter-provider stub. Real Details! integration and the
-- rest of docs/12-INSIGHTS.md (peers, score, history, suggestions) land at M7.
local ADDON = ...
local API = Elmira and Elmira.API
if not API or API.version < 1 then return end

API.RegisterMeterProvider{
  name = "Details",
  currentSegment = function() return nil end,
}
