// member-import: creates member accounts from the club's spreadsheet and makes the first admin
// (PLAN 3.2; docs/CLUB_SCHEMA.md section 2). Server-to-server only: scripts/import-members.mjs reads the
// file and calls this function in batches. Each member's first password (last 5 digits of the ID +
// birth date as MMDDYYYY) is computed here, handed to the Auth Admin API, and then dropped: it is not
// stored, not logged and not returned. The only password ever returned is the first admin's random one,
// once, to the script that writes it to a file outside the repository.
import {
  type Details,
  ID_PATTERN,
  type ImportRow,
  initialPassword,
  validateEnrichRow,
  validateImportRow,
} from "../_shared/member-import-rules.ts";

export const MAX_ROWS_PER_CALL = 60;
export const MAX_ISSUES_PER_CALL = 500;
const MAX_BODY_BYTES = 200_000;
const ISSUE_CODES = new Set([
  "duplicate_member_no",
  "invalid_member_no",
  "member_no_normalized",
  "invalid_birth_date",
  "duplicate_rfid_cleared",
  "invalid_email",
  "missing_name",
]);

export type RowOutcome =
  | {
    source_row: number;
    outcome: "created" | "created_no_account" | "existing";
    /** Set when the row was given a new member number: the number and the ID it claimed in the spreadsheet. */
    member_no?: string;
    reassigned_from?: string;
  }
  | { source_row: number; outcome: "failed"; reason: string };

export interface Deps {
  /** "token" for the temporary bootstrap token, "admin" for a signed-in user with members.import. */
  authorize: (req: Request) => Promise<"token" | "admin" | null>;
  now: () => number;
  passwordDays: number;
  /** Who already holds each of these member numbers (only numbers that exist are returned). */
  existingPeople: (
    memberNos: string[],
  ) => Promise<
    Map<string, { display_name: string; date_of_birth: string | null }>
  >;
  createAuthUser: (
    email: string,
    password: string,
  ) => Promise<
    { ok: true; id: string } | { ok: false; reason: "exists" | "failed" }
  >;
  deleteAuthUser: (id: string) => Promise<void>;
  allocate: (
    batchId: string,
    claimedNo: string,
    displayName: string,
    dob: string | null,
    reserved: string[],
  ) => Promise<{ member_no: string; existing: boolean }>;
  importMember: (a: {
    batchId: string;
    row: ImportRow;
    claimedNo: string | null;
    authUserId: string | null;
    passwordExpiresAt: string | null;
  }) => Promise<{ outcome: "created" | "existing"; rfid_cleared: boolean }>;
  begin: (sha256: string, rowCount: number) => Promise<string>;
  finish: (
    batchId: string,
    counts: {
      created: number;
      skipped: number;
      held_back: number;
      failed: number;
    },
  ) => Promise<void>;
  issue: (
    batchId: string,
    row: number,
    memberNo: string | null,
    code: string,
  ) => Promise<void>;
  /** The member number of a person who was given a new number, found by claimed ID, name and birth date. */
  findReassigned: (
    claimedNo: string,
    displayName: string,
    dob: string | null,
  ) => Promise<string | null>;
  /** Fills the person's empty fields; true when anything changed. */
  enrichPerson: (memberNo: string, details: Details) => Promise<boolean>;
  createAdmin: (
    memberNo: string,
    displayName: string,
    authUserId: string,
  ) => Promise<string>;
  /** The Auth user of an active admin with this member number; null for anyone else. */
  adminResetTarget: (memberNo: string) => Promise<string | null>;
  setAuthPassword: (authUserId: string, password: string) => Promise<boolean>;
  adminResetDone: (memberNo: string) => Promise<void>;
  randomPassword: () => string;
  log: (event: string, fields?: Record<string, string | number>) => void;
}

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });

export const internalEmail = (memberNo: string) =>
  `${memberNo.toLowerCase()}@members.cpc.app`;

type Holder = { display_name: string; date_of_birth: string | null };

const tidy = (v: string) => v.trim().replace(/\s+/g, " ").toLowerCase();
/** The same person: same name, and the same birth date when both are known. */
const samePerson = (holder: Holder, row: ImportRow) =>
  tidy(holder.display_name) === tidy(row.display_name) &&
  (holder.date_of_birth === null || row.dob === null ||
    holder.date_of_birth === row.dob);

