# NatureGap — Grounded Simplification Plan

This is based on directly reading the repo, not on assumptions.
Three concrete actions, in priority order. Nothing else.

---

## 1. Fix the actual multi-city bug (do this first)

File: src/components/map/MapView.tsx
Function: applyLayerPaintExpressions

Current code:
```js
function applyLayerPaintExpressions(map: maplibregl.Map) {
  const defaultCityStats = getCityLayerStats(CITY.id);   // hardcoded
  for (const layerId of PATCH_FILL_LAYER_ORDER) {
    const layer = PATCH_FILL_LAYER_IDS[layerId];
    if (!map.getLayer(layer)) continue;
    map.setPaintProperty(layer, 'fill-color',
      patchFillColorExpression(layerId, defaultCityStats));
  }
  for (const dataset of getHexDatasets(map)) {
    const cityStats = getCityLayerStats(dataset.cityId);   // correct
    ...
  }
}
```

The patch-fill loop uses one hardcoded city's stats (CITY.id from
src/lib/config.ts, currently 'yokohama-honmoku') for every patch
polygon, regardless of which city that polygon belongs to. The hex
loop right below it already does this correctly per dataset.

Fix: patch features need a cityId on them (check whether parks.geojson
already includes city_id in properties — if not, add it in the export
step), then loop the same way the hex loop does:

```js
for (const dataset of getHexDatasets(map)) {   // or equivalent per-city grouping
  const cityStats = getCityLayerStats(dataset.cityId);
  for (const layerId of PATCH_FILL_LAYER_ORDER) {
    const layer = PATCH_FILL_LAYER_IDS[layerId];
    if (!map.getLayer(layer)) continue;
    map.setPaintProperty(layer, 'fill-color',
      patchFillColorExpression(layerId, cityStats),
      { filter: ['==', ['get', 'cityId'], dataset.cityId] } // if per-feature paint isn't supported this way, use a data-driven expression keyed on cityId instead of setPaintProperty per dataset
  }
}
```

The exact mechanics depend on whether patch polygons for both cities
share one MapLibre source or separate sources per city (check this
first — it determines whether you need a data-expression keyed on a
cityId property, or a separate setPaintProperty call per city's own
layer/source, matching how the hex datasets are already split).

Verify: switch to Amsterdam, confirm patch fill colors now use
Amsterdam's own stat range and show visible variation, not a single
color pulled from Yokohama's domain.

### Same root cause, six more places (do these in the same pass)

CITY (from src/lib/config.ts, hardcoded to 'yokohama-honmoku') is
also read directly in six other files, purely for display text —
these will say "Yokohama" even when a user is looking at an
Amsterdam park, since they never look at which city the data on
screen actually belongs to:

- src/components/layout/Navbar.tsx — the badge in the top bar
- src/components/detail/CellDetailPanel.tsx — city name in the panel
- src/components/detail/WardSummaryPanel.tsx — city name in the panel
- src/components/map/LayerControls.tsx — "Yokohama, Japan" location label
- src/app/community/page.tsx — "...in Yokohama" body text
- src/app/layout.tsx — page <title> and meta description

None of these affect data correctness, only labeling — but they're
the exact same bug (single hardcoded city reference that was never
generalized when Amsterdam was added), so fix them alongside #1
rather than as a separate pass. Each one needs to read the actual
city of whatever is currently displayed (the selected cell's own
cityId, or the city the map is currently centered on) instead of
the CITY constant.

One more place worth a quick check rather than a guaranteed fix:
src/lib/data-validation.ts falls back to CITY.id whenever a record
is missing its own cityId. This is a defensive default, not
confirmed broken — just confirm real records always carry their
own cityId so this fallback never silently mislabels something as
Yokohama that isn't.

## 2. Split MapView.tsx without changing behavior

1179 lines in one file. Do not rewrite it. Extract, in this order,
verifying the map still renders identically after each step:

1. Move all the standalone utility functions (parkPolygonsGeoJSON,
   parkCentroidsGeoJSON, safeColor, scoreColor, hexFillLayerIdForDataset,
   hexOutlineLayerId, etc. — everything defined with `function` at
   module scope before the component) into `lib/map-utils.ts`.
   Import them back into MapView.tsx. No logic changes.

2. Move applyLayerPaintExpressions, setLayerVisibility, and the other
   paint/visibility functions into `lib/map-layers.ts`. This is where
   fix #1 above actually lives once extracted — easier to reason about
   in isolation from the component.

3. Move createPopupContent, createLandUseDonutElement, and the marker
   sync functions into `lib/map-markers.ts`.

4. What remains in MapView.tsx should be close to just: the component
   function, its useState/useEffect hooks, and calls into the three
   new files. Target under 300 lines for the component itself.

Do this as three separate small edits, verifying the map still works
after each one, not as one big rewrite.

## 3. Page scope — decided

Five separate routes exist outside the map: /about, /community,
/take-action, /profile, /login. Decision:

- /login, /profile — stay as separate pages (or a small header menu).
  Authentication doesn't belong inside the map canvas.
- /about — stays as a separate static page.
- /community — fold into the right-side info panel. Its content
  (local events, citizen-science opportunities) should surface in
  context, tied to whichever park/cell is selected, rather than as
  its own route.
- /take-action — fold into the right-side info panel. This is the
  natural home for it anyway — recommended actions per park already
  belong in that panel alongside the rest of a park's data.

