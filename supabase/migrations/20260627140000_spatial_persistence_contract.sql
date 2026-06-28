-- Persist NatureGap spatial pipeline outputs without changing auth.

set search_path = public, extensions;

-- ── Hex cells and corridor links ────────────────────────────────────────────

create table if not exists public.hex_cells (
  city_id text not null,
  dataset_id text not null,
  cell_id text not null,
  green_space_id text,
  geometry geometry(Polygon, 4326) not null,
  habitat_quality numeric,
  ndvi_idx numeric,
  canopy_height_idx numeric,
  lst_idx numeric,
  disturbance_idx numeric,
  land_use_class text,
  betweenness_centrality numeric,
  intervention_rank numeric,
  ecological_residual numeric,
  ecological_residual_normalized numeric,
  nature_gap_score numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (city_id, dataset_id, cell_id),
  constraint hex_cells_city_not_blank check (length(trim(city_id)) > 0),
  constraint hex_cells_dataset_not_blank check (length(trim(dataset_id)) > 0),
  constraint hex_cells_cell_not_blank check (length(trim(cell_id)) > 0),
  constraint hex_cells_green_space_fk
    foreign key (city_id, green_space_id)
    references public.green_spaces(city_id, green_space_id)
    on delete restrict
);

create table if not exists public.corridor_links (
  city_id text not null,
  dataset_id text not null,
  link_id text not null,
  geometry geometry(LineString, 4326) not null,
  resistance numeric,
  importance numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (city_id, dataset_id, link_id),
  constraint corridor_links_city_not_blank check (length(trim(city_id)) > 0),
  constraint corridor_links_dataset_not_blank check (length(trim(dataset_id)) > 0),
  constraint corridor_links_link_not_blank check (length(trim(link_id)) > 0)
);

alter table public.hex_cells
drop column if exists path_km,
drop column if exists is_unsampled,
drop column if exists properties,
drop column if exists tree_cover,
drop column if exists heat_exposure,
drop column if exists land_use_green,
drop column if exists nature_gap,
add column if not exists ndvi_idx numeric,
add column if not exists canopy_height_idx numeric,
add column if not exists lst_idx numeric,
add column if not exists disturbance_idx numeric,
add column if not exists land_use_class text,
add column if not exists intervention_rank numeric,
add column if not exists ecological_residual numeric,
add column if not exists ecological_residual_normalized numeric,
add column if not exists nature_gap_score numeric;

alter table public.corridor_links
add column if not exists link_id text,
add column if not exists resistance numeric,
add column if not exists importance numeric;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'corridor_links'
      and column_name = 'from_cell_id'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'corridor_links'
      and column_name = 'to_cell_id'
  ) then
    update public.corridor_links
    set link_id = coalesce(link_id, from_cell_id || '--' || to_cell_id);
  end if;
end;
$$;

alter table public.corridor_links
drop constraint if exists corridor_links_pkey,
drop constraint if exists corridor_links_distinct_cells,
drop constraint if exists corridor_links_weight_nonnegative,
drop constraint if exists corridor_links_from_hex_fk,
drop constraint if exists corridor_links_to_hex_fk,
drop column if exists from_cell_id,
drop column if exists to_cell_id,
drop column if exists weight,
drop column if exists properties;

alter table public.corridor_links
alter column link_id set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'corridor_links_pkey'
      and conrelid = 'public.corridor_links'::regclass
  ) then
    alter table public.corridor_links
    add constraint corridor_links_pkey primary key (city_id, dataset_id, link_id);
  end if;
end;
$$;

create index if not exists hex_cells_green_space_idx
on public.hex_cells (city_id, dataset_id, green_space_id);

create index if not exists hex_cells_geometry_gist_idx
on public.hex_cells using gist (geometry);

create index if not exists corridor_links_city_dataset_idx
on public.corridor_links (city_id, dataset_id);

create index if not exists corridor_links_geometry_gist_idx
on public.corridor_links using gist (geometry);

-- ── Green-space FK mapping for survey locations and records ────────────────

alter table public.survey_points
add column if not exists green_space_id text;

alter table public.quick_sightings
add column if not exists green_space_id text;

