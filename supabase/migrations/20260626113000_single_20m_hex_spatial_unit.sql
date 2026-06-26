-- Enforce the single NatureGap spatial unit: 20 m hexagons.
-- cell_id always refers to public.cell_attributes.cell_id.

set search_path = public, extensions;

alter table public.structured_surveys
add column if not exists cell_id text references public.cell_attributes(cell_id) on delete restrict;

alter table public.cell_attributes
add column if not exists disturbance_index numeric,
add column if not exists fragmentation_index numeric,
add column if not exists intervention_score numeric,
add column if not exists node_importance numeric;

create index if not exists structured_surveys_cell_id_idx on public.structured_surveys (cell_id);
create index if not exists quick_sightings_cell_id_idx on public.quick_sightings (cell_id);

comment on table public.cell_attributes is
  'Canonical 20 m hex grid. This is the only persisted analytical/display grid.';
comment on column public.cell_attributes.cell_id is
  'Stable identifier for one 20 m hexagon; referenced by observations and cell attributes.';
comment on column public.quick_sightings.cell_id is
  'Nearest canonical 20 m hex cell_id; raw GPS point remains in geometry.';
comment on column public.structured_surveys.cell_id is
  'Nearest canonical 20 m hex cell_id for the approved survey point.';

create or replace function public.find_cell_id_for_point(lng double precision, lat double precision)
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
  order by extensions.st_distance(
    extensions.st_transform(extensions.st_centroid(ca.geometry), 3857),
    extensions.st_transform(p.geom, 3857)
  )
  limit 1
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
  join public.cell_attributes ca on true
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
    extensions.st_y(new.geometry)
  )
  into new.cell_id;

  if new.cell_id is null then
    raise exception 'No 20 m hex cell found for quick sighting geometry.'
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
begin
  select public.find_cell_id_for_survey_point(new.survey_point_id)
  into new.cell_id;

  if new.cell_id is null then
    raise exception 'No 20 m hex cell found for structured survey point.'
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists quick_sightings_assign_cell_id on public.quick_sightings;
create trigger quick_sightings_assign_cell_id
before insert or update of geometry on public.quick_sightings
for each row execute function public.assign_quick_sighting_cell_id();

drop trigger if exists structured_surveys_assign_cell_id on public.structured_surveys;
create trigger structured_surveys_assign_cell_id
before insert or update of survey_point_id on public.structured_surveys
for each row execute function public.assign_structured_survey_cell_id();

grant execute on function public.find_cell_id_for_point(double precision, double precision) to authenticated;
grant execute on function public.find_cell_id_for_survey_point(uuid) to authenticated;
