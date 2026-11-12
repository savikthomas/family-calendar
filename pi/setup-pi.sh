#!/usr/bin/env bash
# Turns a Raspberry Pi (Raspberry Pi OS with desktop, Bookworm or Trixie) into a
# full-screen family calendar that starts automatically on boot.
#
# Usage:  bash setup-pi.sh 'https://family-calendar.<you>.workers.dev/?key=YOUR_KEY'
set -euo pipefail

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo "Usage: bash setup-pi.sh 'https://family-calendar.<you>.workers.dev/?key=YOUR_KEY'" >&2
  exit 1
fi

echo "==> Installing Chromium (if needed)"
if ! command -v chromium >/dev/null && ! command -v chromium-browser >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y chromium || sudo apt-get install -y chromium-browser
fi

echo "==> Installing emoji font (flags and weather icons)"
sudo apt-get install -y fonts-noto-color-emoji

echo "==> Boot to desktop with auto-login, disable screen blanking"
sudo raspi-config nonint do_boot_behaviour B4 || true
sudo raspi-config nonint do_blanking 1 || true

echo "==> Writing kiosk launcher"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/calendar-kiosk.sh" <<EOF
#!/usr/bin/env bash
URL='${URL}'
PROFILE="\$HOME/.config/calendar-kiosk-profile"
BROWSER="\$(command -v chromium || command -v chromium-browser)"

# Wait up to 2 minutes for the network after boot
for i in \$(seq 1 60); do
  ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && break
  sleep 2
done

# Restart the browser if it ever exits or crashes
while true; do
  # stop the "Chromium didn't shut down correctly" bubble after power loss
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' \
    "\$PROFILE/Default/Preferences" 2>/dev/null || true
  "\$BROWSER" --kiosk --noerrdialogs --disable-infobars --no-first-run \\
    --disable-session-crashed-bubble --disable-features=Translate \\
    --check-for-update-interval=31536000 --password-store=basic \\
    --user-data-dir="\$PROFILE" "\$URL"
  sleep 5
done
EOF
chmod +x "$HOME/.local/bin/calendar-kiosk.sh"

echo "==> Setting up autostart"
if command -v labwc >/dev/null; then
  mkdir -p "$HOME/.config/labwc"
  touch "$HOME/.config/labwc/autostart"
  sed -i '/calendar-kiosk.sh/d' "$HOME/.config/labwc/autostart"
  echo "$HOME/.local/bin/calendar-kiosk.sh &" >> "$HOME/.config/labwc/autostart"
else
  mkdir -p "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/calendar-kiosk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Family Calendar
Exec=$HOME/.local/bin/calendar-kiosk.sh
X-GNOME-Autostart-enabled=true
EOF
fi

echo "==> Weekly reboot (Sunday 4 AM) to keep things fresh"
( sudo crontab -l 2>/dev/null | grep -v 'calendar-weekly-reboot' ; echo '0 4 * * 0 /sbin/reboot # calendar-weekly-reboot' ) | sudo crontab -

echo
echo "Done. Reboot now with:  sudo reboot"
echo "To change the URL later, edit ~/.local/bin/calendar-kiosk.sh"
