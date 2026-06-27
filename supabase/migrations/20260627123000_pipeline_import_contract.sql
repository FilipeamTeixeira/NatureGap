-- Deterministic R pipeline import contract.
-- R remains the producer of ecological outputs; PostgreSQL validates, stores,
-- and promotes versioned products without recomputing ecological metrics.

set search_path = public, extensions;

-- ── Versioned green-space products ──────────────────────────────────────────

create table if not exists public.green_spaces (
  green_space_id text not null,
  city_id text not null,
  dataset_id text not null,
  generated_at timestamptz not null,
  name text,
  name_ja text,
  ward_id text,
  geometry geometry(MultiPolygon, 4326) not null,
  habitat_quality_index numeric,
  effort_corrected_richness numeric,
  expected_richness numeric,
  ecological_residual numeric,
  nature_gap_score numeric,
  corridor_importance numeric,
  intervention_rank numeric,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (city_id, green_space_id),
  constraint green_spaces_id_not_blank check (length(trim(green_space_id)) > 0),
  constraint green_spaces_city_not_blank check (length(trim(city_id)) > 0),
  constraint green_spaces_dataset_not_blank check (length(trim(dataset_id)) > 0)
);

create table if not exists public.pipeline_green_spaces (
  city_id text not null,
  dataset_id text not null,
  green_space_id text not null,
  generated_at timestamptz not null,
  name text,
  name_ja text,
  ward_id text,
  geometry geometry(MultiPolygon, 4326) not null,
  habitat_quality_index numeric,
  effort_corrected_richness numeric,
  expected_richness numeric,
  ecological_residual numeric,
  nature_gap_score numeric,
  corridor_importance numeric,
  intervention_rank numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (city_id, dataset_id, green_space_id),
  constraint pipeline_green_spaces_dataset_fk
    foreign key (city_id, dataset_id)
    references public.pipeline_datasets(city_id, dataset_id)
    on delete restrict,
  constraint pipeline_green_spaces_id_not_blank check (length(trim(green_space_id)) > 0)
);

alter table public.green_spaces
drop column if exists properties,
drop column if exists tree_cover,
drop column if exists heat_exposure,
drop column if exists land_use_green,
drop column if exists land_use_class,
add column if not exists habitat_quality_index numeric,
add column if not exists effort_corrected_richness numeric,
add column if not exists expected_richness numeric,
add column if not exists ecological_residual numeric,
add column if not exists nature_gap_score numeric,
add column if not exists corridor_importance numeric,
add column if not exists intervention_rank numeric;

alter table public.pipeline_green_spaces
drop column if exists properties,
drop column if exists tree_cover,
drop column if exists heat_exposure,
drop column if exists land_use_green,
drop column if exists land_use_class,
add column if not exists habitat_quality_index numeric,
add column if not exists effort_corrected_richness numeric,
add column if not exists expected_richness numeric,
add column if not exists ecological_residual numeric,
add column if not exists nature_gap_score numeric,
add column if not exists corridor_importance numeric,
add column if not exists intervention_rank numeric;

create index if not exists green_spaces_city_active_idx
on public.green_spaces (city_id, is_active);

create index if not exists green_spaces_geometry_gist_idx
on public.green_spaces using gist (geometry);

create index if not exists pipeline_green_spaces_geometry_gist_idx
on public.pipeline_green_spaces using gist (geometry);

drop trigger if exists green_spaces_set_updated_at on public.green_spaces;
create trigger green_spaces_set_updated_at
before update on public.green_spaces
for each row execute function public.set_updated_at();

drop trigger if exists pipeline_green_spaces_set_updated_at on public.pipeline_green_spaces;
create trigger pipeline_green_spaces_set_updated_at
before update on public.pipeline_green_spaces
for each row execute function public.set_updated_at();

drop trigger if exists green_spaces_prevent_delete on public.green_spaces;
create trigger green_spaces_prevent_delete
before delete on public.green_spaces
for each row execute function public.prevent_hard_delete();

drop trigger if exists pipeline_green_spaces_prevent_delete on public.pipeline_green_spaces;
create trigger pipeline_green_spaces_prevent_delete
before delete on public.pipeline_green_spaces
for each row execute function public.prevent_hard_delete();

