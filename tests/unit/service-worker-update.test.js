const source = Deno.readTextFileSync("web/service-worker.js");

function worker({ online = true, cached = new Map() } = {}) {
  const handlers = new Map();
  const requests = [];
  const installRequests = [];
  const cache = {
    addAll: (items) => { installRequests.push(...items); return Promise.resolve(); },
    match: (request) => Promise.resolve(cached.get(typeof request === "string" ? request : request.url)),
    put: () => Promise.resolve(),
  };
  const self = {
    location: new URL("https://club.example/app/service-worker.js"),
    skipWaiting: () => {},
    addEventListener: (name, handler) => handlers.set(name, handler),
  };
  const fetch = (request, options) => {
    requests.push({ request, options });
    return online ? Promise.resolve(new Response("new release")) : Promise.reject(new Error("offline"));
  };
  new Function("self", "caches", "fetch", source)(self, { open: () => Promise.resolve(cache) }, fetch);
  const get = async (path, mode = "cors") => {
    let response;
    handlers.get("fetch")({
      request: { method: "GET", url: `https://club.example/app/${path}`, mode },
      respondWith: (promise) => { response = promise; },
    });
    return await response;
  };
  return { handlers, requests, installRequests, get };
}

Deno.test("service worker: installation revalidates every shell asset", async () => {
  const env = worker();
  let pending;
  env.handlers.get("install")({ waitUntil: (promise) => { pending = promise; } });
  await pending;
  if (!env.installRequests.length || env.installRequests.some((r) => r.cache !== "no-cache")) {
    throw new Error("All shell installation requests must revalidate");
  }
});

Deno.test("service worker: online requests revalidate browser cache", async () => {
  const env = worker();
  const response = await env.get("app.js");
  if (await response.text() !== "new release" || env.requests[0]?.options.cache !== "no-cache") {
    throw new Error("Shell requests must revalidate and return the current release");
  }
});

Deno.test("service worker: offline assets use current cache, missing JS never receives HTML", async () => {
  const env = worker({ online: false, cached: new Map([
    ["https://club.example/app/styles.css", new Response("cached CSS")],
    ["index.html", new Response("offline shell")],
  ]) });
  if (await (await env.get("styles.css")).text() !== "cached CSS") throw new Error("Offline CSS unavailable");
  if ((await env.get("app.js")).type !== "error") throw new Error("Missing JS must not return HTML");
  if (await (await env.get("", "navigate")).text() !== "offline shell") throw new Error("Offline navigation unavailable");
});
