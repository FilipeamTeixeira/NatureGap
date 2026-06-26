-- Backend support for citizen science Edge Functions.

set search_path = public, extensions;

alter table public.quick_sightings
add column cell_id text references public.cell_attributes(cell_id) on delete restrict;

create index quick_sightings_cell_id_idx on public.quick_sightings (cell_id);

create or replace function public.find_cell_id_for_point(lng double precision, lat double precision)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select ca.cell_id
  from public.cell_attributes ca
  where extensions.st_contains(
    ca.geometry,
    extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)
  )
  order by ca.cell_id
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
  join public.cell_attributes ca
    on extensions.st_contains(ca.geometry, sp.geometry)
  where sp.id = point_id
  order by ca.cell_id
  limit 1
$$;

create or replace function public.enforce_first_quick_sighting_photo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requires_photo boolean;
  prior_count integer;
begin
  if new.species_id is null then
    return new;
  end if;

  select requires_photo_on_first_record
  into requires_photo
  from public.species_reference
  where id = new.species_id;

  if not coalesce(requires_photo, false) then
    return new;
  end if;

  if new.cell_id is null then
    if new.photo_url is null or length(trim(new.photo_url)) = 0 then
      raise exception 'First quick sighting photo rule cannot be evaluated without cell_id.'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  select count(*)
  into prior_count
  from public.quick_sightings
  where cell_id = new.cell_id
    and species_id = new.species_id
    and id <> new.id;

  if prior_count = 0 and (new.photo_url is null or length(trim(new.photo_url)) = 0) then
    raise exception 'First quick sighting for this species in this cell requires a photo.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop policy if exists "Contributors can flag records" on public.flags;

create policy "Authenticated users can flag records"
on public.flags
for insert
to authenticated
with check (
  flagged_by = auth.uid()
  and outcome = 'pending'
);

drop policy if exists "Flags visible to flagger and admins" on public.flags;

create policy "Flags visible to authenticated users"
on public.flags
for select
to authenticated
using (true);

drop policy if exists "Admins review flags" on public.flags;

create policy "Admins and taxonomists review flags"
on public.flags
for update
to authenticated
using (public.is_admin() or public.is_taxonomist())
with check (public.is_admin() or public.is_taxonomist());

create or replace view public.analysis_quick_sightings as
select qs.*
from public.quick_sightings qs
where qs.status <> 'rejected'
  and not exists (
    select 1
    from public.flags f
    where f.record_type = 'quick_sighting'
      and f.record_id = qs.id::text
      and f.outcome in ('pending', 'confirmed')
  );

create or replace view public.analysis_structured_surveys as
select ss.*
from public.structured_surveys ss
where ss.status <> 'rejected'
  and not exists (
    select 1
    from public.flags f
    where f.record_type = 'structured_survey'
      and f.record_id = ss.id::text
      and f.outcome in ('pending', 'confirmed')
  );

create or replace view public.analysis_survey_records as
select sr.*
from public.survey_records sr
join public.analysis_structured_surveys ss on ss.id = sr.survey_id
where not exists (
  select 1
  from public.flags f
  where f.record_type = 'survey_record'
    and f.record_id = sr.id::text
    and f.outcome in ('pending', 'confirmed')
);

grant execute on function public.find_cell_id_for_point(double precision, double precision) to authenticated;
grant execute on function public.find_cell_id_for_survey_point(uuid) to authenticated;
grant select on public.analysis_quick_sightings to authenticated;
grant select on public.analysis_structured_surveys to authenticated;
grant select on public.analysis_survey_records to authenticated;
