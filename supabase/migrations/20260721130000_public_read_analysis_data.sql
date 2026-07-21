-- Viewing is public: analysis + reference data must be readable by anyone,
-- authenticated or not. Authentication is only required to report/add data
-- (survey points, sightings, structured surveys, suggestions) and to moderate.
--
-- This adds anon SELECT (RLS policy + table grant) to the read-only analysis
-- and reference tables. It intentionally does NOT touch user-submission or
-- moderation tables (survey_points, quick_sightings, structured_surveys,
-- survey_records, suggestions, flags, user_roles, audit_log), which stay
-- behind authentication and the existing moderation workflow.
--
-- Mirrors the existing public discovery precedent for pipeline_datasets
-- (20260627143000_public_pipeline_dataset_discovery.sql).

do $$
declare
  target_table text;
  public_tables text[] := array[
    'cell_attributes',
    'pipeline_cell_attributes',
    'green_spaces',
    'pipeline_green_spaces',
    'hex_cells',
    'corridor_links',
    'conservation_actions',
    'community_events',
    'species_reference',
    'city_layer_stats',
    'global_stats',
    'wards'
  ];
begin
  foreach target_table in array public_tables loop
    if to_regclass(format('public.%I', target_table)) is not null then
      execute format('drop policy if exists %I on public.%I', target_table || '_public_read', target_table);
      execute format(
        'create policy %I on public.%I for select to anon using (true)',
        target_table || '_public_read',
        target_table
      );
      execute format('grant select on public.%I to anon', target_table);
    end if;
  end loop;
end $$;

grant usage on schema public to anon;
