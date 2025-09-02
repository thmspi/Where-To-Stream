// Node 18 runtime provides global fetch

import pkg from "./core.js";
const { whereToStream } = pkg;

export async function handler(event) {
  // Log incoming event for troubleshooting
  console.log('incoming watch event:', JSON.stringify(event));
  const headers = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" };
  console.log("Lambda watch handler invoked with event:", JSON.stringify(event));
  const qs = event.queryStringParameters || {};
  const title = (qs.title || "").trim();
  if (!title) {
    return {
      statusCode: 400,
      headers,
      body: JSON.stringify({ error: "Missing ?title" })
    };
  }
  const countries = (qs.countries || "FR,US,DE,GB")
    .split(",").map(s => s.trim().toUpperCase()).filter(Boolean);
  const includeMode = (qs.include || "plus").toLowerCase().includes("strict") ? "strict" : "plus";
  try {
    const result = await whereToStream({ title, countries, includeMode, TMDB_KEY: process.env.TMDB_KEY });
    const providers = (qs.providers || "").split(",").map(s => s.trim()).filter(Boolean);
    if (providers.length) {
      const allow = new Set(providers);
      result.entries = result.entries.filter(e => allow.has(e.provider));
    }
    return {
      statusCode: 200,
      headers,
      body: JSON.stringify(result)
    };
  } catch (err) {
    console.error('watch handler error:', err.stack || err);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: err.message })
    };
  }
}
