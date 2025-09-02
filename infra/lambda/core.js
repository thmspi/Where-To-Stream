// Node 18 runtime provides global fetch

// Ne garder que le streaming (flatrate) ou inclure aussi ads/free
export function pickStreaming(region, mode = "plus") {
  if (!region) return [];
  const buckets = mode === "strict" ? ["flatrate"] : ["flatrate", "ads", "free"];
  const rankOf = k => (k === "flatrate" ? 2 : 1);

  const best = new Map();
  for (const kind of buckets) {
    for (const p of (region[kind] || [])) {
      const prev = best.get(p.provider_id);
      if (!prev || rankOf(kind) > rankOf(prev.offer_type)) {
        best.set(p.provider_id, {
          id: p.provider_id,
          name: p.provider_name,
          offer_type: kind,
          prio: p.display_priority ?? 999
        });
      }
    }
  }
  return [...best.values()].sort(
    (a, b) => (a.prio - b.prio) || a.name.localeCompare(b.name)
  );
}

export async function resolveTitle(query, TMDB_KEY) {
  const r = await fetch(
    `https://api.themoviedb.org/3/search/multi?api_key=${TMDB_KEY}&query=${encodeURIComponent(query)}`
  );
  if (!r.ok) throw new Error(`TMDB search HTTP ${r.status}`);
  const { results = [] } = await r.json();
  const hit = results.find(x => x.media_type === "movie" || x.media_type === "tv");
  if (!hit) return null;
  const year = (hit.release_date || hit.first_air_date || "").slice(0, 4);
  return { id: hit.id, type: hit.media_type, label: `${hit.title || hit.name}${year ? ` (${year})` : ""}` };
}

export async function whereToStream({ title, countries, includeMode = "plus", TMDB_KEY }) {
  const t = await resolveTitle(title, TMDB_KEY);
  if (!t) return { info: null, entries: [] };

  const url = `https://api.themoviedb.org/3/${t.type}/${t.id}/watch/providers?api_key=${TMDB_KEY}`;
  const pr = await fetch(url);
  if (!pr.ok) throw new Error(`TMDB providers HTTP ${pr.status}`);
  const { results } = await pr.json();

  const entries = [];
  for (const code of countries) {
    const region = results?.[code];
    const providers = pickStreaming(region, includeMode);
    for (const p of providers) entries.push({ provider: p.name, country: code, offer_type: p.offer_type });
  }
  entries.sort((a, b) => a.provider.localeCompare(b.provider) || a.country.localeCompare(b.country));
  return { info: t, mode: includeMode === "strict" ? "streaming only" : "streaming + ad/free", entries };
}
