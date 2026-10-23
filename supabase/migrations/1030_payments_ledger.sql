-- 1030_payments_ledger (PLAN 2.3, part 2 of 2; design: docs/CLUB_SCHEMA.md 4.3)
-- payment_submissions (document), ledger_accounts (master), ledger_entries (ledger, append-only).
-- Clients get SELECT only; the payment RPCs (stage 5) submit, verify, reject and void. Payment status and
-- balances are derived from these rows, never stored as a number the browser could change.
-- Sign convention in ledger_entries.amount: positive = credit to the member (money received),
-- negative = charge (a booking or event fee). A balance is the sum of a member's entries.
-- Deviation: ledger_entries has no `recorded_by`; created_by is the actor.

-- ---------------------------------------------------------------------------
-- payment_submissions. class: document.
-- Status machine: submitted -> verified | rejected;  verified -> void.
-- ---------------------------------------------------------------------------
create table public.payment_submissions (
  id              text collate "C" primary key default core.ulid(),
  org_id          text not null references public.orgs (id) on delete restrict,
  unit_id         text collate "C" references public.org_units (id) on delete restrict,
  doc_no          text not null,
  payer_member_id text collate "C" not null references public.members (id) on delete restrict,
  source_type     text not null constraint payment_submissions_source_type_chk check (source_type in ('booking', 'event_registration')),
  source_id       text collate "C" not null,
  method          text not null constraint payment_submissions_method_chk check (method in ('cash', 'gcash', 'maya', 'bank_transfer', 'other')),
  reference_no    text constraint payment_submissions_ref_chk check (reference_no is null or length(btrim(reference_no)) between 1 and 64),
  amount          numeric(12, 2) not null constraint payment_submissions_amount_chk check (amount > 0),
  file_id         text collate "C" references public.files (id) on delete restrict,
  status          text not null default 'submitted'
                  constraint payment_submissions_status_chk check (status in ('submitted', 'verified', 'rejected', 'void')),
  verified_at     timestamptz,
  verified_by     text,
  reject_reason   text,
  void_at         timestamptz,
  void_by         text,
  void_reason     text,
  payload_hash    text not null constraint payment_submissions_hash_chk check (payload_hash ~ '^[0-9a-f]{64}$'),
  created_at      timestamptz not null default now(),
  created_by      text,
  updated_at      timestamptz not null default now(),
  updated_by      text,
  version         integer not null default 1,
  meta            jsonb not null default '{}'::jsonb,
  constraint payment_submissions_doc_no_uq unique (org_id, doc_no),
  constraint payment_submissions_verified_chk check (status not in ('verified') or (verified_at is not null and verified_by is not null)),
  constraint payment_submissions_rejected_chk check (status <> 'rejected' or length(btrim(coalesce(reject_reason, ''))) > 0),
  constraint payment_submissions_void_chk check (status <> 'void' or (void_at is not null and length(btrim(coalesce(void_reason, ''))) > 0))
);
comment on table public.payment_submissions is 'class: document. permissions: payments.submit, payments.verify, payments.void. Written by payment RPCs only. The same method and reference number cannot be live twice.';
create index payment_submissions_org_idx on public.payment_submissions (org_id);
create index payment_submissions_unit_idx on public.payment_submissions (unit_id);
create index payment_submissions_payer_idx on public.payment_submissions (payer_member_id);
create index payment_submissions_source_idx on public.payment_submissions (source_type, source_id);
create index payment_submissions_file_idx on public.payment_submissions (file_id);
create index payment_submissions_status_idx on public.payment_submissions (org_id, status);
create unique index payment_submissions_ref_live_uq on public.payment_submissions (org_id, method, reference_no)
  where reference_no is not null and status in ('submitted', 'verified');

