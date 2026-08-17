-- CIR orthophoto hex metrics: vegetated fraction and within-hex NDVI texture.
-- Supplementary to Sentinel-2 ndvi_idx; not used in habitat_quality.

set search_path = public;

alter table public.cell_attributes
add column if not exists veg_fraction numeric,
add column if not exists ndvi_texture numeric;

alter table public.pipeline_cell_attributes
add column if not exists veg_fraction numeric,
add column if not exists ndvi_texture numeric;

comment on column public.cell_attributes.veg_fraction is
  'Share of CIR orthophoto pixels in the hex with DN-based NDVI >= CIR_VEG_NDVI_THRESHOLD.';
comment on column public.cell_attributes.ndvi_texture is
  'Standard deviation of CIR orthophoto DN-based NDVI within the hex.';

create or replace function public.import_pipeline_dataset_cells_batch(
  target_city_id text,
  target_dataset_id text,
  target_generated_at timestamptz,
  cell_attributes_geojson jsonb
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  batch_feature_count integer;
  duplicate_cell_ids text[];
begin
  if not public.can_manage_pipeline_datasets() then
    raise exception 'Only admins can import pipeline datasets.'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.assert_valid_pipeline_dataset_id(target_dataset_id);

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

  select count(*) into batch_feature_count from import_cells;

  if batch_feature_count = 0 then
    return 0;
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

  insert into public.pipeline_cell_attributes (
    cell_id, geometry, expected_richness, effort_corrected_richness,
    ecological_residual, ecological_residual_normalized, nature_gap_score,
    corridor_importance, intervention_rank,
    heat_exposure, noise, light_pollution, fragmentation, water_proximity,
    connectivity_score, last_updated, disturbance_index, fragmentation_index,
    intervention_score, node_importance, impact_score, habitat_quality,
    habitat_quality_index, species_richness_raw, observed_richness,
    max_expected_richness, is_unsampled, temporal_bias_flag, path_km, n_obs,
    n_survey_dates, habitat_potential, observer_effort_score,
    taxonomic_diversity, species, pressures, interventions, tree_cover,
    land_use_green, veg_fraction, ndvi_texture, city_id, dataset_id, generated_at
  )
  select
    cell_id,
    geometry,
    nullif(props->>'expected_richness', '')::numeric,
    nullif(props->>'effort_corrected_richness', '')::numeric,
    nullif(props->>'ecological_residual', '')::numeric,
    nullif(props->>'ecological_residual_normalized', '')::numeric,
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
    nullif(props->>'veg_fraction', '')::numeric,
    nullif(props->>'ndvi_texture', '')::numeric,
    target_city_id,
    target_dataset_id,
    target_generated_at
  from import_cells
  on conflict (city_id, dataset_id, cell_id) do update set
    geometry = excluded.geometry,
    expected_richness = excluded.expected_richness,
    effort_corrected_richness = excluded.effort_corrected_richness,
    ecological_residual = excluded.ecological_residual,
    ecological_residual_normalized = excluded.ecological_residual_normalized,
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
    veg_fraction = excluded.veg_fraction,
    ndvi_texture = excluded.ndvi_texture,
    generated_at = excluded.generated_at;

  return batch_feature_count;
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
  if not public.can_manage_pipeline_datasets() then
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

  perform public.purge_pipeline_dataset_snapshot(target_city_id, target_dataset_id);

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
    ecological_residual, ecological_residual_normalized, nature_gap_score,
    corridor_importance, intervention_rank,
    heat_exposure, noise, light_pollution, fragmentation, water_proximity,
    connectivity_score, last_updated, disturbance_index, fragmentation_index,
    intervention_score, node_importance, impact_score, habitat_quality,
    habitat_quality_index, species_richness_raw, observed_richness,
    max_expected_richness, is_unsampled, temporal_bias_flag, path_km, n_obs,
    n_survey_dates, habitat_potential, observer_effort_score,
    taxonomic_diversity, species, pressures, interventions, tree_cover,
    land_use_green, veg_fraction, ndvi_texture, city_id, dataset_id, generated_at
  )
  select
    cell_id,
    geometry,
    nullif(props->>'expected_richness', '')::numeric,
    nullif(props->>'effort_corrected_richness', '')::numeric,
    nullif(props->>'ecological_residual', '')::numeric,
    nullif(props->>'ecological_residual_normalized', '')::numeric,
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
    nullif(props->>'veg_fraction', '')::numeric,
    nullif(props->>'ndvi_texture', '')::numeric,
    target_city_id,
    target_dataset_id,
    target_generated_at
  from import_cells
  on conflict (city_id, dataset_id, cell_id) do update set
    geometry = excluded.geometry,
    expected_richness = excluded.expected_richness,
    effort_corrected_richness = excluded.effort_corrected_richness,
    ecological_residual = excluded.ecological_residual,
    ecological_residual_normalized = excluded.ecological_residual_normalized,
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
    veg_fraction = excluded.veg_fraction,
    ndvi_texture = excluded.ndvi_texture,
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
      expected_richness, ecological_residual, ecological_residual_normalized,
      nature_gap_score, corridor_importance, intervention_rank
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
      nullif(props->>'ecological_residual_normalized', '')::numeric,
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
      ecological_residual_normalized = excluded.ecological_residual_normalized,
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
