-- The club offers Openplay, Split Single Elimination and Tournament as format templates. The plain "Single elimination"
-- template is retired: soft-deleted (never a hard delete) so divisions and events that already used it keep their
-- history. Only the unmodified seeded template is touched (one single_elimination stage).
select set_config('core.rpc', 'on', true);

update public.format_templates t
set is_active = false,
    deleted_at = now(),
    deleted_by = 'system',
    delete_reason = 'Retired: the club offers Openplay, Split Single Elimination and Tournament'
where t.deleted_at is null
  and lower(btrim(t.name)) = 'single elimination'
  and jsonb_array_length(t.stages) = 1
  and t.stages -> 0 ->> 'stage_type' = 'single_elimination';

select set_config('core.rpc', 'off', true);