create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  pk jsonb;
begin
  if tg_table_name = 'cell_attributes' then
    pk := jsonb_build_object(
      'cell_id',
      case when tg_op = 'INSERT' then new.cell_id else old.cell_id end
    );
  elsif tg_table_name = 'pipeline_datasets' then
    pk := jsonb_build_object(
      'city_id',
      case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'dataset_id',
      case when tg_op = 'INSERT' then new.dataset_id else old.dataset_id end
    );
  elsif tg_table_name = 'pipeline_cell_attributes' then
    pk := jsonb_build_object(
      'city_id',
      case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'dataset_id',
      case when tg_op = 'INSERT' then new.dataset_id else old.dataset_id end,
      'cell_id',
      case when tg_op = 'INSERT' then new.cell_id else old.cell_id end
    );
  elsif tg_table_name = 'green_spaces' then
    pk := jsonb_build_object(
      'city_id',
      case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'green_space_id',
      case when tg_op = 'INSERT' then new.green_space_id else old.green_space_id end
    );
  elsif tg_table_name = 'pipeline_green_spaces' then
    pk := jsonb_build_object(
      'city_id',
      case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'dataset_id',
      case when tg_op = 'INSERT' then new.dataset_id else old.dataset_id end,
      'green_space_id',
      case when tg_op = 'INSERT' then new.green_space_id else old.green_space_id end
    );
  elsif tg_table_name = 'user_roles' then
    pk := jsonb_build_object(
      'user_id',
      case when tg_op = 'INSERT' then new.user_id else old.user_id end
    );
  else
    pk := jsonb_build_object(
      'id',
      case when tg_op = 'INSERT' then new.id else old.id end
    );
  end if;

  insert into public.audit_log (
    table_name,
    record_pk,
    operation,
    old_row,
    new_row,
    changed_by
  )
  values (
    tg_table_name,
    pk,
    tg_op,
    case when tg_op = 'UPDATE' then to_jsonb(old) else null end,
    to_jsonb(new),
    auth.uid()
  );

  return new;
end;
$$;

drop trigger if exists green_spaces_audit on public.green_spaces;
create trigger green_spaces_audit
after insert or update on public.green_spaces
for each row execute function public.audit_row_change();

drop trigger if exists pipeline_green_spaces_audit on public.pipeline_green_spaces;
create trigger pipeline_green_spaces_audit
after insert or update on public.pipeline_green_spaces
for each row execute function public.audit_row_change();

-- ── Observation export view for R ───────────────────────────────────────────

drop view if exists public.pipeline_observations_export;

create or replace view public.pipeline_observations_export as
select
  qs.id::text as observation_id,
  'quick_sighting'::text as observation_source,
  qs.city_id,
  coalesce(sr.scientific_name, qs.taxon_group::text || ':' || qs.id::text) as taxon_name,
  qs.taxon_group::text as iconic_taxon_name,
  sr.common_name as common_label,
  qs."timestamp"::date as observed_on,
  qs."timestamp" as observed_at,
  0::numeric as observation_weight,
  qs.user_id::text as observer_id,
  qs.gps_accuracy_m,
  qs.cell_id,
  null::uuid as survey_id,
  null::integer as survey_duration_seconds,
  null::jsonb as habitat_indicators,
  extensions.st_x(qs.geometry) as lng,
  extensions.st_y(qs.geometry) as lat,
  qs.status::text as review_status
from public.analysis_quick_sightings qs
left join public.species_reference sr on sr.id = qs.species_id

union all

select
  rec.id::text as observation_id,
  'structured_survey'::text as observation_source,
  survey.city_id,
  coalesce(species.scientific_name, rec.taxon_group::text || ':' || rec.id::text) as taxon_name,
  rec.taxon_group::text as iconic_taxon_name,
  species.common_name as common_label,
  survey.started_at::date as observed_on,
  survey.started_at as observed_at,
  3::numeric as observation_weight,
  survey.user_id::text as observer_id,
  null::numeric as gps_accuracy_m,
  survey.cell_id,
  survey.id as survey_id,
  survey.duration_seconds as survey_duration_seconds,
  survey.habitat_indicators,
  extensions.st_x(point.geometry) as lng,
  extensions.st_y(point.geometry) as lat,
  survey.status::text as review_status