create or replace function core.tg_payments_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  yr integer := extract(year from (now() at time zone 'Asia/Manila'))::integer;
begin
  if new.status <> 'submitted' then
    raise exception 'a new payment starts as submitted' using errcode = '22023';
  end if;
  if not exists (select 1 from public.members m where m.id = new.payer_member_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'only an active member can submit a payment' using errcode = '22023';
  end if;
  if new.source_type = 'booking' and not exists (
    select 1 from public.bookings b where b.id = new.source_id and b.org_id = new.org_id
  ) then
    raise exception 'the booking being paid does not exist' using errcode = '22023';
  end if;
  if new.doc_no is null or new.doc_no = '' then
    new.doc_no := format('PAY-%s-%s', yr, lpad(core.next_number(new.org_id, null, 'payment-' || yr)::text, 5, '0'));
  end if;
  return new;
end $$;
revoke all on function core.tg_payments_insert() from public, anon, authenticated;
create trigger a2_payments_insert before insert on public.payment_submissions
  for each row execute function core.tg_payments_insert();

create or replace function core.tg_payments_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.doc_no, old.payer_member_id, old.source_type, old.source_id, old.method, old.reference_no, old.amount, old.file_id, old.payload_hash)
     is distinct from
     (new.doc_no, new.payer_member_id, new.source_type, new.source_id, new.method, new.reference_no, new.amount, new.file_id, new.payload_hash) then
    raise exception 'a payment''s payer, source, method, reference, amount, proof and hash cannot change; void it and submit again' using errcode = '42501';
  end if;
  if new.status <> old.status and not (
       (old.status = 'submitted' and new.status in ('verified', 'rejected'))
    or (old.status = 'verified' and new.status = 'void')
  ) then
    raise exception 'payment status cannot change from % to %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end $$;
create trigger c2_payments_update before update on public.payment_submissions
  for each row execute function core.tg_payments_update();

