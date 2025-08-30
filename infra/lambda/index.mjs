// index.mjs
import fetch from "node-fetch";

const TMDB = process.env.TMDB_KEY;

async function resolveTitle(query) {
  const r = await fetch(`https://api.themoviedb.org/3/search/multi?api_key=${TMDB}&query=${encodeURIComponent(query)}`);
  if (!r.ok) throw new Error(`TMDB search HTTP ${r.status}`);
  const { results = [] } = await r.json();
  const hit = results.find(x => x.media_type === "movie" || x.media_type === "tv");
  if (!hit) return null;
  const year = (hit.release_date || hit.first_air_date || "").slice(0,4);
  return { id: hit.id, type: hit.media_type, label: `${hit.title || hit.name}${year ? ` (${year})` : ""}` };
}

// pick streaming providers only; mode "strict" = flatrate, "plus" = flatrate+ads+free
function collectStreaming(region, mode = "plus") {
  if (!region) return [];
  const buckets = mode === "strict" ? ["flatrate"] : ["flatrate", "ads", "free"];

  // best-per-provider: prefer flatrate over ads/free if both exist
  const best = new Map(); // provider_id -> { provider_name, offer_type, display_priority }
  for (const kind of buckets) {
    for (const p of (region[kind] || [])) {
      const prev = best.get(p.provider_id);
      const rank = { flatrate: 2, ads: 1, free: 1 }[kind] || 0;
      if (!prev || rank > ({ flatrate: 2, ads: 1, free: 1 }[prev.offer_type] || 0)) {
        best.set(p.provider_id, {
          provider_id: p.provider_id,
          provider_name: p.provider_name,
          offer_type: kind,
          display_priority: p.display_priority ?? 999
        });
      }
    }
  }
  return [...best.values()].sort(
    (a,b) => (a.display_priority - b.display_priority) || a.provider_name.localeCompare(b.provider_name)
  );
}

function headers() {
  return {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,OPTIONS"
  };
}
const ok   = body => ({ statusCode: 200, headers: headers(), body: JSON.stringify(body) });
const fail = (c, body) => ({ statusCode: c, headers: headers(), body: JSON.stringify(body) });

export const handler = async (event) => {
  try {
    const qs = event.queryStringParameters || {};
    const title = (qs.title || "").trim();
    if (!title) return fail(400, { error: "Missing ?title" });

    const countries = (qs.countries || "FR,US,DE,GB,ES,IT,CA,AU")
      .split(",").map(s => s.trim().toUpperCase()).filter(Boolean);

    const mode = (qs.include || "").toLowerCase().includes("strict") ? "strict" : "plus";

    const t = await resolveTitle(title);
    if (!t) return ok({ info: null, entries: [] });

    const url = `https://api.themoviedb.org/3/${t.type}/${t.id}/watch/providers?api_key=${TMDB}`;
    const r = await fetch(url);
    if (!r.ok) throw new Error(`TMDB providers HTTP ${r.status}`);
    const { results } = await r.json();

    // Flatten to "Provider (Country)"
    const entries = [];
    for (const code of countries) {
      const region = results?.[code];
      const providers = collectStreaming(region, mode);
      for (const p of providers) {
        entries.push({ provider: p.provider_name, country: code, offer_type: p.offer_type });
      }
    }

    // Sort alphabetically by provider, then country code
    entries.sort((a,b) => a.provider.localeCompare(b.provider) || a.country.localeCompare(b.country));

    return ok({ info: t, mode: mode === "strict" ? "streaming only" : "streaming + ad/free", entries });
  } catch (e) {
    console.error(e);
    return fail(500, { error: String(e) });
  }
};