Remove the /community and /take-action routes once their content is
migrated into the panel. Update Navbar.tsx to drop links to both.

## 4. Two more simplification spots, lower priority than #1-3

lib/layer-styles.ts: mostly clean (LAYER_RAMPS is a proper config
object), but a few per-layer expression builders (treecover, heat)
carry fallback chains checking 3-4 historical property names in
sequence, plus a sign-flip workaround for lst_idx (coolness, not
heat — inverted at render time rather than fixed in the pipeline).
Same root pattern as #1: a data contract changed once, and each
consumer patched around it locally instead of the rename propagating
through. Fix: pick one canonical name per metric end to end, delete
the fallback chains, fix the LST sign convention at the source.

components/citizen-science/CitizenSciencePanel.tsx (738 lines):
redesign this, not just split it. Current schema check confirms the
review status model is single-stage (submitted → flagged_review →
approved/rejected) — there is no distinct verify step yet, so this
is a real schema change, not a relabeling.

Drop the quick-sighting submission flow entirely. Confirmed in
observation_layer.R: quick_sighting records carry observation_weight
= 0, meaning they already contribute nothing to the actual scores.
Keeping the submission form, its moderation queue, and its edge
function maintains real cost for a feature that duplicates
iNaturalist's core purpose and doesn't affect anything downstream.
Replace it with at most a link that opens iNaturalist with the
park's location pre-filled — no in-app submission or review needed
for that at all.

Structured surveys (the habitat ground-truth checklist) are the only
in-app data submission going forward — this is the genuinely
differentiated piece, keep it exactly as built. Redesign its review
pipeline into three tiers with a distinct verify step before final
approval:

- Surveyor: registers new survey points (pending approval) and
  submits structured surveys at approved points. The only submission
  action available to a regular registered user.
- Verifier: reviews newly submitted surveys for completeness and
  plausibility — realistic duration (already checked, keep the
  under-10-minute auto-flag), internally consistent habitat
  description, species records plausible for the region and season,
  a photo present for any first-time species mention. Verified
  surveys move to a new status, not straight to live.
- Approver/Admin: gives final sign-off on verified surveys before
  they're included in the next pipeline run. Also approves new
  survey points and species suggestions, and is the one who triggers
  and promotes each periodic dataset build (see the import-cadence
  item in the R fixes file).

Extend the status lifecycle to add the missing middle stage:
  submitted -> pending_verification -> verified -> pending_approval
  -> approved (included in next dataset build) / rejected at any
  stage, never hard-deleted.
Survey point suggestions, species suggestions, and local notes go
through this same pipeline as different submission types, rather
than each needing their own separate workflow.

File split, reflecting the redesign: CitizenSciencePanel.tsx becomes
SurveyorSubmissionForm.tsx (the single structured-survey form regular
users see) plus ReviewQueue.tsx (used by verifiers and approvers —
one queue, filtered by the reviewer's role and each item's current
status, not three separate review surfaces).

Not a concern: components/map/LayerControls.tsx already maps over a
THEMATIC_LAYER_GROUPS config array rather than repeating per-layer
blocks. No action needed there.

## 5. "Unsampled" is tracked in the data but never shown to the user

The data model already distinguishes "no observations recorded here"
(is_unsampled) from "observations recorded, biodiversity roughly
matches habitat potential" (a genuinely neutral score) —
src/lib/cell-detail.ts carries an isUnsampled field through. But it
is never referenced in src/components/detail/CellDetailPanel.tsx.
Given 43/50 Yokohama parks and 29/35 Amsterdam parks currently have
zero recorded species, most of what a user sees right now is
silently rendered as "neutral," when the honest state for most of
it is "not enough data yet" — a materially different thing to
communicate, and higher priority than items 2-4 above since it's
about correctness of communication, not just maintainability.

Fix: CellDetailPanel.tsx, WardSummaryPanel.tsx, and the map paint
expressions for the layers that depend on observed richness (Nature
Gap, Ecological Residual, Observed Biodiversity, Intervention
Priority) need to check isUnsampled / is_unsampled and render a
distinct state — a grey/hatched fill on the map rather than the
neutral midpoint of the color ramp, and "Not enough observation data
yet" rather than a numeric score in the panel. Habitat-only layers
(Habitat Quality, Tree Cover, Heat, Land Use, Connectivity) aren't
affected, since they don't depend on citizen-science data at all.

This matters more than it looks: right now most of the map isn't
showing "nature is fine here" or "nature is under pressure here" —
it's showing "we don't know," indistinguishable from the former.
That's a real credibility risk if this is shown to anyone evaluating
the methodology, not just a cosmetic gap.

---

## What not to touch

- lib/supabase.ts, lib/data.ts, and the Supabase Edge Functions not
  named above — these already work as intended. Any AI working on
  this should be told explicitly not to modify these unless the
  specific task requires it. (CitizenSciencePanel.tsx is explicitly
  NOT in this category anymore — item #4 changes its behaviour, not
  just its file structure, including the submit-quick-sighting edge
  function, which should be retired, and the review status lifecycle,
  which needs the new pending_verification/verified stages added.)
- The R pipeline changes from the previous fix list (effort-correction
  threshold, LiDAR renaming, config_amsterdam.R) are separate and can
  proceed independently of this frontend work.
