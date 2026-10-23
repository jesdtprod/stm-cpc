-- 1000_members (PLAN 2.2, part 1 of 3; design: docs/CLUB_SCHEMA.md 4.1)
-- members, member_access, member_status_events, import_batches, member_import_issues, consents.
-- All writes go through RPCs or Edge Functions (service_role); clients get SELECT only, filtered by RLS.
-- Deviation from the design: member_status_events has no separate `actor` column; created_by is the actor.

-- ---------------------------------------------------------------------------
-- core.add_permission: adds a permission code and grants it to the admin role plus any listed roles.
-- Idempotent. Later migrations use it instead of redefining core.seed_catalog.
-- ---------------------------------------------------------------------------
create or replace function core.add_permission(p_code text, p_description text, p_roles text[] default '{}')
returns void language plpgsql set search_path = '' as $$
begin
  insert into public.permissions (code, description) values (p_code, p_description)
  on conflict (code) where deleted_at is null do nothing;

  insert into public.role_permissions (org_id, role_id, permission_id)
  select r.org_id, r.id, pe.id
  from public.roles r
  join public.orgs o on o.id = r.org_id and o.code = 'cpc' and o.deleted_at is null
  join public.permissions pe on pe.code = p_code and pe.deleted_at is null
  where r.deleted_at is null and (r.code = 'admin' or r.code = any (p_roles))
  on conflict (role_id, permission_id) where deleted_at is null do nothing;
end $$;
revoke all on function core.add_permission(text, text, text[]) from public, anon, authenticated;

select core.add_permission('members.review_import', 'Review and resolve member import issues');
select core.add_permission('consents.read', 'View recorded waivers and consents');
select core.add_permission('consents.record', 'Record a waiver or consent for a person');

-- ---------------------------------------------------------------------------
-- import_batches: one row per import run. class: document. No member data inside.
-- ---------------------------------------------------------------------------
create table public.import_batches (
  id             text collate "C" primary key default core.ulid(),
  org_id         text not null references public.orgs (id) on delete restrict,
  unit_id        text collate "C" references public.org_units (id) on delete restrict,
  file_sha256    text not null constraint import_batches_sha_chk check (file_sha256 ~ '^[0-9a-f]{64}$'),
  row_count      integer not null default 0 constraint import_batches_rows_chk check (row_count >= 0),
  created_count  integer not null default 0 constraint import_batches_created_chk check (created_count >= 0),
  skipped_count  integer not null default 0 constraint import_batches_skipped_chk check (skipped_count >= 0),
  held_back_count integer not null default 0 constraint import_batches_held_chk check (held_back_count >= 0),
  failed_count   integer not null default 0 constraint import_batches_failed_chk check (failed_count >= 0),
  status         text not null default 'running'
                 constraint import_batches_status_chk check (status in ('running', 'completed', 'failed')),
  started_by     text,
  created_at     timestamptz not null default now(),
  created_by     text,
  updated_at     timestamptz not null default now(),
  updated_by     text,
  version        integer not null default 1,
  meta           jsonb not null default '{}'::jsonb
);
comment on table public.import_batches is 'class: document. permissions: members.import. Counts and a file hash only; no member data.';
create index import_batches_org_idx on public.import_batches (org_id);
create index import_batches_unit_idx on public.import_batches (unit_id);

-- ---------------------------------------------------------------------------
-- members: one row per club member. class: master (status is the lifecycle; soft delete is for mistakes).
-- ---------------------------------------------------------------------------
create table public.members (
  id              text collate "C" primary key default core.ulid(),
  org_id          text not null references public.orgs (id) on delete restrict,
  unit_id         text collate "C" references public.org_units (id) on delete restrict,
  person_id       text collate "C" not null references public.persons (id) on delete restrict,
  profile_id      text collate "C" references public.profiles (id) on delete restrict,
  member_no       text not null
                  constraint members_member_no_chk check (member_no = upper(btrim(member_no)) and length(member_no) between 3 and 32),
  status          text not null default 'imported'
                  constraint members_status_chk check (status in
                    ('imported', 'invited', 'pending_approval', 'active', 'rejected', 'suspended', 'archived')),
  status_reason   text,
  joined_on       date,
  rfid_code       text constraint members_rfid_chk check (rfid_code is null or length(btrim(rfid_code)) > 0),
  import_batch_id text collate "C" references public.import_batches (id) on delete restrict,
  import_row      integer constraint members_import_row_chk check (import_row is null or import_row > 0),
  created_at      timestamptz not null default now(),
  created_by      text,
  updated_at      timestamptz not null default now(),
  updated_by      text,
  version         integer not null default 1,
  deleted_at      timestamptz,
  deleted_by      text,
  delete_reason   text,
  meta            jsonb not null default '{}'::jsonb,
  constraint members_person_uq unique (person_id),
  constraint members_profile_uq unique (profile_id)
);
comment on table public.members is 'class: master. permissions: members.read, members.update, members.approve, members.suspend; writes by RPC only. Contains personal data (rfid_code).';
create index members_org_idx on public.members (org_id);
create index members_unit_idx on public.members (unit_id);
create index members_status_idx on public.members (org_id, status) where deleted_at is null;
create index members_import_batch_idx on public.members (import_batch_id);
create unique index members_member_no_active_uq on public.members (org_id, member_no) where deleted_at is null;
create unique index members_rfid_active_uq on public.members (org_id, rfid_code) where deleted_at is null and rfid_code is not null;

