import { whereToStream } from "../lambda/core.js";

// Endpoint API local : GET /watch?title=...&countries=FR,US&include=strict|plus
app.get("/watch", async (req, res) => {
  try {
    const title = (req.query.title || "").trim();
    if (!title) return res.status(400).json({ error: "Missing ?title" });

    const countries = (req.query.countries || "FR,US,DE,GB")
      .split(",").map(s => s.trim().toUpperCase()).filter(Boolean);

    const includeMode = (req.query.include || "plus").toLowerCase().includes("strict") ? "strict" : "plus";

    const result = await whereToStream({ title, countries, includeMode, TMDB_KEY: TMDB });
    // Apply provider filter if requested
    const providers = (req.query.providers || "").split(",").map(s => s.trim()).filter(Boolean);
    if (providers.length) {
      const allow = new Set(providers);
      result.entries = result.entries.filter(e => allow.has(e.provider));
    }
    res.json(result);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: String(e) });
  }
});

const PORT = 3000;
app.listen(PORT, () => console.log(`Dev server on http://localhost:${PORT}`));
