-- Observation integrity and contributor privacy, before any app-collected
-- record reaches a published pipeline output (Phase 6a).
--
-- None of this changes stored data. It closes paths by which a record could
-- skip review, keeps account identifiers out of the pipeline export, and keeps
-- records that name no species out of species richness. On 2026-10-02 the
-- export held zero app records, so nothing has been published that this
-- would have stopped.

set search_path = public, extensions;

-- ── 1. Review cannot be skipped ─────────────────────────────────────────────
-- A survey enters the analysis views at status 'approved'. The insert policy
-- checked only role and ownership, so a surveyor could insert a survey that was
-- already approved; and records could be added to a survey after it had been
-- verified and approved. start-structured-survey inserts 'submitted' (the
-- in-progress state) and add-survey-record writes through the caller's own
-- client, so both keep working unchanged.

drop policy if exists "Surveyors submit structured surveys" on public.structured_surveys;
create policy "Surveyors submit structured surveys"
on public.structured_surveys
for insert
to authenticated
with check (
  (public.is_surveyor() or public.is_admin())
  and user_id = auth.uid()
  and status = 'submitted'
);

drop policy if exists "Surveyors add records to their surveys" on public.survey_records;
create policy "Surveyors add records to their surveys"
on public.survey_records
for insert
to authenticated
with check (
  public.is_admin()
  or (
    public.is_surveyor()
    and exists (
      select 1
      from public.structured_surveys ss
      where ss.id = survey_records.survey_id
        and ss.user_id = auth.uid()
        and ss.status = 'submitted'
    )
  )
);

-- ── 2. The export contract: pseudonymous, identified, from approved points ──
-- observer_id was the contributor's account id, and the pipeline carries
-- observer ids into public outputs (observer_ids_json in
-- top_interventions.json). md5 of a random v4 UUID keeps distinct-observer
-- counts per cell without publishing the account id.
--
-- A record with no identified species (the form's "Unknown species": no
-- species_id, so the join finds no row — scientific_name is NOT NULL in
-- species_reference) used to export a placeholder taxon 'group:<record id>',
-- so every such record counted as its own species. They stay stored and
-- moderated; they are just not species.
--
-- Surveys at a survey point that was later rejected no longer export.
--
-- Same columns, names and types in the same order, so create or replace
-- keeps the R reader (01_ingest/export_supabase_observations.R) unchanged.

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
  'app:' || md5(qs.user_id::text) as observer_id,
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
where sr.scientific_name is not null

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
  'app:' || md5(survey.user_id::text) as observer_id,
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
left join public.species_reference species on species.id = rec.species_id
where species.scientific_name is not null
  and point.status = 'approved';

-- ── 3. Signed-in users no longer read the analysis views ────────────────────
-- These views run with their owner's rights, so they bypassed the base tables'
-- row-level security: any signed-in account could list every approved survey
-- with its contributor's user id. Nothing in the app or the Edge Functions
-- reads them; the pipeline reads the export as the postgres role, which owns
-- the views and keeps access.

revoke select on public.pipeline_observations_export from authenticated, anon;
revoke select on public.analysis_quick_sightings from authenticated, anon;
revoke select on public.analysis_structured_surveys from authenticated, anon;
revoke select on public.analysis_survey_records from authenticated, anon;
