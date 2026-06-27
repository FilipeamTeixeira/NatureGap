-- Add immutable pipeline dataset versioning while preserving the existing
-- cell_attributes table as the active projection used by current app FKs.

set search_path = public, extensions;

-- ── Dataset metadata ────────────────────────────────────────────────────────

create table if not exists public.pipeline_datasets (
  city_id text not null,
  dataset_id text not null,
  generated_at timestamptz not null,
  storage_prefix text not null,
  manifest_path text not null,
  source_layer text not null default 'hexgrid',
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (city_id, dataset_id),
  constraint pipeline_datasets_city_id_not_blank check (length(trim(city_id)) > 0),
  constraint pipeline_datasets_dataset_id_not_blank check (length(trim(dataset_id)) > 0),
  constraint pipeline_datasets_storage_prefix_not_blank check (length(trim(storage_prefix)) > 0),
  constraint pipeline_datasets_manifest_path_not_blank check (length(trim(manifest_path)) > 0),
  constraint pipeline_datasets_source_layer_not_blank check (length(trim(source_layer)) > 0)
);

create unique index if not exists pipeline_datasets_one_active_per_city_idx
on public.pipeline_datasets (city_id)
where is_active;

create index if not exists pipeline_datasets_generated_at_idx
on public.pipeline_datasets (generated_at desc);

drop trigger if exists pipeline_datasets_set_updated_at on public.pipeline_datasets;
create trigger pipeline_datasets_set_updated_at
before update on public.pipeline_datasets
for each row execute function public.set_updated_at();

drop trigger if exists pipeline_datasets_prevent_delete on public.pipeline_datasets;
create trigger pipeline_datasets_prevent_delete
before delete on public.pipeline_datasets
for each row execute function public.prevent_hard_delete();

comment on table public.pipeline_datasets is
  'Metadata for immutable R pipeline runs. One active dataset per city is promoted for the frontend.';

-- ── Active cell projection metadata ─────────────────────────────────────────

alter table public.cell_attributes
add column if not exists city_id text not null default 'yokohama-honmoku',
add column if not exists dataset_id text not null default 'legacy',
add column if not exists generated_at timestamptz not null default now();

create index if not exists cell_attributes_city_dataset_idx
on public.cell_attributes (city_id, dataset_id);

create index if not exists cell_attributes_city_intervention_rank_idx
on public.cell_attributes (city_id, intervention_rank);

comment on column public.cell_attributes.city_id is
  'City for the active cell projection row.';
comment on column public.cell_attributes.dataset_id is
  'Active pipeline dataset that produced this cell row.';
comment on column public.cell_attributes.generated_at is
  'Generation timestamp for the active pipeline dataset.';

-- ── Immutable cell outputs ──────────────────────────────────────────────────

create table if not exists public.pipeline_cell_attributes (
  like public.cell_attributes including defaults including constraints
);

alter table public.pipeline_cell_attributes
alter column city_id set not null,
alter column dataset_id set not null,
alter column generated_at set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'pipeline_cell_attributes_pk'
      and conrelid = 'public.pipeline_cell_attributes'::regclass
  ) then
    alter table public.pipeline_cell_attributes
    add constraint pipeline_cell_attributes_pk primary key (city_id, dataset_id, cell_id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'pipeline_cell_attributes_dataset_fk'
      and conrelid = 'public.pipeline_cell_attributes'::regclass
  ) then
    alter table public.pipeline_cell_attributes
    add constraint pipeline_cell_attributes_dataset_fk
      foreign key (city_id, dataset_id)
      references public.pipeline_datasets(city_id, dataset_id)
      on delete restrict;
  end if;
end;
$$;

create index if not exists pipeline_cell_attributes_geometry_gist_idx
on public.pipeline_cell_attributes using gist (geometry);

create index if not exists pipeline_cell_attributes_city_rank_idx
on public.pipeline_cell_attributes (city_id, dataset_id, intervention_rank);

create index if not exists pipeline_cell_attributes_generated_at_idx
on public.pipeline_cell_attributes (generated_at desc);

