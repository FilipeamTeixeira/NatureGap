-- Corrective migration: restore the full promote_pipeline_dataset body from
-- 20260723190000_pipeline_import_replace.sql and append staging purge for
-- other dataset_ids after successful promotion.

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
  if not public.can_manage_pipeline_datasets() then
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

  -- Retire cells that are no longer part of this import so the active
  -- projection matches the uploaded dataset (hard deletes remain forbidden).
  update public.cell_attributes ca
  set
    dataset_id = 'superseded',
    last_updated = now()
  where ca.city_id = target_city_id
    and ca.dataset_id <> 'legacy'
    and ca.dataset_id <> target_dataset_id
    and not exists (
      select 1
      from public.pipeline_cell_attributes pca
      where pca.city_id = target_city_id
        and pca.dataset_id = target_dataset_id
        and pca.cell_id = ca.cell_id
    );

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
    ecological_residual, ecological_residual_normalized, nature_gap_score,
    corridor_importance, intervention_rank,
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
    ecological_residual, ecological_residual_normalized, nature_gap_score,
    corridor_importance, intervention_rank,
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
    expected_richness, ecological_residual, ecological_residual_normalized,
    nature_gap_score, corridor_importance, intervention_rank, is_active
  )
  select
    green_space_id, city_id, dataset_id, generated_at, name, name_ja,
    ward_id, geometry, habitat_quality_index, effort_corrected_richness,
    expected_richness, ecological_residual, ecological_residual_normalized,
    nature_gap_score, corridor_importance, intervention_rank, true
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
    ecological_residual_normalized = excluded.ecological_residual_normalized,
    nature_gap_score = excluded.nature_gap_score,
    corridor_importance = excluded.corridor_importance,
    intervention_rank = excluded.intervention_rank,
    is_active = true;

  -- Purge staging rows for any OTHER dataset_id for this city,
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