async function processRow(
  deps: Deps,
  batchId: string,
  input: ImportRow,
  known: Map<string, Holder>,
  reserved: string[],
): Promise<RowOutcome> {
  let row = input;
  let claimed: string | null = null;
  let needsNewId = input.needs_new_id;
  if (!needsNewId) {
    const holder = known.get(input.member_no);
    if (holder) {
      if (samePerson(holder, input)) {
        return { source_row: input.source_row, outcome: "existing" };
      }
      // The number belongs to someone else: this person gets a new one instead of being skipped.
      needsNewId = true;
    }
  }
  if (needsNewId) {
    // The ID is shared with another row or person: this person gets a new number (the same one on a re-run).
    claimed = input.member_no;
    let alloc: { member_no: string; existing: boolean };
    try {
      alloc = await deps.allocate(
        batchId,
        claimed,
        input.display_name,
        input.dob,
        reserved,
      );
    } catch {
      return {
        source_row: input.source_row,
        outcome: "failed",
        reason: "allocation_failed",
      };
    }
    if (alloc.existing) {
      return {
        source_row: input.source_row,
        outcome: "existing",
        member_no: alloc.member_no,
        reassigned_from: claimed,
      };
    }
    row = { ...input, member_no: alloc.member_no };
  }
  const reassigned = claimed
    ? { member_no: row.member_no, reassigned_from: claimed }
    : {};
  let userId: string | null = null;
  if (row.dob) {
    const created = await deps.createAuthUser(
      internalEmail(row.member_no),
      initialPassword(row.member_no, row.dob),
    );
    if (!created.ok) {
      return {
        source_row: row.source_row,
        outcome: "failed",
        reason: created.reason === "exists"
          ? "auth_user_exists"
          : "auth_failed",
      };
    }
    userId = created.id;
  }
  try {
    // passwordDays = 0 means the first password does not expire (the club's decision).
    const expires = userId && deps.passwordDays > 0
      ? new Date(deps.now() + deps.passwordDays * 86_400_000).toISOString()
      : null;
    const result = await deps.importMember({
      batchId,
      row,
      claimedNo: claimed,
      authUserId: userId,
      passwordExpiresAt: expires,
    });
    if (result.outcome === "existing") {
      if (userId) await deps.deleteAuthUser(userId);
      return { source_row: row.source_row, outcome: "existing", ...reassigned };
    }
    return {
      source_row: row.source_row,
      outcome: userId ? "created" : "created_no_account",
      ...reassigned,
    };
  } catch {
    if (userId) await deps.deleteAuthUser(userId).catch(() => {});
    return {
      source_row: row.source_row,
      outcome: "failed",
      reason: "database_error",
    };
  }
}

async function pool<T, R>(
  items: T[],
  size: number,
  fn: (x: T) => Promise<R>,
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(size, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    }),
  );
  return out;
}

const isBatchId = (v: unknown): v is string =>
  typeof v === "string" && /^[0-7][0-9A-HJKMNP-TV-Z]{25}$/.test(v);
