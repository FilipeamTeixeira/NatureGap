create or replace function public.promote_pipeline_dataset(
  target_city_id text,
  target_dataset_id text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  -- [keep every line of the existing function body exactly as is,
  --  up through the final green_spaces insert/upsert block]

  -- New: purge staging rows for any OTHER dataset_id for this city,
  -- now that promotion to target_dataset_id has succeeded.
  perform set_config('naturegap.pipeline_import_purge', 'on', true);

  delete from public.pipeline_cell_attributes
  where city_id = target_city_id
    and dataset_id <> target_dataset_id;

  delete from public.pipeline_green_spaces
  where city_id = target_city_id
    and dataset_id <> target_dataset_id;

  perform set_config('naturegap.pipeline_import_purge', 'off', true);
end;
$$;