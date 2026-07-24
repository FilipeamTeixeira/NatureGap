-- NatureGap pipeline PostgreSQL reset.
--
-- Purpose:
--   Remove imported/generated pipeline analysis data from Supabase Postgres so
--   the app can use Supabase Storage + PMTiles as the published data source.
--
-- Preserved:
--   Citizen-science submissions, survey records, species reference data,
--   users/roles, moderation data, suggestions, flags, and audit_log.
--
-- Run manually in the Supabase SQL editor or with psql after reviewing.

begin;

-- Keep citizen-science rows, but detach their analytical cell references so
-- public.cell_attributes can be emptied despite ON DELETE RESTRICT FKs.
update public.quick_sightings
set cell_id = null
where cell_id is not null;

update public.structured_surveys
set cell_id = null
where cell_id is not null;

-- These tables intentionally have hard-delete guards. This reset is a manual
-- operator action, so disable user triggers only for this transaction.
alter table if exists public.cell_attributes disable trigger user;
alter table if exists public.pipeline_cell_attributes disable trigger user;
alter table if exists public.green_spaces disable trigger user;
alter table if exists public.pipeline_green_spaces disable trigger user;
alter table if exists public.pipeline_datasets disable trigger user;
alter table if exists public.hex_cells disable trigger user;
alter table if exists public.corridor_links disable trigger user;

do $$
begin
  if to_regclass('public.corridor_links') is not null then
    delete from public.corridor_links;
  end if;
  if to_regclass('public.hex_cells') is not null then
    delete from public.hex_cells;
  end if;
  if to_regclass('public.pipeline_cell_attributes') is not null then
    delete from public.pipeline_cell_attributes;
  end if;
  if to_regclass('public.pipeline_green_spaces') is not null then
    delete from public.pipeline_green_spaces;
  end if;
  if to_regclass('public.cell_attributes') is not null then
    delete from public.cell_attributes;
  end if;
  if to_regclass('public.green_spaces') is not null then
    delete from public.green_spaces;
  end if;
  if to_regclass('public.city_layer_stats') is not null then
    delete from public.city_layer_stats;
  end if;
  if to_regclass('public.pipeline_datasets') is not null then
    delete from public.pipeline_datasets;
  end if;
end $$;

alter table if exists public.corridor_links enable trigger user;
alter table if exists public.hex_cells enable trigger user;
alter table if exists public.pipeline_datasets enable trigger user;
alter table if exists public.pipeline_green_spaces enable trigger user;
alter table if exists public.green_spaces enable trigger user;
alter table if exists public.pipeline_cell_attributes enable trigger user;
alter table if exists public.cell_attributes enable trigger user;

commit;

create temp table if not exists pg_temp.pipeline_cleanup_counts (
  table_name text primary key,
  rows bigint
) on commit drop;

truncate table pg_temp.pipeline_cleanup_counts;

do $$
declare
  target text;
begin
  foreach target in array array[
    'cell_attributes',
    'pipeline_cell_attributes',
    'green_spaces',
    'pipeline_green_spaces',
    'hex_cells',
    'corridor_links',
    'city_layer_stats',
    'pipeline_datasets'
  ]
  loop
    if to_regclass(format('public.%I', target)) is null then
      insert into pg_temp.pipeline_cleanup_counts values (target, null);
    else
      execute format(
        'insert into pg_temp.pipeline_cleanup_counts select %L, count(*) from public.%I',
        target,
        target
      );
    end if;
  end loop;
end $$;

select table_name, rows
from pg_temp.pipeline_cleanup_counts
order by table_name;
