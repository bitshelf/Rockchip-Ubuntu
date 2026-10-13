-- WirePlumber 0.4 (noble): name Rockchip platform ALSA cards after their
-- kernel longnames so desktop audio panels match `aplay -l` instead of three
-- indistinguishable "Built-in Audio" entries.
--
-- Loaded from /usr/share/wireplumber/main.lua.d/ after the stock
-- 50-alsa-config.lua (which defines alsa_monitor.rules).  Rules run after
-- WirePlumber's "Built-in Audio" fallback in prepareDevice(), so the
-- device.description set here wins.  The rules also serve as the fallback
-- layer if UCM2 matching ever fails: they key on api.alsa.card.longname,
-- which alsa-udev sets independently of UCM.
--
-- 0.4 matches semantics: tuples within one group are AND-ed, groups are
-- OR-ed.  Longname and short name can never both match, so each card gets
-- exactly one group keyed on the longname.

local rockchip_cards = {
  { longname = "^rockchip-hdmi$",   desc = "HDMI (rockchip-hdmi)" },
  { longname = "^rockchip-dp0$",    desc = "DisplayPort (rockchip-dp0)" },
  { longname = "^rockchip-es8388$", desc = "ES8388 (rockchip-es8388)" },
}
for _, card in ipairs (rockchip_cards) do
  table.insert (alsa_monitor.rules, {
    matches = { { { "api.alsa.card.longname", "matches", card.longname } } },
    apply_properties = { ["device.description"] = card.desc },
  })
end
