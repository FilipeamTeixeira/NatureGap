-- pipeline_cell_attributes is created once with LIKE cell_attributes. Later
-- columns added only to cell_attributes were never mirrored, so import fails.
-- Also backfill both tables when migrations were never applied remotely.

set search_path = public;

alter table public.cell_attributes
add column if not exists disturbance_index numeric,
add column if not exists fragmentation_index numeric,
add column if not exists intervention_score numeric,
add column if not exists node_importance numeric,
add column if not exists impact_score integer,
add column if not exists nature_gap_score numeric,
add column if not exists habitat_quality numeric,
add column if not exists habitat_quality_index numeric,
add column if not exists species_richness_raw integer,
add column if not exists observed_richness numeric,
add column if not exists ecological_residual_normalized numeric,
add column if not exists max_expected_richness integer,
add column if not exists is_unsampled boolean,
add column if not exists temporal_bias_flag boolean,
add column if not exists path_km numeric,
add column if not exists n_obs integer,
add column if not exists n_survey_dates integer,
add column if not exists habitat_potential text,
add column if not exists observer_effort_score numeric,
add column if not exists taxonomic_diversity numeric,
add column if not exists species jsonb default '[]'::jsonb,
add column if not exists pressures jsonb default '[]'::jsonb,
add column if not exists interventions jsonb default '[]'::jsonb,
add column if not exists tree_cover numeric,
add column if not exists land_use_green numeric;

alter table public.pipeline_cell_attributes
add column if not exists disturbance_index numeric,
add column if not exists fragmentation_index numeric,
add column if not exists intervention_score numeric,
add column if not exists node_importance numeric,
add column if not exists impact_score integer,
add column if not exists nature_gap_score numeric,
add column if not exists habitat_quality numeric,
add column if not exists habitat_quality_index numeric,
add column if not exists species_richness_raw integer,
add column if not exists observed_richness numeric,
add column if not exists ecological_residual_normalized numeric,
add column if not exists max_expected_richness integer,
add column if not exists is_unsampled boolean,
add column if not exists temporal_bias_flag boolean,
add column if not exists path_km numeric,
add column if not exists n_obs integer,
add column if not exists n_survey_dates integer,
add column if not exists habitat_potential text,
add column if not exists observer_effort_score numeric,
add column if not exists taxonomic_diversity numeric,
add column if not exists species jsonb default '[]'::jsonb,
add column if not exists pressures jsonb default '[]'::jsonb,
add column if not exists interventions jsonb default '[]'::jsonb,
add column if not exists tree_cover numeric,
add column if not exists land_use_green numeric;

alter table public.green_spaces
add column if not exists habitat_quality_index numeric,
add column if not exists effort_corrected_richness numeric,
add column if not exists expected_richness numeric,
add column if not exists ecological_residual numeric,
add column if not exists ecological_residual_normalized numeric,
add column if not exists nature_gap_score numeric,
add column if not exists corridor_importance numeric,
add column if not exists intervention_rank numeric;

alter table public.pipeline_green_spaces
add column if not exists habitat_quality_index numeric,
add column if not exists effort_corrected_richness numeric,
add column if not exists expected_richness numeric,
add column if not exists ecological_residual numeric,
add column if not exists ecological_residual_normalized numeric,
add column if not exists nature_gap_score numeric,
add column if not exists corridor_importance numeric,
add column if not exists intervention_rank numeric;

do $$
declare
  col record;
begin
  for col in
    select
      a.attname as column_name,
      pg_catalog.format_type(a.atttypid, a.atttypmod) as column_type,
      pg_get_expr(ad.adbin, ad.adrelid) as column_default
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    left join pg_catalog.pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
    where n.nspname = 'public'
      and c.relname = 'cell_attributes'
      and a.attnum > 0
      and not a.attisdropped
      and a.attname not in (
        select a2.attname
        from pg_catalog.pg_attribute a2
        join pg_catalog.pg_class c2 on c2.oid = a2.attrelid
        join pg_catalog.pg_namespace n2 on n2.oid = c2.relnamespace
        where n2.nspname = 'public'
          and c2.relname = 'pipeline_cell_attributes'
          and a2.attnum > 0
          and not a2.attisdropped
      )
  loop
    execute format(
      'alter table public.pipeline_cell_attributes add column if not exists %I %s%s',
      col.column_name,
      col.column_type,
      case
        when col.column_default is not null then ' default ' || col.column_default
        else ''
      end
    );
  end loop;
end $$;

comment on table public.pipeline_cell_attributes is
  'Immutable per-cell outputs from every R pipeline dataset. Schema tracks cell_attributes.';