-- Lifecycle guard: imported -> invited -> pending_approval -> active; pending_approval -> rejected;
-- active <-> suspended; any -> archived. New rows start as imported (import) or pending_approval (sign-up).
create or replace function core.tg_members_status() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.status not in ('imported', 'pending_approval') then
      raise exception 'a new member starts as imported or pending_approval, not %', new.status using errcode = '22023';
    end if;
    return new;
  end if;
  if new.status = old.status then return new; end if;
  if not (
    (old.status = 'imported' and new.status = 'invited')
    or (old.status = 'invited' and new.status = 'pending_approval')
    or (old.status = 'pending_approval' and new.status in ('active', 'rejected'))
    or (old.status = 'active' and new.status = 'suspended')
    or (old.status = 'suspended' and new.status = 'active')
    or (old.status <> 'archived' and new.status = 'archived')
  ) then
    raise exception 'member status cannot change from % to %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end $$;
create trigger c2_members_status before insert or update on public.members
  for each row execute function core.tg_members_status();

-- ---------------------------------------------------------------------------
-- member_status_events: append-only history. class: ledger (log). Written by a trigger on members.
-- ---------------------------------------------------------------------------
create table public.member_status_events (
  id          text collate "C" primary key default core.ulid(),
  org_id      text not null references public.orgs (id) on delete restrict,
  unit_id     text collate "C" references public.org_units (id) on delete restrict,
  member_id   text collate "C" not null references public.members (id) on delete restrict,
  from_status text,
  to_status   text not null,
  reason      text,
  occurred_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  created_by  text,
  updated_at  timestamptz not null default now(),
  updated_by  text,
  version     integer not null default 1,
  meta        jsonb not null default '{}'::jsonb
);
comment on table public.member_status_events is 'class: ledger (log, append-only). permissions: members.read.';
create index member_status_events_org_idx on public.member_status_events (org_id);
create index member_status_events_unit_idx on public.member_status_events (unit_id);
create index member_status_events_member_idx on public.member_status_events (member_id, occurred_at desc);

create or replace function core.tg_members_log_status() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.member_status_events (org_id, unit_id, member_id, from_status, to_status, reason)
    values (new.org_id, new.unit_id, new.id, null, new.status, new.status_reason);
  elsif new.status is distinct from old.status then
    insert into public.member_status_events (org_id, unit_id, member_id, from_status, to_status, reason)
    values (new.org_id, new.unit_id, new.id, old.status, new.status, new.status_reason);
  end if;
  return null;
end $$;
revoke all on function core.tg_members_log_status() from public, anon, authenticated;
create trigger y_members_log_status after insert or update on public.members
  for each row execute function core.tg_members_log_status();

