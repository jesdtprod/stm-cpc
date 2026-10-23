// Rules for the existing-member import (PLAN 3.2; docs/CLUB_SCHEMA.md section 2).
// Pure functions, no network: used by scripts/import-members.mjs to read the whole file (duplicates need
// every row) and by the member-import Edge Function to re-check each row it receives.
// Only six fields are imported: ID NO, Display Name, Date of Birth, Mobile Number, Email Address, RFID CODE.

export const ID_PATTERN = /^CPC-\d{4}-\d{5}$/;
export const MIN_BIRTH_YEAR = 1920;

export type IssueCode =
  | "duplicate_member_no"
  | "invalid_member_no"
  | "member_no_normalized"
  | "invalid_birth_date"
  | "duplicate_rfid_cleared"
  | "invalid_email"
  | "missing_name"
  | "member_no_reassigned";

export interface RawRow {
  /** Row number in the spreadsheet (header is row 1). */
  row: number;
  id_no: string | null;
  display_name: string | null;
  /** ISO date when the cell was a real date. */
  dob: string | null;
  /** Text when the cell was text (read as month/day/year). */
  dob_text: string | null;
  mobile: string | null;
  email: string | null;
  rfid: string | null;
}

export interface ImportRow {
  source_row: number;
  member_no: string;
  display_name: string;
  /** ISO date, or null when missing/unreadable (the member is created without an account). */
  dob: string | null;
  mobile: string | null;
  email: string | null;
  rfid: string | null;
  /**
   * True when another row has the same ID: the first row keeps it, every other row gets a new number from
   * the club's yearly sequence, assigned by the server. `member_no` then holds the ID the row claimed.
   */
  needs_new_id: boolean;
}

export interface Issue {
  source_row: number;
  member_no_claimed: string | null;
  issue_code: IssueCode;
}

export interface Analysis {
  rows: ImportRow[];
  issues: Issue[];
  counts: {
    total: number;
    skipped_no_id: number;
    held_back: number;
    reassigned: number;
    importable: number;
    with_account: number;
    without_account: number;
  };
}

const clean = (v: unknown): string | null => {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s === "" ? null : s;
};

/** "  cpc-2026-00001 " -> "CPC-2026-00001"; a six-digit number with one leading zero is shortened. */
export function normalizeMemberNo(
  raw: string | null,
): { member_no: string; shortened: boolean } | null {
  const s = clean(raw)?.toUpperCase();
  if (!s) return null;
  if (ID_PATTERN.test(s)) return { member_no: s, shortened: false };
  const m = /^CPC-(\d{4})-0(\d{5})$/.exec(s);
  if (m) return { member_no: `CPC-${m[1]}-${m[2]}`, shortened: true };
  return null;
}

/** Real calendar date from 1920 up to today, as YYYY-MM-DD; otherwise null. */
export function validIsoDate(iso: string, today = new Date()): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const date = new Date(Date.UTC(y, mo - 1, d));
  if (
    date.getUTCFullYear() !== y || date.getUTCMonth() !== mo - 1 ||
    date.getUTCDate() !== d
  ) return null;
  if (y < MIN_BIRTH_YEAR) return null;
  if (date.getTime() > today.getTime()) return null;
  return iso;
}

/** Text dates are read as month/day/year, the club's format. */
export function parseBirthDate(
  isoCell: string | null,
  text: string | null,
  today = new Date(),
): string | null {
  const iso = clean(isoCell);
  if (iso) return validIsoDate(iso.slice(0, 10), today);
  const t = clean(text);
  if (!t) return null;
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(t);
  if (!m) return null;
  const pad = (n: string) => n.padStart(2, "0");
  return validIsoDate(`${m[3]}-${pad(m[1])}-${pad(m[2])}`, today);
}

/** 09XXXXXXXXX when the number can be read as a Philippine mobile; otherwise as typed (trimmed). */
export function normalizeMobile(raw: string | null): string | null {
  const s = clean(raw);
  if (!s) return null;
  const digits = s.replace(/\D/g, "");
  if (/^09\d{9}$/.test(digits)) return digits;
  if (/^9\d{9}$/.test(digits)) return `0${digits}`;
  if (/^639\d{9}$/.test(digits)) return `0${digits.slice(2)}`;
  return s.slice(0, 32);
}

/** Lowercase address, or null when it does not look like an email. */
export function normalizeEmail(raw: string | null): string | null {
  const s = clean(raw)?.toLowerCase();
  if (!s || s.length > 254) return null;
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s) ? s : null;
}

export function normalizeRfid(raw: string | null): string | null {
  const s = clean(raw);
  if (!s) return null;
  return s.slice(0, 40);
}

export function cleanName(raw: string | null): string | null {
  const s = clean(raw)?.replace(/\s+/g, " ");
  return s ? s.slice(0, 120) : null;
}

/**
 * First password: the last 5 digits of the member ID followed by the birth date as MMDDYYYY, for example
 * CPC-2026-00001 born 2025-12-21 -> "0000112212025". Called only inside the Edge Function, never stored.
 */
export function initialPassword(memberNo: string, dobIso: string): string {
  const digits = memberNo.replace(/\D/g, "");
  const [y, m, d] = dobIso.split("-");
  return `${digits.slice(-5)}${m}${d}${y}`;
}

