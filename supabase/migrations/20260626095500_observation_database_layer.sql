-- NatureGap observation database layer.
-- Scope: schema, PostGIS, enums, constraints, indexes, RLS, auditability.

create schema if not exists extensions;
create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

set search_path = public, extensions;

-- ── Enums ───────────────────────────────────────────────────────────────────

create type public.user_role as enum (
  'contributor',
  'surveyor',
  'taxonomist',
  'admin'
);

create type public.taxon_group as enum (
  'bird',
  'insect',
  'plant',
  'amphibian',
  'other'
);

create type public.review_status as enum (
  'submitted',
  'flagged_review',
  'approved',
  'rejected'
);

create type public.survey_point_status as enum (
  'pending',
  'approved',
  'rejected'
);

create type public.suggestion_type as enum (
  'species',
  'action',
  'survey_point',
  'local_note',
  'habitat_photo'
);

create type public.suggestion_status as enum (
  'pending',
  'approved',
  'rejected',
  'needs_revision'
);

create type public.flag_record_type as enum (
  'quick_sighting',
  'structured_survey',
  'survey_record',
  'survey_point',
  'suggestion',
  'species_reference',
  'conservation_action',
  'cell_attribute'
);

create type public.flag_outcome as enum (
  'pending',
  'confirmed',
  'dismissed',
  'reversed'
);

create type public.conservation_impact_type as enum (
  'canopy',
  'connectivity',
  'floristic_richness',
  'water',
  'light',
  'noise'
);

create type public.conservation_effort_level as enum (
  'individual',
  'community',
  'institutional'
);

-- ── Auth roles and RLS helpers ──────────────────────────────────────────────

