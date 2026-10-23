-- 0003_core_tenancy_people (PLAN 1.3)
-- orgs, org_units, persons, person_relations, profiles. All master data (soft delete).
-- RLS is enabled here with no policies (deny all); policies arrive in 0004 once
-- core.has_permission exists. Deviations from DATABASE.md section 9, on purpose:
--   * orgs.org_id = id (a CHECK enforces it) so one RLS shape covers every table.
--   * persons has no profile_id: the link lives once, in profiles.person_id (unique).
--   * org_units has no unit_id (a unit is not scoped to itself).

-- ---------------------------------------------------------------------------
-- orgs: top-level tenant. class: master. permissions: org.read, org.manage
-- ---------------------------------------------------------------------------
create table public.orgs (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null,
  code          text not null,
  name          text not null,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint orgs_org_self_chk check (org_id = id),
  constraint orgs_code_chk check (code ~ '^[a-z][a-z0-9_-]{1,30}$')
);
comment on table public.orgs is 'class: master. permissions: org.read, org.manage.';
create unique index orgs_code_active_uq on public.orgs (code) where deleted_at is null;

create or replace function core.tg_orgs_self_org() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.org_id := new.id;
  return new;
end $$;
create trigger a_self_org before insert on public.orgs
  for each row execute function core.tg_orgs_self_org();

-- ---------------------------------------------------------------------------
-- org_units: branch / site / venue. class: master. permissions: org.read, org.manage
-- ---------------------------------------------------------------------------
create table public.org_units (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  parent_id     text collate "C" references public.org_units (id) on delete restrict,
  code          text not null,
  name          text not null,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint org_units_not_own_parent_chk check (parent_id is distinct from id)
);
comment on table public.org_units is 'class: master. permissions: org.read, org.manage.';
create index org_units_org_idx on public.org_units (org_id);
create index org_units_parent_idx on public.org_units (parent_id);
create unique index org_units_code_active_uq on public.org_units (org_id, code) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- persons: anyone the system records; a person does not need a login.
-- class: master. permissions: members.read, members.create, members.update.
-- Personal data (RA 10173): email, mobile and date_of_birth are masked in audit_log.
-- ---------------------------------------------------------------------------
create table public.persons (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  kind          text not null default 'member'
                constraint persons_kind_chk check (kind in ('member', 'guest', 'guardian', 'contact', 'other')),
  first_name    text,
  last_name     text,
  display_name  text not null,
  email         text,
  mobile        text,
  date_of_birth date,
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
comment on table public.persons is 'class: master. permissions: members.read, members.create, members.update. Contains personal data.';
create index persons_org_idx on public.persons (org_id);
create index persons_unit_idx on public.persons (unit_id);

-- ---------------------------------------------------------------------------
-- person_relations: guardian, emergency contact, family. class: master.
-- ---------------------------------------------------------------------------
create table public.person_relations (
  id                text collate "C" primary key default core.ulid(),
  org_id            text not null references public.orgs (id) on delete restrict,
  person_id         text collate "C" not null references public.persons (id) on delete restrict,
  related_person_id text collate "C" not null references public.persons (id) on delete restrict,
  relation_type     text not null
                    constraint person_relations_type_chk check (relation_type in ('guardian', 'emergency_contact', 'family', 'other')),
  created_at        timestamptz not null default now(),
  created_by        text,
  updated_at        timestamptz not null default now(),
  updated_by        text,
  version           integer not null default 1,
  deleted_at        timestamptz,
  deleted_by        text,
  delete_reason     text,
  meta              jsonb not null default '{}'::jsonb,
  constraint person_relations_distinct_chk check (person_id <> related_person_id)
);
comment on table public.person_relations is 'class: master. permissions: members.read, members.update.';
create index person_relations_org_idx on public.person_relations (org_id);
create index person_relations_person_idx on public.person_relations (person_id);
create index person_relations_related_idx on public.person_relations (related_person_id);
create unique index person_relations_active_uq
  on public.person_relations (person_id, related_person_id, relation_type) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- profiles: login identity. class: master (deactivate with is_active, never hard delete).
-- auth.users.id (uuid) is referenced only from here. Created by Edge Functions, never by clients.
-- ---------------------------------------------------------------------------
create table public.profiles (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  auth_user_id  uuid not null references auth.users (id) on delete restrict,
  person_id     text collate "C" references public.persons (id) on delete restrict,
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
  constraint profiles_auth_user_uq unique (auth_user_id),
  constraint profiles_person_uq unique (person_id)
);
comment on table public.profiles is 'class: master. permissions: members.read; writes only by service code and RPCs.';
create index profiles_org_idx on public.profiles (org_id);

select core.attach_standard('public.orgs', 'master');
select core.attach_standard('public.org_units', 'master');
select core.attach_standard('public.persons', 'master');
select core.attach_standard('public.person_relations', 'master');
select core.attach_standard('public.profiles', 'master');

alter table public.orgs enable row level security;
alter table public.org_units enable row level security;
alter table public.persons enable row level security;
alter table public.person_relations enable row level security;
alter table public.profiles enable row level security;

-- Real caller lookup (replaces the stub from 0002): the active profile of the signed-in user.
create or replace function core.current_profile_id() returns text
language sql stable security definer set search_path = '' as $$
  select p.id
  from public.profiles p
  where p.auth_user_id = (select auth.uid())
    and p.is_active
    and p.deleted_at is null
  limit 1
$$;
revoke all on function core.current_profile_id() from public, anon;
grant execute on function core.current_profile_id() to authenticated, service_role;