drop trigger if exists pipeline_cell_attributes_prevent_delete on public.pipeline_cell_attributes;
create trigger pipeline_cell_attributes_prevent_delete
before delete on public.pipeline_cell_attributes
for each row execute function public.prevent_hard_delete();

comment on table public.pipeline_cell_attributes is
  'Immutable per-cell outputs from every R pipeline dataset. cell_attributes remains the active projection.';

-- ── Audit support for composite-key pipeline tables ─────────────────────────

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

drop trigger if exists pipeline_datasets_audit on public.pipeline_datasets;
create trigger pipeline_datasets_audit
after insert or update on public.pipeline_datasets
for each row execute function public.audit_row_change();

drop trigger if exists pipeline_cell_attributes_audit on public.pipeline_cell_attributes;
create trigger pipeline_cell_attributes_audit
after insert or update on public.pipeline_cell_attributes
for each row execute function public.audit_row_change();

-- ── Transactional city metadata ─────────────────────────────────────────────

alter table public.survey_points
add column if not exists city_id text not null default 'yokohama-honmoku';

alter table public.quick_sightings
add column if not exists city_id text not null default 'yokohama-honmoku';

alter table public.structured_surveys
add column if not exists city_id text not null default 'yokohama-honmoku';

create index if not exists survey_points_city_status_idx
on public.survey_points (city_id, status);

create index if not exists quick_sightings_city_cell_timestamp_idx
on public.quick_sightings (city_id, cell_id, "timestamp");

create index if not exists structured_surveys_city_cell_started_idx
on public.structured_surveys (city_id, cell_id, started_at);

comment on column public.survey_points.city_id is
  'City namespace for survey point location.';
comment on column public.quick_sightings.city_id is
  'City namespace for live observation assignment.';
comment on column public.structured_surveys.city_id is
  'City namespace inherited from the survey point.';

-- ── City-aware cell assignment ──────────────────────────────────────────────

create or replace function public.find_cell_id_for_point(
  lng double precision,
  lat double precision,
  target_city_id text
)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  with point_input as (
    select extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326) as geom
  )
  select ca.cell_id
  from public.cell_attributes ca, point_input p
  where target_city_id is null or ca.city_id = target_city_id
  order by extensions.st_distance(
    extensions.st_transform(extensions.st_centroid(ca.geometry), 3857),
    extensions.st_transform(p.geom, 3857)
  )
  limit 1
$$;

create or replace function public.find_cell_id_for_point(lng double precision, lat double precision)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select public.find_cell_id_for_point(lng, lat, null::text)
$$;

create or replace function public.find_cell_id_for_survey_point(point_id uuid)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select ca.cell_id
  from public.survey_points sp
  join public.cell_attributes ca on ca.city_id = sp.city_id
  where sp.id = point_id
  order by extensions.st_distance(
    extensions.st_transform(extensions.st_centroid(ca.geometry), 3857),
    extensions.st_transform(sp.geometry, 3857)
  )
  limit 1
$$;

create or replace function public.assign_quick_sighting_cell_id()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.geometry is null then
    return new;
  end if;

  select public.find_cell_id_for_point(
    extensions.st_x(new.geometry),
    extensions.st_y(new.geometry),
    new.city_id
  )
  into new.cell_id;

  if new.cell_id is null then
    raise exception 'No active 20 m hex cell found for quick sighting geometry in city %.', new.city_id
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end;
$$;

create or replace function public.assign_structured_survey_cell_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  point_city_id text;
begin
  select sp.city_id
  into point_city_id
  from public.survey_points sp
  where sp.id = new.survey_point_id;

  if point_city_id is null then
    raise exception 'Structured survey point % does not exist.', new.survey_point_id
      using errcode = 'foreign_key_violation';
  end if;

  new.city_id = point_city_id;

  select public.find_cell_id_for_survey_point(new.survey_point_id)
  into new.cell_id;

  if new.cell_id is null then
    raise exception 'No active 20 m hex cell found for structured survey point % in city %.', new.survey_point_id, new.city_id
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end;
$$;

