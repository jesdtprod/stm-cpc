-- 1240_settings_readonly_prefix (PLAN 4.1): the member ID prefix is read-only in the app too. The ID pattern and the
-- prefix go together, and changing one alone would make new sign-ups fail. Otherwise as 1230.

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
  if p_key in ('timezone', 'members.id_pattern', 'members.id_prefix') then
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