create table public.user_roles (
  user_id uuid primary key references auth.users(id) on delete restrict,
  role public.user_role not null default 'contributor',
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.current_app_role()
returns public.user_role
language sql
stable
security definer
set search_path = public, auth
as $$
  select role
  from public.user_roles
  where user_id = auth.uid()
$$;

create or replace function public.has_app_role(required_role public.user_role)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select coalesce(
    exists (
      select 1
      from public.user_roles
      where user_id = auth.uid()
        and role = required_role
    ),
    false
  )
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.has_app_role('admin')
$$;

create or replace function public.is_taxonomist()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.has_app_role('taxonomist')
$$;

create or replace function public.is_surveyor()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.has_app_role('surveyor')
$$;

create or replace function public.is_contributor()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.has_app_role('contributor')
$$;

-- ── Domain tables ───────────────────────────────────────────────────────────

create table public.species_reference (
  id uuid primary key default extensions.gen_random_uuid(),
  taxon_group public.taxon_group not null,
  common_name text not null,
  scientific_name text not null,
  region_plausibility jsonb not null default '{}'::jsonb,
  requires_photo_on_first_record boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint species_reference_common_name_not_blank check (length(trim(common_name)) > 0),
  constraint species_reference_scientific_name_not_blank check (length(trim(scientific_name)) > 0),
  constraint species_reference_unique_taxon unique (taxon_group, scientific_name)
);

create table public.survey_points (
  id uuid primary key default extensions.gen_random_uuid(),
  geometry geometry(Point, 4326) not null,
  status public.survey_point_status not null default 'pending',
  suggested_by uuid not null references auth.users(id) on delete restrict,
  approved_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint survey_points_approved_by_required check (
    status <> 'approved' or approved_by is not null
  )
);

create table public.quick_sightings (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  taxon_group public.taxon_group not null,
  species_id uuid references public.species_reference(id) on delete restrict,
  photo_url text,
  geometry geometry(Point, 4326) not null,
  gps_accuracy_m numeric(8, 2) not null,
  "timestamp" timestamptz not null default now(),
  status public.review_status not null default 'submitted',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quick_sightings_gps_accuracy_nonnegative check (gps_accuracy_m >= 0),
  constraint quick_sightings_photo_url_not_blank check (
    photo_url is null or length(trim(photo_url)) > 0
  )
);

create table public.structured_surveys (
  id uuid primary key default extensions.gen_random_uuid(),
  survey_point_id uuid not null references public.survey_points(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  started_at timestamptz not null,
  submitted_at timestamptz,
  duration_seconds integer not null,
  status public.review_status not null default 'submitted',
  habitat_indicators jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint structured_surveys_duration_nonnegative check (duration_seconds >= 0),
  constraint structured_surveys_submitted_after_started check (
    submitted_at is null or submitted_at >= started_at
  )
);

create table public.survey_records (
  id uuid primary key default extensions.gen_random_uuid(),
  survey_id uuid not null references public.structured_surveys(id) on delete restrict,
  taxon_group public.taxon_group not null,
  species_id uuid references public.species_reference(id) on delete restrict,
  count integer not null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint survey_records_count_nonnegative check (count >= 0),
  constraint survey_records_notes_not_blank check (
    notes is null or length(trim(notes)) > 0
  )
);

create table public.suggestions (
  id uuid primary key default extensions.gen_random_uuid(),
  type public.suggestion_type not null,
  payload jsonb not null default '{}'::jsonb,
  status public.suggestion_status not null default 'pending',
  submitted_by uuid not null references auth.users(id) on delete restrict,
  reviewed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint suggestions_review_fields_consistent check (
    (status = 'pending' and reviewed_by is null and reviewed_at is null)
    or (status <> 'pending' and reviewed_by is not null and reviewed_at is not null)
  )
);

create table public.flags (
  id uuid primary key default extensions.gen_random_uuid(),
  record_type public.flag_record_type not null,
  record_id text not null,
  reason text not null,
  flagged_by uuid not null references auth.users(id) on delete restrict,
  reviewed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  outcome public.flag_outcome not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint flags_record_id_not_blank check (length(trim(record_id)) > 0),
  constraint flags_reason_not_blank check (length(trim(reason)) > 0),
  constraint flags_review_fields_consistent check (
    (outcome = 'pending' and reviewed_by is null and reviewed_at is null)
    or (outcome <> 'pending' and reviewed_by is not null and reviewed_at is not null)
  )
);

create table public.conservation_actions (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null,
  description text not null,
  impact_type public.conservation_impact_type not null,
  effort_level public.conservation_effort_level not null,
  target_audience text not null,
  source_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint conservation_actions_name_not_blank check (length(trim(name)) > 0),
  constraint conservation_actions_description_not_blank check (length(trim(description)) > 0),
  constraint conservation_actions_target_audience_not_blank check (length(trim(target_audience)) > 0),
  constraint conservation_actions_source_url_not_blank check (
    source_url is null or length(trim(source_url)) > 0
  )
);

create table public.cell_attributes (
  cell_id text primary key,
  geometry geometry(Polygon, 4326) not null,
  expected_richness numeric,
  effort_corrected_richness numeric,
  ecological_residual numeric,
  corridor_importance numeric,
  intervention_rank integer,
  heat_exposure numeric,
  noise numeric,
  light_pollution numeric,
  fragmentation numeric,
  water_proximity numeric,
  connectivity_score numeric,
  last_updated timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cell_attributes_cell_id_not_blank check (length(trim(cell_id)) > 0),
  constraint cell_attributes_expected_richness_nonnegative check (
    expected_richness is null or expected_richness >= 0
  ),
  constraint cell_attributes_effort_corrected_richness_nonnegative check (
    effort_corrected_richness is null or effort_corrected_richness >= 0
  ),
  constraint cell_attributes_intervention_rank_positive check (
    intervention_rank is null or intervention_rank > 0
  )
);

-- ── Audit log and write guards ──────────────────────────────────────────────

create table public.audit_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  record_pk jsonb not null,
  operation text not null,
  old_row jsonb,
  new_row jsonb,
  changed_by uuid references auth.users(id) on delete set null,
  changed_at timestamptz not null default now()
);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.prevent_hard_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'Hard deletes are not allowed on %. Use lifecycle status fields instead.', tg_table_name
    using errcode = 'check_violation';
end;
$$;

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
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end,
    auth.uid()
  );

  if tg_op in ('INSERT', 'UPDATE') then
    return new;
  end if;

  return old;
