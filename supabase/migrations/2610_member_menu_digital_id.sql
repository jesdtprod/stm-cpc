-- Setting member_menu.digital_id (Settings > Member Menu): shows or hides My Digital ID in the side menu, the dashboard quick
-- links and the Assistive Touch menu. On by default.

insert into public.settings (org_id, key, value)
select o.id, 'member_menu.digital_id', 'true'::jsonb from public.orgs o
where o.code = 'cpc' and o.deleted_at is null
  and not exists (select 1 from public.settings s where s.org_id = o.id and s.key = 'member_menu.digital_id' and s.unit_id is null and s.deleted_at is null);

do $$
declare def text;
begin
  select pg_get_functiondef('core.setting_valid(text,jsonb)'::regprocedure) into def;
  def := replace(def, '''member_menu.games'',', '''member_menu.games'', ''member_menu.digital_id'',');
  if def not like '%member_menu.digital_id%' then raise exception 'setting_valid patch did not apply'; end if;
  execute def;
end $$;

notify pgrst, 'reload schema';
