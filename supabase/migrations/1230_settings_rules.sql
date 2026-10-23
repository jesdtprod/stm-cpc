-- 1230_settings_rules (PLAN 4.1): settings are validated per key, changed through one permissioned,
-- idempotent, audited function, and a few system settings cannot be changed from the app.
--   core.setting_valid(key, value)   the rules for every known key (type, range, allowed values). Keys the club
--                                    adds itself keep the generic rule (any non-null value).
--   core.update_setting(...)          settings.manage; the setting must already exist (no new keys from the app);
--                                    the same key replays, a changed request with the same key is refused; the old
--                                    and new value and the reason go to audit_log.
-- Read-only from the app (changed by a migration): timezone (the club works in Asia/Manila) and members.id_pattern
-- (a wrong pattern would lock members out).

create or replace function core.setting_valid(p_key text, p_value jsonb) returns boolean
language plpgsql stable set search_path = '' as $$
declare
  t text;
  n numeric;
  item text;
begin
  if p_value is null or p_value = 'null'::jsonb then
    return false;
  end if;
  t := jsonb_typeof(p_value);

  if p_key = 'timezone' then
    return t = 'string' and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_value #>> '{}');
  end if;

  if p_key in ('members.signup_enabled', 'members.auto_approve_imported', 'booking.approval_required',
               'payments.required.court_booking', 'payments.required.event_registration',
               'payments.proof_required_non_cash', 'events.registration_approval_required',
               'events.waitlist_enabled', 'ranks.movement_enabled') then
    return t = 'boolean';
  end if;

  if p_key in ('club.name', 'events.default_scoring_rule') then
    return t = 'string' and char_length(btrim(p_value #>> '{}')) between 1 and 80;
  end if;
  if p_key = 'members.id_prefix' then
    return t = 'string' and (p_value #>> '{}') ~ '^[A-Z]{2,6}$';
  end if;
  if p_key = 'members.id_pattern' then
    return t = 'string' and char_length(p_value #>> '{}') between 1 and 200;
  end if;
  if p_key = 'payments.instructions' then
    return t = 'string' and char_length(p_value #>> '{}') <= 1000;
  end if;

  if p_key = 'payments.methods' then
    if t <> 'array' or jsonb_array_length(p_value) not between 1 and 4 then
      return false;
    end if;
    for item in select jsonb_array_elements_text(p_value) loop
      if item not in ('cash', 'gcash', 'maya', 'bank_transfer') then
        return false;
      end if;
    end loop;
    return (select count(distinct e) = jsonb_array_length(p_value) from jsonb_array_elements_text(p_value) e);
  end if;

  -- whole numbers within a range
  if p_key in ('members.temp_password_days', 'session.idle_minutes', 'booking.slot_minutes', 'booking.advance_days',
               'booking.max_participants', 'booking.request_expiry_hours', 'booking.cancel_cutoff_hours') then
    if t <> 'number' then
      return false;
    end if;
    n := (p_value #>> '{}')::numeric;
    if n <> trunc(n) then
      return false;
    end if;
    return case p_key
      when 'members.temp_password_days' then n between 0 and 365
      when 'session.idle_minutes' then n between 5 and 120
      when 'booking.slot_minutes' then n between 15 and 240
      when 'booking.advance_days' then n between 1 and 365
      when 'booking.max_participants' then n between 1 and 20
      when 'booking.request_expiry_hours' then n between 1 and 168
      else n between 0 and 168
    end;
  end if;

  -- money
  if p_key in ('booking.cancel_fee', 'booking.no_show_fee') then
    if t <> 'number' then
      return false;
    end if;
    n := (p_value #>> '{}')::numeric;
    return n >= 0 and n <= 100000 and n = round(n, 2);
  end if;

  return true;
end $$;

create or replace function core.update_setting(p_key text, p_value jsonb, p_reason text, p_idem text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_org text;
  v_row public.settings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_response jsonb;
begin
  select m.org_id into v_org from core.my_profile() m;
  if v_org is null or not core.has_permission(v_org, null, 'settings.manage') then
    raise exception 'you do not have permission to change settings' using errcode = '42501';
  end if;
  if p_key in ('timezone', 'members.id_pattern') then
    raise exception 'this setting is changed by the club developer, not in the app' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  select * into v_row from public.settings s
  where s.org_id = v_org and s.unit_id is null and s.key = p_key and s.deleted_at is null for update;
  if not found then
    raise exception 'unknown setting' using errcode = '22023';
  end if;
  if not core.setting_valid(p_key, p_value) then
    raise exception 'that value is not allowed for this setting' using errcode = '22023';
  end if;
  if p_key = 'events.default_scoring_rule' and not exists (
    select 1 from public.scoring_rules r
    where r.org_id = v_org and r.name = p_value #>> '{}' and r.deleted_at is null
  ) then
    raise exception 'there is no scoring rule with that name' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_idem, v_org, 'setting.update',
    jsonb_build_object('key', p_key, 'value', p_value, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;

  if v_row.value = p_value then
    v_response := jsonb_build_object('ok', true, 'key', p_key, 'value', p_value, 'unchanged', true);
    perform core.idem_complete(p_idem, v_response);
    return v_response;
  end if;

  update public.settings set value = p_value where id = v_row.id;
  perform core.write_audit(v_org, 'setting.update', 'public.settings', v_row.id,
    jsonb_build_object('key', p_key, 'value', v_row.value),
    jsonb_build_object('key', p_key, 'value', p_value, 'reason', v_reason));
  v_response := jsonb_build_object('ok', true, 'key', p_key, 'value', p_value);
  perform core.idem_complete(p_idem, v_response);
  return v_response;
end $$;

create or replace function public.update_setting(p_key text, p_value jsonb, p_reason text, p_idem text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.update_setting(p_key, p_value, p_reason, p_idem) $$;

revoke all on function core.update_setting(text, jsonb, text, text), public.update_setting(text, jsonb, text, text)
  from public, anon, authenticated;
-- The function checks settings.manage itself.
grant execute on function core.update_setting(text, jsonb, text, text), public.update_setting(text, jsonb, text, text)
  to authenticated, service_role;
