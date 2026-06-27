-- Let public map viewers discover active pipeline datasets without relying on
-- Supabase Storage folder listing. Tile and JSON products still live in the
-- public pipeline-export bucket.

set search_path = public;

drop policy if exists "Pipeline datasets readable" on public.pipeline_datasets;
create policy "Pipeline datasets readable"
on public.pipeline_datasets
for select
to anon, authenticated
using (true);

grant select on public.pipeline_datasets to anon, authenticated;

update public.pipeline_datasets
set is_active = false
where city_id in ('yokohama-honmoku', 'amsterdam-schimmelstraat');

insert into public.pipeline_datasets (
  city_id,
  dataset_id,
  generated_at,
  storage_prefix,
  manifest_path,
  source_layer,
  is_active
)
values
  (
    'yokohama-honmoku',
    '20260627T121500Z',
    '2026-06-27T12:22:39Z'::timestamptz,
    'pipeline-export/yokohama-honmoku/20260627T121500Z/',
    'pipeline-export/yokohama-honmoku/20260627T121500Z/manifest.json',
    'hexgrid',
    true
  ),
  (
    'amsterdam-schimmelstraat',
    '20260627T120826Z',
    '2026-06-27T12:21:56Z'::timestamptz,
    'pipeline-export/amsterdam-schimmelstraat/20260627T120826Z/',
    'pipeline-export/amsterdam-schimmelstraat/20260627T120826Z/manifest.json',
    'hexgrid',
    true
  )
on conflict (city_id, dataset_id) do update set
  generated_at = excluded.generated_at,
  storage_prefix = excluded.storage_prefix,
  manifest_path = excluded.manifest_path,
  source_layer = excluded.source_layer,
  is_active = excluded.is_active;

update public.pipeline_datasets
set is_active = true
where (city_id, dataset_id) in (
  values
    ('yokohama-honmoku', '20260627T121500Z'),
    ('amsterdam-schimmelstraat', '20260627T120826Z')
);