end;
$$;

create or replace function public.enforce_taxonomist_species_correction()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if public.is_admin() then
    return new;
  end if;

  if public.is_taxonomist() then
    if (to_jsonb(new) - 'species_id' - 'updated_at') = (to_jsonb(old) - 'species_id' - 'updated_at') then
      return new;
    end if;
  end if;

  raise exception 'Only admins may update this record, except taxonomists correcting species_id.'
    using errcode = 'insufficient_privilege';
end;
$$;

create or replace function public.enforce_approved_survey_point()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  point_status public.survey_point_status;
begin
  select status into point_status
  from public.survey_points
  where id = new.survey_point_id;

  if point_status is distinct from 'approved' then
    raise exception 'Structured surveys must reference an approved survey point.'
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end;
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

  select count(*)
  into prior_count
  from public.quick_sightings
  where user_id = new.user_id
    and species_id = new.species_id
    and id <> new.id;

  if prior_count = 0 and (new.photo_url is null or length(trim(new.photo_url)) = 0) then
    raise exception 'First quick sighting for this species requires a photo.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create or replace function public.enforce_species_taxon_group()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  reference_group public.taxon_group;
begin
  if new.species_id is null then
    return new;
  end if;

  select taxon_group
  into reference_group
  from public.species_reference
  where id = new.species_id;

  if reference_group is distinct from new.taxon_group then
    raise exception 'species_id taxon group (%) does not match record taxon_group (%).',
      reference_group,
      new.taxon_group
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end;
$$;

create or replace function public.enforce_flag_record_exists()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  exists_record boolean;
begin
  case new.record_type
    when 'quick_sighting' then
      select exists(select 1 from public.quick_sightings where id::text = new.record_id) into exists_record;
    when 'structured_survey' then
      select exists(select 1 from public.structured_surveys where id::text = new.record_id) into exists_record;
    when 'survey_record' then
      select exists(select 1 from public.survey_records where id::text = new.record_id) into exists_record;
    when 'survey_point' then
      select exists(select 1 from public.survey_points where id::text = new.record_id) into exists_record;
    when 'suggestion' then
      select exists(select 1 from public.suggestions where id::text = new.record_id) into exists_record;
    when 'species_reference' then
      select exists(select 1 from public.species_reference where id::text = new.record_id) into exists_record;
    when 'conservation_action' then
      select exists(select 1 from public.conservation_actions where id::text = new.record_id) into exists_record;
    when 'cell_attribute' then
      select exists(select 1 from public.cell_attributes where cell_id = new.record_id) into exists_record;
  end case;

  if not coalesce(exists_record, false) then
    raise exception 'Flag target %.% does not exist.', new.record_type, new.record_id
      using errcode = 'foreign_key_violation';
  end if;

  return new;
end;
$$;

create or replace function public.mark_duplicate_quick_sighting()
returns trigger
language plpgsql
security definer
set search_path = public
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

create trigger user_roles_set_updated_at
before update on public.user_roles
for each row execute function public.set_updated_at();

create trigger species_reference_set_updated_at
before update on public.species_reference
for each row execute function public.set_updated_at();

create trigger survey_points_set_updated_at
before update on public.survey_points
for each row execute function public.set_updated_at();

create trigger quick_sightings_set_updated_at
before update on public.quick_sightings
for each row execute function public.set_updated_at();

create trigger structured_surveys_set_updated_at
before update on public.structured_surveys
for each row execute function public.set_updated_at();