-- ── Dataset promotion helper ────────────────────────────────────────────────

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
  if not public.is_admin() then
    raise exception 'Only admins can promote pipeline datasets.'
      using errcode = 'insufficient_privilege';
  end if;

  update public.pipeline_datasets
  set is_active = false
  where city_id = target_city_id
    and is_active;

  update public.pipeline_datasets
  set is_active = true
  where city_id = target_city_id
    and dataset_id = target_dataset_id;

  if not found then
    raise exception 'Pipeline dataset %.% does not exist.', target_city_id, target_dataset_id
      using errcode = 'foreign_key_violation';
  end if;

  insert into public.cell_attributes (
    cell_id,
    geometry,
    expected_richness,
    effort_corrected_richness,
    ecological_residual,
    corridor_importance,
    intervention_rank,
    heat_exposure,
    noise,
    light_pollution,
    fragmentation,
    water_proximity,
    connectivity_score,
    last_updated,
    disturbance_index,
    fragmentation_index,
    intervention_score,
    node_importance,
    impact_score,
    habitat_quality,
    habitat_quality_index,
    species_richness_raw,
    observed_richness,
    max_expected_richness,
    is_unsampled,
    temporal_bias_flag,
    path_km,
    n_obs,
    n_survey_dates,
    habitat_potential,
    observer_effort_score,
    taxonomic_diversity,
    species,
    pressures,
    interventions,
    tree_cover,
    land_use_green,
    city_id,
    dataset_id,
    generated_at
  )
  select
    cell_id,
    geometry,
    expected_richness,
    effort_corrected_richness,
    ecological_residual,
    corridor_importance,
    intervention_rank,
    heat_exposure,
    noise,
    light_pollution,
    fragmentation,
    water_proximity,
    connectivity_score,
    last_updated,
    disturbance_index,
    fragmentation_index,
    intervention_score,
    node_importance,
    impact_score,
    habitat_quality,
    habitat_quality_index,
    species_richness_raw,
    observed_richness,
    max_expected_richness,
    is_unsampled,
    temporal_bias_flag,
    path_km,
    n_obs,
    n_survey_dates,
    habitat_potential,
    observer_effort_score,
    taxonomic_diversity,
    species,
    pressures,
    interventions,
    tree_cover,
    land_use_green,
    city_id,
    dataset_id,
    generated_at
  from public.pipeline_cell_attributes
  where city_id = target_city_id
    and dataset_id = target_dataset_id
  on conflict (cell_id) do update set
    geometry = excluded.geometry,
    expected_richness = excluded.expected_richness,
    effort_corrected_richness = excluded.effort_corrected_richness,
    ecological_residual = excluded.ecological_residual,
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
end;
$$;

-- ── RLS and grants ──────────────────────────────────────────────────────────

alter table public.pipeline_datasets enable row level security;
alter table public.pipeline_cell_attributes enable row level security;

drop policy if exists "Pipeline datasets readable" on public.pipeline_datasets;
create policy "Pipeline datasets readable"
on public.pipeline_datasets
for select
to authenticated
using (true);

drop policy if exists "Admins manage pipeline datasets" on public.pipeline_datasets;
create policy "Admins manage pipeline datasets"
on public.pipeline_datasets
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Pipeline cell attributes readable" on public.pipeline_cell_attributes;
create policy "Pipeline cell attributes readable"
on public.pipeline_cell_attributes
for select
to authenticated
using (true);

drop policy if exists "Admins manage pipeline cell attributes" on public.pipeline_cell_attributes;
create policy "Admins manage pipeline cell attributes"
on public.pipeline_cell_attributes
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

grant select on public.pipeline_datasets to authenticated;
grant select on public.pipeline_cell_attributes to authenticated;
grant insert, update on public.pipeline_datasets to authenticated;
grant insert, update on public.pipeline_cell_attributes to authenticated;
grant execute on function public.find_cell_id_for_point(double precision, double precision, text) to authenticated;
grant execute on function public.promote_pipeline_dataset(text, text) to authenticated;