from public.analysis_survey_records rec
join public.analysis_structured_surveys survey on survey.id = rec.survey_id
join public.survey_points point on point.id = survey.survey_point_id
left join public.species_reference species on species.id = rec.species_id;

grant select on public.pipeline_observations_export to authenticated;

-- ── Import validation and promotion ─────────────────────────────────────────

create or replace function public.assert_valid_pipeline_dataset_id(value text)
returns void
language plpgsql
stable
set search_path = public
as $$
begin
  if value is null or value !~ '^[0-9]{8}T[0-9]{6}Z$' then
    raise exception 'Invalid dataset_id "%". Expected UTC format YYYYMMDDTHHMMSSZ.', coalesce(value, '<null>')
      using errcode = 'check_violation';
  end if;
end;
$$;

create or replace function public.promote_pipeline_dataset(
  target_city_id text,
  target_dataset_id text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  stale_cells integer;
begin
  if not public.is_admin() then
    raise exception 'Only admins can promote pipeline datasets.'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.assert_valid_pipeline_dataset_id(target_dataset_id);

  if not exists (
    select 1
    from public.pipeline_datasets
    where city_id = target_city_id
      and dataset_id = target_dataset_id
  ) then
    raise exception 'Pipeline dataset %.% does not exist.', target_city_id, target_dataset_id
      using errcode = 'foreign_key_violation';
  end if;

  select count(*)
  into stale_cells
  from public.cell_attributes ca
  where ca.city_id = target_city_id
    and ca.dataset_id <> 'legacy'
    and not exists (
      select 1
      from public.pipeline_cell_attributes pca
      where pca.city_id = target_city_id
        and pca.dataset_id = target_dataset_id
        and pca.cell_id = ca.cell_id
    );

  if stale_cells > 0 then
    raise exception 'Cannot promote %.%: % active cell rows would become stale.', target_city_id, target_dataset_id, stale_cells
      using errcode = 'check_violation';
  end if;

  update public.pipeline_datasets
  set is_active = false
  where city_id = target_city_id
    and is_active;

  update public.pipeline_datasets
  set is_active = true
  where city_id = target_city_id
    and dataset_id = target_dataset_id;

  insert into public.cell_attributes (
    cell_id, geometry, expected_richness, effort_corrected_richness,
    ecological_residual, nature_gap_score, corridor_importance, intervention_rank,
    heat_exposure, noise, light_pollution, fragmentation, water_proximity,
    connectivity_score, last_updated, disturbance_index, fragmentation_index,
    intervention_score, node_importance, impact_score, habitat_quality,
    habitat_quality_index, species_richness_raw, observed_richness,
    max_expected_richness, is_unsampled, temporal_bias_flag, path_km, n_obs,
    n_survey_dates, habitat_potential, observer_effort_score,
    taxonomic_diversity, species, pressures, interventions, tree_cover,
    land_use_green, city_id, dataset_id, generated_at
  )
  select
    cell_id, geometry, expected_richness, effort_corrected_richness,
    ecological_residual, nature_gap_score, corridor_importance, intervention_rank,
    heat_exposure, noise, light_pollution, fragmentation, water_proximity,
    connectivity_score, last_updated, disturbance_index, fragmentation_index,
    intervention_score, node_importance, impact_score, habitat_quality,
    habitat_quality_index, species_richness_raw, observed_richness,
    max_expected_richness, is_unsampled, temporal_bias_flag, path_km, n_obs,
    n_survey_dates, habitat_potential, observer_effort_score,
    taxonomic_diversity, species, pressures, interventions, tree_cover,
    land_use_green, city_id, dataset_id, generated_at
  from public.pipeline_cell_attributes
  where city_id = target_city_id
    and dataset_id = target_dataset_id
  on conflict (cell_id) do update set
    geometry = excluded.geometry,
    expected_richness = excluded.expected_richness,
    effort_corrected_richness = excluded.effort_corrected_richness,
    ecological_residual = excluded.ecological_residual,
    nature_gap_score = excluded.nature_gap_score,
    corridor_importance = excluded.corridor_importance,
    intervention_rank = excluded.intervention_rank,
    heat_exposure = excluded.heat_exposure,
    noise = excluded.noise,
    light_pollution = excluded.light_pollution,
    fragmentation = excluded.fragmentation,
    water_proximity = excluded.water_proximity,
    connectivity_score = excluded.connectivity_score,
    last_updated = excluded.last_updated,
    disturbance_index = excluded.disturbance_index,
    fragmentation_index = excluded.fragmentation_index,
    intervention_score = excluded.intervention_score,
    node_importance = excluded.node_importance,
    impact_score = excluded.impact_score,
    habitat_quality = excluded.habitat_quality,
    habitat_quality_index = excluded.habitat_quality_index,
    species_richness_raw = excluded.species_richness_raw,
    observed_richness = excluded.observed_richness,
    max_expected_richness = excluded.max_expected_richness,
    is_unsampled = excluded.is_unsampled,
    temporal_bias_flag = excluded.temporal_bias_flag,
    path_km = excluded.path_km,
    n_obs = excluded.n_obs,
    n_survey_dates = excluded.n_survey_dates,
    habitat_potential = excluded.habitat_potential,
    observer_effort_score = excluded.observer_effort_score,
    taxonomic_diversity = excluded.taxonomic_diversity,
    species = excluded.species,
    pressures = excluded.pressures,
    interventions = excluded.interventions,
    tree_cover = excluded.tree_cover,
    land_use_green = excluded.land_use_green,
    city_id = excluded.city_id,
    dataset_id = excluded.dataset_id,
    generated_at = excluded.generated_at;

  update public.green_spaces
  set is_active = false
  where city_id = target_city_id
    and dataset_id <> target_dataset_id;

  insert into public.green_spaces (
    green_space_id, city_id, dataset_id, generated_at, name, name_ja,
    ward_id, geometry, habitat_quality_index, effort_corrected_richness,
    expected_richness, ecological_residual, nature_gap_score, corridor_importance,
    intervention_rank, is_active
  )
  select
    green_space_id, city_id, dataset_id, generated_at, name, name_ja,
    ward_id, geometry, habitat_quality_index, effort_corrected_richness,
    expected_richness, ecological_residual, nature_gap_score, corridor_importance,
    intervention_rank, true
  from public.pipeline_green_spaces
  where city_id = target_city_id
    and dataset_id = target_dataset_id
  on conflict (city_id, green_space_id) do update set
    city_id = excluded.city_id,
    dataset_id = excluded.dataset_id,
    generated_at = excluded.generated_at,
    name = excluded.name,
    name_ja = excluded.name_ja,
    ward_id = excluded.ward_id,
    geometry = excluded.geometry,
    habitat_quality_index = excluded.habitat_quality_index,
    effort_corrected_richness = excluded.effort_corrected_richness,
    expected_richness = excluded.expected_richness,
    ecological_residual = excluded.ecological_residual,
    nature_gap_score = excluded.nature_gap_score,
    corridor_importance = excluded.corridor_importance,
    intervention_rank = excluded.intervention_rank,
    is_active = true;
end;
$$;

create or replace function public.import_pipeline_dataset(
  target_city_id text,
  target_dataset_id text,
  target_generated_at timestamptz,
  target_storage_prefix text,
  target_manifest_path text,
  target_source_layer text,
  cell_attributes_geojson jsonb,
  green_spaces_geojson jsonb default null,
  activate boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  cell_feature_count integer;
  imported_cell_count integer;
  green_feature_count integer := 0;
  imported_green_count integer := 0;
  duplicate_cell_ids text[];
  duplicate_green_ids text[];
begin
  if not public.is_admin() then
    raise exception 'Only admins can import pipeline datasets.'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.assert_valid_pipeline_dataset_id(target_dataset_id);

  if target_city_id is null or length(trim(target_city_id)) = 0 then
    raise exception 'city_id is required.' using errcode = 'check_violation';
  end if;

  if target_generated_at is null then
    raise exception 'generated_at is required.' using errcode = 'check_violation';
  end if;

  if cell_attributes_geojson->>'type' <> 'FeatureCollection' then
    raise exception 'cell_attributes_geojson must be a GeoJSON FeatureCollection.'
      using errcode = 'check_violation';
  end if;

  drop table if exists pg_temp.import_cells;
  create temp table import_cells on commit drop as
  select
    coalesce(f.feature->'properties'->>'cell_id', f.feature->'properties'->>'cellId') as cell_id,
    case
      when f.feature ? 'geometry' and f.feature->'geometry' <> 'null'::jsonb
      then extensions.st_setsrid(extensions.st_geomfromgeojson((f.feature->'geometry')::text), 4326)::geometry(Polygon, 4326)
      else null::geometry(Polygon, 4326)
    end as geometry,
    f.feature->'properties' as props
  from jsonb_array_elements(cell_attributes_geojson->'features') as f(feature);

  select count(*) into cell_feature_count from import_cells;

  if cell_feature_count = 0 then
    raise exception 'cell_attributes_geojson contains no features.' using errcode = 'check_violation';
  end if;

  if exists (select 1 from import_cells where cell_id is null or length(trim(cell_id)) = 0) then
    raise exception 'cell_attributes_geojson contains missing cell IDs.' using errcode = 'check_violation';
  end if;

  if exists (select 1 from import_cells where geometry is null or extensions.st_isempty(geometry)) then
    raise exception 'cell_attributes_geojson contains missing geometries.' using errcode = 'check_violation';
  end if;

  select array_agg(cell_id order by cell_id)
  into duplicate_cell_ids
  from (
    select cell_id
    from import_cells
    group by cell_id
    having count(*) > 1
  ) d;

  if duplicate_cell_ids is not null then
    raise exception 'cell_attributes_geojson contains duplicate cell IDs: %.', duplicate_cell_ids
      using errcode = 'unique_violation';
  end if;

  insert into public.pipeline_datasets (
    city_id, dataset_id, generated_at, storage_prefix, manifest_path, source_layer, is_active
  )
  values (
    target_city_id, target_dataset_id, target_generated_at, target_storage_prefix,
    target_manifest_path, coalesce(nullif(target_source_layer, ''), 'hexgrid'), false
  )
  on conflict (city_id, dataset_id) do update set
    generated_at = excluded.generated_at,
    storage_prefix = excluded.storage_prefix,
    manifest_path = excluded.manifest_path,
    source_layer = excluded.source_layer;

  insert into public.pipeline_cell_attributes (
    cell_id, geometry, expected_richness, effort_corrected_richness,
    ecological_residual, nature_gap_score, corridor_importance, intervention_rank,
    heat_exposure, noise, light_pollution, fragmentation, water_proximity,
    connectivity_score, last_updated, disturbance_index, fragmentation_index,
    intervention_score, node_importance, impact_score, habitat_quality,
    habitat_quality_index, species_richness_raw, observed_richness,
    max_expected_richness, is_unsampled, temporal_bias_flag, path_km, n_obs,
    n_survey_dates, habitat_potential, observer_effort_score,
    taxonomic_diversity, species, pressures, interventions, tree_cover,
    land_use_green, city_id, dataset_id, generated_at
  )
  select
    cell_id,
    geometry,
    nullif(props->>'expected_richness', '')::numeric,
    nullif(props->>'effort_corrected_richness', '')::numeric,
    nullif(props->>'ecological_residual', '')::numeric,
    nullif(props->>'nature_gap_score', '')::numeric,
    nullif(props->>'corridor_importance', '')::numeric,
    nullif(props->>'intervention_rank', '')::integer,
    nullif(props->>'heat_exposure', '')::numeric,
    nullif(props->>'noise', '')::numeric,
    nullif(props->>'light_pollution', '')::numeric,
    nullif(props->>'fragmentation', '')::numeric,
    nullif(props->>'water_proximity', '')::numeric,
    nullif(props->>'connectivity_score', '')::numeric,
    coalesce(nullif(props->>'last_updated', '')::timestamptz, target_generated_at),
    nullif(props->>'disturbance_index', '')::numeric,
    nullif(props->>'fragmentation_index', '')::numeric,
    nullif(props->>'intervention_score', '')::numeric,
    nullif(props->>'node_importance', '')::numeric,
    nullif(props->>'impact_score', '')::integer,
    nullif(props->>'habitat_quality', '')::numeric,
    nullif(props->>'habitat_quality_index', '')::numeric,
    nullif(props->>'species_richness_raw', '')::integer,
    nullif(props->>'observed_richness', '')::numeric,
    nullif(props->>'max_expected_richness', '')::integer,
    coalesce(nullif(props->>'is_unsampled', '')::boolean, false),
    coalesce(nullif(props->>'temporal_bias_flag', '')::boolean, false),
    nullif(props->>'path_km', '')::numeric,
    nullif(props->>'n_obs', '')::integer,
    nullif(props->>'n_survey_dates', '')::integer,
    nullif(props->>'habitat_potential', ''),
    nullif(props->>'observer_effort_score', '')::numeric,
    nullif(props->>'taxonomic_diversity', '')::numeric,
    coalesce(props->'species', '[]'::jsonb),
    coalesce(props->'pressures', '[]'::jsonb),
    coalesce(props->'interventions', '[]'::jsonb),
    nullif(props->>'tree_cover', '')::numeric,
    nullif(props->>'land_use_green', '')::numeric,
    target_city_id,
    target_dataset_id,
    target_generated_at
  from import_cells
  on conflict (city_id, dataset_id, cell_id) do update set
    geometry = excluded.geometry,
    expected_richness = excluded.expected_richness,
    effort_corrected_richness = excluded.effort_corrected_richness,
    ecological_residual = excluded.ecological_residual,
    nature_gap_score = excluded.nature_gap_score,
    corridor_importance = excluded.corridor_importance,
    intervention_rank = excluded.intervention_rank,
    heat_exposure = excluded.heat_exposure,
    noise = excluded.noise,
    light_pollution = excluded.light_pollution,
    fragmentation = excluded.fragmentation,
    water_proximity = excluded.water_proximity,
    connectivity_score = excluded.connectivity_score,
    last_updated = excluded.last_updated,
    disturbance_index = excluded.disturbance_index,
    fragmentation_index = excluded.fragmentation_index,
    intervention_score = excluded.intervention_score,
    node_importance = excluded.node_importance,
    impact_score = excluded.impact_score,
    habitat_quality = excluded.habitat_quality,
    habitat_quality_index = excluded.habitat_quality_index,
    species_richness_raw = excluded.species_richness_raw,
    observed_richness = excluded.observed_richness,
    max_expected_richness = excluded.max_expected_richness,
    is_unsampled = excluded.is_unsampled,
    temporal_bias_flag = excluded.temporal_bias_flag,
    path_km = excluded.path_km,
    n_obs = excluded.n_obs,
    n_survey_dates = excluded.n_survey_dates,
    habitat_potential = excluded.habitat_potential,
    observer_effort_score = excluded.observer_effort_score,
    taxonomic_diversity = excluded.taxonomic_diversity,
    species = excluded.species,
    pressures = excluded.pressures,
    interventions = excluded.interventions,
    tree_cover = excluded.tree_cover,
    land_use_green = excluded.land_use_green,
    generated_at = excluded.generated_at;

  select count(*)
  into imported_cell_count
  from public.pipeline_cell_attributes
  where city_id = target_city_id
    and dataset_id = target_dataset_id;

  if imported_cell_count <> cell_feature_count then
    raise exception 'Imported cell row count mismatch for %.%: expected %, found %.',
      target_city_id, target_dataset_id, cell_feature_count, imported_cell_count
      using errcode = 'check_violation';
  end if;

  if green_spaces_geojson is not null then
    if green_spaces_geojson->>'type' <> 'FeatureCollection' then
      raise exception 'green_spaces_geojson must be a GeoJSON FeatureCollection.'
        using errcode = 'check_violation';
    end if;

    drop table if exists pg_temp.import_green_spaces;
    create temp table import_green_spaces on commit drop as
    select
      coalesce(f.feature->'properties'->>'id', f.feature->'properties'->>'green_space_id') as green_space_id,
      case
        when f.feature ? 'geometry' and f.feature->'geometry' <> 'null'::jsonb
        then extensions.st_multi(extensions.st_setsrid(extensions.st_geomfromgeojson((f.feature->'geometry')::text), 4326))::geometry(MultiPolygon, 4326)
        else null::geometry(MultiPolygon, 4326)
      end as geometry,
      f.feature->'properties' as props
    from jsonb_array_elements(green_spaces_geojson->'features') as f(feature);

    select count(*) into green_feature_count from import_green_spaces;

    if exists (select 1 from import_green_spaces where green_space_id is null or length(trim(green_space_id)) = 0) then
      raise exception 'green_spaces_geojson contains missing IDs.' using errcode = 'check_violation';
    end if;

    if exists (select 1 from import_green_spaces where geometry is null or extensions.st_isempty(geometry)) then
      raise exception 'green_spaces_geojson contains missing geometries.' using errcode = 'check_violation';
    end if;

    select array_agg(green_space_id order by green_space_id)
    into duplicate_green_ids
    from (
      select green_space_id
      from import_green_spaces
      group by green_space_id
      having count(*) > 1
    ) d;

    if duplicate_green_ids is not null then
      raise exception 'green_spaces_geojson contains duplicate IDs: %.', duplicate_green_ids
        using errcode = 'unique_violation';
    end if;

    insert into public.pipeline_green_spaces (
      city_id, dataset_id, green_space_id, generated_at, name, name_ja,
      ward_id, geometry, habitat_quality_index, effort_corrected_richness,
      expected_richness, ecological_residual, nature_gap_score, corridor_importance,
      intervention_rank
    )
    select
      target_city_id,
      target_dataset_id,
      green_space_id,
      target_generated_at,
      nullif(props->>'name', ''),
      nullif(props->>'nameJa', ''),
      nullif(props->>'wardId', ''),
      geometry,
      nullif(props->>'habitat_quality_index', '')::numeric,
      nullif(props->>'effort_corrected_richness', '')::numeric,
      nullif(props->>'expected_richness', '')::numeric,
      nullif(props->>'ecological_residual', '')::numeric,
      nullif(props->>'nature_gap_score', '')::numeric,
      nullif(props->>'corridor_importance', '')::numeric,
      nullif(props->>'intervention_rank', '')::numeric
    from import_green_spaces
    on conflict (city_id, dataset_id, green_space_id) do update set
      generated_at = excluded.generated_at,
      name = excluded.name,
      name_ja = excluded.name_ja,
      ward_id = excluded.ward_id,
      geometry = excluded.geometry,
      habitat_quality_index = excluded.habitat_quality_index,
      effort_corrected_richness = excluded.effort_corrected_richness,
      expected_richness = excluded.expected_richness,
      ecological_residual = excluded.ecological_residual,
      nature_gap_score = excluded.nature_gap_score,
      corridor_importance = excluded.corridor_importance,
      intervention_rank = excluded.intervention_rank;

    select count(*)
    into imported_green_count
    from public.pipeline_green_spaces
    where city_id = target_city_id
      and dataset_id = target_dataset_id;

    if imported_green_count <> green_feature_count then
      raise exception 'Imported green-space row count mismatch for %.%: expected %, found %.',
        target_city_id, target_dataset_id, green_feature_count, imported_green_count
        using errcode = 'check_violation';
    end if;
  end if;

  if activate then
    perform public.promote_pipeline_dataset(target_city_id, target_dataset_id);
  end if;

  return jsonb_build_object(
    'cityId', target_city_id,
    'datasetId', target_dataset_id,
    'cellFeatureCount', cell_feature_count,
    'cellRowsImported', imported_cell_count,
    'greenSpaceFeatureCount', green_feature_count,
    'greenSpaceRowsImported', imported_green_count,
    'activated', activate
  );
end;
$$;

alter table public.green_spaces enable row level security;
alter table public.pipeline_green_spaces enable row level security;

drop policy if exists "Green spaces readable" on public.green_spaces;
create policy "Green spaces readable"
on public.green_spaces
for select
to authenticated
using (true);

drop policy if exists "Admins manage green spaces" on public.green_spaces;
create policy "Admins manage green spaces"
on public.green_spaces
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Pipeline green spaces readable" on public.pipeline_green_spaces;
create policy "Pipeline green spaces readable"
on public.pipeline_green_spaces
for select
to authenticated
using (true);

drop policy if exists "Admins manage pipeline green spaces" on public.pipeline_green_spaces;
create policy "Admins manage pipeline green spaces"
on public.pipeline_green_spaces
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

grant select on public.green_spaces to authenticated;
grant select on public.pipeline_green_spaces to authenticated;
grant insert, update on public.green_spaces to authenticated;
grant insert, update on public.pipeline_green_spaces to authenticated;
grant execute on function public.assert_valid_pipeline_dataset_id(text) to authenticated;
grant execute on function public.import_pipeline_dataset(text, text, timestamptz, text, text, text, jsonb, jsonb, boolean) to authenticated;
