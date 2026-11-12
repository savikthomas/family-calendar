# Family Calendar Display (Skylight alternative)

A wall calendar for a Raspberry Pi and a 15.6" 1080p screen. It shows the family members, world clocks, a month view with a colored dot per person, a 5-day forecast, and an upcoming-events list with an icon and a name tag on each event. Everything comes from your Google calendars. There are no subscriptions or ads, and it starts automatically on boot.

```
Google Calendar (secret ICS links)
        │
Cloudflare Worker (free plan) ── fetches the feeds and hides the links behind an access key
        │
Raspberry Pi ── Chromium kiosk, full screen, auto-start
```

- **Cost:** $0/month. The Worker makes about 600 requests a day; the free limit is 100,000.
- **Updates:** changes made in Google Calendar appear within about 5–10 minutes.
- **Weather:** Open-Meteo (free, no API key).
- **Screen care:** dims at night and shifts the layout by a few pixels every 3 minutes to prevent burn-in.
- **Offline:** if Wi-Fi or Google drops, the last good data stays on screen and the footer shows a warning.

---

## 1. Get the Google Calendar links

For **each** calendar you want to show (each person's calendar and the shared family one):

1. Open Google Calendar on a computer → ⚙️ **Settings**.
2. On the left, under *Settings for my calendars*, click the calendar.
3. Go to **Integrate calendar** → copy **Secret address in iCal format** (it ends in `basic.ics`).

> Only someone with "Make changes and manage sharing" permission sees the secret address. For a calendar shared with you, ask its owner, or have them give you that permission.
> Treat these links like passwords. Anyone who has one can read that calendar.

### One shared family calendar? Tag events by person

If everyone uses **one** shared calendar, list your family in `PEOPLE` in `wrangler.toml`. The display then tags each event automatically:

| Event | Shows as |
|---|---|
| `Shan: Soccer Practice` or `[Shan] Soccer Practice` | **Soccer Practice**, tagged Shan |
| `Shan & Ann - Swim class` | **Swim class**, tagged Shan and Ann |
| `Pick up Shan from school` | tagged Shan (the title is kept as typed) |
| An event that invites a person's email (add the email to `match`) | tagged that person |
| `Family dinner` (no name) | tagged with the calendar's own name, e.g. **Family** |

Names match whole words only, so "Annual checkup" isn't tagged Ann. To add nicknames or emails:
`{"name":"Aby","color":"#FF2E7E","match":["abby","aby.thomas@gmail.com"]}`

## 2. Deploy the Worker to Cloudflare

Requires [Node.js](https://nodejs.org) (LTS) on your computer.

```bash
cd family-calendar
npm install
npx wrangler login            # opens a browser to sign in to Cloudflare
```

Edit `wrangler.toml`. It's already set up for Thomas Family Calendar, Federal Way in °C, and India/Qatar clocks. Change `WORLD_CLOCKS` to add or remove clocks; time zone names are listed [here](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones).

Add your calendars as a secret. Paste this as **one line** when prompted, using your own names, colors and links:

```bash
npx wrangler secret put CALENDARS
```
```json
[{"name":"Savi","color":"#1F5BFF","url":"https://calendar.google.com/calendar/ical/.../basic.ics"},{"name":"Aby","color":"#FF2E7E","url":"https://..."},{"name":"Shan","color":"#14A9B8","url":"https://..."},{"name":"Ann","color":"#8A2BF2","url":"https://..."}]
```

Set an access key (any long random string):

```bash
npx wrangler secret put ACCESS_KEY
```

Deploy:

```bash
npx wrangler deploy
```

Your display URL is `https://family-calendar.<your-subdomain>.workers.dev/?key=YOUR_ACCESS_KEY`.
Open it on your laptop first to check that it works. Add `&demo` to the end to see sample data.

*Optional:* in the Cloudflare dashboard → Workers → family-calendar → Settings → Domains, you can add a custom domain such as `calendar.yourdomain.com`.

## 3a. Recommended for the Compute Stick: minimal Debian (no Windows popups, ever)

The screen runs only **cage**, a program that shows a single app full screen, with Chromium inside it. There's no desktop, taskbar, notifications or update prompts. Security updates install silently.

1. **BIOS, one time:** press **F2** at boot → **Power** → **After Power Failure** → **Power On**. If there's an **Operating System** selection, set it to **Linux**. Save with F10.
2. On your PC, download the **Debian netinst ISO** (amd64) from debian.org and write it to a USB stick with **Rufus**.
3. Boot the Compute Stick from the USB (press **F10** at power-on for the boot menu). Then:
   - Choose **Install** (the text installer is fine), connect to your Wi-Fi, and erase the whole disk (the Windows install).
   - Set a root password and create your own user, for example `savi`.
   - At **Software selection**, **untick** "Debian desktop environment" and "GNOME". **Tick** "SSH server" and "standard system utilities".
4. After the reboot, log in, find the IP with `ip -br a`, and from your Windows PC copy the script over:
   ```powershell
   scp .\linux\setup-linux.sh savi@<stick-ip>:~
   ```
5. On the stick (or over `ssh savi@<stick-ip>`):
   ```bash
   su -c "bash setup-linux.sh 'https://family-calendar.<your-subdomain>.workers.dev/?key=YOUR_ACCESS_KEY' America/Los_Angeles 22:00 06:00"
   su -c reboot
   ```

After that it's an appliance: power on → calendar.
- **Night mode:** the screen turns **off at 22:00 and back on at 06:00**, and the display goes into standby with no signal. To choose other times, add them to the setup command, e.g. `... America/Los_Angeles 21:30 06:30`. Use `none none` to keep the screen on all the time. To test it right away: `sudo -u calendar /usr/local/bin/calendar-screen off` (then `on`).
- **Change the URL:** run the script again.
- **Admin console:** Ctrl+Alt+F2 (Ctrl+Alt+F1 goes back to the calendar), or use SSH.
- **Logs:** `/home/calendar/kiosk.log`

## 3b. Or: keep Windows on the Compute Stick

Windows still works, but it can show its own prompts over the calendar from time to time. The Windows script blocks most of them.

1. **One-time BIOS setting so it turns on whenever it gets power.** Press **F2** at boot → **Power** → **After Power Failure** → **Power On** → F10 to save.
2. Sign in to Windows with your admin account, connect Wi-Fi, and run Windows Update and Edge update once.
3. Copy the `windows` folder to the stick, open **PowerShell as Administrator**, and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Setup-CalendarKiosk.ps1 -Url 'https://family-calendar.<your-subdomain>.workers.dev/?key=YOUR_ACCESS_KEY' -TimeZone 'Pacific Standard Time'
Restart-Computer
```

After that it's plug and play. On power-up it auto-logs in to a local **Calendar** account and opens the calendar full screen in Edge. If Edge closes, it reopens it; the screen never sleeps; and the stick reboots every Sunday at 4 AM.

- **Getting back to your admin account:** press Ctrl+Alt+Del → Sign out, and **hold Shift** while it signs out so auto-login doesn't kick in.
- **Changing the URL:** run the script again with the new `-Url`.
- **Undoing it:** `.\Setup-CalendarKiosk.ps1 -Uninstall`
- **Use the stick's own power adapter.** A TV's USB port can't supply enough power.

## 3c. Or: set up a Raspberry Pi

Any Pi 3B+, 4 or 5 works. A Pi 4 with 2 GB or more is the sweet spot.

1. Use **Raspberry Pi Imager** to flash **Raspberry Pi OS (64-bit) with desktop**. In the Imager settings, set your Wi-Fi, a username, and turn on SSH.
2. Boot the Pi with the display attached, then SSH in (or open a terminal on the Pi).
3. Copy `pi/setup-pi.sh` to the Pi and run it with your URL:

```bash
bash setup-pi.sh 'https://family-calendar.<your-subdomain>.workers.dev/?key=YOUR_ACCESS_KEY'
sudo reboot
```

After the reboot, the Pi logs in automatically and opens the calendar full screen. If the browser closes or crashes, it restarts itself. The Pi also reboots once a week (Sunday at 4 AM).

**Timezone:** the clock and event times use the Pi's timezone. Check it with `timedatectl`, and set it with `sudo raspi-config` → Localisation → Timezone.

**Shared family calendar:** if you add it as its own entry (for example `{"name":"Family","color":"#F08A24","url":"..."}`), it gets its own color and tag. If the same event is on two people's calendars, it shows once with both name tags.

**Event icons** are chosen from the event title. For example, "soccer" gets a ball, "grocery" a cart, "piano", "band" or "music" a music note, "doctor" or "dentist" a stethoscope, "meeting" a laptop, "gym" a dumbbell, and "family", "youth" or "party" a people icon. Anything else gets a calendar icon. You can edit the list in `ICON_RULES` in `src/index.html`.

## Changing things later

| Want to… | Do this |
|---|---|
| Add or remove a person or calendar | `npx wrangler secret put CALENDARS` (paste the whole list again). The display picks it up within 5 minutes. |
| Change the title, clocks, location, °C/°F, or night hours | Edit `wrangler.toml` → `npx wrangler deploy` |
| Change the look | Edit `src/index.html` → `npx wrangler deploy`. The Pi reloads the page at 3:30 AM daily, or you can reboot it. |
| Exit the kiosk on the Pi | Plug in a keyboard and press `Alt+F4`, or SSH in and run `pkill chromium` (it restarts after 5 s). |

## Troubleshooting

- **Blank page or "Not found":** the `?key=` in the URL doesn't match `ACCESS_KEY`.
- **Footer says "Couldn't refresh: Mom (HTTP 502)":** that calendar's link is wrong or was reset in Google. Copy a fresh secret address.
- **No weather:** check `WEATHER_LAT` / `WEATHER_LON` in `wrangler.toml`.
- **Screen goes black after 10 minutes:** run `sudo raspi-config` → Display Options → Screen Blanking → No.
- **Local testing:** create a `.dev.vars` file (values in single quotes), then run `npm run dev`:
  ```
  CALENDARS='[{"name":"Test","color":"#E3A126","url":"https://..."}]'
  ACCESS_KEY=test
  ```
