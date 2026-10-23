-- 1270_courts_admin (PLAN 4.4): what the courts admin screens need from the database.
--   * soft_delete / restore_row now cover courts, court_hours, court_rates and court_blackouts (courts.manage)
--   * a court with upcoming bookings cannot be deleted (FEATURES 7.1): pending, confirmed or checked-in bookings that
--     have not ended block it until they are cancelled or moved. Closing a court (status) is still allowed.
insert into core.soft_delete_targets (table_name, permission) values
  ('courts', 'courts.manage'),
  ('court_hours', 'courts.manage'),
  ('court_rates', 'courts.manage'),
  ('court_blackouts', 'courts.manage')
on conflict (table_name) do nothing;

create or replace function core.tg_courts_in_use() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_open integer;
begin
  if new.deleted_at is not null and old.deleted_at is null then
    select count(*)::integer into v_open from public.bookings b
    where b.court_id = new.id and b.status in ('pending_approval', 'confirmed', 'checked_in') and upper(b.during) > now();
    if v_open > 0 then
      raise exception 'court % has % upcoming booking(s); cancel or move them first, or close the court instead', new.code, v_open
        using errcode = '23503';
    end if;
  end if;
  return new;
end $$;
create trigger c2_courts_in_use before update on public.courts
  for each row execute function core.tg_courts_in_use();
