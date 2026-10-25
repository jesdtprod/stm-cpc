-- 1560_notifications (PLAN 9.3; the older public.notifications queue from 0005 stays for SMS and email later): notifications that reach people in real time, even when the app is hidden or closed.
--   * member_notifications (append-only): one row per message for one member, written by database triggers when something that
--     matters happens (approval, booking decisions, payments, event registration, the draw, results, rank changes, a scheduled
--     match). Staff get a message when something waits for them (a new member, booking request, payment or registration).
--   * Realtime: open pages hear about a new row at once (Supabase Realtime, filtered by row-level security to the owner).
--   * Web Push: when the member has registered a device, the insert asks the Edge Function push-send (through pg_net, with a
--     shared secret kept in the vault) to push it to the device, so the message arrives even when the browser is in the
--     background or closed. The push payload is only a title, a short text and an in-app address.
--   * push_subscriptions hold each device's push address and keys. They are never readable from the browser (no policy);
--     devices are registered and removed only through register_push / unregister_push.
--   * A failure to push never blocks the business action that caused the message.

create extension if not exists pg_net;

-- ---------------------------------------------------------------------------
-- tables
-- ---------------------------------------------------------------------------
create table public.member_notifications (
  id         text collate "C" primary key default core.ulid(),
  org_id     text not null references public.orgs (id) on delete restrict,
  unit_id    text collate "C" references public.org_units (id) on delete restrict,
  member_id  text collate "C" not null references public.members (id) on delete restrict,
  kind       text not null constraint member_notifications_kind_chk check (kind ~ '^[a-z_]+\.[a-z_]+$'),
  title      text not null constraint member_notifications_title_chk check (length(btrim(title)) between 1 and 120),
  body       text constraint member_notifications_body_chk check (body is null or length(body) <= 300),
  url        text constraint member_notifications_url_chk check (url is null or url ~ '^#/[A-Za-z0-9/_?=&.-]{0,200}$'),
  created_at timestamptz not null default now(),
  created_by text,
  updated_at timestamptz not null default now(),
  updated_by text,
  version    integer not null default 1,
  meta       jsonb not null default '{}'::jsonb
);
comment on table public.member_notifications is 'class: ledger (append-only). One message for one member. Written by triggers only; read by its owner.';
create index member_notifications_org_idx on public.member_notifications (org_id);
create index member_notifications_unit_idx on public.member_notifications (unit_id);
create index member_notifications_member_idx on public.member_notifications (member_id, created_at desc);

create table public.member_notification_reads (
  id              text collate "C" primary key default core.ulid(),
  org_id          text not null references public.orgs (id) on delete restrict,
  unit_id         text collate "C" references public.org_units (id) on delete restrict,
  member_id       text collate "C" not null references public.members (id) on delete restrict,
  notification_id text collate "C" not null references public.member_notifications (id) on delete restrict,
  created_at      timestamptz not null default now(),
  created_by      text,
  updated_at      timestamptz not null default now(),
  updated_by      text,
  version         integer not null default 1,
  meta            jsonb not null default '{}'::jsonb,
  constraint member_notification_reads_uq unique (notification_id, member_id)
);
comment on table public.member_notification_reads is 'class: ledger (append-only). Marks a notification as read by its owner.';
create index member_notification_reads_org_idx on public.member_notification_reads (org_id);
create index member_notification_reads_unit_idx on public.member_notification_reads (unit_id);
create index member_notification_reads_member_idx on public.member_notification_reads (member_id);

