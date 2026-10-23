// One wrapper for every supabase-js call (PLAN 1B.4).
//  * a ULID key made when a form opens and reused on every retry (DATABASE.md section 7)
//  * an x-request-id header on every request, written to the audit log by the database
//  * database and network errors mapped to plain-language messages
import { ulid } from "./ulid.js";

const MESSAGES = {
  network: "Can't reach the server. Check your connection and try again.",
  captcha: "The security check failed. Try again.",
  in_progress: "That request is still being processed. Try again in a moment.",
  conflict:
    "This request does not match an earlier one. Reload the page and try again.",
  forbidden: "You don't have permission to do that.",
  session_expired: "Your session has expired. Sign in again.",
  duplicate: "That already exists.",
  in_use:
    "That item is linked to other records, so it can't be changed this way.",
  invalid: "Some of the information is not valid. Check it and try again.",
  state: "That record can't be changed in its current state.",
  not_found: "We couldn't find that record.",
  server: "Something went wrong on our side. Try again in a moment.",
  unknown: "Something went wrong. Try again.",
};
const RETRYABLE = new Set(["network", "in_progress", "server"]);

export class ApiError extends Error {
  constructor(
    kind,
    { code = null, status = null, requestId = null, cause } = {},
  ) {
    super(MESSAGES[kind] ?? MESSAGES.unknown, { cause });
    this.name = "ApiError";
    this.kind = kind;
    this.code = code;
    this.status = status;
    this.requestId = requestId;
    this.retryable = RETRYABLE.has(kind);
  }
}

/** Maps a supabase-js / PostgREST / Postgres / fetch error to an ApiError. */
export function mapError(err, requestId = null) {
  if (err instanceof ApiError) return err;
  const code = String(err?.code ?? err?.error_code ?? "");
  const status = Number(err?.status ?? err?.statusCode ?? 0) || null;
  const text = String(err?.message ?? "");
  let kind = "unknown";
  if (
    err?.name === "TypeError" && /fetch|network/i.test(text) ||
    err?.name === "AuthRetryableFetchError"
  ) kind = "network";
  else if (code === "captcha_failed") kind = "captcha";
  else if (code === "CP409") kind = "in_progress";
  else if (code === "CP422") kind = "conflict";
  else if (code === "PGRST301" || /jwt expired/i.test(text) || status === 401) {
    kind = "session_expired";
  } else if (code === "42501" || status === 403) kind = "forbidden";
  else if (code === "23505") kind = "duplicate";
  else if (code === "23503") kind = "in_use";
  else if (["23514", "22023", "22P02", "23502"].includes(code)) {
    kind = "invalid";
  } else if (code === "55000") kind = "state";
  else if (code === "PGRST116") kind = "not_found";
  else if (status && status >= 500) kind = "server";
  return new ApiError(kind, {
    code: code || null,
    status,
    requestId,
    cause: err,
  });
}

/** fetch wrapper that stamps a fresh x-request-id on every request and remembers the latest. */
export function makeFetch(
  base = (...args) => fetch(...args),
  newId = ulid,
  sink = {},
) {
  const wrapped = (input, init = {}) => {
    const headers = new Headers(
      init.headers ?? (input instanceof Request ? input.headers : undefined),
    );
    const id = newId();
    headers.set("x-request-id", id);
    sink.lastRequestId = id;
    return base(input, { ...init, headers });
  };
  wrapped.sink = sink;
  return wrapped;
}

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Runs `fn` (returning a supabase-js {data, error}), retrying retryable failures with the SAME inputs. */
export async function call(
  fn,
  { retries = 2, baseMs = 400, sleep = defaultSleep, requestId = () => null } =
    {},
) {
  for (let attempt = 0;; attempt++) {
    try {
      const { data, error } = await fn();
      if (error) throw error;
      return data;
    } catch (e) {
      const err = mapError(e, requestId());
      if (!err.retryable || attempt >= retries) throw err;
      await sleep(baseMs * 2 ** attempt);
    }
  }
}

/**
 * api = createApi({ client, sink, ...retryOptions })
 *   api.newKey()                     ULID for a new user intent; reuse it for every retry of that intent
 *   api.rpc(name, args, { key })     calls an RPC; the key is passed as p_idempotency_key
 *   api.create(table, key, row)      insert with id = key; a retry of the same key is a no-op
 *   api.read(buildQuery)             buildQuery(client) returns a supabase-js query
 */
export function createApi({ client, sink = {}, ...options }) {
  const opts = { ...options, requestId: () => sink.lastRequestId ?? null };
  return {
    newKey: () => ulid(),
    lastRequestId: () => sink.lastRequestId ?? null,
    rpc: (name, args = {}, { key, ...callOptions } = {}) =>
      call(
        () =>
          client.rpc(name, key ? { ...args, p_idempotency_key: key } : args),
        { ...opts, ...callOptions },
      ),
    create: (table, key, row, callOptions) =>
      call(
        () =>
          client.from(table).upsert({ ...row, id: key }, {
            onConflict: "id",
            ignoreDuplicates: true,
          }),
        { ...opts, ...callOptions },
      ),
    read: (buildQuery, callOptions) =>
      call(() => buildQuery(client), { ...opts, ...callOptions }),
  };
}
