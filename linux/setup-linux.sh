#!/usr/bin/env bash
# Family Calendar appliance for any x86 mini PC (tested target: Intel Compute Stick STK2M3W64CC)
# on a minimal Debian 12/13 install (no desktop). After this, the box:
#   power on -> auto-login -> calendar full screen (cage + Chromium) -> nothing else, ever.
#
# Usage (as root or with sudo):
#   bash setup-linux.sh 'https://family-calendar.<you>.workers.dev/?key=YOUR_KEY' [America/Los_Angeles] [22:00] [06:00]
#   The last two are when the screen turns off and back on (default 22:00 / 06:00; "none" keeps it on).
# Run it again any time to change the URL, time zone or screen schedule.
set -euo pipefail

URL="${1:-}"
TZONE="${2:-}"
SCREEN_OFF="${3:-22:00}"
SCREEN_ON="${4:-06:00}"
KIOSK_USER="calendar"

if [[ $EUID -ne 0 ]]; then echo "Please run with sudo." >&2; exit 1; fi
if [[ ! "$URL" =~ ^https?:// ]]; then
  echo "Usage: sudo bash setup-linux.sh 'https://family-calendar.<you>.workers.dev/?key=YOUR_KEY' [Time/Zone] [OFF HH:MM] [ON HH:MM]" >&2
  exit 1
fi
for t in "$SCREEN_OFF" "$SCREEN_ON"; do
  if [[ "$t" != none && ! "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "Screen times must be HH:MM (24-hour) or 'none' (got '$t')" >&2; exit 1
  fi
done

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Installing packages (cage, Chromium, emoji font, automatic security updates)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  cage chromium wlr-randr fonts-noto-color-emoji fonts-dejavu-core \
  unattended-upgrades apt-listchanges ca-certificates curl \
  firmware-iwlwifi firmware-misc-nonfree 2>/dev/null \
|| apt-get install -y --no-install-recommends \
  cage chromium wlr-randr fonts-noto-color-emoji fonts-dejavu-core \
  unattended-upgrades apt-listchanges ca-certificates curl

if [[ -n "$TZONE" ]]; then
  say "Setting time zone to $TZONE"
  timedatectl set-timezone "$TZONE"
fi
timedatectl set-ntp true || true

say "Creating kiosk user '$KIOSK_USER'"
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$KIOSK_USER"
  passwd --lock "$KIOSK_USER" >/dev/null     # no password login; only auto-login on the screen
fi
for g in video render input audio; do
  getent group "$g" >/dev/null && usermod -aG "$g" "$KIOSK_USER"
done

say "Saving calendar URL"
install -d -m 755 /etc/calendar-kiosk
{
  printf 'URL=%q\n' "$URL"
  printf 'SCREEN_OFF=%q\n' "$SCREEN_OFF"
  printf 'SCREEN_ON=%q\n' "$SCREEN_ON"
} > /etc/calendar-kiosk/config
chmod 644 /etc/calendar-kiosk/config

say "Writing kiosk launcher"
cat > /usr/local/bin/calendar-kiosk <<'EOF'
#!/usr/bin/env bash
# Runs on tty1 for the kiosk user: cage (single-app Wayland compositor) + Chromium, forever.
source /etc/calendar-kiosk/config
PROFILE="$HOME/.config/calendar-kiosk"
mkdir -p "$PROFILE"

# wait up to ~2 minutes for the network
for _ in $(seq 1 60); do
  curl -fsS --max-time 3 -o /dev/null https://www.gstatic.com/generate_204 && break
  sleep 2
done

while true; do
  # suppress "Chromium didn't shut down correctly" after a power cut
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' \
    "$PROFILE/Default/Preferences" 2>/dev/null || true
  cage -d -- chromium \
    --ozone-platform=wayland --kiosk --noerrdialogs --disable-infobars --no-first-run \
    --disable-session-crashed-bubble --disable-features=Translate,MediaRouter \
    --check-for-update-interval=31536000 --password-store=basic \
    --user-data-dir="$PROFILE" "$URL"
  sleep 5
done
EOF
chmod 755 /usr/local/bin/calendar-kiosk

say "Auto-login on the screen (tty1)"
install -d /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
cat > "/home/$KIOSK_USER/.bash_profile" <<'EOF'
# Start the calendar when logging in on the physical screen
if [ "$(tty)" = "/dev/tty1" ]; then
  exec /usr/local/bin/calendar-kiosk >"$HOME/kiosk.log" 2>&1
fi
EOF
chown "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.bash_profile"

say "Night schedule: screen off at $SCREEN_OFF, on at $SCREEN_ON"
cat > /usr/local/bin/calendar-screen <<'EOF'
#!/usr/bin/env bash
# Turns the display off at night and back on in the morning by switching cage's HDMI output.
# Runs every 2 minutes as the kiosk user. Usage: calendar-screen [auto|on|off]
source /etc/calendar-kiosk/config
mode="${1:-auto}"
want=on
if [[ "$mode" == on || "$mode" == off ]]; then
  want="$mode"
elif [[ "${SCREEN_OFF:-none}" != none && "${SCREEN_ON:-none}" != none ]]; then
  mins() { echo $(( 10#${1%%:*} * 60 + 10#${1##*:} )); }
  now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  off=$(mins "$SCREEN_OFF"); on=$(mins "$SCREEN_ON")
  if (( off < on )); then
    if (( now >= off && now < on )); then want=off; fi
  elif (( off > on )); then
    if (( now >= off || now < on )); then want=off; fi
  fi
fi

XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
WAYLAND_DISPLAY=""
for s in "$XDG_RUNTIME_DIR"/wayland-[0-9]; do
  if [[ -S "$s" ]]; then WAYLAND_DISPLAY="$(basename "$s")"; break; fi
done
[[ -n "$WAYLAND_DISPLAY" ]] || exit 0      # calendar not running yet
export WAYLAND_DISPLAY

wlr-randr | awk '/^[^ ]/ {name=$1} /Enabled:/ {print name, $2}' | while read -r name enabled; do
  if [[ "$want" == off && "$enabled" == yes ]]; then
    wlr-randr --output "$name" --off
  elif [[ "$want" == on && "$enabled" == no ]]; then
    wlr-randr --output "$name" --on
  fi
done
EOF
chmod 755 /usr/local/bin/calendar-screen
cat > /etc/systemd/system/calendar-screen.service <<EOF
[Unit]
Description=Family calendar night screen schedule
[Service]
Type=oneshot
User=$KIOSK_USER
ExecStart=/usr/local/bin/calendar-screen auto
EOF
cat > /etc/systemd/system/calendar-screen.timer <<'EOF'
[Unit]
Description=Check the family calendar screen schedule every 2 minutes
[Timer]
OnBootSec=90
OnCalendar=*:0/2
AccuracySec=15s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now calendar-screen.timer >/dev/null

say "Never sleep, never blank the screen, quiet fast boot"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null
if [[ -f /etc/default/grub ]]; then
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
  if ! grep -q 'consoleblank=0' /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=0"/' /etc/default/grub
  fi
  update-grub >/dev/null 2>&1 || true
fi

say "Keep Wi-Fi awake (Intel Wi-Fi power saving causes dropouts on these sticks)"
cat > /etc/modprobe.d/calendar-wifi.conf <<'EOF'
options iwlwifi power_save=0
options iwlmvm power_scheme=1
EOF

say "Automatic security updates (reboot at 4 AM only if an update needs it)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52calendar-kiosk <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

say "Weekly reboot (Sunday 4:30 AM)"
echo '30 4 * * 0 root /sbin/reboot' > /etc/cron.d/calendar-weekly-reboot
chmod 644 /etc/cron.d/calendar-weekly-reboot

systemctl daemon-reload

cat <<EOF

Done. Reboot with:  sudo reboot

  Calendar URL : $URL
  Change it    : run this script again with the new URL (or edit /etc/calendar-kiosk/config and reboot)
  Screen       : off $SCREEN_OFF, on $SCREEN_ON  (try it: sudo -u $KIOSK_USER /usr/local/bin/calendar-screen off  ...then  on)
  Admin access : press Ctrl+Alt+F2 for a login prompt (Ctrl+Alt+F1 returns to the calendar), or SSH in
  Logs         : /home/$KIOSK_USER/kiosk.log
EOF
