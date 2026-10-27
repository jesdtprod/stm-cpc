// Proves that concurrent booking requests for one court and time produce exactly one booking, and that sending a
// request again returns the same booking (PLAN 2.3 and 5.4).
// pgTAP runs in a single connection, so it cannot do this. This script opens several real connections at once on the
// linked project. Each one calls the real request_booking function as a fake member (the caller is set the way the API
// sets it, through the JWT claims) and then holds its transaction open for two seconds, so the others must wait on the
// exclusion constraint. The requests are the same slot with different booking IDs: one wins, the rest lose.
// It then sends the winner's request again and expects the same booking back (replayed), and a different request under
// the same ID to be refused (CP422).
// It creates fake rows (court "ctest-court", member CPC-2026-99991, one auth user) and removes them afterwards.
// Run: deno task db:concurrency

import { ulid } from "../web/lib/ulid.js";

const CLI = ["supabase@2.118.0", "db", "query", "--linked", "-o", "json"];
const PARALLEL = 4;
const CODE = "ctest-court";
const MEMBER_NO = "CPC-2026-99991";
const START =
  `(date_trunc('day', now() at time zone 'Asia/Manila') + interval '3 days 9 hours') at time zone 'Asia/Manila'`;

// The CLI logs in with a temporary role and sometimes fails or times out before the SQL even starts, most often when
// several run at once. That is a connection problem, not a result, so such a call is simply tried again.
const CONNECTION = /login role|timed out|failed to connect|temp role/;
async function sql(text, name) {
  const file = `supabase/.temp/${name}.sql`;
  await Deno.writeTextFile(file, text);
  for (let n = 1;; n++) {
    const { code, stdout, stderr } = await new Deno.Command("npx", {
      args: ["-y", ...CLI, "-f", file],
      stdout: "piped",
      stderr: "piped",
    }).output();
    const result = {
      ok: code === 0,
      out: new TextDecoder().decode(stdout),
      err: new TextDecoder().decode(stderr),
    };
    if (result.ok || n === 5 || !CONNECTION.test(result.err + result.out)) {
      return result;
    }
    await new Promise((resolve) => setTimeout(resolve, 2000 * n));
  }
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
declare mids text[]; pids text[]; cid text; uids uuid[];
begin
  select array_agg(id), array_agg(profile_id) filter (where profile_id is not null) into mids, pids from public.members where member_no = '${MEMBER_NO}';
  select array_agg(auth_user_id) into uids from public.profiles where id = any (coalesce(pids, '{}'));
  select id into cid from public.courts where code = '${CODE}';
  alter table public.booking_participants disable trigger user;
  alter table public.booking_events disable trigger user;
  alter table public.bookings disable trigger user;
  alter table public.court_hours disable trigger user;
  alter table public.courts disable trigger user;
  alter table public.org_members disable trigger user;
  alter table public.profiles disable trigger user;
  alter table public.member_status_events disable trigger user;
  alter table public.members disable trigger user;
  alter table public.persons disable trigger user;
  delete from public.booking_participants where booking_id in (select id from public.bookings where court_id = cid);
  delete from public.booking_events where booking_id in (select id from public.bookings where court_id = cid);
  delete from public.bookings where court_id = cid;
  delete from public.court_hours where court_id = cid;
  delete from public.courts where id = cid;
  delete from public.member_status_events where member_id = any (coalesce(mids, '{}'));
  delete from public.org_members where profile_id = any (coalesce(pids, '{}'));
  with gone as (delete from public.members where member_no = '${MEMBER_NO}' returning person_id, profile_id)
    delete from public.profiles where id in (select profile_id from gone);
  delete from public.persons where display_name = 'Fake Concurrency Tester';
  alter table public.booking_participants enable trigger user;
  alter table public.booking_events enable trigger user;
  alter table public.bookings enable trigger user;
  alter table public.court_hours enable trigger user;
  alter table public.courts enable trigger user;
  alter table public.org_members enable trigger user;
  alter table public.profiles enable trigger user;
  alter table public.member_status_events enable trigger user;
  alter table public.members enable trigger user;
  alter table public.persons enable trigger user;
  delete from auth.users where id = any (coalesce(uids, '{}'));
end $$;
select 1 as cleaned;`;

await sql(cleanup, "conc-cleanup");

// A fake active member with an account, and a court open all day, every day.
const AUTH_ID = crypto.randomUUID();
const setup = await sql(
  `do $$
declare o text := (select id from public.orgs where code = 'cpc'); per text := core.ulid(); prof text := core.ulid(); mid text := core.ulid(); cid text := core.ulid();
begin
  insert into auth.users (id, email) values ('${AUTH_ID}', 'ctest-99991@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, o, 'Fake Concurrency Tester');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (prof, o, '${AUTH_ID}', per);
  insert into public.org_members (org_id, profile_id, role_id) values (o, prof, (select id from public.roles where org_id = o and code = 'member'));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, o, per, prof, '${MEMBER_NO}');
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  insert into public.courts (id, org_id, code, name) values (cid, o, '${CODE}', 'Concurrency Test Court');
  insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from)
  select o, cid, d, '00:00', '23:59:59', '2000-01-01' from generate_series(0, 6) d;
