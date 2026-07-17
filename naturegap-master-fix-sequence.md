# NatureGap — Master Fix Sequence

Two reference files are attached: naturegap-grounded-simplification.md
and naturegap-three-real-fixes.md. Read both fully before starting.
Every decision that was previously open is now settled and already
reflected in the files themselves: LiDAR removed entirely, Community
and Take Action pages fold into the info panel, the species-area
exponent is documented as an assumption rather than a false citation,
fragmentation_index is disabled from user-facing surfaces rather than
implemented in this pass, quick sightings are dropped in favour of a
plain iNaturalist link, and citizen-submitted data is reviewed
through a three-tier verify-then-approve pipeline before it affects
any score.

Work through the phases below IN ORDER. Do not start a phase until
the previous one is verified. This order matters: phase 1 is a
frontend bug, independent of the R pipeline, and needs to be checked
in isolation before anything else changes. Phase 2 fixes the pipeline
formulas that determine whether the core scores mean anything at all
— nothing downstream is worth polishing until those are right.

---

## Phase 1 — MapView.tsx multi-city bug (grounded-simplification.md, item 1)

Fix the CITY.id hardcoding in applyLayerPaintExpressions, and the six
label siblings in the same item. Do this phase alone. Nothing else.

STOP after this phase. Verify: switch the map to Amsterdam, confirm
patch fill colors now show real variation using Amsterdam's own
value range, and confirm the six label locations show the correct
city name rather than always "Yokohama". Report back what you see
on both cities before proceeding to Phase 2.

---

## Phase 2 — R pipeline correctness fixes (three-real-fixes.md, all six items)

Only start this after Phase 1 is confirmed working. These determine
whether the core Nature Gap / Ecological Residual scores are
methodologically sound, not just whether they render — do all six
before trusting any output from the pipeline:

1. Effort-correction threshold fix in observation_layer.R (item 1).
2. LiDAR removal, including the habitat_quality re-weighting it
   requires (item 2 — the re-weighting is not optional; without it,
   habitat_quality silently caps at 0.70 everywhere).
3. Create config_amsterdam.R from config_yokohama.R (item 3).
4. Expected richness must scale with patch area, computed once per
   patch from total area via a species-area power law rather than
   averaged up from a flat per-hex ceiling (item 4). Remove the
   incorrect Aronson et al. 2014 citation as part of this — document
   the exponent as an assumption, not a cited fact.
5. Disable fragmentation_index and the other NA-placeholder
   connectivity metrics from anything user-facing until they are
   actually computed (item 5). Do not implement them in this pass.
6. Check the current state of SUPABASE_OBSERVATIONS_ENABLED before
   anything else in this item — if it has never been explicitly set,
   no citizen-submitted data has ever reached a live score. Set up
   the periodic pipeline schedule described in item 6: each scheduled
   run re-pulls GBIF/iNaturalist, pulls approved structured surveys,
   writes a new pipeline_datasets row with is_active = FALSE, and
   waits for a manual promotion step before going live.

Re-run the pipeline for both cities after all six changes.

STOP after this phase. Verify: the previously-extreme Amsterdam
outlier park now shows as unsampled/NA rather than a runaway value;
both cities' pipeline runs go through the same config-driven process;
expected_richness now visibly differs between a small and a large
park with similar habitat quality; no user-facing surface still shows
fragmentation data; and a new pipeline_datasets row is created (but
not yet promoted) on a trial scheduled run. Report back before
proceeding.

---

## Phase 3 — Data-honesty fix (grounded-simplification.md, item 5)

Only start this after Phase 2 is confirmed working. Given how many
parks in both cities currently have zero recorded species, this is
higher priority than the citizen-science redesign or the structural
cleanup that follow — it's about whether the map is telling the
truth, not about maintainability or new features.

Make CellDetailPanel.tsx, WardSummaryPanel.tsx, and the map paint
expressions for Nature Gap, Ecological Residual, Observed
Biodiversity, and Intervention Priority check isUnsampled /
is_unsampled and render a distinct "not enough data yet" state,
instead of silently showing the neutral midpoint of the color ramp.

STOP after this phase. Verify: a park with zero recorded species now
visibly renders and reads differently from a park with real
observations showing a genuinely neutral score, on both the map and
in the detail panel.

---

## Phase 4 — Citizen-science redesign (grounded-simplification.md, item 4's CitizenSciencePanel.tsx section)

Only start this after Phase 3 is confirmed working. This is a real
schema and behaviour change, not a refactor — treat it as its own
phase, not part of the lower-priority cleanup in Phase 5.

1. Retire the quick-sighting submission flow and its edge function.
   Replace with a link out to iNaturalist, location pre-filled.
2. Extend the review status lifecycle to add the missing verify
   stage: submitted -> pending_verification -> verified ->
   pending_approval -> approved / rejected.
3. Split CitizenSciencePanel.tsx into SurveyorSubmissionForm.tsx and
   ReviewQueue.tsx (the latter filtered by role: Verifier sees
   pending_verification items, Approver sees verified items).
4. Route survey point suggestions, species suggestions, and local
   notes through this same pipeline as submission types, rather than
   separate workflows.

STOP after this phase. Verify: a submitted structured survey moves
through pending_verification -> verified -> pending_approval ->
approved correctly with the right role able to act at each stage,
and that an approved survey is what Phase 2's periodic pipeline run
actually picks up.

---

## Phase 5 — Structural simplification (grounded-simplification.md, items 2-3 and item 4's layer-styles.ts section)

Only start this after Phase 4 is confirmed working. These are
maintainability improvements, not bug fixes — no rush, and each one
should leave behavior unchanged. Do them as separate, individually
verified edits, not one combined rewrite:

1. Split MapView.tsx into map-utils.ts / map-layers.ts / map-markers.ts
   (item 2). Verify the map still renders identically after each of
   the three extraction steps.

2. Fold /community and /take-action into the right-side info panel,
   remove those two routes, update Navbar.tsx (item 3, decided).
   Verify the panel shows the migrated content correctly when a park
   is selected, and that the old routes are gone.

3. Clean up layer-styles.ts fallback chains and the LST sign-flip
   (item 4's layer-styles.ts section). Verify all ten layers still
   render correctly after removing the historical property-name
   fallback chains.

---

## Throughout all phases

- Do not modify lib/supabase.ts, lib/data.ts, or any Supabase Edge
  Function not explicitly named above.
- Do not introduce new architecture, new folders, or new abstractions
  beyond what each item explicitly describes.
- Do not implement fragmentation_index or attempt to source a new
  citation for the species-area exponent as part of this sequence —
  both are explicitly deferred, not silently expanded into new scope.
- Do not rebuild the quick-sighting flow in any form beyond the plain
  iNaturalist link — it is deliberately removed, not deferred.
- After every individual fix, state plainly what to check to confirm
  it worked, and wait for confirmation before moving to the next item
  within the same phase.
