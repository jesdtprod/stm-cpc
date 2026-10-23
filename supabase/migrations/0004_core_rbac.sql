-- 0004_core_rbac (PLAN 1.4)
-- Permission catalog, roles, role bundles, memberships, the authorization helpers
-- (core.has_permission, core.is_org_member) and the RLS policies for the 1.3 tables.
-- Clients only read these tables; every write goes through service code or RPCs.

-- Composite keys so memberships and role bundles cannot point across orgs.
alter table public.org_units add constraint org_units_id_org_uq unique (id, org_id);
alter table public.profiles add constraint profiles_id_org_uq unique (id, org_id);

-- ---------------------------------------------------------------------------
-- permissions: global catalog of codes (<module>.<action>). class: master.
-- Global, so it has no org_id.
-- ---------------------------------------------------------------------------
create table public.permissions (
  id            text collate "C" primary key default core.ulid(),
  code          text not null constraint permissions_code_chk check (code ~ '^[a-z_]+\.[a-z_]+$'),
  description   text not null,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb
);
comment on table public.permissions is 'class: master (global catalog, no org_id). Readable by any signed-in user; written by migrations only.';
create unique index permissions_code_active_uq on public.permissions (code) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- roles: bundles of permissions per org. class: master. permission: roles.manage
-- ---------------------------------------------------------------------------
create table public.roles (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  code          text not null constraint roles_code_chk check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name          text not null,
  description   text,
  is_system     boolean not null default false,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint roles_id_org_uq unique (id, org_id)
);
comment on table public.roles is 'class: master. permission: roles.manage.';
create index roles_org_idx on public.roles (org_id);
create unique index roles_code_active_uq on public.roles (org_id, code) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- role_permissions: which codes a role grants. class: master. permission: roles.manage
-- ---------------------------------------------------------------------------
create table public.role_permissions (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null,
  role_id       text collate "C" not null,
  permission_id text collate "C" not null references public.permissions (id) on delete restrict,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint role_permissions_role_fk foreign key (role_id, org_id) references public.roles (id, org_id) on delete restrict
);
comment on table public.role_permissions is 'class: master. permission: roles.manage.';
create index role_permissions_org_idx on public.role_permissions (org_id);
create index role_permissions_role_idx on public.role_permissions (role_id);
create index role_permissions_permission_idx on public.role_permissions (permission_id);
create unique index role_permissions_active_uq on public.role_permissions (role_id, permission_id) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- org_members: profile <-> org (<-> unit) with a role. The table RLS reads.
-- unit_id null = org-wide; unit_id set = only rows of that unit. class: master.
-- permissions: members.read (read); changes only by RPC.
-- ---------------------------------------------------------------------------
create table public.org_members (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  profile_id    text collate "C" not null,
  unit_id       text collate "C",
  role_id       text collate "C" not null,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint org_members_profile_fk foreign key (profile_id, org_id) references public.profiles (id, org_id) on delete restrict,
  constraint org_members_role_fk foreign key (role_id, org_id) references public.roles (id, org_id) on delete restrict,
  constraint org_members_unit_fk foreign key (unit_id, org_id) references public.org_units (id, org_id) on delete restrict
);
comment on table public.org_members is 'class: master. permission: members.read; writes by RPC only.';
create index org_members_org_idx on public.org_members (org_id);
create index org_members_profile_idx on public.org_members (profile_id);
create index org_members_role_idx on public.org_members (role_id);
create index org_members_unit_idx on public.org_members (unit_id);
create unique index org_members_active_uq on public.org_members (profile_id, org_id, coalesce(unit_id, '')) where deleted_at is null;

select core.attach_standard('public.permissions', 'master');
select core.attach_standard('public.roles', 'master');
select core.attach_standard('public.role_permissions', 'master');
select core.attach_standard('public.org_members', 'master');

alter table public.permissions enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.org_members enable row level security;

-- ---------------------------------------------------------------------------
-- Authorization helpers. security definer, search_path empty, auth.uid() wrapped in a select.
-- ---------------------------------------------------------------------------