end $$;
select 1 as ready;`,
  "conc-setup",
);
if (!setup.ok) {
  console.error(setup.err);
  Deno.exit(1);
}

const call = (id) =>
  `perform set_config('request.jwt.claims', json_build_object('sub', '${AUTH_ID}', 'role', 'authenticated')::text, true);
  perform core.request_booking('${id}', (select id from public.courts where code = '${CODE}'), ${START}, 60, '{}');`;

const attemptOnce = (i, id) =>
  sql(
    `do $$
begin
  ${call(id)}
  perform pg_sleep(2);
end $$;
select 1 as booked;`,
    `conc-attempt-${i}`,
  );

const attempt = (i, id) => attemptOnce(i, id);

const ids = Array.from({ length: PARALLEL }, () => ulid());
const results = await Promise.all(ids.map((id, i) => attempt(i + 1, id)));

const wins = results.filter((r) => r.ok).length;
const conflicts =
  results.filter((r) =>
    !r.ok && /just taken|exclusion|23P01|Only 1 booking/.test(r.err + r.out)
  ).length;
const winnerId = ids[results.findIndex((r) => r.ok)];

const check = await sql(
  `select count(*)::int as live from public.bookings b join public.courts c on c.id = b.court_id
   where c.code = '${CODE}' and b.status in ('pending_approval','confirmed','checked_in');`,
  "conc-check",
);
const live = rows(check)[0]?.live;

// Retry: the winner's request again returns the same booking; another request under the same ID is refused.
const retry = await sql(
  `do $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '${AUTH_ID}', 'role', 'authenticated')::text, true);
  r := core.request_booking('${winnerId}', (select id from public.courts where code = '${CODE}'), ${START}, 60, '{}');
  if r ->> 'id' <> '${winnerId}' or (r ->> 'replayed') is distinct from 'true' then
    raise exception 'RETRY_NOT_SAME';
  end if;
  begin
    perform core.request_booking('${winnerId}', (select id from public.courts where code = '${CODE}'), ${START}, 120, '{}');
    raise exception 'DIFFERENT_NOT_REFUSED';
  exception when sqlstate 'CP422' then
    null;
  end;
end $$;
select 1 as retried;`,
  "conc-retry",
);
const retried = retry.ok;
const total = await sql(
  `select count(*)::int as n from public.bookings b join public.courts c on c.id = b.court_id where c.code = '${CODE}';`,
  "conc-total",
);
const bookings = rows(total)[0]?.n;

const firstError = (r) =>
  (r.err + r.out).split("\n").find((l) => /ERROR|error|exclusion|taken/.test(l))
    ?.trim().slice(0, 140);
for (const [i, r] of results.entries()) {
  if (!r.ok) console.log(`request ${i + 1} refused: ${firstError(r)}`);
}
if (!retried) console.log(`retry check failed: ${firstError(retry)}`);

await sql(cleanup, "conc-cleanup");
const left = await sql(
  `select (select count(*) from public.courts where code = '${CODE}')::int as courts,
          (select count(*) from public.members where member_no = '${MEMBER_NO}')::int as members,
          (select count(*) from auth.users where email = 'ctest-99991@members.example.test')::int as users;`,
  "conc-left",
);
const leftover = rows(left)[0];

console.log(
  `${PARALLEL} parallel requests: ${wins} succeeded, ${conflicts} refused by court or daily limits, ${live} live booking(s) in the database`,
);
console.log(
  `retry with the same ID: ${
    retried ? "same booking returned, a different request refused" : "FAILED"
  }; bookings for the court: ${bookings}`,
);
console.log(
  `cleanup: ${leftover?.courts} court(s), ${leftover?.members} member(s), ${leftover?.users} user(s) left`,
);
const pass = wins === 1 && conflicts === PARALLEL - 1 && live === 1 &&
  retried && bookings === 1 && leftover?.courts === 0 &&
  leftover?.members === 0 && leftover?.users === 0;
console.log(pass ? "PASS" : "FAIL");
Deno.exit(pass ? 0 : 1);
