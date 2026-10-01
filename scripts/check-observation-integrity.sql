-- Read-only checks for supabase/migrations/20261002090000_observation_integrity_privacy.sql.
--
--   psql "$DATABASE_URL" -f scripts/check-observation-integrity.sql
--   (or paste into the Supabase SQL editor)
--
-- Every row should read result = 'ok'. Nothing here writes; the optional
-- bypass test at the end runs inside a transaction that is rolled back.

-- 1. Review cannot be skipped: both insert policies now require the
--    in-progress status.
select 'insert policies require status submitted' as check_name,
  case when count(*) = 2 then 'ok' else 'FAIL' end as result
from pg_policies
where schemaname = 'public'
  and policyname in ('Surveyors submit structured surveys', 'Surveyors add records to their surveys')
  and with_check ilike '%status = ''submitted''%';

-- 2. Signed-in and anonymous users cannot read the export or analysis views.
select 'app roles cannot read export or analysis views' as check_name,
  case when bool_or(has_table_privilege(r.role, v.view, 'select')) then 'FAIL' else 'ok' end as result
from (values ('authenticated'), ('anon')) as r(role)
cross join (values
  ('public.pipeline_observations_export'),
  ('public.analysis_quick_sightings'),
  ('public.analysis_structured_surveys'),
  ('public.analysis_survey_records')
) as v(view);

-- 3. No account id leaves through the export: every observer is a pseudonym.
select 'observers are pseudonymous' as check_name,
  case when count(*) filter (where observer_id !~ '^app:[0-9a-f]{32}$') = 0 then 'ok' else 'FAIL' end as result,
  count(*) as exported_rows
from public.pipeline_observations_export;

-- 4. No placeholder taxa ('group:<record id>') from unidentified records.
select 'every exported record names a species' as check_name,
  case when count(*) filter (
    where taxon_name is null or taxon_name ~ ':[0-9a-f-]{36}$'
  ) = 0 then 'ok' else 'FAIL' end as result
from public.pipeline_observations_export;

-- 5. Nothing exports from a survey point that is not approved.
select 'surveys export only from approved points' as check_name,
  case when count(*) = 0 then 'ok' else 'FAIL' end as result
from public.pipeline_observations_export e
join public.structured_surveys ss on ss.id = e.survey_id
join public.survey_points p on p.id = ss.survey_point_id
where p.status <> 'approved';

-- 6. Optional: try the bypass as a real surveyor and watch it fail.
--    Replace both placeholders with a surveyor's user id and an approved
--    survey point id, then run this block on its own. The insert must raise
--    "new row violates row-level security policy"; the rollback undoes
--    everything either way.
--
-- begin;
-- set local role authenticated;
-- select set_config('request.jwt.claims',
--   json_build_object('sub', '<surveyor-user-uuid>', 'role', 'authenticated')::text, true);
-- insert into public.structured_surveys (survey_point_id, user_id, started_at, duration_seconds, habitat_indicators, status)
-- values ('<approved-survey-point-uuid>', '<surveyor-user-uuid>', now(), 900, '{}', 'approved');
-- rollback;