-- The single permission check used by policies and RPCs.
-- p_unit_id null asks for an org-wide grant; a unit-bound membership grants only its own unit.
create or replace function core.has_permission(p_org_id text, p_unit_id text, p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.profiles p
    join public.org_members m on m.profile_id = p.id and m.org_id = p_org_id
    join public.orgs o on o.id = m.org_id
    join public.roles r on r.id = m.role_id
    join public.role_permissions rp on rp.role_id = r.id
    join public.permissions pe on pe.id = rp.permission_id
    where p.auth_user_id = (select auth.uid())
      and p.is_active and p.deleted_at is null
      and m.is_active and m.deleted_at is null
      and o.deleted_at is null and r.deleted_at is null
      and rp.deleted_at is null and pe.deleted_at is null
      and pe.code = p_code
      and (m.unit_id is null or (p_unit_id is not null and m.unit_id = p_unit_id))
  )
$$;

-- True for any active member of the org, whatever the role (including pending members).
create or replace function core.is_org_member(p_org_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.profiles p
    join public.org_members m on m.profile_id = p.id and m.org_id = p_org_id
    join public.orgs o on o.id = m.org_id
    where p.auth_user_id = (select auth.uid())
      and p.is_active and p.deleted_at is null
      and m.is_active and m.deleted_at is null
      and o.deleted_at is null
  )
$$;

-- True when the person row is the caller's own.
create or replace function core.is_own_person(p_person_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
    where p.auth_user_id = (select auth.uid())
      and p.is_active and p.deleted_at is null
      and p.person_id = p_person_id
  )
$$;

revoke all on function core.has_permission(text, text, text) from public, anon;
revoke all on function core.is_org_member(text) from public, anon;
revoke all on function core.is_own_person(text) from public, anon;
grant execute on function core.has_permission(text, text, text) to authenticated, service_role;
grant execute on function core.is_org_member(text) to authenticated, service_role;
grant execute on function core.is_own_person(text) to authenticated, service_role;

-- What the UI asks to decide which screens to show. Convenience only: the database still checks.
create or replace function public.my_permissions() returns table (org_id text, unit_id text, code text)
language sql stable security definer set search_path = '' as $$
  select m.org_id, m.unit_id, pe.code
  from public.profiles p
  join public.org_members m on m.profile_id = p.id
  join public.roles r on r.id = m.role_id
  join public.role_permissions rp on rp.role_id = r.id
  join public.permissions pe on pe.id = rp.permission_id
  where p.auth_user_id = (select auth.uid())
    and p.is_active and p.deleted_at is null
    and m.is_active and m.deleted_at is null
    and r.deleted_at is null and rp.deleted_at is null and pe.deleted_at is null
$$;
revoke all on function public.my_permissions() from public, anon;
grant execute on function public.my_permissions() to authenticated;

-- ---------------------------------------------------------------------------
-- RLS policies for the 1.3 and 1.4 tables (select only for security tables).
-- ---------------------------------------------------------------------------
create policy orgs_select on public.orgs for select to authenticated
  using (core.is_org_member(id));

create policy org_units_select on public.org_units for select to authenticated
  using (core.is_org_member(org_id));
create policy org_units_insert on public.org_units for insert to authenticated
  with check (core.has_permission(org_id, null, 'org.manage'));
create policy org_units_update on public.org_units for update to authenticated
  using (core.has_permission(org_id, null, 'org.manage'))
  with check (core.has_permission(org_id, null, 'org.manage'));

select core.enable_standard_rls('public.persons', 'org', 'members');
create policy persons_select_own on public.persons for select to authenticated
  using (core.is_own_person(id));

select core.enable_standard_rls('public.person_relations', 'org', 'members');

create policy profiles_select on public.profiles for select to authenticated
  using (auth_user_id = (select auth.uid()) or core.has_permission(org_id, null, 'members.read'));

-- Documented exception to "no using (true)": the catalog of permission codes is not sensitive.
create policy permissions_select on public.permissions for select to authenticated
  using (true);

create policy roles_select on public.roles for select to authenticated
  using (core.is_org_member(org_id));
create policy role_permissions_select on public.role_permissions for select to authenticated
  using (core.has_permission(org_id, null, 'roles.manage'));
create policy org_members_select on public.org_members for select to authenticated
  using (profile_id = core.current_profile_id() or core.has_permission(org_id, null, 'members.read'));

