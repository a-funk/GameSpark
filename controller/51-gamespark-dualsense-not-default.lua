-- A DualSense on USB is also a 4-channel sound card (speaker on channels 1-2, haptics on 3-4). Games that support it
-- open their own stream to it for haptics and controller-speaker sounds; the game's main audio must stay on the TV.
-- Lowest priority so WirePlumber never picks it as the default output (e.g. while the TV's HDMI sink is missing).
-- Installed by system/fex-system.sh controllers into ~/.config/wireplumber/main.lua.d/ (WirePlumber 0.4).
table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_output.usb-Sony_Interactive_Entertainment_*" } },
    { { "node.name", "matches", "alsa_input.usb-Sony_Interactive_Entertainment_*" } },
  },
  apply_properties = { ["priority.session"] = 1, ["priority.driver"] = 1 },
})