-- ---------------------------------------------------------------------------
-- ledger_accounts: one money account per member (more owner types can be added later).
-- ---------------------------------------------------------------------------
create table public.ledger_accounts (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  owner_type    text not null default 'member' constraint ledger_accounts_owner_type_chk check (owner_type in ('member')),
  owner_id      text collate "C" not null,
  currency      text not null default 'PHP' constraint ledger_accounts_currency_chk check (currency = 'PHP'),
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
comment on table public.ledger_accounts is 'class: master. permissions: payments.verify (read all); the owner reads their own. Created by RPCs.';
create index ledger_accounts_org_idx on public.ledger_accounts (org_id);
create index ledger_accounts_unit_idx on public.ledger_accounts (unit_id);
create index ledger_accounts_owner_idx on public.ledger_accounts (owner_type, owner_id);
create unique index ledger_accounts_owner_active_uq on public.ledger_accounts (org_id, owner_type, owner_id, currency) where deleted_at is null;

create or replace function core.tg_ledger_accounts_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.owner_type = 'member' and not exists (
    select 1 from public.members m where m.id = new.owner_id and m.org_id = new.org_id
  ) then
    raise exception 'the account owner is not a member of this club' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_ledger_accounts_owner() from public, anon, authenticated;
create trigger a2_ledger_accounts_owner before insert on public.ledger_accounts
  for each row execute function core.tg_ledger_accounts_owner();

-- ---------------------------------------------------------------------------
-- ledger_entries: append-only. A correction is a new entry that reverses an old one exactly.
-- ---------------------------------------------------------------------------
create table public.ledger_entries (
  id                 text collate "C" primary key default core.ulid(),
  org_id             text not null references public.orgs (id) on delete restrict,
  unit_id            text collate "C" references public.org_units (id) on delete restrict,
  account_id         text collate "C" not null references public.ledger_accounts (id) on delete restrict,
  amount             numeric(18, 4) not null constraint ledger_entries_amount_chk check (amount <> 0),
  source_type        text not null constraint ledger_entries_source_type_chk check (source_type in ('booking', 'payment', 'event_registration', 'adjustment')),
  source_id          text collate "C" not null,
  client_ref         text not null constraint ledger_entries_client_ref_chk check (length(btrim(client_ref)) between 1 and 64),
  reverses_entry_id  text collate "C" references public.ledger_entries (id) on delete restrict,
  occurred_at        timestamptz not null default now(),
  note               text,
  created_at         timestamptz not null default now(),
  created_by         text,
  updated_at         timestamptz not null default now(),
  updated_by         text,
  version            integer not null default 1,
  meta               jsonb not null default '{}'::jsonb,
  constraint ledger_entries_not_self_reverse_chk check (reverses_entry_id is distinct from id)
);
comment on table public.ledger_entries is 'class: ledger (append-only). Positive = credit to the member, negative = charge. Written by payment and booking RPCs only; balances are sums of these rows.';
create index ledger_entries_org_idx on public.ledger_entries (org_id);
create index ledger_entries_unit_idx on public.ledger_entries (unit_id);
create index ledger_entries_account_idx on public.ledger_entries (account_id, occurred_at desc);
create index ledger_entries_source_idx on public.ledger_entries (source_type, source_id);
-- The same business event is recorded once, however many times the RPC is retried.
create unique index ledger_entries_idempotent_uq on public.ledger_entries (org_id, source_type, source_id, client_ref);
-- An entry can be reversed once.
create unique index ledger_entries_reverses_uq on public.ledger_entries (reverses_entry_id) where reverses_entry_id is not null;

create or replace function core.tg_ledger_entries_check() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  orig public.ledger_entries;
begin
  if not exists (select 1 from public.ledger_accounts a where a.id = new.account_id and a.org_id = new.org_id and a.deleted_at is null) then
    raise exception 'the ledger account does not exist' using errcode = '22023';
  end if;
  if new.reverses_entry_id is not null then
    select * into orig from public.ledger_entries where id = new.reverses_entry_id;
    if not found then
      raise exception 'the entry being reversed does not exist' using errcode = '22023';
    end if;
    if orig.reverses_entry_id is not null then
      raise exception 'a reversal cannot itself be reversed; record a new entry' using errcode = '22023';
    end if;
    if orig.account_id <> new.account_id or orig.amount <> -new.amount then
      raise exception 'a reversal must be in the same account and for the exact opposite amount' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
revoke all on function core.tg_ledger_entries_check() from public, anon, authenticated;
create trigger a2_ledger_entries_check before insert on public.ledger_entries
  for each row execute function core.tg_ledger_entries_check();

-- True when the ledger account belongs to the caller.
create or replace function core.is_own_ledger_account(p_account_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.ledger_accounts a
    where a.id = p_account_id and a.owner_type = 'member' and core.is_own_member(a.owner_id)
  )
$$;
revoke all on function core.is_own_ledger_account(text) from public, anon;
grant execute on function core.is_own_ledger_account(text) to authenticated, service_role;

select core.attach_standard('public.payment_submissions', 'document');
select core.attach_standard('public.ledger_accounts', 'master');
select core.attach_standard('public.ledger_entries', 'ledger');

alter table public.payment_submissions enable row level security;
alter table public.ledger_accounts enable row level security;
alter table public.ledger_entries enable row level security;

create policy payment_submissions_select on public.payment_submissions for select to authenticated
  using (core.has_permission(org_id, null, 'payments.verify') or core.is_own_member(payer_member_id));
create policy ledger_accounts_select on public.ledger_accounts for select to authenticated
  using (core.has_permission(org_id, null, 'payments.verify') or (owner_type = 'member' and core.is_own_member(owner_id)));
create policy ledger_entries_select on public.ledger_entries for select to authenticated
  using (core.has_permission(org_id, null, 'payments.verify') or core.is_own_ledger_account(account_id));

select core.grant_client_dml('public.payment_submissions', false, false);
select core.grant_client_dml('public.ledger_accounts', false, false);
select core.grant_client_dml('public.ledger_entries', false, false);
grant select, insert, update on public.payment_submissions, public.ledger_accounts to service_role;
grant select, insert on public.ledger_entries to service_role;

-- ---------------------------------------------------------------------------
-- Derived figures. security_invoker: each caller sees only the rows their own policies allow.
-- ---------------------------------------------------------------------------
create view public.ledger_balances with (security_invoker = true) as
  select e.org_id, e.account_id, sum(e.amount) as balance, count(*)::integer as entry_count, max(e.occurred_at) as last_entry_at
  from public.ledger_entries e
  group by e.org_id, e.account_id;
comment on view public.ledger_balances is 'Balance per account = sum of its ledger entries. security_invoker.';

create view public.source_payment_totals with (security_invoker = true) as
  select p.org_id, p.source_type, p.source_id,
         coalesce(sum(p.amount) filter (where p.status = 'verified'), 0)::numeric(12, 2) as verified_total,
         coalesce(sum(p.amount) filter (where p.status = 'submitted'), 0)::numeric(12, 2) as pending_total,
         count(*) filter (where p.status in ('submitted', 'verified'))::integer as live_payments
  from public.payment_submissions p
  group by p.org_id, p.source_type, p.source_id;
comment on view public.source_payment_totals is 'Verified and pending payment amounts per booking or event registration. security_invoker.';

grant select on public.ledger_balances, public.source_payment_totals to authenticated, service_role;