create trigger survey_records_set_updated_at
before update on public.survey_records
for each row execute function public.set_updated_at();

create trigger suggestions_set_updated_at
before update on public.suggestions
for each row execute function public.set_updated_at();

create trigger flags_set_updated_at
before update on public.flags
for each row execute function public.set_updated_at();

create trigger conservation_actions_set_updated_at
before update on public.conservation_actions
for each row execute function public.set_updated_at();

create trigger cell_attributes_set_updated_at
before update on public.cell_attributes
for each row execute function public.set_updated_at();

create trigger quick_sightings_taxonomist_species_correction
before update on public.quick_sightings
for each row execute function public.enforce_taxonomist_species_correction();

create trigger survey_records_taxonomist_species_correction
before update on public.survey_records
for each row execute function public.enforce_taxonomist_species_correction();

create trigger structured_surveys_approved_point
before insert or update of survey_point_id on public.structured_surveys
for each row execute function public.enforce_approved_survey_point();

create trigger quick_sightings_first_photo
before insert or update of species_id, photo_url on public.quick_sightings
for each row execute function public.enforce_first_quick_sighting_photo();

create trigger quick_sightings_species_taxon_group
before insert or update of species_id, taxon_group on public.quick_sightings
for each row execute function public.enforce_species_taxon_group();

create trigger survey_records_species_taxon_group
before insert or update of species_id, taxon_group on public.survey_records
for each row execute function public.enforce_species_taxon_group();

create trigger quick_sightings_duplicate_window
before insert on public.quick_sightings
for each row execute function public.mark_duplicate_quick_sighting();

create trigger flags_target_exists
before insert or update of record_type, record_id on public.flags
for each row execute function public.enforce_flag_record_exists();

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'user_roles',
    'species_reference',
    'survey_points',
    'quick_sightings',
    'structured_surveys',
    'survey_records',
    'suggestions',
    'flags',
    'conservation_actions',
    'cell_attributes'
  ]
  loop
    execute format(
      'create trigger %I_prevent_delete before delete on public.%I for each row execute function public.prevent_hard_delete()',
      table_name,
      table_name
    );
    execute format(
      'create trigger %I_audit after insert or update on public.%I for each row execute function public.audit_row_change()',
      table_name,
      table_name
    );
  end loop;
end;
$$;

create trigger audit_log_prevent_delete
before delete on public.audit_log
for each row execute function public.prevent_hard_delete();

-- ── Indexes ─────────────────────────────────────────────────────────────────

create index user_roles_role_idx on public.user_roles (role);

create index species_reference_taxon_group_idx on public.species_reference (taxon_group);

create index survey_points_geometry_gist_idx on public.survey_points using gist (geometry);
create index survey_points_status_idx on public.survey_points (status);
create index survey_points_suggested_by_idx on public.survey_points (suggested_by);
create index survey_points_approved_by_idx on public.survey_points (approved_by);

create index quick_sightings_geometry_gist_idx on public.quick_sightings using gist (geometry);
create index quick_sightings_user_id_idx on public.quick_sightings (user_id);
create index quick_sightings_taxon_group_idx on public.quick_sightings (taxon_group);
create index quick_sightings_species_id_idx on public.quick_sightings (species_id);
create index quick_sightings_status_idx on public.quick_sightings (status);
create index quick_sightings_timestamp_idx on public.quick_sightings ("timestamp");

create index structured_surveys_survey_point_id_idx on public.structured_surveys (survey_point_id);
create index structured_surveys_user_id_idx on public.structured_surveys (user_id);
create index structured_surveys_status_idx on public.structured_surveys (status);
create index structured_surveys_started_at_idx on public.structured_surveys (started_at);

create index survey_records_survey_id_idx on public.survey_records (survey_id);
create index survey_records_taxon_group_idx on public.survey_records (taxon_group);
create index survey_records_species_id_idx on public.survey_records (species_id);