/**
 * The whole-file pass: skips, hold-backs, shared IDs and RFID codes, and per-row clean-up.
 * Rows that share an ID are all imported: the first (lowest spreadsheet row) keeps the ID and the others are
 * marked `needs_new_id`.
 */
export function analyzeFile(raw: RawRow[], today = new Date()): Analysis {
  const issues: Issue[] = [];
  const rfidRows = new Map<string, number[]>();
  let skippedNoId = 0;

  const parsed = raw.map((r) => {
    const id = clean(r.id_no);
    const norm = normalizeMemberNo(r.id_no);
    const rfid = normalizeRfid(r.rfid);
    if (rfid) rfidRows.set(rfid, [...(rfidRows.get(rfid) ?? []), r.row]);
    return { r, id, norm, rfid, name: cleanName(r.display_name) };
  });

  // Only rows that can be imported claim an ID; the first claimant keeps it.
  const firstClaimant = new Map<string, number>();
  for (const p of parsed) {
    if (p.norm && p.name && !firstClaimant.has(p.norm.member_no)) {
      firstClaimant.set(p.norm.member_no, p.r.row);
    }
  }

  const rows: ImportRow[] = [];
  let held = 0;
  let reassigned = 0;
  for (const { r, id, norm, rfid, name } of parsed) {
    if (!id) {
      skippedNoId++;
      continue;
    }
    if (!norm) {
      issues.push({
        source_row: r.row,
        member_no_claimed: id.toUpperCase().slice(0, 40),
        issue_code: "invalid_member_no",
      });
      held++;
      continue;
    }
    if (!name) {
      issues.push({
        source_row: r.row,
        member_no_claimed: norm.member_no,
        issue_code: "missing_name",
      });
      held++;
      continue;
    }
    const needsNewId = firstClaimant.get(norm.member_no) !== r.row;
    if (needsNewId) reassigned++;
    if (norm.shortened) {
      issues.push({
        source_row: r.row,
        member_no_claimed: norm.member_no,
        issue_code: "member_no_normalized",
      });
    }
    const dob = parseBirthDate(r.dob, r.dob_text, today);
    if (!dob) {
      issues.push({
        source_row: r.row,
        member_no_claimed: norm.member_no,
        issue_code: "invalid_birth_date",
      });
    }
    const email = normalizeEmail(r.email);
    if (clean(r.email) && !email) {
      issues.push({
        source_row: r.row,
        member_no_claimed: norm.member_no,
        issue_code: "invalid_email",
      });
    }
    let keepRfid = rfid;
    if (rfid && (rfidRows.get(rfid)?.length ?? 0) > 1) {
      issues.push({
        source_row: r.row,
        member_no_claimed: norm.member_no,
        issue_code: "duplicate_rfid_cleared",
      });
      keepRfid = null;
    }
    rows.push({
      source_row: r.row,
      member_no: norm.member_no,
      display_name: name,
      dob,
      mobile: normalizeMobile(r.mobile),
      email,
      rfid: keepRfid,
      needs_new_id: needsNewId,
    });
  }

  const withAccount = rows.filter((x) => x.dob).length;
  return {
    rows,
    issues,
    counts: {
      total: raw.length,
      skipped_no_id: skippedNoId,
      held_back: held,
      reassigned,
      importable: rows.length,
      with_account: withAccount,
      without_account: rows.length - withAccount,
    },
  };
}

/** The Edge Function re-checks every row it is sent; returns the cleaned row or the reason it is refused. */
export function validateImportRow(
  v: unknown,
  today = new Date(),
): { ok: true; row: ImportRow } | { ok: false; reason: string } {
  if (typeof v !== "object" || v === null) {
    return { ok: false, reason: "not_an_object" };
  }
  const o = v as Record<string, unknown>;
  const row = o.source_row;
  if (
    typeof row !== "number" || !Number.isInteger(row) || row < 1 || row > 100000
  ) {
    return { ok: false, reason: "bad_row_number" };
  }
  const memberNo = typeof o.member_no === "string" ? o.member_no : "";
  if (!ID_PATTERN.test(memberNo)) return { ok: false, reason: "bad_member_no" };
  const name = cleanName(
    typeof o.display_name === "string" ? o.display_name : null,
  );
  if (!name) return { ok: false, reason: "missing_name" };
  let dob: string | null = null;
  if (o.dob !== null && o.dob !== undefined) {
    if (typeof o.dob !== "string") {
      return { ok: false, reason: "bad_birth_date" };
    }
    dob = validIsoDate(o.dob, today);
    if (!dob) return { ok: false, reason: "bad_birth_date" };
  }
  const str = (x: unknown, max: number): string | null =>
    typeof x === "string" && x.trim() !== "" ? x.trim().slice(0, max) : null;
  const email = str(o.email, 254) ? normalizeEmail(str(o.email, 254)) : null;
  return {
    ok: true,
    row: {
      source_row: row,
      member_no: memberNo,
      display_name: name,
      dob,
      mobile: str(o.mobile, 32),
      email,
      rfid: str(o.rfid, 40),
      needs_new_id: o.needs_new_id === true,
    },
  };
}
