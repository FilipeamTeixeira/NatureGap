-- Complete citizen-science workflow alignment.
-- Keeps R as the only ecological producer and preserves no-hard-delete rules.

set search_path = public, extensions;

-- ── Role helper alignment ──────────────────────────────────────────────────
-- Edge Functions treat missing role rows as contributor. RLS must do the same.

create or replace function public.current_app_role()
returns public.user_role
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce(
    (select role from public.user_roles where user_id = auth.uid()),
    'contributor'::public.user_role
  )
$$;

create or replace function public.has_app_role(required_role public.user_role)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select case
    when auth.uid() is null then false
    when public.current_app_role() = 'admin' then true
    when required_role = 'contributor' then true
    else public.current_app_role() = required_role
  end
$$;

-- ── Structured observer metadata ───────────────────────────────────────────

alter table public.structured_surveys
add column if not exists observer_metadata jsonb not null default '{}'::jsonb;

comment on column public.structured_surveys.observer_metadata is
  'Non-ecological observer/session metadata such as GPS accuracy and client timing.';

-- ── Suggestions are a unified community queue ───────────────────────────────

drop policy if exists "Surveyors submit suggestions" on public.suggestions;
drop policy if exists "Authenticated users submit suggestions" on public.suggestions;

create policy "Authenticated users submit suggestions"
on public.suggestions
for insert
to authenticated
with check (
  submitted_by = auth.uid()
  and status = 'pending'
);

-- ── Duplicate quick sighting quality flag ───────────────────────────────────

create or replace function public.mark_duplicate_quick_sighting()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  duplicate_exists boolean;
begin
  select exists (
    select 1
    from public.quick_sightings qs
    where qs.id <> new.id
      and qs.user_id = new.user_id
      and qs.taxon_group = new.taxon_group
      and qs.species_id is not distinct from new.species_id
      and abs(extract(epoch from (qs."timestamp" - new."timestamp"))) <= 1800
      and extensions.st_dwithin(qs.geometry::geography, new.geometry::geography, greatest(new.gps_accuracy_m, 25))
  )
  into duplicate_exists;

  if duplicate_exists and new.status = 'submitted' then
    new.status = 'flagged_review';
  end if;

  return new;
end;
$$;

create or replace function public.flag_duplicate_quick_sighting()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  duplicate_exists boolean;
  duplicate_reason text := 'Duplicate detection: same taxon/species within 30 minutes and GPS tolerance';
begin
  select exists (
    select 1
    from public.quick_sightings qs
    where qs.id <> new.id
      and qs.user_id = new.user_id
      and qs.taxon_group = new.taxon_group
      and qs.species_id is not distinct from new.species_id
      and abs(extract(epoch from (qs."timestamp" - new."timestamp"))) <= 1800
      and extensions.st_dwithin(qs.geometry::geography, new.geometry::geography, greatest(new.gps_accuracy_m, 25))
  )
  into duplicate_exists;

  if duplicate_exists and not exists (
    select 1
    from public.flags f
    where f.record_type = 'quick_sighting'
      and f.record_id = new.id::text
      and f.reason = duplicate_reason
  ) then
    insert into public.flags (record_type, record_id, reason, flagged_by, outcome)
    values ('quick_sighting', new.id::text, duplicate_reason, new.user_id, 'pending');
  end if;

  return new;
end;
$$;

drop trigger if exists quick_sightings_duplicate_flag on public.quick_sightings;
create trigger quick_sightings_duplicate_flag
after insert on public.quick_sightings
for each row execute function public.flag_duplicate_quick_sighting();

-- ── Analysis views only expose approved, unflagged observations ─────────────

create or replace view public.analysis_quick_sightings as
select qs.*
from public.quick_sightings qs
where qs.status = 'approved'
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
where ss.status = 'approved'
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

grant select on public.analysis_quick_sightings to authenticated;
grant select on public.analysis_structured_surveys to authenticated;
grant select on public.analysis_survey_records to authenticated;

-- ── R export contract: quick sightings are presence-only ────────────────────

drop view if exists public.pipeline_observations_export;

create or replace view public.pipeline_observations_export as
select
  qs.id::text as observation_id,
  'quick_sighting'::text as observation_source,
  qs.city_id,
  coalesce(sr.scientific_name, qs.taxon_group::text || ':' || qs.id::text) as taxon_name,
  qs.taxon_group::text as iconic_taxon_name,
  sr.common_name as common_label,
  qs."timestamp"::date as observed_on,
  qs."timestamp" as observed_at,
  0::numeric as observation_weight,
  qs.user_id::text as observer_id,
  qs.gps_accuracy_m,
  qs.cell_id,
  null::uuid as survey_id,
  null::integer as survey_duration_seconds,
  null::jsonb as habitat_indicators,
  extensions.st_x(qs.geometry) as lng,
  extensions.st_y(qs.geometry) as lat,
  qs.status::text as review_status
from public.analysis_quick_sightings qs
left join public.species_reference sr on sr.id = qs.species_id

union all

select
  rec.id::text as observation_id,
  'structured_survey'::text as observation_source,
  survey.city_id,
  coalesce(species.scientific_name, rec.taxon_group::text || ':' || rec.id::text) as taxon_name,
  rec.taxon_group::text as iconic_taxon_name,
  species.common_name as common_label,
  survey.started_at::date as observed_on,
  survey.started_at as observed_at,
  3::numeric as observation_weight,
  survey.user_id::text as observer_id,
  null::numeric as gps_accuracy_m,
  survey.cell_id,
  survey.id as survey_id,
  survey.duration_seconds as survey_duration_seconds,
  survey.habitat_indicators,
  extensions.st_x(point.geometry) as lng,
  extensions.st_y(point.geometry) as lat,
  survey.status::text as review_status
from public.analysis_survey_records rec
join public.analysis_structured_surveys survey on survey.id = rec.survey_id
join public.survey_points point on point.id = survey.survey_point_id
left join public.species_reference species on species.id = rec.species_id;

grant select on public.pipeline_observations_export to authenticated;