create table public.push_subscriptions (
  id           text collate "C" primary key default core.ulid(),
  org_id       text not null references public.orgs (id) on delete restrict,
  unit_id      text collate "C" references public.org_units (id) on delete restrict,
  profile_id   text collate "C" not null references public.profiles (id) on delete restrict,
  endpoint     text not null constraint push_subscriptions_endpoint_chk check (endpoint ~ '^https://' and length(endpoint) <= 1000),
  p256dh       text not null constraint push_subscriptions_p256dh_chk check (length(p256dh) between 20 and 200),
  auth_key     text not null constraint push_subscriptions_auth_chk check (length(auth_key) between 8 and 100),
  user_agent   text constraint push_subscriptions_ua_chk check (user_agent is null or length(user_agent) <= 300),
  revoked_at   timestamptz,
  last_ok_at   timestamptz,
  created_at   timestamptz not null default now(),
  created_by   text,
  updated_at   timestamptz not null default now(),
  updated_by   text,
  version      integer not null default 1,
  meta         jsonb not null default '{}'::jsonb,
  constraint push_subscriptions_endpoint_uq unique (endpoint)
);
comment on table public.push_subscriptions is 'class: document. A device registered for push messages. Contains the device keys: never readable from the browser, only through register_push / unregister_push and the push-send function (service role).';
create index push_subscriptions_org_idx on public.push_subscriptions (org_id);
create index push_subscriptions_unit_idx on public.push_subscriptions (unit_id);
create index push_subscriptions_profile_idx on public.push_subscriptions (profile_id) where revoked_at is null;

select core.attach_standard('public.member_notifications', 'ledger');
select core.attach_standard('public.member_notification_reads', 'ledger');
select core.attach_standard('public.push_subscriptions', 'document');

alter table public.member_notifications enable row level security;
alter table public.member_notification_reads enable row level security;
alter table public.push_subscriptions enable row level security;
create policy member_notifications_select on public.member_notifications for select to authenticated using (core.is_own_member(member_id));
create policy member_notification_reads_select on public.member_notification_reads for select to authenticated using (core.is_own_member(member_id));
select core.grant_client_dml('public.member_notifications', false, false);
select core.grant_client_dml('public.member_notification_reads', false, false);
revoke all on public.push_subscriptions from anon, authenticated;
grant select, insert, update on public.member_notifications, public.member_notification_reads, public.push_subscriptions to service_role;

-- open pages hear about new rows at once
do $$
begin
  alter publication supabase_realtime add table public.member_notifications;
exception when others then
  null; -- no realtime publication (a bare local database) or already added
end $$;