-- ---------------------------------------------------------------------------
-- Seed: permission catalog, default org, default roles. Idempotent; re-run it from a new
-- migration when the catalog grows. Fake or club-level data only.
-- ---------------------------------------------------------------------------
create or replace function core.seed_catalog() returns void
language plpgsql set search_path = '' as $$
begin
  insert into public.permissions (code, description)
  select v.code, v.description from (values
    ('members.read', 'View member records'),
    ('members.create', 'Create member records'),
    ('members.update', 'Edit member records'),
    ('members.approve', 'Approve or reject new members'),
    ('members.suspend', 'Suspend or reinstate members'),
    ('members.import', 'Import members from a file'),
    ('members.reset_password', 'Reset a member password'),
    ('categories.manage', 'Manage skill-level categories'),
    ('ranks.manage', 'Manage ranks'),
    ('ranks.override', 'Override a member rank'),
    ('courts.manage', 'Manage courts'),
    ('bookings.create', 'Request a court booking'),
    ('bookings.read_all', 'View all bookings'),
    ('bookings.approve', 'Approve or reject bookings'),
    ('bookings.cancel_any', 'Cancel any booking'),
    ('bookings.checkin', 'Check members in'),
    ('payments.submit', 'Submit payment proof'),
    ('payments.verify', 'Verify payments'),
    ('payments.void', 'Void payments'),
    ('events.manage', 'Manage events and tournaments'),
    ('events.register', 'Register for events'),
    ('events.approve_registration', 'Approve event registrations'),
    ('draws.run', 'Run a draw'),
    ('draws.redo', 'Redo a draw'),
    ('brackets.manage', 'Manage brackets'),
    ('scores.enter', 'Enter match scores'),
    ('scores.finalize', 'Finalize match scores'),
    ('scores.correct', 'Correct finalized scores'),
    ('settings.manage', 'Manage settings'),
    ('audit.read', 'Read the audit log'),
    ('org.read', 'View organization details'),
    ('org.manage', 'Manage organization and units'),
    ('roles.manage', 'Manage roles and permissions')
  ) as v(code, description)
  on conflict (code) where deleted_at is null do nothing;

  insert into public.orgs (code, name) values ('cpc', 'Capitol Pickleball Club')
  on conflict (code) where deleted_at is null do nothing;

  insert into public.roles (org_id, code, name, description, is_system)
  select o.id, v.code, v.name, v.description, true
  from public.orgs o
  cross join (values
    ('pending_member', 'Pending member', 'Not yet approved: password change and profile completion only'),
    ('member', 'Member', 'Book courts, register for events, view own data'),
    ('referee', 'Referee / scorekeeper', 'Enter and finalize match scores'),
    ('front_desk', 'Front desk', 'Day-to-day check-in and booking support'),
    ('manager', 'Manager', 'Courts, categories, ranks, events, brackets, settings'),
    ('admin', 'Admin', 'Approvals and everything else')
  ) as v(code, name, description)
  where o.code = 'cpc' and o.deleted_at is null
  on conflict (org_id, code) where deleted_at is null do nothing;

  insert into public.role_permissions (org_id, role_id, permission_id)
  select r.org_id, r.id, pe.id
  from public.roles r
  join public.orgs o on o.id = r.org_id and o.code = 'cpc'
  join (values
    ('member', 'bookings.create'), ('member', 'payments.submit'), ('member', 'events.register'),
    ('referee', 'scores.enter'), ('referee', 'scores.finalize'),
    ('front_desk', 'members.read'), ('front_desk', 'bookings.read_all'), ('front_desk', 'bookings.checkin'),
    ('front_desk', 'bookings.create'), ('front_desk', 'payments.submit'),
    ('manager', 'members.read'), ('manager', 'courts.manage'), ('manager', 'categories.manage'),
    ('manager', 'ranks.manage'), ('manager', 'events.manage'), ('manager', 'events.approve_registration'),
    ('manager', 'draws.run'), ('manager', 'draws.redo'), ('manager', 'brackets.manage'),
    ('manager', 'scores.enter'), ('manager', 'scores.finalize'), ('manager', 'scores.correct'),
    ('manager', 'settings.manage'), ('manager', 'bookings.read_all'), ('manager', 'bookings.checkin')
  ) as g(role_code, perm_code) on g.role_code = r.code
  join public.permissions pe on pe.code = g.perm_code and pe.deleted_at is null
  where r.deleted_at is null
  on conflict (role_id, permission_id) where deleted_at is null do nothing;

  insert into public.role_permissions (org_id, role_id, permission_id)
  select r.org_id, r.id, pe.id
  from public.roles r
  join public.orgs o on o.id = r.org_id and o.code = 'cpc'
  cross join public.permissions pe
  where r.code = 'admin' and r.deleted_at is null and pe.deleted_at is null
  on conflict (role_id, permission_id) where deleted_at is null do nothing;
end $$;
revoke all on function core.seed_catalog() from public, anon, authenticated;

select core.seed_catalog();
