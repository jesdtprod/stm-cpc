// Creates the one supabase-js client and the api wrapper around it.
// supabase-js is self-hosted (vendor/, loaded by index.html), so no third-party script runs here.
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "../supabase-config.js";
import { createApi, makeFetch } from "./api.js";

export function createClients() {
  const sdk = globalThis.supabase;
  if (!sdk) throw new Error("supabase-js did not load");
  const sink = {};
  const client = sdk.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
      storageKey: "cpc.auth",
    },
    global: { fetch: makeFetch(undefined, undefined, sink) },
  });
  return { client, api: createApi({ client, sink }) };
}