-- ---------------------------------------------------------------------------
-- writing messages
-- ---------------------------------------------------------------------------
create or replace function core.notify_member(p_member_id text, p_kind text, p_title text, p_body text, p_url text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.member_notifications (org_id, member_id, kind, title, body, url)
  select m.org_id, m.id, p_kind, left(p_title, 120), left(p_body, 300), p_url
  from public.members m where m.id = p_member_id and m.deleted_at is null;
end $$;
revoke all on function core.notify_member(text, text, text, text, text) from public, anon, authenticated;

-- the members of a club who hold a permission
create or replace function core.members_with_permission(p_org text, p_code text) returns setof text
language sql stable security definer set search_path = '' as $$
  select distinct m.id
  from public.members m
  join public.profiles p on p.id = m.profile_id and p.is_active and p.deleted_at is null
  join public.org_members om on om.profile_id = p.id and om.org_id = p_org and om.is_active and om.deleted_at is null
  join public.role_permissions rp on rp.role_id = om.role_id and rp.deleted_at is null
  join public.permissions pe on pe.id = rp.permission_id and pe.code = p_code and pe.deleted_at is null
  where m.org_id = p_org and m.deleted_at is null and m.status = 'active'
$$;
revoke all on function core.members_with_permission(text, text) from public, anon, authenticated;

create or replace function core.notify_staff(p_org text, p_code text, p_kind text, p_title text, p_body text, p_url text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v text;
begin
  for v in select core.members_with_permission(p_org, p_code) loop
    perform core.notify_member(v, p_kind, p_title, p_body, p_url);
  end loop;
end $$;
revoke all on function core.notify_staff(text, text, text, text, text, text) from public, anon, authenticated;

create or replace function core.manila_when(p_at timestamptz) returns text
language sql stable set search_path = '' as $$
  select to_char(p_at at time zone 'Asia/Manila', 'Dy Mon FMDD, FMHH12:MI AM')
$$;
revoke all on function core.manila_when(timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- pushing to registered devices
-- ---------------------------------------------------------------------------
create or replace function core.tg_member_notifications_dispatch() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
  v_secret text;
begin
  begin
    if exists (
      select 1 from public.push_subscriptions s join public.members m on m.profile_id = s.profile_id
      where m.id = new.member_id and s.revoked_at is null) then
      select d.decrypted_secret into v_url from vault.decrypted_secrets d where d.name = 'push_function_url';
      select d.decrypted_secret into v_secret from vault.decrypted_secrets d where d.name = 'push_dispatch_secret';
      if v_url is not null and v_secret is not null then
        perform net.http_post(url := v_url, body := jsonb_build_object('notification_id', new.id),
          headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),
          timeout_milliseconds := 5000);
      end if;
    end if;
  exception when others then
    null; -- a push problem must never undo the action that caused the message
  end;
  return null;
end $$;
revoke all on function core.tg_member_notifications_dispatch() from public, anon, authenticated;
create trigger z_member_notifications_dispatch after insert on public.member_notifications
  for each row execute function core.tg_member_notifications_dispatch();

-- ---------------------------------------------------------------------------
-- what causes a message
-- ---------------------------------------------------------------------------
-- members: approved, rejected, suspended; staff hear of a new application
create or replace function core.tg_notify_member_status() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  select p.display_name into v_name from public.persons p where p.id = new.person_id;
  if new.status = 'pending_approval' then
    perform core.notify_staff(new.org_id, 'members.approve', 'staff.member_pending', 'New member waiting for approval',
      coalesce(v_name, 'Someone') || ' applied to join the club.', '#/admin/members');
  elsif tg_op = 'UPDATE' and new.status = 'active' and old.status in ('pending_approval', 'invited') then
    perform core.notify_member(new.id, 'member.approved', 'Your membership was approved',
      'You can now book courts, join events and follow your ranking.', '#/');
  elsif tg_op = 'UPDATE' and new.status = 'rejected' then
    perform core.notify_member(new.id, 'member.rejected', 'Your application was not approved',
      'Please contact the club if you have questions.', '#/pending');
  elsif tg_op = 'UPDATE' and new.status = 'suspended' then
    perform core.notify_member(new.id, 'member.suspended', 'Your membership was suspended',
      'Please contact the club for details.', '#/pending');
  end if;
  return null;
end $$;
revoke all on function core.tg_notify_member_status() from public, anon, authenticated;
create trigger z_members_notify after insert or update of status on public.members
  for each row execute function core.tg_notify_member_status();

-- bookings: a new request for staff; confirmed, declined, cancelled by someone else or expired for the member
create or replace function core.tg_notify_booking() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_when text := core.manila_when(lower(new.during));
  v_actor text := core.current_profile_id();
  v_owner_profile text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  select m.profile_id into v_owner_profile from public.members m where m.id = new.requested_by_member_id;
  if new.status = 'pending_approval' then
    perform core.notify_staff(new.org_id, 'bookings.approve', 'staff.booking_request', 'New court booking request',
      new.court_name_snapshot || ' · ' || v_when, '#/admin/bookings');
  elsif new.status = 'confirmed' then
    perform core.notify_member(new.requested_by_member_id, 'booking.confirmed', 'Your booking is confirmed',
      new.court_name_snapshot || ' · ' || v_when, '#/bookings');
  elsif new.status = 'rejected' then
    perform core.notify_member(new.requested_by_member_id, 'booking.rejected', 'Your booking was declined',
      new.court_name_snapshot || ' · ' || v_when, '#/bookings');
  elsif new.status = 'cancelled' and v_actor is distinct from v_owner_profile then
    perform core.notify_member(new.requested_by_member_id, 'booking.cancelled', 'Your booking was cancelled by the club',
      new.court_name_snapshot || ' · ' || v_when, '#/bookings');
  elsif new.status = 'expired' then
    perform core.notify_member(new.requested_by_member_id, 'booking.expired', 'Your booking request expired',
      new.court_name_snapshot || ' · ' || v_when, '#/bookings');
  end if;
  return null;
end $$;
revoke all on function core.tg_notify_booking() from public, anon, authenticated;
create trigger z_bookings_notify after insert or update of status on public.bookings
  for each row execute function core.tg_notify_booking();

-- payments: waiting for staff; verified, rejected or voided for the payer
create or replace function core.tg_notify_payment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  if new.status = 'submitted' then
    perform core.notify_staff(new.org_id, 'payments.verify', 'staff.payment_submitted', 'Payment waiting to be checked',
      'A payment of ' || to_char(new.amount, 'FM999,999,990.00') || ' was submitted.', '#/admin/payments');
  elsif new.status = 'verified' then
    perform core.notify_member(new.payer_member_id, 'payment.verified', 'Your payment was verified',
      'Thank you. ' || new.doc_no, '#/bookings');
  elsif new.status = 'rejected' then
    perform core.notify_member(new.payer_member_id, 'payment.rejected', 'Your payment was not accepted',
      coalesce('Reason: ' || new.reject_reason, new.doc_no), '#/bookings');
  elsif new.status = 'void' then
    perform core.notify_member(new.payer_member_id, 'payment.voided', 'Your payment was voided', new.doc_no, '#/bookings');
  end if;
  return null;
end $$;
revoke all on function core.tg_notify_payment() from public, anon, authenticated;
create trigger z_payments_notify after insert or update of status on public.payment_submissions
  for each row execute function core.tg_notify_payment();

-- event registrations
create or replace function core.tg_notify_registration() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_div text;
  v_event text;
  v_url text;
  v_partner text := new.meta ->> 'partner_member_id';
  v_actor text := core.current_profile_id();
  v_owner_profile text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  select d.name, e.name, '#/bracket?division=' || d.id into v_div, v_event, v_url
  from public.divisions d join public.events e on e.id = d.event_id where d.id = new.division_id;
  select m.profile_id into v_owner_profile from public.members m where m.id = new.member_id;
  if new.status = 'requested' and (tg_op = 'INSERT') then
    perform core.notify_staff(new.org_id, 'events.approve_registration', 'staff.registration_requested', 'New event registration',
      v_event || ' · ' || v_div, '#/admin/events');
  elsif new.status = 'confirmed' then
    perform core.notify_member(new.member_id, 'registration.confirmed', 'You are registered', v_event || ' · ' || v_div, '#/events');
    if v_partner is not null then
      perform core.notify_member(v_partner, 'registration.confirmed', 'You are registered as a partner', v_event || ' · ' || v_div, '#/events');
    end if;
  elsif new.status = 'rejected' then
    perform core.notify_member(new.member_id, 'registration.rejected', 'Your registration was not accepted', v_event || ' · ' || v_div, '#/events');
  elsif new.status = 'waitlisted' then
    perform core.notify_member(new.member_id, 'registration.waitlisted', 'You are on the waitlist', v_event || ' · ' || v_div, '#/events');
  elsif new.status = 'requested' and tg_op = 'UPDATE' and old.status = 'waitlisted' then
    perform core.notify_member(new.member_id, 'registration.promoted', 'A place opened up for you', v_event || ' · ' || v_div, '#/events');
  elsif new.status = 'withdrawn' and v_actor is distinct from v_owner_profile then
    perform core.notify_member(new.member_id, 'registration.withdrawn', 'Your registration was withdrawn by the club', v_event || ' · ' || v_div, '#/events');
  end if;
  return null;
end $$;
revoke all on function core.tg_notify_registration() from public, anon, authenticated;
create trigger z_registrations_notify after insert or update of status on public.registrations
  for each row execute function core.tg_notify_registration();

-- the draw and the final results reach every player in the division
create or replace function core.tg_notify_division() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_event text;
  v_member text;
begin
  if new.status is not distinct from old.status or new.status not in ('drawn', 'finalized') then
    return null;
  end if;
  select e.name into v_event from public.events e where e.id = new.event_id;
  for v_member in
    select distinct em.member_id from public.entry_members em
    join public.entries en on en.id = em.entry_id and en.status = 'active' where en.division_id = new.id
  loop
    if new.status = 'drawn' then
      perform core.notify_member(v_member, 'draw.made', 'The draw is done: ' || new.name,
        v_event || '. See your bracket and matches.', '#/bracket?division=' || new.id);
    else
      perform core.notify_member(v_member, 'division.finalized', 'Final results are in: ' || new.name,
        v_event || '. See the final placements.', '#/bracket?division=' || new.id);
    end if;
  end loop;
  return null;
end $$;
revoke all on function core.tg_notify_division() from public, anon, authenticated;
create trigger z_divisions_notify after update of status on public.divisions
  for each row execute function core.tg_notify_division();

-- a changed rank (a move by a rule or by hand), not a reversal or a result with no change
create or replace function core.tg_notify_rank() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_to text;
begin
  if new.reverses_id is not null or new.from_rank_id is not distinct from new.to_rank_id then
    return null;
  end if;
  select r.name into v_to from public.ranks r where r.id = new.to_rank_id;
  perform core.notify_member(new.member_id, 'rank.changed', 'Your rank changed to ' || coalesce(v_to, 'a new rank'),
    coalesce(new.reason, 'See your rank history.'), '#/ranking');
  return null;
end $$;
revoke all on function core.tg_notify_rank() from public, anon, authenticated;
create trigger z_rank_history_notify after insert on public.rank_history
  for each row execute function core.tg_notify_rank();

-- a match given a time: both sides hear of it
create or replace function core.tg_notify_match_time() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_member text;
  v_div text;
  v_name text;
  v_a text;
  v_b text;
begin
  if new.scheduled_at is null or new.scheduled_at is not distinct from old.scheduled_at
     or new.status <> 'scheduled' or new.entry_a_id is null or new.entry_b_id is null then
    return null;
  end if;
  select d.id, d.name into v_div, v_name from public.division_stages s join public.divisions d on d.id = s.division_id where s.id = new.division_stage_id;
  v_a := core.entry_name(new.entry_a_id);
  v_b := core.entry_name(new.entry_b_id);
  for v_member in
    select distinct em.member_id from public.entry_members em where em.entry_id in (new.entry_a_id, new.entry_b_id)
  loop
    perform core.notify_member(v_member, 'match.scheduled', 'Your match is scheduled',
      v_name || ': ' || v_a || ' v ' || v_b || ' · ' || core.manila_when(new.scheduled_at), '#/bracket?division=' || v_div);
  end loop;
  return null;
end $$;
revoke all on function core.tg_notify_match_time() from public, anon, authenticated;
create trigger z_matches_notify_time after update of scheduled_at on public.matches
  for each row execute function core.tg_notify_match_time();

-- ---------------------------------------------------------------------------
-- reading and clearing (the signed-in member)
-- ---------------------------------------------------------------------------
create or replace function core.my_notifications(p_limit integer default 50)
returns table (id text, kind text, title text, body text, url text, created_at timestamptz, is_read boolean)
language sql stable security definer set search_path = '' as $$
  select n.id, n.kind, n.title, n.body, n.url, n.created_at,
    exists (select 1 from public.member_notification_reads r where r.notification_id = n.id and r.member_id = n.member_id)
  from public.member_notifications n
  join public.members m on m.id = n.member_id and m.profile_id = core.current_profile_id() and m.deleted_at is null
  order by n.created_at desc, n.id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200)
$$;

create or replace function core.my_unread_count() returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.member_notifications n
  join public.members m on m.id = n.member_id and m.profile_id = core.current_profile_id() and m.deleted_at is null
  where not exists (select 1 from public.member_notification_reads r where r.notification_id = n.id and r.member_id = n.member_id)
$$;

-- p_ids null marks everything read
create or replace function core.mark_notifications_read(p_ids text[] default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  m public.members;
  v_n integer;
begin
  select * into m from public.members x where x.profile_id = core.current_profile_id() and x.deleted_at is null;
  if not found then
    raise exception 'no member account' using errcode = '42501';
  end if;
  insert into public.member_notification_reads (org_id, member_id, notification_id)
  select n.org_id, n.member_id, n.id from public.member_notifications n
  where n.member_id = m.id and (p_ids is null or n.id = any (p_ids))
  on conflict (notification_id, member_id) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------------
-- devices
-- ---------------------------------------------------------------------------
create or replace function core.register_push(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_profile text := core.current_profile_id();
  v_org text;
begin
  if v_profile is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  select org_id into v_org from public.profiles where id = v_profile;
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then
    raise exception 'that is not a push address' using errcode = '22023';
  end if;
  if (select count(*) from public.push_subscriptions s where s.profile_id = v_profile and s.revoked_at is null and s.endpoint <> p_endpoint) >= 10 then
    raise exception 'too many devices are registered; remove one first' using errcode = '22023';
  end if;
  insert into public.push_subscriptions (org_id, profile_id, endpoint, p256dh, auth_key, user_agent)
  values (v_org, v_profile, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update set profile_id = excluded.profile_id, org_id = excluded.org_id, p256dh = excluded.p256dh,
    auth_key = excluded.auth_key, user_agent = excluded.user_agent, revoked_at = null;
end $$;

create or replace function core.unregister_push(p_endpoint text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.push_subscriptions set revoked_at = now()
  where endpoint = p_endpoint and profile_id = core.current_profile_id() and revoked_at is null;
end $$;

create or replace function core.my_push_registered(p_endpoint text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.push_subscriptions s
    where s.endpoint = p_endpoint and s.profile_id = core.current_profile_id() and s.revoked_at is null)
$$;

-- for the push-send function (service role only): who to push to, and what to say
create or replace function public.push_targets(p_notification_id text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('title', n.title, 'body', n.body, 'url', n.url, 'tag', n.kind,
    'subs', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth_key))
                      from public.push_subscriptions s join public.members m on m.profile_id = s.profile_id
                      where m.id = n.member_id and s.revoked_at is null), '[]'::jsonb))
  from public.member_notifications n where n.id = p_notification_id
$$;

create or replace function public.push_mark(p_ok_ids text[], p_gone_ids text[]) returns void
language sql security definer set search_path = '' as $$
  update public.push_subscriptions set last_ok_at = now() where id = any (coalesce(p_ok_ids, '{}'));
  update public.push_subscriptions set revoked_at = now() where id = any (coalesce(p_gone_ids, '{}')) and revoked_at is null
$$;

-- public wrappers (security invoker) for the signed-in member
create or replace function public.my_notifications(p_limit integer default 50)
returns table (id text, kind text, title text, body text, url text, created_at timestamptz, is_read boolean)
language sql stable security invoker set search_path = '' as $$ select * from core.my_notifications(p_limit) $$;
create or replace function public.my_unread_count() returns integer
language sql stable security invoker set search_path = '' as $$ select core.my_unread_count() $$;
create or replace function public.mark_notifications_read(p_ids text[] default null) returns integer
language sql security invoker set search_path = '' as $$ select core.mark_notifications_read(p_ids) $$;
create or replace function public.register_push(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null) returns void
language sql security invoker set search_path = '' as $$ select core.register_push(p_endpoint, p_p256dh, p_auth, p_user_agent) $$;
create or replace function public.unregister_push(p_endpoint text) returns void
language sql security invoker set search_path = '' as $$ select core.unregister_push(p_endpoint) $$;
create or replace function public.my_push_registered(p_endpoint text) returns boolean
language sql stable security invoker set search_path = '' as $$ select core.my_push_registered(p_endpoint) $$;

revoke all on function
  core.my_notifications(integer), core.my_unread_count(), core.mark_notifications_read(text[]),
  core.register_push(text, text, text, text), core.unregister_push(text), core.my_push_registered(text),
  public.my_notifications(integer), public.my_unread_count(), public.mark_notifications_read(text[]),
  public.register_push(text, text, text, text), public.unregister_push(text), public.my_push_registered(text),
  public.push_targets(text), public.push_mark(text[], text[])
from public, anon, authenticated;
grant execute on function
  core.my_notifications(integer), core.my_unread_count(), core.mark_notifications_read(text[]),
  core.register_push(text, text, text, text), core.unregister_push(text), core.my_push_registered(text),
  public.my_notifications(integer), public.my_unread_count(), public.mark_notifications_read(text[]),
  public.register_push(text, text, text, text), public.unregister_push(text), public.my_push_registered(text)
to authenticated, service_role;
grant execute on function public.push_targets(text), public.push_mark(text[], text[]) to service_role;