create index suggestions_type_idx on public.suggestions (type);
create index suggestions_status_idx on public.suggestions (status);
create index suggestions_submitted_by_idx on public.suggestions (submitted_by);
create index suggestions_reviewed_by_idx on public.suggestions (reviewed_by);

create index flags_record_target_idx on public.flags (record_type, record_id);
create index flags_flagged_by_idx on public.flags (flagged_by);
create index flags_reviewed_by_idx on public.flags (reviewed_by);
create index flags_outcome_idx on public.flags (outcome);

create index conservation_actions_impact_type_idx on public.conservation_actions (impact_type);
create index conservation_actions_effort_level_idx on public.conservation_actions (effort_level);

create index cell_attributes_cell_id_idx on public.cell_attributes (cell_id);
create index cell_attributes_geometry_gist_idx on public.cell_attributes using gist (geometry);
create index cell_attributes_intervention_rank_idx on public.cell_attributes (intervention_rank);
create index cell_attributes_last_updated_idx on public.cell_attributes (last_updated);

create index audit_log_table_name_idx on public.audit_log (table_name);
create index audit_log_changed_by_idx on public.audit_log (changed_by);
create index audit_log_changed_at_idx on public.audit_log (changed_at);

-- ── RLS ─────────────────────────────────────────────────────────────────────

alter table public.user_roles enable row level security;
alter table public.species_reference enable row level security;
alter table public.survey_points enable row level security;
alter table public.quick_sightings enable row level security;
alter table public.structured_surveys enable row level security;
alter table public.survey_records enable row level security;
alter table public.suggestions enable row level security;
alter table public.flags enable row level security;
alter table public.conservation_actions enable row level security;
alter table public.cell_attributes enable row level security;
alter table public.audit_log enable row level security;

create policy "Users can read their own role; admins can read all roles"
on public.user_roles
for select
to authenticated
using (user_id = auth.uid() or public.is_admin());

create policy "Admins can grant roles"
on public.user_roles
for insert
to authenticated
with check (public.is_admin());

create policy "Admins can update roles"
on public.user_roles
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Species reference is readable"
on public.species_reference
for select
to authenticated
using (true);

create policy "Taxonomists and admins can insert species reference"
on public.species_reference
for insert
to authenticated
with check (public.is_taxonomist() or public.is_admin());

create policy "Taxonomists and admins can update species reference"
on public.species_reference
for update
to authenticated
using (public.is_taxonomist() or public.is_admin())
with check (public.is_taxonomist() or public.is_admin());

create policy "Survey points are visible when approved, owned, or privileged"
on public.survey_points
for select
to authenticated
using (
  status = 'approved'
  or suggested_by = auth.uid()
  or public.is_surveyor()
  or public.is_admin()
);

create policy "Surveyors can suggest survey points"
on public.survey_points
for insert
to authenticated
with check (
  (public.is_surveyor() or public.is_admin())
  and suggested_by = auth.uid()
  and (status = 'pending' or public.is_admin())
);

create policy "Admins control survey point approvals"
on public.survey_points
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Quick sightings are visible to owner and review roles"
on public.quick_sightings
for select
to authenticated
using (
  user_id = auth.uid()
  or status = 'approved'
  or public.is_taxonomist()
  or public.is_surveyor()
  or public.is_admin()
);

create policy "Contributors can submit quick sightings"
on public.quick_sightings
for insert
to authenticated
with check (
  (public.is_contributor() or public.is_admin())
  and user_id = auth.uid()
  and status in ('submitted', 'flagged_review')
);

create policy "Taxonomists correct quick sighting species; admins control review"
on public.quick_sightings
for update
to authenticated
using (public.is_taxonomist() or public.is_admin())
with check (public.is_taxonomist() or public.is_admin());