-- ---------------------------------------------------------------------------
-- member_access: sign-in state for each member. Service-written only; holds no password or secret.
-- class: master. Clients have no access (the member's own flag is exposed by an RPC in stage 3).
-- ---------------------------------------------------------------------------
create table public.member_access (
  id                       text collate "C" primary key default core.ulid(),
  org_id                   text not null references public.orgs (id) on delete restrict,
  unit_id                  text collate "C" references public.org_units (id) on delete restrict,
  member_id                text collate "C" not null references public.members (id) on delete restrict,
  must_change_password     boolean not null default true,
  temp_password_expires_at timestamptz,
  last_login_at            timestamptz,
  failed_attempts          integer not null default 0 constraint member_access_attempts_chk check (failed_attempts >= 0),
  locked_until             timestamptz,
  created_at               timestamptz not null default now(),
  created_by               text,
  updated_at               timestamptz not null default now(),
  updated_by               text,
  version                  integer not null default 1,
  deleted_at               timestamptz,
  deleted_by               text,
  delete_reason            text,
  meta                     jsonb not null default '{}'::jsonb,
  constraint member_access_member_uq unique (member_id)
);
comment on table public.member_access is 'class: master. Service-written only (member-login, member-import). No client access. Holds no password.';
create index member_access_org_idx on public.member_access (org_id);
create index member_access_unit_idx on public.member_access (unit_id);

-- ---------------------------------------------------------------------------
-- member_import_issues: what the import held back, changed or flagged. class: master (resolved, not deleted).
-- ---------------------------------------------------------------------------
create table public.member_import_issues (
  id                text collate "C" primary key default core.ulid(),
  org_id            text not null references public.orgs (id) on delete restrict,
  unit_id           text collate "C" references public.org_units (id) on delete restrict,
  batch_id          text collate "C" not null references public.import_batches (id) on delete restrict,
  member_id         text collate "C" references public.members (id) on delete restrict,
  source_row        integer not null constraint member_import_issues_row_chk check (source_row > 0),
  member_no_claimed text,
  issue_code        text not null constraint member_import_issues_code_chk check (issue_code in
                      ('duplicate_member_no', 'invalid_member_no', 'member_no_normalized',
                       'invalid_birth_date', 'duplicate_rfid_cleared', 'invalid_email')),
  detail            text,
  resolved_at       timestamptz,
  resolved_by       text,
  created_at        timestamptz not null default now(),
  created_by        text,
  updated_at        timestamptz not null default now(),
  updated_by        text,
  version           integer not null default 1,
  deleted_at        timestamptz,
  deleted_by        text,
  delete_reason     text,
  meta              jsonb not null default '{}'::jsonb,
  constraint member_import_issues_resolved_chk check ((resolved_at is null) = (resolved_by is null))
);
comment on table public.member_import_issues is 'class: master. permissions: members.review_import. Row numbers and codes only; no personal data in detail.';
create index member_import_issues_org_idx on public.member_import_issues (org_id);
create index member_import_issues_unit_idx on public.member_import_issues (unit_id);
create index member_import_issues_batch_idx on public.member_import_issues (batch_id);
create index member_import_issues_member_idx on public.member_import_issues (member_id);
create index member_import_issues_open_idx on public.member_import_issues (org_id, issue_code) where resolved_at is null and deleted_at is null;
-- One issue per code per source row per batch, so a re-run of the same batch logic cannot double-report.
create unique index member_import_issues_row_code_uq on public.member_import_issues (batch_id, source_row, issue_code) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- consents: waiver and privacy acceptance. class: ledger (log, append-only).
-- For a minor, accepted_by_person_id is the guardian.
-- ---------------------------------------------------------------------------
create table public.consents (
  id                      text collate "C" primary key default core.ulid(),
  org_id                  text not null references public.orgs (id) on delete restrict,
  unit_id                 text collate "C" references public.org_units (id) on delete restrict,
  person_id               text collate "C" not null references public.persons (id) on delete restrict,
  kind                    text not null constraint consents_kind_chk check (kind in ('waiver', 'privacy')),
  doc_version             text not null constraint consents_doc_version_chk check (length(btrim(doc_version)) > 0),
  accepted_at             timestamptz not null default now(),
  accepted_by_person_id   text collate "C" references public.persons (id) on delete restrict,
  created_at              timestamptz not null default now(),
  created_by              text,
  updated_at              timestamptz not null default now(),
  updated_by              text,
  version                 integer not null default 1,
  meta                    jsonb not null default '{}'::jsonb
);
comment on table public.consents is 'class: ledger (log, append-only). permissions: consents.read, consents.record.';
create index consents_org_idx on public.consents (org_id);
create index consents_unit_idx on public.consents (unit_id);
create index consents_person_idx on public.consents (person_id, kind);
create index consents_accepted_by_idx on public.consents (accepted_by_person_id);

select core.attach_standard('public.import_batches', 'document');
select core.attach_standard('public.members', 'master');
select core.attach_standard('public.member_status_events', 'ledger');
select core.attach_standard('public.member_access', 'master');
select core.attach_standard('public.member_import_issues', 'master');
select core.attach_standard('public.consents', 'ledger');

-- ---------------------------------------------------------------------------
-- RLS: members see their own rows; staff see by permission; nobody writes directly.
-- ---------------------------------------------------------------------------
alter table public.import_batches enable row level security;
alter table public.members enable row level security;
alter table public.member_status_events enable row level security;
alter table public.member_access enable row level security;
alter table public.member_import_issues enable row level security;
alter table public.consents enable row level security;

create policy members_select on public.members for select to authenticated
  using (profile_id = core.current_profile_id() or core.has_permission(org_id, null, 'members.read'));
create policy member_status_events_select on public.member_status_events for select to authenticated
  using (core.has_permission(org_id, null, 'members.read'));
create policy import_batches_select on public.import_batches for select to authenticated
  using (core.has_permission(org_id, null, 'members.import'));
create policy member_import_issues_select on public.member_import_issues for select to authenticated
  using (core.has_permission(org_id, null, 'members.review_import'));
create policy consents_select on public.consents for select to authenticated
  using (core.is_own_person(person_id) or core.has_permission(org_id, null, 'consents.read'));
-- member_access: no client may read it. A policy that matches nothing keeps the "every table has a policy" rule.
create policy member_access_select on public.member_access for select to authenticated
  using (false);

-- Privileges: select only for clients; member_access has none at all.
select core.grant_client_dml('public.members', false, false);
select core.grant_client_dml('public.member_status_events', false, false);
select core.grant_client_dml('public.import_batches', false, false);
select core.grant_client_dml('public.member_import_issues', false, false);
select core.grant_client_dml('public.consents', false, false);
revoke all on public.member_access from anon, authenticated;

grant select, insert, update on public.members, public.member_access, public.import_batches,
  public.member_import_issues to service_role;
grant select, insert on public.member_status_events, public.consents to service_role;