alter table public.structured_surveys
add column if not exists green_space_id text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'survey_points_green_space_fk'
      and conrelid = 'public.survey_points'::regclass
  ) then
    alter table public.survey_points
    add constraint survey_points_green_space_fk
      foreign key (city_id, green_space_id)
      references public.green_spaces(city_id, green_space_id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'quick_sightings_green_space_fk'
      and conrelid = 'public.quick_sightings'::regclass
  ) then
    alter table public.quick_sightings
    add constraint quick_sightings_green_space_fk
      foreign key (city_id, green_space_id)
      references public.green_spaces(city_id, green_space_id)
      on delete restrict;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'structured_surveys_green_space_fk'
      and conrelid = 'public.structured_surveys'::regclass
  ) then
    alter table public.structured_surveys
    add constraint structured_surveys_green_space_fk
      foreign key (city_id, green_space_id)
      references public.green_spaces(city_id, green_space_id)
      on delete restrict;
  end if;
end;
$$;

create index if not exists survey_points_green_space_idx
on public.survey_points (city_id, green_space_id);

create index if not exists quick_sightings_green_space_idx
on public.quick_sightings (city_id, green_space_id);

create index if not exists structured_surveys_green_space_idx
on public.structured_surveys (city_id, green_space_id);

create or replace function public.find_green_space_id_for_point(
  point_geom geometry(Point, 4326),
  target_city_id text
)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select gs.green_space_id
  from public.green_spaces gs
  where gs.city_id = target_city_id
    and gs.is_active
    and extensions.st_contains(gs.geometry, point_geom)
  order by extensions.st_area(extensions.st_transform(gs.geometry, 3857)) asc,
           gs.green_space_id
  limit 1
$$;

create or replace function public.assign_survey_point_green_space_id()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.geometry is null then
    return new;
  end if;

  select public.find_green_space_id_for_point(new.geometry, new.city_id)
  into new.green_space_id;

  return new;
end;
$$;

create or replace function public.assign_quick_sighting_green_space_id()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.geometry is null then
    return new;
  end if;

  select public.find_green_space_id_for_point(new.geometry, new.city_id)
  into new.green_space_id;

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
  point_green_space_id text;
begin
  select sp.city_id, sp.green_space_id
  into point_city_id, point_green_space_id
  from public.survey_points sp
  where sp.id = new.survey_point_id;

  if point_city_id is null then
    raise exception 'Structured survey point % does not exist.', new.survey_point_id
      using errcode = 'foreign_key_violation';
  end if;

  new.city_id = point_city_id;
  new.green_space_id = point_green_space_id;

  select public.find_cell_id_for_survey_point(new.survey_point_id)
  into new.cell_id;

  if new.cell_id is null then
    raise exception 'No active 20 m hex cell found for structured survey point % in city %.', new.survey_point_id, new.city_id
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists survey_points_assign_green_space_id on public.survey_points;
create trigger survey_points_assign_green_space_id
before insert or update of geometry, city_id on public.survey_points
for each row execute function public.assign_survey_point_green_space_id();

drop trigger if exists quick_sightings_assign_green_space_id on public.quick_sightings;
create trigger quick_sightings_assign_green_space_id
before insert or update of geometry, city_id on public.quick_sightings
for each row execute function public.assign_quick_sighting_green_space_id();

-- Keep existing structured_surveys_assign_cell_id trigger name and
-- survey_point_id mapping; the function now also copies green_space_id.

update public.survey_points sp
set green_space_id = public.find_green_space_id_for_point(sp.geometry, sp.city_id)
where sp.green_space_id is null
  and sp.geometry is not null;

update public.quick_sightings qs
set green_space_id = public.find_green_space_id_for_point(qs.geometry, qs.city_id)
where qs.green_space_id is null
  and qs.geometry is not null;

update public.structured_surveys ss
set green_space_id = sp.green_space_id
from public.survey_points sp
where ss.survey_point_id = sp.id
  and ss.green_space_id is null;

-- ── Auditing, guards, RLS, grants ───────────────────────────────────────────

drop trigger if exists hex_cells_set_updated_at on public.hex_cells;
create trigger hex_cells_set_updated_at
before update on public.hex_cells
for each row execute function public.set_updated_at();

