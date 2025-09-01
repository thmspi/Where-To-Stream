// dev-server/index.mjs
import fetch from "node-fetch";

dotenv.config(); // charge TMDB_KEY depuis .env
const TMDB = process.env.TMDB_KEY;

export async function handler(event) {
  const title = (event.queryStringParameters?.title || "").trim();
  if (!title) {
    return {
      statusCode: 400,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: "Missing ?title" })
    };
  }

  try {
    const url = `https://api.themoviedb.org/3/search/movie?api_key=${process.env.TMDB_KEY}&query=${encodeURIComponent(title)}`;
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`TMDB HTTP ${resp.status}`);
    const { results = [] } = await resp.json();
    const hits = results.map(hit => ({
      id: hit.id,
      title: hit.title,
      year: (hit.release_date || "").slice(0, 4),
      poster: hit.poster_path
    }));

    return {
      statusCode: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ results: hits })
    };
  } catch (err) {
    return {
      statusCode: 500,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: err.message })
    };
  }
}