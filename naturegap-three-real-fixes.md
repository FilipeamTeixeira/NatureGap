# NatureGap — R pipeline fixes, grounded in the actual repo

Do not restructure anything else. These are the only changes needed.

## 1. Fix the effort-correction outlier (this is the flatness bug)

File: pipeline/03_observations/observation_layer.R

Two occurrences of:
  is_unsampled = path_km <= 0

Change both to:
  is_unsampled = path_km < 0.05

(0.05 km = 50m minimum accessible path length to count as sampled.
A shorter path fragment is almost always an OSM geometry artifact,
not a real access point.)

Re-run the pipeline for Amsterdam after this change and confirm
osm-1472521078 (or whichever park has the stray path fragment) now
shows is_unsampled = TRUE and NA for effort_corrected_richness,
rather than an extreme outlier value.

## 2. LiDAR — remove entirely (decided)

The data is real (Meta/WRI Global Canopy Height, satellite-derived,
not LiDAR) but every variable and file is named "lidar_variance".
Decision: remove it. OSM plus the Copernicus-derived layers already
in use are enough without it.

  In habitat_model.R, delete the lidar_variance / lidar_variance_idx
  block (the canopy variance extraction and rescale), and change
  disturbance_idx to just:
    disturbance_idx = osm_disturbance_idx
  Remove LIDAR_VARIANCE_FILE / RAW_LIDAR_VARIANCE from both config
  files. Remove pipeline/00_download/download_canopy_height.R from
  run_pipeline.R's execution order if nothing else depends on it.
  Also remove the LiDAR references in README.md (the "What makes it
  different" table and the data sources table) and drop `lidR` from
  any dependency list if present.

This also resolves a separate bug for free: disturbance_idx currently
goes fully to NA whenever canopy data is missing, instead of falling
back to osm_disturbance_idx alone. Removing the canopy dependency
means disturbance_idx is just osm_disturbance_idx always, so that
bug no longer has anywhere to occur.

### Important: this also requires re-weighting habitat_quality itself

canopy_height_idx (a SEPARATE derived value from the same Meta/WRI
download, used directly in the main habitat_quality formula at a
0.30 weight) is not the same thing as lidar_variance_idx (which only
feeds disturbance_idx). Removing download_canopy_height.R makes
canopy_height_idx permanently NA everywhere. The current formula in
habitat_model.R is:

  habitat_quality = 0.35 * replace_na(ndvi_idx, 0) +
                    0.30 * replace_na(canopy_height_idx, 0) +
                    0.20 * replace_na(lst_idx, 0) +
                    0.15 * (1 - replace_na(disturbance_idx, 1))

Without a fix, replace_na(canopy_height_idx, 0) silently contributes
zero for every cell once the download is removed — habitat_quality
would be capped at a maximum of 0.70 everywhere, structurally, for
both cities, not because of missing data in specific spots but by
construction. This must change to:

  habitat_quality = 0.50 * replace_na(ndvi_idx, 0) +
                    0.286 * replace_na(lst_idx, 0) +
                    0.214 * (1 - replace_na(disturbance_idx, 1))

(the three original non-canopy weights of 0.35/0.20/0.15, proportionally
rescaled to sum to 1.0 now that canopy_height_idx is gone entirely).
Remove the canopy_height_idx term and the replace_na(canopy_height_idx, 0)
line completely — do not leave it in the formula at zero weight, remove
it from the mutate() call outright so it's clear from reading the code
that it no longer exists, not that it's just always zero.

## 3. Create config_amsterdam.R

Copy config_yokohama.R to config_amsterdam.R. Edit only the
city-specific values (CITY_ID, BBOX_CITY, CRS, any Amsterdam-specific
paths). Do not touch any of the six pipeline scripts — they already
read from config, not from hardcoded values. Commit this file so
Amsterdam's dataset is reproducible through the same run_pipeline.R
as Yokohama, rather than however it was originally produced.

## 4. Expected richness must scale with park area (real methodology bug)

Files: pipeline/05_residuals/residuals.R and pipeline/05_patch/patch_aggregation.R

Current behaviour: expected_richness is computed per 20m hex using a
flat MAX_EXPECTED_RICHNESS constant (350), then aggregated to patch
level with finite_weighted_mean — an area-weighted AVERAGE, not a sum.
Averaging doesn't change scale: a tiny park and a large park with
similar per-hex habitat quality end up with nearly the same
expected_richness. This violates the species-area relationship
(larger areas support more species, all else equal) and is a real
formula bug, not just a documentation gap.

Do not fix this by summing hex-level values instead of averaging —
richness is not additive across adjacent cells (the same species
present in two neighbouring hexes doesn't mean twice the richness),
so summing would overcorrect in the other direction.

Correct fix: compute expected_richness once per patch, directly from
total patch area, using a species-area power law:

  expected_richness_patch = C * (patch_area_m2 ^ Z) * quality_modifier

Where:
- patch_area_m2 is the patch's total area (already available on
  green_spaces)
- quality_modifier is the existing area-weighted mean of
  habitat_quality_index, corridor_importance, and accessibility
  across the patch's hexes (0 to 1) — averaging IS appropriate here,
  since these are intensive properties, not counts
- Z is the species-area exponent. Do not cite Aronson et al. 2014 for
  this (see below). Use a value in the 0.2-0.3 range as a documented,
  honestly-labelled assumption rather than a specific literature
  citation, until a proper literature review is done. Label it in the
  methodology docs as "an assumption informed by general species-area
  relationship literature, not calibrated to Yokohama or Amsterdam
  specifically"
- C is a scaling constant chosen so expected_richness lands in a
  plausible range at your actual smallest and largest patch sizes —
  check this against your real park area distribution, don't guess

Move this calculation out of the per-hex step in residuals.R (delete
the per-hex expected_richness and the MAX_EXPECTED_RICHNESS constant
entirely) and into patch_aggregation.R, computed once per patch after
hex-level quality metrics are aggregated.

### Also fix: remove the incorrect citation

Wherever "Aronson et al. 2014" is cited as the source for the
species-area exponent (methodology docs, code comments), remove that
specific attribution. That paper is a real, well-cited urban
biodiversity paper, but it's a cross-city comparison of urbanization
drivers, not a source for a within-city, patch-level species-area
exponent. Do not replace it with another citation unless it's been
properly checked — label the exponent as an assumption, not a cited
fact, until then.

## 5. fragmentation_index and related metrics are placeholder NA

File: pipeline/04_connectivity/connectivity.R

fragmentation_index, edge_density, patch_isolation, and
patch_size_distribution are currently hardcoded to NA_real_, never
actually computed. Only betweenness_centrality (used as
corridor_importance) is real.

Minimum fix for this pass: remove references to fragmentation_index
and the other NA placeholders from anything user-facing — methodology
docs, layer definitions, the frontend — until they're actually
computed. Don't show a layer or number that's silently always
blank/null as if it were a real metric.

Actually implementing fragmentation_index is a separate, bounded task
for later, not part of this fix pass: proportion of patch perimeter
adjacent to non-habitat hexes, computable with sf::st_touches or
st_intersects between each patch boundary and the non-habitat hex
layer.

## 6. Data refresh cadence: periodic and versioned, not live

You already have the right infrastructure for this, just not used
deliberately yet. The pipeline_dataset_versioning migration created
public.pipeline_datasets with dataset_id, generated_at, and an
is_active flag, with the comment "Metadata for immutable R pipeline
runs. One active dataset per city is promoted for the frontend."
That's exactly a periodic, versioned, explicitly-promoted model —
use it as designed rather than pursuing live/continuous updates.

Decision: run the full pipeline on a fixed schedule (quarterly is a
reasonable default, matching the species-reference reseed cadence
already recommended elsewhere), not continuously. Each scheduled run
should, together, in one pass:

1. Re-pull GBIF and iNaturalist records fresh for that run.
2. Pull every structured survey that has reached "approved" status
   (see the citizen-science redesign in the grounded-simplification
   file) since the last run — this requires SUPABASE_OBSERVATIONS_ENABLED
   to be deliberately set for scheduled runs, not left as whatever
   its default happens to be. Check this env var's current state
   before anything else — if it has never been explicitly set, no
   citizen-submitted data has ever affected your live scores,
   regardless of how much the feature has been used.
3. Recompute every score from this one combined snapshot.
4. Write the result as a new row in pipeline_datasets with a fresh
   dataset_id, is_active left FALSE.
5. Only after a manual check of the new dataset's numbers (spot-check
   a handful of parks against the previous version, confirm nothing
   looks broken) does an admin flip is_active to TRUE for that
   dataset_id, which is the actual "publish" step.

This means: scores update on a predictable, explainable schedule
rather than shifting unpredictably between visits, every published
version is dated and reproducible, and there's a natural human
checkpoint (step 5) before anything new goes live — the same
Approver role from the citizen-science redesign is the natural
owner of this step, since publishing a dataset and approving the
surveys that feed into it are the same kind of decision.

## Not a bug, worth knowing

43/50 Yokohama parks and 29/35 Amsterdam parks currently have zero
recorded species (pre-launch, no real observation data yet). This
means roughly half of each city's parks fall back to a neutral
natureGapScoreNorm of 0 by design, which also looks like flatness
but isn't the same issue as #1 above. This resolves as real
citizen-science data comes in, or can be partially offset by
seeding GBIF/iNaturalist historical records per park before launch.
