#!/usr/bin/env bash
# Hardware parity probe (ROADMAP P2.2). Runs on the Deck, in whichever session
# is live, and prints a stable key=value report so two runs can be diffed.
#
# READ-ONLY BY CONSTRUCTION. It writes nothing, and it deliberately does not
# touch TDP, fan curves or charge limits -- CLAUDE.md requires per-item operator
# approval for those every time, so P2.3's rows are left to a human. Reading a
# battery percentage is not thermal control, but nothing here even sets a value.
set -uo pipefail

# Every external call is time-boxed. Over SSH there is no session bus and no
# terminal, and bluetoothctl/pactl will block forever waiting for one -- which
# is how the first version of this probe hung instead of reporting.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
t() { timeout 5 "$@" 2>/dev/null; }

kv() { printf '%s=%s\n' "$1" "${2:-<none>}"; }

echo "### session"
S=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
kv session.id "$S"
kv session.type "$(loginctl show-session "$S" -p Type --value 2>/dev/null)"
kv session.desktop "$(loginctl show-session "$S" -p Desktop --value 2>/dev/null)"
kv session.compositor "$(ps -u deck -o comm= | sort -u | grep -xE 'Hyprland|gamescope-wl' | paste -sd, )"

echo "### wifi"
kv wifi.device "$(t nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
kv wifi.state "$(t nmcli -t -f TYPE,STATE device 2>/dev/null | awk -F: '$1=="wifi"{print $2; exit}')"
kv wifi.driver "$(basename "$(readlink -f /sys/class/net/wl*/device/driver 2>/dev/null | head -1)" 2>/dev/null)"
kv wifi.ssid "$(t nmcli -t -f ACTIVE,SSID connection show --active 2>/dev/null | awk -F: '$1=="yes"{print "<connected>"; exit}')"
# journalctl, not dmesg: dmesg needs CAP_SYSLOG on this kernel and returns
# nothing unprivileged, which reads as "no firmware" rather than "cannot tell".
kv wifi.firmware "$(t journalctl -k -b --no-pager | grep -oE 'QCA2066[^ ]*|fw_build_id[^ ,]*' | tail -1)"

echo "### bluetooth"
kv bt.service "$(t systemctl is-active bluetooth 2>/dev/null)"
kv bt.adapter "$(t bluetoothctl list 2>/dev/null | awk '{print $2; exit}')"
kv bt.powered "$(t bluetoothctl show 2>/dev/null | awk -F': ' '/Powered:/{print $2; exit}')"
kv bt.rfkill "$(t rfkill list bluetooth 2>/dev/null | grep -c 'yes')"

echo "### audio"
kv audio.pipewire "$(t systemctl --user is-active pipewire 2>/dev/null)"
kv audio.wireplumber "$(t systemctl --user is-active wireplumber 2>/dev/null)"
kv audio.sinks "$(t pactl list short sinks 2>/dev/null | wc -l)"
kv audio.sink.default "$(t pactl get-default-sink 2>/dev/null)"
kv audio.sources "$(t pactl list short sources 2>/dev/null | wc -l)"
kv audio.card "$(t pactl list short cards 2>/dev/null | awk '{print $2}' | paste -sd,)"

echo "### input"
kv input.total "$(grep -c '^N: Name=' /proc/bus/input/devices 2>/dev/null)"
for want in 'Steam Deck Controller' 'Steam Virtual Gamepad' 'FTS3528' 'AT Translated' 'Wireless Controller'; do
  n=$(grep -c "N: Name=\"${want}" /proc/bus/input/devices 2>/dev/null)
  kv "input.dev.$(echo "$want" | tr ' ' '_')" "$n"
done
# NOT `grep /dev/input/event*` -- reading an input node BLOCKS until an event
# arrives, which is how this probe hung the first time. Count the nodes.
kv input.event.nodes "$(set -- /dev/input/event*; [ -e "$1" ] && echo $# || echo 0)"
kv input.js.nodes "$(set -- /dev/input/js*; [ -e "$1" ] && echo $# || echo 0)"
# shellcheck disable=SC2012  # sysfs device names are alphanumeric by kernel
# convention; `find` here would add a second failure mode for no benefit.
kv input.accel "$(ls /sys/bus/iio/devices/ 2>/dev/null | paste -sd,)"

echo "### display"
kv display.drm "$(set -- /sys/class/drm/card[0-9]-*; [ -e "$1" ] && echo $# || echo 0)"
kv display.connected "$(for c in /sys/class/drm/card*-*/status; do [ -r "$c" ] && [ "$(cat "$c")" = connected ] && basename "$(dirname "$c")"; done | paste -sd,)"
kv display.backlight "$(cat /sys/class/backlight/amdgpu_bl0/brightness 2>/dev/null)/$(cat /sys/class/backlight/amdgpu_bl0/max_brightness 2>/dev/null)"

echo "### power (READ-ONLY -- P2.3 rows are NOT probed, they need operator approval)"
kv power.battery "$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)"
kv power.status "$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1)"
kv power.ac "$(cat /sys/class/power_supply/AC*/online 2>/dev/null | head -1)"

echo "### kernel"
kv kernel.release "$(uname -r)"
kv kernel.neptune "$(uname -r | grep -c neptune)"
