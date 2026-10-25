// Local test server for the web app: `deno task dev` then open http://localhost:8099/
// It sends Cache-Control: no-store on every file, so the browser always loads the newest scripts and styles while you work
// (a plain static server lets the browser keep old modules, which shows an old page next to new ones). Files are served only from web/.
const ROOT = new URL("../web/", import.meta.url);
const extname = (p) => (p.match(/\.[A-Za-z0-9]+$/) ?? [""])[0].toLowerCase();
const PORT = Number(Deno.env.get("PORT") ?? 8099);
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webp": "image/webp",
  ".jpg": "image/jpeg",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
};

Deno.serve({ port: PORT, hostname: "127.0.0.1" }, async (req) => {
  const url = new URL(req.url);
  let path = decodeURIComponent(url.pathname);
  if (path.endsWith("/")) path += "index.html";
  if (path.includes("..") || path.includes("\\")) {
    return new Response("Not found", { status: 404 });
  }
  try {
    const file = await Deno.readFile(new URL(path.slice(1), ROOT));
    return new Response(file, {
      headers: {
        "Content-Type": TYPES[extname(path)] ?? "application/octet-stream",
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch {
    return new Response("Not found", {
      status: 404,
      headers: { "Cache-Control": "no-store" },
    });
  }
});
console.log(`Serving web/ at http://localhost:${PORT}/ (no caching)`);
