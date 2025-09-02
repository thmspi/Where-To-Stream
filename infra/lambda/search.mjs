// dev-server/index.mjs
// Using built-in fetch in Node.js 18 runtime

// Simple in-memory cache keyed by title to reduce TMDB rate-limit errors
const cache = new Map();
export async function handler(event) {
  // Log incoming event for troubleshooting
  console.log('incoming search event:', JSON.stringify(event));
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': '*'
  };

  console.log("Lambda search handler invoked with event:", JSON.stringify(event));
  const title = (event.queryStringParameters?.title || "").trim();
  if (!title) {
    return {
      statusCode: 400,
      headers,
      body: JSON.stringify({ error: "Missing ?title" })
    };
  }

  try {
    // Return cached results if available
    const key = title.toLowerCase();
    if (cache.has(key)) {
      const cached = cache.get(key);
      return { statusCode: 200, headers, body: JSON.stringify({ results: cached }) };
    }
    const url = `https://api.themoviedb.org/3/search/movie?api_key=${process.env.TMDB_KEY}&query=${encodeURIComponent(title)}`;
    // Try fetch, retry once on rate-limit
    let resp = await fetch(url);
    let json = await resp.json();
    if (resp.status === 429) {
      console.warn('TMDB rate limit, retrying once');
      await new Promise(r => setTimeout(r, 1000));
      resp = await fetch(url);
      json = await resp.json();
      if (resp.status === 429) {
        return {
          statusCode: 429,
          headers,
          body: JSON.stringify({ error: 'TMDB rate limit exceeded, please try again later' })
        };
      }
    }
    // Handle other errors
    if (!resp.ok) {
      console.error('TMDB search failed', resp.status, json);
      throw new Error(json.status_message || `TMDB HTTP ${resp.status}`);
    }
    // Parse results array
    const results = Array.isArray(json.results) ? json.results : [];
    const hits = results.map(hit => ({
      id: hit.id,
      title: hit.title,
      year: (hit.release_date || "").slice(0, 4),
      poster: hit.poster_path
    }));

    // Cache results
    cache.set(key, hits);
    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ results: hits })
    };
  } catch (err) {
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: err.message })
    };
  }
}