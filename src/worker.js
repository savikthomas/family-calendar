// Family Calendar — Cloudflare Worker
// Serves the display page and proxies your private ICS calendar feeds
// (browsers can't fetch Google/Outlook/iCloud ICS links directly because of CORS).

import PAGE from "./index.html";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Optional shared secret so the page and feeds aren't public.
    if (env.ACCESS_KEY && url.searchParams.get("key") !== env.ACCESS_KEY) {
      return new Response("Not found", { status: 404 });
    }

    if (url.pathname === "/" || url.pathname === "/index.html") {
      return new Response(PAGE, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    if (url.pathname === "/api/config") {
      let calendars;
      try {
        calendars = getCalendars(env);
      } catch (err) {
        return json({ error: err.message }, 500);
      }
      return json({
        title: env.TITLE || "Family Calendar",
        agendaDays: clampInt(env.AGENDA_DAYS || env.DAYS, 60, 7, 120),
        timeFormat: env.TIME_FORMAT === "24h" ? "24h" : "12h",
        timeLabel: env.TIME_LABEL || "",
        weather: {
          lat: env.WEATHER_LAT ? Number(env.WEATHER_LAT) : null,
          lon: env.WEATHER_LON ? Number(env.WEATHER_LON) : null,
          units: env.TEMP_UNITS === "celsius" ? "celsius" : "fahrenheit",
          name: env.LOCATION_NAME || "",
        },
        night: {
          start: clampInt(env.NIGHT_START, 22, 0, 24),
          end: clampInt(env.NIGHT_END, 6, 0, 24),
          dim: env.NIGHT_DIM ? Number(env.NIGHT_DIM) : 0.7,
        },
        clocks: parseList(env.WORLD_CLOCKS),
        people: parseList(env.PEOPLE).filter((p) => p && p.name),
        // Only names and colors go to the browser, never the feed URLs.
        calendars: calendars.map(({ name, color }) => ({ name, color })),
      });
    }

    const m = url.pathname.match(/^\/api\/ics\/(\d+)$/);
    if (m) {
      let cal;
      try {
        cal = getCalendars(env)[Number(m[1])];
      } catch (err) {
        return new Response(err.message, { status: 500 });
      }
      if (!cal) return new Response("Unknown calendar", { status: 404 });

      const src = cal.url.replace(/^webcal:\/\//i, "https://");
      const upstream = await fetch(src, {
        headers: { "user-agent": "FamilyCalendarDisplay/1.0" },
        cf: { cacheTtl: 300, cacheEverything: true }, // cache feeds at the edge for 5 min
      });
      if (!upstream.ok) {
        return new Response(`Calendar source returned HTTP ${upstream.status}`, { status: 502 });
      }
      return new Response(upstream.body, {
        headers: { "content-type": "text/calendar; charset=utf-8", "cache-control": "no-store" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
};

function getCalendars(env) {
  let list;
  try {
    list = JSON.parse(env.CALENDARS || "[]");
  } catch {
    throw new Error("CALENDARS secret is not valid JSON");
  }
  if (!Array.isArray(list)) throw new Error("CALENDARS must be a JSON array");
  return list
    .filter((c) => c && c.url)
    .map((c, i) => ({ name: c.name || `Calendar ${i + 1}`, color: c.color || "#7A7A7A", url: c.url }));
}

function parseList(value) {
  try {
    const v = JSON.parse(value || "[]");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

function clampInt(value, fallback, min, max) {
  const n = parseInt(value, 10);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
