-- NatureGap — Per-city normalisation columns and stats table
-- Adds _norm columns to green_spaces and hex_cells (additions only),
-- and creates city_layer_stats for legend endpoint values.

-- ── green_spaces: nine normalised metric columns ────────────────────────────

alter table public.green_spaces
  add column if not exists habitat_quality_norm           float,
  add column if not exists effort_corrected_richness_norm float,
  add column if not exists expected_richness_norm         float,
  add column if not exists corridor_importance_norm       float,
  add column if not exists mean_canopy_norm               float,
  add column if not exists mean_lst_norm                  float,
  add column if not exists ecological_residual_norm       float,
  add column if not exists nature_gap_score_norm          float,
  add column if not exists intervention_rank_norm         float;

-- ── hex_cells: six normalised metric columns ────────────────────────────────

alter table public.hex_cells
  add column if not exists ndvi_norm               float,
  add column if not exists canopy_norm             float,
  add column if not exists lst_norm                float,
  add column if not exists disturbance_norm        float,
  add column if not exists betweenness_norm        float,
  add column if not exists residual_norm           float,
  add column if not exists nature_gap_score_norm   float;

-- ── city_layer_stats: per-city percentile bounds for legend rendering ────────

create table if not exists public.city_layer_stats (
  city_id  text  not null,
  metric   text  not null,
  min_val  float,
  max_val  float,
  p05      float,
  p10      float,
  p25      float,
  p50      float,
  p75      float,
  p90      float,
  p95      float,
  bound    float,   -- symmetric bound for diverging metrics; null for sequential
  primary key (city_id, metric)
);

create index if not exists city_layer_stats_city_idx
  on public.city_layer_stats (city_id);

-- Row-level security: readable by all (stats are not sensitive),
-- writable only by the service role (pipeline writes).
alter table public.city_layer_stats enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename  = 'city_layer_stats'
      and policyname = 'city_layer_stats_select'
  ) then
    execute $pol$
      create policy city_layer_stats_select
        on public.city_layer_stats
        for select
        using (true)
    $pol$;
  end if;
end;
$$;
