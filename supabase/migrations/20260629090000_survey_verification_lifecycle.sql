-- Three-tier structured-survey review: add the missing verify stage.
-- Lifecycle: submitted (in progress) -> pending_verification -> verified
--            -> approved / rejected (never hard-deleted).
--
-- Enum values are added in their own migration so the transaction that adds
-- them commits before any later migration references them (Postgres forbids
-- using a freshly added enum value in the same transaction that adds it).

set search_path = public, extensions;

alter type public.review_status add value if not exists 'pending_verification';
alter type public.review_status add value if not exists 'verified';