drop trigger if exists corridor_links_set_updated_at on public.corridor_links;
create trigger corridor_links_set_updated_at
before update on public.corridor_links
for each row execute function public.set_updated_at();

drop trigger if exists hex_cells_prevent_delete on public.hex_cells;
create trigger hex_cells_prevent_delete
before delete on public.hex_cells
for each row execute function public.prevent_hard_delete();

drop trigger if exists corridor_links_prevent_delete on public.corridor_links;
create trigger corridor_links_prevent_delete
before delete on public.corridor_links
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
    pk := jsonb_build_object('cell_id', case when tg_op = 'INSERT' then new.cell_id else old.cell_id end);
  elsif tg_table_name = 'hex_cells' then
    pk := jsonb_build_object(
      'city_id', case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'dataset_id', case when tg_op = 'INSERT' then new.dataset_id else old.dataset_id end,
      'cell_id', case when tg_op = 'INSERT' then new.cell_id else old.cell_id end
    );
  elsif tg_table_name = 'corridor_links' then
    pk := jsonb_build_object(
      'city_id', case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'dataset_id', case when tg_op = 'INSERT' then new.dataset_id else old.dataset_id end,
      'link_id', case when tg_op = 'INSERT' then new.link_id else old.link_id end
    );
  elsif tg_table_name = 'pipeline_datasets' then
    pk := jsonb_build_object(
      'city_id', case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'dataset_id', case when tg_op = 'INSERT' then new.dataset_id else old.dataset_id end
    );
  elsif tg_table_name = 'pipeline_cell_attributes' then
    pk := jsonb_build_object(
      'city_id', case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'dataset_id', case when tg_op = 'INSERT' then new.dataset_id else old.dataset_id end,
      'cell_id', case when tg_op = 'INSERT' then new.cell_id else old.cell_id end
    );
  elsif tg_table_name = 'green_spaces' then
    pk := jsonb_build_object(
      'city_id', case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'green_space_id', case when tg_op = 'INSERT' then new.green_space_id else old.green_space_id end
    );
  elsif tg_table_name = 'pipeline_green_spaces' then
    pk := jsonb_build_object(
      'city_id', case when tg_op = 'INSERT' then new.city_id else old.city_id end,
      'dataset_id', case when tg_op = 'INSERT' then new.dataset_id else old.dataset_id end,
      'green_space_id', case when tg_op = 'INSERT' then new.green_space_id else old.green_space_id end
    );
  elsif tg_table_name = 'user_roles' then
    pk := jsonb_build_object('user_id', case when tg_op = 'INSERT' then new.user_id else old.user_id end);
  else
    pk := jsonb_build_object('id', case when tg_op = 'INSERT' then new.id else old.id end);
  end if;

  insert into public.audit_log (
    table_name, record_pk, operation, old_row, new_row, changed_by
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

drop trigger if exists hex_cells_audit on public.hex_cells;
create trigger hex_cells_audit
after insert or update on public.hex_cells
for each row execute function public.audit_row_change();

drop trigger if exists corridor_links_audit on public.corridor_links;
create trigger corridor_links_audit
after insert or update on public.corridor_links
for each row execute function public.audit_row_change();

alter table public.hex_cells enable row level security;
alter table public.corridor_links enable row level security;

drop policy if exists "Hex cells readable" on public.hex_cells;
create policy "Hex cells readable"
on public.hex_cells
for select
to authenticated
using (true);

drop policy if exists "Admins manage hex cells" on public.hex_cells;
create policy "Admins manage hex cells"
on public.hex_cells
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Corridor links readable" on public.corridor_links;
create policy "Corridor links readable"
on public.corridor_links
for select
to authenticated
using (true);

drop policy if exists "Admins manage corridor links" on public.corridor_links;
create policy "Admins manage corridor links"
on public.corridor_links
for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

grant select on public.hex_cells to authenticated;
grant select on public.corridor_links to authenticated;
grant insert, update on public.hex_cells to authenticated;
grant insert, update on public.corridor_links to authenticated;
grant execute on function public.find_green_space_id_for_point(geometry, text) to authenticated;
