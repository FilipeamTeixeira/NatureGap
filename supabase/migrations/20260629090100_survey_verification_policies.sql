-- Three-tier review authorisation.
--
-- Surveyor  : submits structured surveys at approved points (existing insert
--             policy unchanged). Submission now lands in pending_verification.
-- Verifier  : the taxonomist role. Advances pending_verification -> verified,
--             or rejects, but cannot publish (approve) a survey.
-- Approver  : the admin role. Advances verified -> approved (the state the
--             analysis views require), or rejects. Covered by the existing
--             admin update policy, so no new admin policy is needed here.
--
-- Multiple permissive UPDATE policies are OR-ed by Postgres, so this is purely
-- additive to the existing admin-only policy.

set search_path = public, extensions;

drop policy if exists "Taxonomists verify structured surveys" on public.structured_surveys;

create policy "Taxonomists verify structured surveys"
on public.structured_surveys
for update
to authenticated
using (public.is_taxonomist() and status = 'pending_verification')
with check (public.is_taxonomist() and status in ('verified', 'rejected'));