create policy "Structured surveys visible to owner and review roles"
on public.structured_surveys
for select
to authenticated
using (
  user_id = auth.uid()
  or public.is_surveyor()
  or public.is_taxonomist()
  or public.is_admin()
);

create policy "Surveyors submit structured surveys"
on public.structured_surveys
for insert
to authenticated
with check (
  (public.is_surveyor() or public.is_admin())
  and user_id = auth.uid()
);

create policy "Admins control structured survey review"
on public.structured_surveys
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Survey records visible through survey access"
on public.survey_records
for select
to authenticated
using (
  public.is_taxonomist()
  or public.is_surveyor()
  or public.is_admin()
  or exists (
    select 1
    from public.structured_surveys ss
    where ss.id = survey_records.survey_id
      and ss.user_id = auth.uid()
  )
);

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
    )
  )
);

create policy "Taxonomists correct survey record species; admins control records"
on public.survey_records
for update
to authenticated
using (public.is_taxonomist() or public.is_admin())
with check (public.is_taxonomist() or public.is_admin());

create policy "Suggestions visible to submitter and reviewers"
on public.suggestions
for select
to authenticated
using (
  submitted_by = auth.uid()
  or public.is_surveyor()
  or public.is_taxonomist()
  or public.is_admin()
);

create policy "Surveyors submit suggestions"
on public.suggestions
for insert
to authenticated
with check (
  (public.is_surveyor() or public.is_admin())
  and submitted_by = auth.uid()
  and status = 'pending'
);

create policy "Admins control suggestions"
on public.suggestions
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Flags visible to flagger and admins"
on public.flags
for select
to authenticated
using (
  flagged_by = auth.uid()
  or public.is_admin()
);

create policy "Contributors can flag records"
on public.flags
for insert
to authenticated
with check (
  (public.is_contributor() or public.is_admin())
  and flagged_by = auth.uid()
  and outcome = 'pending'
);

create policy "Admins review flags"
on public.flags
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Conservation actions are readable"
on public.conservation_actions
for select
to authenticated
using (true);

create policy "Admins insert conservation actions"
on public.conservation_actions
for insert
to authenticated
with check (public.is_admin());

create policy "Admins update conservation actions"
on public.conservation_actions
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Cell attributes are readable"
on public.cell_attributes
for select
to authenticated
using (true);

create policy "Admins insert cell attributes"
on public.cell_attributes
for insert
to authenticated
with check (public.is_admin());

create policy "Admins update cell attributes"
on public.cell_attributes
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy "Admins read audit log"
on public.audit_log
for select
to authenticated
using (public.is_admin());

-- ── Grants for Supabase API roles; RLS still controls row access. ───────────

grant usage on schema public to authenticated;
grant usage on schema extensions to authenticated;
grant usage on type public.user_role to authenticated;
grant usage on type public.taxon_group to authenticated;
grant usage on type public.review_status to authenticated;
grant usage on type public.survey_point_status to authenticated;
grant usage on type public.suggestion_type to authenticated;
grant usage on type public.suggestion_status to authenticated;
grant usage on type public.flag_record_type to authenticated;
grant usage on type public.flag_outcome to authenticated;
grant usage on type public.conservation_impact_type to authenticated;
grant usage on type public.conservation_effort_level to authenticated;

grant select, insert, update on public.user_roles to authenticated;
grant select, insert, update on public.species_reference to authenticated;
grant select, insert, update on public.survey_points to authenticated;
grant select, insert, update on public.quick_sightings to authenticated;
grant select, insert, update on public.structured_surveys to authenticated;
grant select, insert, update on public.survey_records to authenticated;
grant select, insert, update on public.suggestions to authenticated;
grant select, insert, update on public.flags to authenticated;
grant select, insert, update on public.conservation_actions to authenticated;
grant select, insert, update on public.cell_attributes to authenticated;
grant select on public.audit_log to authenticated;

grant usage, select on sequence public.audit_log_id_seq to authenticated;
