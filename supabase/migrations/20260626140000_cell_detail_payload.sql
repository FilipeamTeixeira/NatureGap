-- Store click-time cell detail in PostgreSQL so the frontend does not load
-- cells.json or merge cell stats into GeoJSON at runtime.

set search_path = public, extensions;

alter table public.cell_attributes
add column if not exists impact_score integer,
add column if not exists habitat_quality numeric,
add column if not exists habitat_quality_index numeric,
add column if not exists species_richness_raw integer,
add column if not exists observed_richness numeric,
add column if not exists max_expected_richness integer,
add column if not exists is_unsampled boolean,
add column if not exists temporal_bias_flag boolean,
add column if not exists path_km numeric,
add column if not exists n_obs integer,
add column if not exists n_survey_dates integer,
add column if not exists habitat_potential text,
add column if not exists observer_effort_score numeric,
add column if not exists taxonomic_diversity numeric,
add column if not exists species jsonb not null default '[]'::jsonb,
add column if not exists pressures jsonb not null default '[]'::jsonb,
add column if not exists interventions jsonb not null default '[]'::jsonb,
add column if not exists tree_cover numeric,
add column if not exists land_use_green numeric;

comment on column public.cell_attributes.species is
  'Click-time taxonomic breakdown for the cell; not included in PMTiles.';
comment on column public.cell_attributes.pressures is
  'Click-time explanatory pressure strings for the cell; not included in PMTiles.';
comment on column public.cell_attributes.interventions is
  'Click-time intervention descriptions for the cell; PMTiles stores only intervention_rank.';
