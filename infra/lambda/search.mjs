// dev-server/index.mjs
import express from "express";
import dotenv from "dotenv";
import fetch from "node-fetch";
import { whereToStream } from "../lambda/core.js";

dotenv.config(); // charge TMDB_KEY depuis .env
const TMDB = process.env.TMDB_KEY;

const app = express();

// Sert la page web locale depuis /web
app.use(express.static("web"));
// Local search endpoint: GET /search?title=…
app.get("/search", async (req, res) => {
  try {
    const title = (req.query.title || "").trim();
    if (!title) return res.status(400).json({ error: "Missing ?title" });

    const url = `https://api.themoviedb.org/3/search/movie?api_key=${TMDB}&query=${encodeURIComponent(title)}`;
    const r = await fetch(url);
    if (!r.ok) throw new Error(`TMDB search HTTP ${r.status}`);
    const { results = [] } = await r.json();

    const hits = results.map(hit => ({
      id: hit.id,
      title: hit.title,
      year: (hit.release_date || "").slice(0, 4),
      poster: hit.poster_path
    }));
    res.json({ results: hits });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: String(e) });
  }
});