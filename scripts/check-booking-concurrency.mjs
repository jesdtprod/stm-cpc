// Proves that concurrent requests for one court and time produce exactly one booking (PLAN 2.3).
// pgTAP runs in a single connection, so it cannot do this. This script opens several real
// connections at once on the linked project: each runs a transaction that inserts the same slot and
// then holds it open for two seconds, so the others must wait on the exclusion constraint.
// It creates fake rows (court "ctest-court", member CPC-2026-99991) and removes them afterwards.
// Run: deno task db:concurrency

const CLI = ["supabase@2.118.0", "db", "query", "--linked", "-o", "json"];
const PARALLEL = 4;
const CODE = "ctest-court";
const MEMBER_NO = "CPC-2026-99991";

async function sql(text, name) {
  const file = `supabase/.temp/${name}.sql`;
  await Deno.writeTextFile(file, text);
  const { code, stdout, stderr } = await new Deno.Command("npx", {
    args: ["-y", ...CLI, "-f", file],
    stdout: "piped",
    stderr: "piped",
  }).output();
  return {
    ok: code === 0,
    out: new TextDecoder().decode(stdout),
    err: new TextDecoder().decode(stderr),
  };
}

const rows = (r) => {
  try {
    return JSON.parse(r.out).rows ?? [];
  } catch {
    return [];
  }
};

await Deno.mkdir("supabase/.temp", { recursive: true });

const cleanup = `do $$
begin
  alter table public.booking_events disable trigger d_no_delete;
  alter table public.bookings disable trigger d_no_delete;
  alter table public.member_status_events disable trigger d_no_delete;
  alter table public.members disable trigger d_no_delete;
  alter table public.persons disable trigger d_no_delete;
  alter table public.courts disable trigger d_no_delete;
  delete from public.booking_events where booking_id in (select b.id from public.bookings b join public.courts c on c.id = b.court_id where c.code = '${CODE}');
  delete from public.bookings where court_id in (select id from public.courts where code = '${CODE}');
  delete from public.courts where code = '${CODE}';
  delete from public.member_status_events where member_id in (select id from public.members where member_no = '${MEMBER_NO}');
  with gone as (delete from public.members where member_no = '${MEMBER_NO}' returning person_id)
    delete from public.persons where id in (select person_id from gone);
  alter table public.booking_events enable trigger d_no_delete;
  alter table public.bookings enable trigger d_no_delete;
  alter table public.member_status_events enable trigger d_no_delete;
  alter table public.members enable trigger d_no_delete;
  alter table public.persons enable trigger d_no_delete;
  alter table public.courts enable trigger d_no_delete;
end $$;
select 1 as cleaned;`;

await sql(cleanup, "conc-cleanup");

const setup = await sql(
  `with o as (select id from public.orgs where code = 'cpc'),
p as (insert into public.persons (org_id, display_name) select id, 'Fake Concurrency Tester' from o returning id, org_id),
m as (insert into public.members (org_id, person_id, member_no, status) select org_id, id, '${MEMBER_NO}', 'pending_approval' from p returning id),
c as (insert into public.courts (org_id, code, name) select id, '${CODE}', 'Concurrency Test Court' from o returning id)
select (select count(*) from m) as members, (select count(*) from c) as courts;
update public.members set status = 'active' where member_no = '${MEMBER_NO}';
select 1 as ready;`,
  "conc-setup",
);
if (!setup.ok) {
  console.error(setup.err);
  Deno.exit(1);
}

const attemptOnce = (i) =>
  sql(
    `do $$
begin
  insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  select o.id, c.id, m.id, tstzrange('2030-01-15 09:00+08', '2030-01-15 10:00+08'), repeat('${
      i.toString(16)
    }', 64), 100, 100, c.name
  from public.orgs o, public.courts c, public.members m
  where o.code = 'cpc' and c.code = '${CODE}' and m.member_no = '${MEMBER_NO}';
  perform pg_sleep(2);
end $$;
select 1 as inserted;`,
    `conc-attempt-${i}`,
  );

// The CLI sometimes times out before the SQL even starts; run such an attempt again.
async function attempt(i) {
  for (let n = 1;; n++) {
    const r = await attemptOnce(i);
    if (
      r.ok || n === 3 ||
      !/login role|timed out|failed to connect/.test(r.err + r.out)
    ) {
      return r;
    }
  }
}

const results = await Promise.all(
  Array.from({ length: PARALLEL }, (_, i) => attempt(i + 1)),
);

const wins = results.filter((r) => r.ok).length;
const conflicts =
  results.filter((r) =>
    !r.ok && /exclusion constraint|23P01/.test(r.err + r.out)
  ).length;

const check = await sql(
  `select count(*)::int as live from public.bookings b join public.courts c on c.id = b.court_id
   where c.code = '${CODE}' and b.status in ('pending_approval','confirmed','checked_in');`,
  "conc-check",
);
const live = rows(check)[0]?.live;
const firstError = (r) =>
  (r.err + r.out).split("\n").find((l) => /ERROR|error|exclusion/.test(l))
    ?.trim().slice(0, 140);
for (const [i, r] of results.entries()) {
  if (!r.ok) console.log(`request ${i + 1} refused: ${firstError(r)}`);
}

await sql(cleanup, "conc-cleanup");
const left = await sql(
  `select (select count(*) from public.courts where code = '${CODE}')::int as courts,
          (select count(*) from public.members where member_no = '${MEMBER_NO}')::int as members;`,
  "conc-left",
);
const leftover = rows(left)[0];

console.log(
  `${PARALLEL} parallel requests: ${wins} succeeded, ${conflicts} refused by the exclusion constraint, ${live} live booking(s) in the database`,
);
console.log(
  `cleanup: ${leftover?.courts} court(s), ${leftover?.members} member(s) left`,
);
const pass = wins === 1 && conflicts === PARALLEL - 1 && live === 1 &&
  leftover?.courts === 0 && leftover?.members === 0;
console.log(pass ? "PASS" : "FAIL");
Deno.exit(pass ? 0 : 1);