const isInt = (v: unknown, min: number, max: number): v is number =>
  typeof v === "number" && Number.isInteger(v) && v >= min && v <= max;

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.headers.get("origin")) {
    return json(403, { ok: false, code: "forbidden" });
  }
  if (req.method !== "POST") {
    return json(405, { ok: false, code: "method_not_allowed" });
  }
  if (!(await deps.authorize(req))) {
    return json(401, { ok: false, code: "unauthorized" });
  }

  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return json(413, { ok: false, code: "bad_request" });
    }
    const parsed = JSON.parse(text);
    if (
      typeof parsed !== "object" || parsed === null || Array.isArray(parsed)
    ) throw new Error("shape");
    body = parsed as Record<string, unknown>;
  } catch {
    return json(400, { ok: false, code: "bad_request" });
  }

  switch (body.action) {
    case "begin": {
      const sha = body.file_sha256;
      if (
        typeof sha !== "string" || !/^[0-9a-f]{64}$/.test(sha) ||
        !isInt(body.row_count, 0, 100000)
      ) {
        return json(400, { ok: false, code: "bad_request" });
      }
      return json(200, {
        ok: true,
        batch_id: await deps.begin(sha, body.row_count),
      });
    }

    case "rows": {
      if (
        !isBatchId(body.batch_id) || !Array.isArray(body.rows) ||
        body.rows.length < 1 || body.rows.length > MAX_ROWS_PER_CALL
      ) {
        return json(400, { ok: false, code: "bad_request" });
      }
      const results: RowOutcome[] = [];
      const valid: ImportRow[] = [];
      for (const r of body.rows) {
        const v = validateImportRow(r, new Date(deps.now()));
        if (v.ok) valid.push(v.row);
        else {
          const n = (r as { source_row?: unknown })?.source_row;
          results.push({
            source_row: typeof n === "number" ? n : 0,
            outcome: "failed",
            reason: v.reason,
          });
        }
      }
      const reserved = Array.isArray(body.reserved_nos)
        ? body.reserved_nos
        : [];
      if (
        reserved.length > 5000 ||
        !reserved.every((x) => typeof x === "string" && ID_PATTERN.test(x))
      ) {
        return json(400, { ok: false, code: "bad_request" });
      }
      const known = await deps.existingPeople(valid.map((r) => r.member_no));
      const done = await pool(
        valid,
        4,
        (row) =>
          processRow(
            deps,
            body.batch_id as string,
            row,
            known,
            reserved as string[],
          ),
      );
      results.push(...done);
      results.sort((a, b) => a.source_row - b.source_row);
      return json(200, { ok: true, results });
    }

    case "enrich": {
      if (
        !Array.isArray(body.rows) || body.rows.length < 1 ||
        body.rows.length > MAX_ROWS_PER_CALL
      ) {
        return json(400, { ok: false, code: "bad_request" });
      }
      const valid: (ImportRow & { details: Details })[] = [];
      const results: {
        source_row: number;
        outcome: "updated" | "unchanged" | "not_found" | "failed";
        reason?: string;
      }[] = [];
      for (const r of body.rows) {
        const v = validateEnrichRow(r);
        if (v.ok) valid.push(v.row);
        else {results.push({
            source_row:
              typeof (r as { source_row?: unknown })?.source_row === "number"
                ? (r as { source_row: number }).source_row
                : 0,
            outcome: "failed",
            reason: v.reason,
          });}
      }
      const known = await deps.existingPeople(valid.map((r) => r.member_no));
      const done = await pool(valid, 4, async (row) => {
        try {
          let target: string | null = null;
          if (!row.needs_new_id) {
            const holder = known.get(row.member_no);
            if (holder && samePerson(holder, row)) target = row.member_no;
          }
          target ??= await deps.findReassigned(
            row.member_no,
            row.display_name,
            row.dob,
          );
          if (!target) {
            return {
              source_row: row.source_row,
              outcome: "not_found" as const,
            };
          }
          const changed = await deps.enrichPerson(target, row.details);
          return {
            source_row: row.source_row,
            outcome: changed ? ("updated" as const) : ("unchanged" as const),
          };
        } catch {
          return {
            source_row: row.source_row,
            outcome: "failed" as const,
            reason: "database_error",
          };
        }
      });
      results.push(...done);
      results.sort((a, b) => a.source_row - b.source_row);
      return json(200, { ok: true, results });
    }

    case "issues": {
      if (
        !isBatchId(body.batch_id) || !Array.isArray(body.issues) ||
        body.issues.length > MAX_ISSUES_PER_CALL
      ) {
        return json(400, { ok: false, code: "bad_request" });
      }
      let recorded = 0;
      for (const i of body.issues as Record<string, unknown>[]) {
        const memberNo = typeof i?.member_no_claimed === "string"
          ? i.member_no_claimed.slice(0, 40)
          : null;
        if (
          !isInt(i?.source_row, 1, 100000) ||
          typeof i?.issue_code !== "string" || !ISSUE_CODES.has(i.issue_code)
        ) continue;
        await deps.issue(
          body.batch_id,
          i.source_row as number,
          memberNo,
          i.issue_code,
        );
        recorded++;
      }
      return json(200, { ok: true, recorded });
    }

    case "finish": {
      const { created, skipped, held_back, failed } = body;
      if (
        !isBatchId(body.batch_id) ||
        ![created, skipped, held_back, failed].every((n) => isInt(n, 0, 100000))
      ) {
        return json(400, { ok: false, code: "bad_request" });
      }
      await deps.finish(body.batch_id, {
        created: created as number,
        skipped: skipped as number,
        held_back: held_back as number,
        failed: failed as number,
      });
      return json(200, { ok: true });
    }

    case "create_admin": {
      const memberNo = body.member_no;
      const name = body.display_name;
      if (
        typeof memberNo !== "string" || !ID_PATTERN.test(memberNo) ||
        typeof name !== "string" || name.trim().length < 2 || name.length > 120
      ) {
        return json(400, { ok: false, code: "bad_request" });
      }
      const password = deps.randomPassword();
      const created = await deps.createAuthUser(
        internalEmail(memberNo),
        password,
      );
      if (!created.ok) {
        return json(409, {
          ok: false,
          code: created.reason === "exists" ? "already_exists" : "auth_failed",
        });
      }
      try {
        await deps.createAdmin(memberNo, name.trim(), created.id);
      } catch {
        await deps.deleteAuthUser(created.id).catch(() => {});
        return json(409, { ok: false, code: "already_exists" });
      }
      deps.log("admin.created");
      // The one place a password leaves this function: once, to the script that files it away.
      return json(200, { ok: true, member_no: memberNo, password });
    }

    case "reset_admin_password": {
      // Only for an administrator who forgot the password. The new password is random, set in Auth, and returned once
      // to the script that files it away; the account must choose its own password at the next sign-in.
      const memberNo = body.member_no;
      if (typeof memberNo !== "string" || !ID_PATTERN.test(memberNo)) {
        return json(400, { ok: false, code: "bad_request" });
      }
      const target = await deps.adminResetTarget(memberNo);
      if (!target) return json(404, { ok: false, code: "not_found" });
      const password = deps.randomPassword();
      if (!(await deps.setAuthPassword(target, password))) {
        return json(502, { ok: false, code: "auth_failed" });
      }
      await deps.adminResetDone(memberNo);
      deps.log("admin.password_reset");
      return json(200, { ok: true, member_no: memberNo, password });
    }

    default:
      return json(400, { ok: false, code: "bad_request" });
  }
}
