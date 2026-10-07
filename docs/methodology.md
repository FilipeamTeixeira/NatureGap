# Methodology Notes

This document describes NatureGap's analytical methods, assumptions, and known
limitations. All ecological and spatial calculations originate in the R pipeline.
PostgreSQL/PostGIS stores R outputs and performs live record-to-cell assignment.
PMTiles and MapLibre are presentation layers.

## 1. Source Of Truth

The R pipeline is the only authoritative source for:

- habitat quality
- observer effort correction
- expected richness
- ecological residual
- Nature Gap score
- connectivity metrics
- intervention score and ranking
- opportunity gap (§15)
- pressure strings and detail-panel scientific summaries

Frontend fallbacks in `src/lib/cell-detail.ts` are local/demo safeguards only.
They must not be treated as scientific outputs.

## 2. Spatial Grid

Resolution:

```text
20 m hexagons
```

Generated with:

```r
sf::st_make_grid(area, cellsize = 20, square = FALSE)
```

CRS:

- Local processing uses each city's national projected CRS, set as `CRS_LOCAL`
  in `pipeline/cities/<city>.R`:
  - `yokohama`: JGD2011 / Japan Plane Rectangular CS VI, `EPSG:6674`
  - `amsterdam`: Amersfoort / RD New, `EPSG:28992`
  - `porto`: ETRS89 / Portugal TM06, `EPSG:3763`
- Web/PostGIS export: WGS84, `EPSG:4326`

Contract:

- The 20 m hex grid is the only analytical grid.
- The same cell IDs connect R outputs, PMTiles features, PostgreSQL
  `cell_attributes`, quick sightings, structured surveys, and detail lookup.
- Do not introduce a secondary analytical grid.
- Unsampled cells are excluded from residual inference, not treated as zero.

## 3. Input Streams

External observations:

- iNaturalist
- GBIF

Application observations:

- `quick_sightings`: opportunistic, presence-only, zero weight in
  effort-corrected richness
- `structured_surveys` + `survey_records`: protocol-based, time-bounded,
  higher analytical weight, effort metadata, habitat indicators

Current implementation note:

- The R pipeline reads iNaturalist and GBIF raw files, plus approved app
  observations exported from Supabase.
- That export is implemented: `pipeline_observations_export` (PostgreSQL view)
  → `pipeline/01_ingest/export_supabase_observations.R` →
  `raw/supabase_observations.gpkg`, read by the tiled observation standardisation
  in `pipeline/02_habitat/process_tile.R`.
- It runs only when `SUPABASE_OBSERVATIONS_ENABLED="1"` (or
  `SUPABASE_OBSERVATIONS_REQUIRED="1"`) is set for the run. With the flag unset
  or `"0"`, app observations stay transactional records and map overlays and
  reach no model output. See docs/pipeline-runbook.md.
- Weights applied at import: `structured_survey` = 3, `quick_sighting` = 0,
  anything else = 1.
- iNaturalist observers enter as pseudonyms: `inat:` + an HMAC-SHA256 of the
  iNaturalist user id, keyed with a random secret drawn once per ingest run and
  never stored (`01_ingest/ingest.R`). One person's records share a pseudonym
  within a run, which is what lets them be grouped into visits; a plain hash
  would not do, because user ids are sequential and public. Archives fetched
  before 2026-10-05 carry no iNaturalist observer at all. GBIF's `recordedBy` is
  not yet pseudonymised.

Eligibility rules for app observations before R import:

- Exclude rejected records.
- Exclude records with pending or confirmed quality flags.
- Preserve raw geometry.
- Preserve GPS accuracy.
- Preserve structured-survey effort and habitat indicators.
- Preserve the assigned 20 m `cell_id` when available.
- Export only records that name a species. A record without one (the form's
  "Unknown species") is stored and moderated but is not a species; it used to
  export as a placeholder taxon and count once per record.
- Export surveys only from survey points that are still approved.
- Export contributors as pseudonyms (`app:` + md5 of the account id), never the
  account id: observer ids reach public outputs such as
  `top_interventions.json`.
- The export and the analysis views behind it are readable by the pipeline's
  database role only, not by app users.
- A survey can only be created in its in-progress state, and records can only be
  added while it is in progress, so neither can skip review.
  (`supabase/migrations/20261002090000_observation_integrity_privacy.sql`;
  checks in `scripts/check-observation-integrity.sql`.)

### 3.1 Observation quality gates

All three streams are held to one standard, applied once in
`apply_obs_quality_gates()` (`pipeline/02_habitat/process_tile.R`) after the
streams are bound rather than per source. Constants live in `config.R`.

| gate | constant | rule |
| --- | --- | --- |
| obscured coordinates | `OBS_DROP_OBSCURED` | drop iNaturalist records where `obscured`, `geoprivacy` or `taxon_geoprivacy` is set |
| positional accuracy | `OBS_MAX_ACCURACY_M` = 30 | drop records whose *stated* accuracy exceeds the threshold |
| unknown accuracy | `OBS_UNKNOWN_ACCURACY_WEIGHT` = 0.5 | keep, and multiply `observation_weight` |
| recency | `OBS_YEAR_MIN` = 2015 | drop records before the Sentinel-2 MSI operational start, and undated records |
| record basis | `OBS_EXCLUDE_BASIS` | drop GBIF `PRESERVED_SPECIMEN` (applied on import, `01_ingest/ingest.R`) |

Accuracy is `public_positional_accuracy` for iNaturalist,
`coordinateUncertaintyInMeters` for GBIF, and `gps_accuracy_m` for app records —
the last of which was exported but discarded before these gates existed.

Two design points decide the coverage cost:

1. **Unknown accuracy is downweighted, not dropped.** 91.6% of Porto's GBIF
   records and 83.4% of Yokohama's state no accuracy at all; a hard rule would
   discard the GBIF stream in two of four cities. The discount interacts with
   `taxon_weight = max(observation_weight)` per (cell, taxon), so a species also
   recorded precisely is not penalised — the weight bites only where every
   record of that species in that cell is imprecise.
2. **Stated-but-coarse accuracy is dropped.** These are records whose own
   metadata says they cannot locate a 20 m cell: worse than 1 km for 71.2% of
   Amsterdam's records and 42.9% of Gent's, with the worst stated values at
   2,700 km.

Effect on the GBIF stream, measured on the archives as fetched:

| City | records | after gates | retained | of survivors, accuracy unknown |
| --- | --- | --- | --- | --- |
| Porto | 299,071 | 272,367 | 91.1% | 95.6% |
| Amsterdam | 1,118,999 | 207,381 | 18.5% | 86.9% |
| Gent | 1,246,884 | 279,431 | 22.4% | 44.0% |
| Yokohama | 42,539 | 11,662 | 27.4% | 84.4% |

Amsterdam and Yokohama lose most of their GBIF records, and 29.8% of Yokohama's
archive was `PRESERVED_SPECIMEN` alone. Both cities were already the weakest
fits (section 6.1), so the gates are expected to change those fits materially;
whether they improve them is an empirical question for the next run, not a claim
made here.

## 4. Habitat Quality Index

Habitat quality is computed per tile in
`pipeline/02_habitat/process_tile.R` (`finish_citywide_metrics()`), which
`pipeline/02_habitat/habitat_model.R` drives and whose output it writes.

Current implementation:

```text
habitat_quality =
  0.50 * ndvi_idx
  + 0.286 * lst_idx
  + 0.214 * (1 - disturbance_idx)
```

Sub-indexes:

| Sub-index | Source | Transformation | Rationale |
| --- | --- | --- | --- |
| `ndvi_idx` | Sentinel-2 B4/B8 | NDVI rescaled from [-0.2, 1.0] | Photosynthetically active vegetation |
| `lst_idx` | Landsat ST_B10 | `1 - percentile_rank(lst_celsius)` | Cooler cells are less heat-stressed |
| `disturbance_idx` | OSM footways/paths/tracks and amenities | `rescale01(0.60 * path_density + 0.40 * amenity_proximity)` | Human presence and access proxy disturbance |

There is no `green_idx` term: green cover enters through `ndvi_idx` rather than
through an OSM/landcover area fraction. Path density is not a standalone term
either — it enters only inside `disturbance_idx`, and separately (as a length,
not a density) in the effort correction of section 5.

Other stressor and context features are computed on the same grid and exported
but do **not** enter `habitat_quality`: `noise` (road/rail density and
proximity), `light_pollution` (street lamps, lit roads), `water_proximity`,
`heat_exposure` (the un-inverted LST rank), `built_fraction_wc`,
`impervious_fraction`, `tree_fraction`, and `canopy_height_idx`.

Limitations:

- Weights are expert-assigned and not yet empirically calibrated.
- NDVI does not distinguish native vegetation from ornamental or invasive cover.
- OSM completeness varies by city, and `disturbance_idx` inherits that.
- LST is date-sensitive; the pipeline composites three seasonal windows
  (`LST_SEASON_WINDOWS`), but a single growing season still anchors it.
- `habitat_quality` has a narrow dynamic range in dense cities (Amsterdam
  interquartile range 0.436–0.598), which is why connectivity resistance is
  built from permeability instead (section 9).

Where a national CIR orthophoto is available (Portugal DGT Ortos, Netherlands
PDOK luchtfoto CIR), ingest also writes `veg_fraction` (share of 0.5 m pixels
with DN-based NDVI ≥ 0.2) and `ndvi_texture` (within-hex SD of that NDVI).
These are supplementary hex attributes. They do **not** enter `habitat_quality`,
which continues to use Sentinel-2 `ndvi_idx` so cities stay comparable.

## 5. Observer Effort Correction

Effort correction is computed in `pipeline/02_habitat/process_tile.R`
(`finish_citywide_metrics()`), on the same tiled pass that builds habitat
quality. `pipeline/03_observations/observation_layer.R` is the contract gate for
it: it fails the run if a sampled cell lacks `survey_effort_units` or
`observed_richness`, or if an unsampled cell carries either, then writes
`grid_observations.gpkg` and the per-cell taxa JSON.

Problem:

Citizen-science observations cluster where people walk. Raw richness therefore
confounds biodiversity with observer effort.

Canonical formula:

```text
survey_effort_units_i = log(1 + path_local_m_i)

effort_corrected_richness_i =
  species_richness_i / survey_effort_units_i

observed_richness_i =
  effort_corrected_richness_i
```

Where:

- `species_richness_i` is the distinct species count in cell `i`.
- `path_local_m_i` is OSM pedestrian path length, in metres, within
  `PATH_RADIUS_M` (40 m) of cell `i`'s centroid. A 20 m hex is ~350 m², so a
  path centreline only clips a narrow ribbon of cells: measuring the cell
  alone marks a cell one hex off a footway as unsampled even though it is
  plainly observable from that footway.
- the denominator is a length in metres. `log1p` of a length in kilometres is
  inert at this cell size (`log1p(x) ≈ x` for `x` ≈ 0.02), which turned effort
  correction into division by a near-zero denominator.
- `path_km_i` is the per-cell intersected length. It is still exported for
  transparency but no longer drives effort correction.
- `survey_effort_units_i` is the explicit effort denominator used by every
  city pipeline run.
- `observed_richness_i` is the exported biodiversity metric used by hex,
  patch, and detail outputs. It is intentionally effort-normalised, not raw
  species count.

Unsampled rule:

```text
if path_local_m_i < MIN_PATH_M (50 m):
  is_unsampled_i = true
  survey_effort_units_i = NA
  observed_richness_i = NA
  effort_corrected_richness_i = NA
```

Unsampled cells are excluded from residual inference. They are not zero-richness
cells.

Missing-value rule:

- Sampled cells with no records keep `survey_effort_units_i > 0` and export
  `observed_richness_i = 0`.
- Unsampled cells export `observed_richness_i = NA`; exporters may coalesce to
  `0` only for render-only PMTiles fields that cannot style nulls reliably, and
  must then flag the cell `isUnsampled` so the zero is never drawn as a value
  (§11).
- Patch-level `observed_richness` is **not** an aggregate of the cell-level
  field. It is a ratio of pooled sums — distinct taxa pooled across the patch's
  sampled cells, divided by those cells' pooled `survey_effort_units` (§6.2).
  Hex and patch values are the same *kind* of quantity (species per effort unit)
  but are not on the same scale, because the patch denominator sums over cells.
  Do not compare a patch value to a hex value.

Structured-survey rule:

- Structured surveys receive analytical weight; quick sightings remain
  presence-only and do not affect effort-corrected richness.
- Live Supabase survey import is wired through `pipeline_observations_export`
  and `raw/supabase_observations.gpkg`.
- Structured-survey effort metadata affects effort summaries and weighting in R,
  not SQL or frontend code.

Limitations:

- Path length is a proxy for observer effort, not direct effort.
- It does not fully account for observer skill, seasonal effort, private access,
  or unmapped paths.
- GPS accuracy is stored and should be used in weighting/quality decisions, but
  final weighting details should remain in R.

## 6. Expected Richness

Expected richness is the **fitted conditional expectation of the observed
quantity**, not an index. That is what makes section 7 a residual: the same
quantity stands on both sides of the subtraction, in the same units.

The shared fit lives in `pipeline/05_residuals/expected_model.R` and is applied
at two scales. Every run records its family, link, coefficients, dispersion,
explained deviance, training row count,
and any fallback in `expected_richness_model.json`, which is carried into the
export manifest under `metricDefinitions.expectedRichness.model`.

### 6.1 Per-hex expected richness (`pipeline/05_residuals/residuals.R`)

```text
species_richness_i ~ quasipoisson( log link ),
  habitat_component + connectivity_component + accessibility_component
  + offset( log(survey_effort_units_i) )

expected_richness_i = exp( X_i . beta )        # expected count per effort unit
```

A quasi-Poisson GLM with a log link and `log(survey_effort_units)` as an offset —
the standard form for a count observed under varying effort. Fitted per city on
**sampled cells only** (an unsampled cell has no observation to explain). Because
the offset's coefficient is fixed at 1, the expected *rate* is `exp(X.beta)` and
needs no exposure at prediction time, which is how an unsampled cell still
receives an expected value without inventing a reference effort.

Fit, measured on all four configured cities (recorded per run in
`processed/expected_richness_model.json`):

| City | n train | explained deviance | dispersion | habitat | connectivity | accessibility |
| --- | --- | --- | --- | --- | --- | --- |
| Porto | 30,947 | 0.1405 | 16.7 | +3.543 | +0.023 | +6.268 |
| Amsterdam | 67,147 | 0.0298 | 246.3 | +0.662 | +0.580 | +3.143 |
| Yokohama | 52,014 | 0.0211 | 301.6 | +0.759 | +1.313 | +0.138 |
| Gent | 64,875 | 0.0088 | 102.7 | **-0.152** | +0.282 | +2.520 |

The heavy overdispersion is why the quasi- family is required — plain Poisson
would report standard errors far too small. Dispersion of 246 and 302 is beyond
"heavy": at that level the variance structure is misspecified, not merely
inflated.

Three findings in that table constrain what the expected model can be said to
do, and they are not visible from Porto alone:

1. **Explained deviance spans 0.009 to 0.140.** Porto, the only city measured in
   earlier versions of this document, is the best case by a factor of five.
2. **Coefficients are not stable across cities.** `habitat_component` ranges from
   -0.152 to +3.543, including a sign change. A negative habitat coefficient
   says better habitat predicts *fewer* species, which is not an ecological
   result — it means the term is not identifying habitat.
3. **Effort enters the model twice.** `survey_effort_units` is `log1p(path_local_m)`
   and enters as `offset(log(.))` with its coefficient fixed at 1.
   `accessibility_component` is that same quantity divided by a constant
   (`log1p(path_local_m) / log1p(max_path_local_m)`) and enters as a *free*
   covariate. The model can therefore re-estimate the effort adjustment it was
   supposed to hold fixed, which is the most likely reason accessibility is the
   dominant term in three of four cities.

Consequence for the headline metric: `observed_richness` is already
effort-corrected (section 5) and `expected_richness` is substantially a function
of the same path density, so `ecological_residual` is a difference between two
effort-laden quantities. Part of what the Nature Gap maps is where people walk.
This is a specification problem, identified and not yet corrected.

The predictors are unchanged from the previous formulation:
`habitat_component` is `habitat_quality`, `connectivity_component` is
`corridor_importance` clamped to `[0, 1]`, and
`accessibility_component = log1p(path_local_m) / log1p(max_path_local_m)`
clamped to `[0, 1]` and `0` for unsampled cells.

Below `EXPECTED_MODEL_MIN_CELLS` (30) usable rows — or with a constant response,
no varying predictor, non-convergence, or collinear non-finite coefficients — the
fit is refused and a constant rate is used instead
(`sum(response) / sum(exposure)`, the constant-rate MLE). That keeps both sides of
the residual in the same units and is flagged as `fallback: true` in the model
record rather than failing silently.

**This replaces OLS on the pre-divided ratio**, which was the first version of
this fit. OLS was wrong in two ways here. It can predict a negative richness, and
did for **19.5%** of Porto's sampled cells; those were clamped to 0, so for a
fifth of the sampled grid the "expected" value was a floor artefact and the
residual was simply `-observed`. And a linear model on an 89%-zero count
understates the relationship: R² 0.0148 against the GLM's explained deviance of
0.1987. A low linear R² on this data was therefore partly a wrong-model artefact,
not only a data-density limit.

**This replaces `SPECIES_AREA_C * (CELL_SIZE^2)^SPECIES_AREA_Z * (0.65 * habitat_quality + 0.20 * corridor_importance + 0.15 * accessibility)`.**
At hex scale the area term was a constant — `12 * 400^0.25 ≈ 53.7`, identical for
every hex — so it supplied scale and nothing else, on top of three
expert-assigned weights. The scale was the defect. It put expected richness near
20 (Porto sampled mean 20.01) while `effort_corrected_richness` — species per
log-metre of path — sits near 0.05. Subtracting the second from the first is not
a leftover of anything. Measured on the 2026-08-19 exports:

| | Porto | Amsterdam | Yokohama |
|---|---|---|---|
| sampled cells | 31,562 | 19,832 | 18,253 |
| mean observed richness | 0.049 | 0.033 | 0.021 |
| sampled cells with ≥1 species recorded | 10.8% | 10.0% | 4.6% |
| corr(`ecological_residual`, `expected_richness`) | 0.9987 | 0.9996 | 0.9990 |
| observed share of residual variance | 0.26% | 0.08% | 0.21% |
| residual > 0 | 99.99% | 99.99% | 99.99% |

The old residual was `expected_richness` under another name, and the documented
positive bias in section 8 followed arithmetically from the scale clash rather
than from ecology. Porto's top 20 intervention cells all carried
`habitat_quality ≈ 0.94`, `species_richness = 0`, and an `ecological_residual`
exactly equal to `expected_richness` — the ranking was selecting the best
habitat, not the largest shortfall.

`SPECIES_AREA_*` no longer applies at hex scale. `MAX_EXPECTED_RICHNESS` (350) is
still exported as `max_expected_richness` for transparency and read by the
frontend, but it scales nothing at either scale.

Limitations:

- Fitted per city, so hex expected richness is a within-city benchmark and is
  **not comparable between cities**. Two cities' raw residuals are not the same
  statement.
- In-sample fit, so the residual is not independent of the predictors. Note that
  a log link minimises deviance rather than squared error, so — unlike the earlier
  OLS version — the raw gap is **not** centred on the response scale: it is
  positive in 82% of Porto's sampled cells (section 7).
- The response is 89% zeros at 20 m, so much of the variation is unexplained. An
  earlier version of this section reported "roughly 20% of the deviance" as
  explained and concluded the hex-scale gap was "weakly but genuinely
  determined". That reading rested on Porto alone and does not survive
  measurement of the other three cities: explained deviance is 0.030 in
  Amsterdam, 0.021 in Yokohama and **0.009 in Gent**, with dispersion up to 302
  and an inverted habitat coefficient in Gent (see the table in section 6.1).
  At 0.9% of deviance the Gent fit is not distinguishable from a constant, so
  the per-cell residual there carries no habitat signal to speak of.
- The claim that survives is narrower: at hex scale the expected model is weakly
  determined **in Porto** and effectively undetermined in Gent, with Amsterdam
  and Yokohama in between. The per-cell Nature Gap should not be presented as an
  ecological result in any city other than possibly Porto until either the
  specification issue in section 6.1 is resolved or the metric is reported at a
  coarser grain.
- The grain-size comparison has now been run
  (`pipeline/sensitivity/sweep_grain_scale.R`). The same specification was
  refitted on square blocks from 20 m to 1000 m, with richness recomputed from
  the observation points at each grain — richness is not additive, so summing
  per-cell values would count a species once per cell it occupies. Explained
  deviance, and the habitat coefficient with `log(cells per block)` added to
  control the species-area effect:

  | grain | Porto dev / hab | Gent dev / hab | Amsterdam dev / hab | Yokohama dev / hab |
  | --- | --- | --- | --- | --- |
  | 20 m | 0.069 / +2.85 | 0.008 / -0.15 | 0.029 / +1.31 | 0.079 / +3.88 |
  | 100 m | 0.219 / +2.70 | 0.020 / -1.86 | 0.043 / +0.23 | 0.082 / +4.59 |
  | 200 m | 0.244 / +2.03 | 0.045 / -2.73 | 0.013 / +1.33 | 0.128 / +4.09 |
  | 500 m | 0.244 / +1.50 | 0.077 / -2.50 | 0.008 / +0.27 | 0.203 / +3.26 |
  | 1000 m | 0.321 / +1.60 | 0.198 / -2.59 | 0.054 / -0.06 | 0.482 / +4.74 |

  The mechanism is confirmed: 20 m units are dominated by zeros (69% of sampled
  units in Porto, 94% in Yokohama, 54% in Gent), and no richness model can fit a
  response that is mostly zero. Aggregation removes that (near 0% by 500 m).

  But it rescues only two cities, and explained deviance alone is misleading —
  the habitat coefficient is the diagnostic:
  - **Porto**: habitat positive and stable at every grain, and it survives the
    area control almost intact. The aggregation gain is a real signal that 20 m
    was destroying.
  - **Yokohama**: habitat positive throughout, but the area control removes a
    third to a half of it at coarse grain (+8.47 to +4.74 at 1 km) and deviance
    rises when area is added, so area was a genuine missing confounder. Only 80
    sampled units support the 1 km row. Directionally consistent, thinly
    supported.
  - **Gent**: habitat is **negative at all six grains** and becomes more so with
    aggregation, robust to the area control. Aggregation buys a better fit to a
    model whose habitat term runs backwards. Not a recovered relationship.
  - **Amsterdam**: no stable sign at any grain (four sign changes) and
    dispersion reaching 726. No coherent signal at any scale tested.

  Consequences. Per-cell reporting at 20 m is not defensible in any city.
  Coarser-grain reporting is defensible for Porto, provisional for Yokohama, and
  not defensible for Gent or Amsterdam at any grain tested — so the validity of
  the Nature Gap is city-dependent and cannot be claimed as one uniform
  methodology across the four cities. Dispersion does not improve with grain in
  any city, so the quasi-Poisson variance structure is misspecified at every
  scale, independently of grain.

  The area coefficient is negative in Porto and Yokohama. This is not a
  species-area result: the effort offset is `log(log1p(path_m))` and path length
  scales with block extent, so the offset already carries area, and the control
  term is picking up the residual after it. It is a symptom of the same
  effort-entanglement described above, not an estimate of a species-area
  exponent — `SPECIES_AREA_Z` remains an uncalibrated assumption and is
  untouched by this analysis.

### 6.2 Patch (park) expected richness (`pipeline/05_patch/patch_aggregation.R`)

Patch area genuinely varies, so an area term is meaningful here — larger areas
support more species, all else equal (the species-area relationship). The
coefficient on that term is now fitted rather than asserted:

```text
area_term = patch_area_m2 ^ SPECIES_AREA_Z

pooled_species_richness ~ quasipoisson( log link ),
  area_term + quality_modifier + offset( log(pooled_effort_units) )

expected_richness_patch = exp( X . beta )      # expected count per effort unit
```

Measured on Porto: explained deviance **0.2771**, dispersion **5.91**, against
OLS R² 0.0532 on the pre-divided ratio.

Where:

- `patch_area_m2` is the park's total area.
- `quality_modifier` is the area-weighted mean of `habitat_quality_index`,
  `corridor_importance`, and accessibility across the park's hexes, clamped to
  `[0, 1]`. Averaging is appropriate here because these are intensive
  properties, not counts.
- Fitted on patches with at least one sampled cell, requiring
  `EXPECTED_MODEL_MIN_PATCHES` (8) usable rows, with the same constant-rate
  fallback as section 6.1.
- Expected richness is computed once per patch from total area, not by averaging
  the per-hex value — an area-weighted average does not scale with size, so a
  small park and a large park of similar per-hex quality would otherwise get
  nearly the same expected richness.

- `SPECIES_AREA_Z = 0.25` remains the species-area exponent and sets the shape of
  the area term. **This value is an assumption informed by general species-area
  relationship literature, not calibrated to any of the three cities, and not
  sourced to a specific citation.** It is set within the commonly cited 0.2–0.3
  range pending a proper literature review or local calibration.
- `SPECIES_AREA_C` is **no longer used**. It was a tuning constant chosen so
  expected richness landed in a plausible range, and it set the entire patch
  scale; the fitted coefficient on `area_term` replaces it. The constant remains
  in `config.R` for reproducibility records and back-compatibility only.

Limitations:

- `SPECIES_AREA_Z` is still a documented assumption, not a calibrated or cited
  value.
- Patch observed richness is now a **ratio of pooled sums** (see below), not an
  area-weighted mean of per-cell ratios. Pooling does **not** reduce sparsity: a
  patch is zero exactly when no sampled cell in it holds a record, which is true
  of 72% of Porto's 1,058 scored patches either way. What it fixes is the
  estimator, not the data.
- Neither scale models regional species-pool constraints.

#### The pooled response

Patch `observed_richness` / `effort_corrected_richness` — the response the model
above is fitted against — is

```text
observed_richness_patch =
  distinct_taxa(sampled cells in patch) / sum(survey_effort_units of those cells)
```

computed in `pipeline/05_patch/patch_aggregation.R` using the shared taxa reader
in `pipeline/cell_taxa.R`.

**Why a ratio of sums and not a mean of ratios.** The previous definition was the
area-weighted mean of each cell's `species / effort` ratio. That is not an
estimate of what a park holds: it depends on how the park happens to be tiled,
and it is inflated by cells that hold a record and little path. On the
2026-08-19 Porto export, the largest park read **1.198** under the mean of ratios
against **0.781** pooled, from 637 distinct taxa over 142 sampled cells and
816.0 pooled effort units.

Both sides use whole-cell membership. `overlap_rank` in `patch_aggregation.R`
assigns each cell to at most one green space, so a species cannot be
double-counted across patches; and since presence cannot be prorated across a
boundary, neither is the effort that found it. Only sampled cells count on either
side — an unsampled cell's effort is below threshold by definition, so counting
its taxa but not its effort would overstate richness per unit effort.

`species_richness_raw` at patch scale is the same pooled distinct count. It
previously summed per-cell counts, which counts a species once per cell it
occupies: **1,049 against 637 distinct** for that park, and **1.37× inflation**
across Porto's patches. `06_export/export.R` no longer carries a sum-of-ratios
fallback for the patch response either — that was a third, incompatible
definition of the same quantity.

Limitations of the pooled response:

- `cell_taxa.json` is keyed by `cell_id`, so `05_patch` guards it with
  `assert_cell_taxa_usable()`: a **missing** file stops the run (03_observations
  has not been run for this dataset, and the code would otherwise fall back to
  the old mean-of-ratios estimator unannounced), a **stale** file whose keys match
  under half the current grid also stops it (a grid rebuilt without re-running
  03_observations would pool to zero everywhere while looking like a real result),
  and an **empty** file only warns, since a city may genuinely have no classified
  taxa.
- Pooled richness counts only taxa classified into the five groups
  (`plant`, `bird`, `insect`, `mammal`, `fungi`). A record whose iconic taxon
  falls outside them has no label in `cell_taxa.json` and is invisible here,
  which is why pooled richness is positive in 27.8% of scored patches against
  28.4% for the old mean of ratios — about six patches hold records that no
  classified group claims.
- The structured-survey weighting of §3 does **not** propagate. Hex
  `species_richness` weights a structured-survey taxon 3×; the pooled label union
  is unweighted, because `cell_taxa.json` carries labels without weights.
- Pooled effort sums `log1p(path_local_m)` over cells, so it is not a length and
  grows with cell count. It is a consistent denominator, not an interpretable
  one.

## 7. Ecological Residual

Ecological residual is computed in `pipeline/05_residuals/residuals.R`.

Formula:

```text
ecological_residual_raw_i =
  expected_richness_i - effort_corrected_richness_i

ecological_residual_normalized_i =
  (ecological_residual_raw_i - city_mean(ecological_residual_raw)) /
  city_stddev(ecological_residual_raw)
```

Because `expected_richness` is the fitted expectation of the same quantity
(section 6), this is a residual in the statistical sense — a leftover:

- Both sides are the same quantity in the same units (species per effort unit).
- It measures shortfall the fitted predictors could not explain. It is not an
  absolute ecological deficit, and a high-quality cell no longer scores a large
  gap merely for being high quality.

**It is not centred on zero.** An earlier version of this fit was OLS, for which
centring held by construction; the current fit uses a log link and minimises
deviance rather than squared error, so the raw gap on the response scale is
positive in **82.0%** of Porto's sampled cells (83.6% of scored patches; both
measured on the 2026-10-01 export). What the fit does guarantee is a zero
**effort-weighted** sum: with an intercept and the log(effort) offset, the
estimating equations force Σ effort × residual = 0. The unweighted mean is also
close to zero (−0.0004 in Porto), but only because a long negative tail of
richly recorded cells balances many small positive gaps; the median sits at
+0.088. Two things depend on that asymmetry and handle it explicitly:

- `nature_gap_score` centres every term itself on the city median
  (`score_scaling.R`, §8), so the score and its bands are unaffected.
- `underperformance` is floored at the **sampled median residual**, not at zero
  (§10). At 82% positive, a zero floor would exclude only 18% of sampled cells.

**The residual is expected minus observed — a gap, not a surplus.** It is signed
so that the headline metric and the residual point the same way: bigger means
further below expectation. The patch-level residual in
`pipeline/05_patch/patch_aggregation.R` uses the same orientation.

Interpretation:

- `ecological_residual` stores the raw expected-minus-observed value for
  backend analytics.
- `ecological_residual_normalized` stores the city-wise standardized residual,
  exported for analytics and detail panels.
- **Positive** residual: fewer species recorded than the model predicts —
  habitat pressure, restoration priority.
- **Negative** residual: more species recorded than the model predicts — above
  expectation, potential refuge.
- Near zero: observed richness aligns with the model.
- Unsampled: `NA`.

Rendering uses `residualNorm` (`norm_diverging(ecological_residual)` in
`06_export/export.R`: the residual **centred on its median** and divided by the
larger of |p10 − median| and |p90 − median|, clamped to `[-1, 1]`), not
`ecological_residual_normalized`. The centring is what stops a one-sided
distribution collapsing onto one arm of the diverging ramp — see §8.1. Raw
backend values are not clamped. `src/lib/layer-styles.ts` colours `+1` red and
`-1` green, following the sign convention above.

Downstream thresholds must not assume an absolute scale. The residual's spread
now follows each city's own richness scale rather than a fixed ~0–50 index, so
`06_export/export.R` derives its residual pressure cutoff from the sampled 75th
percentile (`RESIDUAL_PRESSURE_CUTOFF`, recorded in the manifest as
`metricDefinitions.ecologicalResidual.pressureCutoff`) instead of the previous
hard-coded `> 20`, which could never fire on the new scale.

Limitations:

- Fitted per city and in-sample, so raw residuals are not comparable between
  cities, and the zero point is a property of the fit rather than of the
  ecology.
- At hex scale the response is mostly zeros (section 6.1), so most of the
  residual's variation is the observation itself. Treat hex residuals as
  provisional until observations are pooled at a scale where richness counts are
  non-trivial.

### 7.1 Residual window and observation coverage

The expected model's fit statistic says how well `expected_richness` tracks the
observation. It does not say what `ecological_residual` is made of. For
R = E − Y, with λ = Var(E) / Var(Y) and ρ = cor(E, Y):

```text
cor(R, -Y) = (1 - ρ√λ) / √(1 + λ - 2ρ√λ)
```

At λ ≪ 1 the residual is the observation with its sign flipped; at λ ≫ 1 it is
the model. `RESIDUAL_WINDOW_LAMBDA` (`config.R`) sets the window at [0.25, 4],
which is generous: at λ = 0.25 and ρ = 0 the residual still shares 80% of its
variance with the observation.

Every export computes this per scale (`pipeline/residual_diagnostics.R`) and
writes it to the manifest at `metricDefinitions.ecologicalResidual.window`: n,
both variances, λ, ρ, cor(R, −Y) as measured and as the formula predicts,
cor(R, E), the variance shared with the observation, and a `regime` of
`observation-dominated`, `informative` or `model-dominated`. Hex values cover the
sampled cells; park values use the unrounded pooled values, not `park-stats.json`,
which rounds `expectedRichness` to 0.1 and would move Porto's park λ to 0.0149.
The pipeline gates nothing on the result; the frontend uses it to decide what
to draw (§8.4).

Porto, 2026-10-01 export:

| scale | n | λ | ρ | cor(R, −Y) | shared with the observation | regime |
| --- | --- | --- | --- | --- | --- | --- |
| hex | 30,947 | 0.0280 | 0.176 | 0.9859 | 97.2% | observation-dominated |
| park | 1,814 | 0.0129 | 0.062 | 0.9936 | 98.7% | observation-dominated |

Measured and predicted cor(R, −Y) agree to six digits at both scales.

`metricDefinitions.observedRichness.coverage` records what the `MIN_PATH_M`
admission rule leaves the observation: cells total and admitted, admitted cells
holding at least one record and at least one species, and the share of all
records that fall in excluded cells. Those records never reach the model. Porto:
30,947 of 119,771 cells admitted (25.8%), 7,340 of them (23.7%) holding any
record, and 107,161 of 227,110 records (47.2%) in excluded cells.

#### Coarser grain does not restore the window

Pooling to parks does not rescue it: park λ is 0.0001–0.025 across the four
cities (lower than hex in Porto and Gent, higher in Amsterdam and Yokohama, far
from the window in all). So the grain sweep
(`pipeline/sensitivity/sweep_grain_scale.R`) now reports λ for the same
specification refitted on square blocks, and `lambda_once` for the same fit
with effort entered once — the accessibility term dropped and nothing else, so
effort is the offset only (paper R6).
Its 20 m row uses additive in-cell path length, so it does not reproduce the
published hex λ; consistency across grains is what it measures.

| grain | Porto | Yokohama | Amsterdam | Gent |
| --- | --- | --- | --- | --- |
| 20 m | 0.0058 (0.0058) | 0.0036 (0.0036) | 0.0003 (0.0003) | <0.0001 (<0.0001) |
| 100 m | 0.050 (0.037) | 0.0095 (0.0066) | 0.0021 (0.0020) | 0.0047 (0.0043) |
| 200 m | 0.0085 (0.0053) | 0.032 (0.020) | 0.0019 (0.0019) | 0.0009 (0.0009) |
| 500 m | 0.19 (0.060) | 0.11 (0.071) | 0.0031 (0.0025) | 0.061 (0.060) |
| 1000 m | **0.31** (0.053) | **0.31** (0.12) | 0.040 (0.0021) | 0.16 (0.14) |

λ, current specification; `lambda_once` in brackets; bold is inside the window.
At every grain fine enough to act on, the residual is the observation in all
four cities. Porto and Yokohama reach the window only at 1 km, on 58 and 80
blocks, and only because the duplicated effort term supplies the expectation's
spread: with effort entered once neither reaches it at any grain, and Porto's
1 km λ falls from 0.31 to 0.053. λ is also fragile to a handful of extreme
blocks (Porto's dip at 200 m) — the record-concentration problem, where a few
blocks hold tens of thousands of records — which is not a grain effect.

The consequence is a reporting rule rather than a new grid: where a city's
window is not `informative`, the frontend withholds the two residual-based
layers (Nature Gap and Ecological residual) and points to their inputs
instead (§8.4). The residual is still computed,
exported and recorded; the layers return on their own when a run's λ enters the
window. Better observations are the route there: structured, effort-known
surveys reduce Var(observed) noise, whereas a richer expectation model cannot
add variance the data does not support.

## 8. Nature Gap Score

Nature Gap score is computed in `pipeline/05_residuals/residuals.R`, with the
patch-level equivalent in `pipeline/05_patch/patch_aggregation.R`. Both use the
shared scaling in `pipeline/score_scaling.R`.

Current implementation:

```text
robust_centre(v) =
  clamp( (v - median(v)) / max(|p10(v) - median(v)|, |p90(v) - median(v)|), -1, 1 )

nature_gap_score_i =
  (
    0.50 * robust_centre(ecological_residual)_i +
    0.30 * robust_centre(1 - habitat_quality)_i +
    0.20 * robust_centre(1 - corridor_importance)_i
  ) * 100
```

Each term is centred on the median of the **scored** cells and scaled by a
percentile half-spread, so an unsampled cell cannot move the median that scored
cells are measured against. The centring parameters — median, spread, quantiles,
n, and the share of values clamped — are written to `score_scaling.json` per
scale and carried into the export manifest under
`metricDefinitions.natureGapScore.scaling`.

Interpretation:

- **Positive**: worse than a typical cell in this city — the gap is real relative
  to local conditions.
- **Negative**: better than a typical cell in this city.
- **Zero**: typical for this city.
- Range: `[-100, +100]` — each term spans `±` its weight.
- Unsampled: `NA`.

**This is a within-city relative index, and zero means "typical cell for this
city", not "as expected" in any absolute sense.** The score was already
city-relative in substance — the biodiversity term always divided by a
city-specific maximum — so this makes an existing property explicit rather than
introducing one. Two consequences follow and are not fixable by calibration:

- Scores are **not comparable between cities**.
- The centring parameters are computed per run, so scores are **not comparable
  across dataset versions** of the same city either: a re-run with new
  observations shifts the median and therefore shifts the score of a cell whose
  own data did not change. Compare cells within one `dataset_id`, not across two.

### 8.1 What this replaced, and why

The previous formulation was

```text
0.50 * clamp(ecological_residual / max|ecological_residual|, -1, 1)
  + 0.30 * (1 - habitat_quality)
  + 0.20 * (1 - corridor_importance)
```

and it failed in three separate ways, all measured on the 2026-08-19 Porto
export:

1. **The biodiversity term was destroyed by a single outlier.** Dividing by
   `max|ecological_residual|` is only stable if the maximum is representative.
   With the fitted residual of section 6.1 the residual has sd 0.44 while one hex
   reaches -50.6 (272 species in ~350 m²), so the term spanned **-0.17 to +0.14
   of its nominal ±50**. The headline score would have contained no measurable
   biodiversity signal at all.
2. **The two deficit terms could only add.** `1 - habitat_quality` and
   `1 - corridor_importance` are non-negative by construction. Measured medians:
   `0.30 * (1 - habitat_quality) * 100` = **+18.3**, and
   `0.20 * (1 - corridor_importance) * 100` = **+20.0** — the latter pinned at
   exactly its maximum because `corridor_importance` is 0 in **88%** of sampled
   cells. A term at its ceiling for 88% of the grid is a constant, not a
   measurement. Together they imposed a ~+38 floor.
3. **The render normalisation did not centre.** `norm_diverging()` divided by
   `max(|p10|, |p90|)` without subtracting the median, so a distribution that
   never crossed zero mapped almost entirely onto one arm of the diverging ramp
   and the map rendered near-uniform.

Band distributions on Porto's 31,562 sampled cells, against the `SCORE_THRESHOLDS`
below:

| | p05 | p50 | p95 | much-better / better / as-expected / worse / much-worse |
|---|---|---|---|---|
| as published 2026-08-19 | 54.5 | 57.4 | 59.7 | 0 / 0 / 0 / 0 / **100%** |
| fitted expected richness only | 15.8 | 38.3 | 45.8 | 0 / 0 / 2 / 4 / **93%** |
| + robust biodiversity term only | −15.2 | 38.6 | 74.0 | 5 / 4 / 1 / 0 / **89%** |
| **all three terms centred (current)** | **−65.5** | **3.0** | **43.6** | **20 / 10 / 35 / 11 / 24** |

Fixing expected richness alone left 93% of cells in one band; only centring all
three terms produces a distribution the five-band scale can describe. The median
cell now reads `as-expected`, which is what a median cell should read.

`norm_diverging()` now applies the same `robust_centre` as the score, so legend
and score cannot disagree. One behavioural difference from the old version: where
a term has no spread at all, it yields `0` for cells that have a value and `NA`
elsewhere, rather than `0` everywhere.

### 8.2 Bands

`SCORE_THRESHOLDS` in `src/lib/config.ts` is the single frontend source of truth
for `src/lib/utils.ts` and `src/lib/cell-detail.ts`. `SCORE_BREAKS` in
`pipeline/06_export/export.R` holds the same values for `score_status()` and
`score_color()`, and is exported in the manifest as
`metricDefinitions.natureGapScore.bandBreaks`.

| Nature Gap score range | Status |
| --- | --- |
| `< -15` | `much-better` |
| `< -5` | `better` |
| `< 10` | `as-expected` |
| `< 20` | `worse` |
| `>= 20` | `much-worse` |
| missing (`NA`) | `not-assessed` |

These breaks were re-verified against the centred distribution and left
unchanged; they partition Porto 20 / 10 / 35 / 11 / 24.

A missing score — an unsampled cell, or a park with no sampled cell — is
`not-assessed`: a data state, not a sixth band. `score_status()` used to map it
to `as-expected`, so the 2026-08-26 Porto export published 3,440 of its 5,254
parks, every park without usable data, in the same band as parks that were
measured and found typical. The frontend draws `not-assessed` features grey
(`UNSAMPLED_FILL_COLOR`) with a legend entry of their own.

**Previously the pipeline's own ladders were inverted.** `score_status()` and
`score_color()` in `06_export/export.R` tested `score < -20 ~ "much-worse"` and
`score >= 15 ~ "much-better"` — the opposite of the convention above and of
`config.ts`, despite a comment asserting they were in sync. Every scored park in
the published Porto export therefore carries `status: "much-better"` at a median
`natureGapScore` of **+41.6**. Both ladders now read from `SCORE_BREAKS`.

### 8.3 Related exported fields

`natureGapScore` is intentionally separate from `ecological_residual`. PMTiles
expose `natureGapScore` (plus `natureGapScoreNorm` for styling), and
`ecologicalResidual` / `ecologicalResidualNormalized` / `residualNorm` for the
residual layer. `impactScore` is a legacy field holding
`round(bio_residual_norm * 50)` — the biodiversity term alone, and now on the
centred scale, so its values change meaning with this revision. Prefer
`natureGapScore`.

### 8.4 When the map withholds the score

The Nature Gap score is half residual, so it inherits the residual window
(§7.1). The frontend reads each city's verdict from the manifest
(`metricDefinitions.ecologicalResidual.window`, via
`src/lib/residual-window.ts`) and, for any city whose verdict is not
`informative`:

- draws the Nature Gap and Ecological residual layers in the not-assessed grey,
  per city — hex cells against the `hex` verdict, parks against `patch` — so a
  map showing two cities greys only the unsupported one;
- replaces those layers' ramps in the legend with "Not shown for {city}" and
  the city's own numbers (λ, and the share of the difference that is the
  observation);
- shows the same reason in place of the score band and the residual arithmetic
  in cell and park panels, and leaves the score out of the hover popup;
- opens on Habitat quality instead of Nature Gap, unless the viewer has picked
  a thematic layer, and switches back only if it made the switch itself. The
  choice follows the `hex` verdict, since hex cells are the only gap map drawn
  while park fills are off at overview zoom (`HAS_PATCH_OVERVIEW`); with them
  on, a withheld `patch` verdict counts too.

The two inputs — which is what the difference contains anyway (paper R1) — stay
available separately: expected richness as its own layer, and the observation
as the Observed biodiversity layer (record counts per cell) and as
effort-corrected observed richness in each panel's Biodiversity tab. There is no
map layer of effort-corrected observed richness. "Where to look next" also
stays: at this data density its ranking already reads as corridor cells with
few records. A dataset whose manifest has no window block
keeps the previous behaviour. Nothing is recomputed or hidden in the exports;
the decision is made at display time and reverses on its own when a run's λ
enters the window. On the 2026-10-01 exports every city is
`observation-dominated` at both scales.

## 9. Connectivity Analysis

Connectivity is computed in `pipeline/04_connectivity/connectivity.R`.

Graph construction:

- Nodes: 20 m hex centroids, restricted to cells above `CONN_MIN_PERMEABILITY`
- Edges: hexes that share a boundary (`sf::st_touches`)
- Edge weight: centroid distance scaled by the mean habitat resistance of the
  two cells it joins
- Graph engine: `igraph`

Permeability and resistance:

    permeability = vegetation * (1 - built_fraction_wc)
    resistance   = 1 + (CONN_MAX_RESISTANCE - 1) * (1 - permeability)

`vegetation` is `veg_fraction` where available, falling back to
`tree_fraction + shrub_fraction + grass_fraction` and then `green_fraction_wc`
(Yokohama has no `veg_fraction`; the fallbacks correlate 0.78 with it on
Amsterdam and are close to binary, so corridors are blockier there — see
section 4 on where `veg_fraction` comes from).

Resistance is floored at 1 rather than reaching 0, so ideal habitat still costs
its true length; zero-cost edges make shortest paths degenerate. Cells below
the permeability floor are dropped from the graph entirely rather than carried
at high cost — nothing disperses through a building — and they receive `NA`
corridor values, not zero.

**This replaces an earlier specification of `resistance = 1 - habitat_quality`,
which was documented but never implemented.** It does not work in practice:
`habitat_quality` is an NDVI-led blend with almost no dynamic range (Amsterdam
interquartile range 0.436–0.598) that scores a cell which is 87.5% built and
3.3% vegetated at 0.515. Resistance derived from it varies only between about
8.6 and 11.7 city-wide, producing a near-uniform lattice on which betweenness
degenerates into geometry. Measured on Amsterdam, that formulation left 205
isolated top-decile "corridor" cells; the formulation above leaves 5.

Until this change, corridors were computed on the **OSM pedestrian path
network** rather than on habitat at all — betweenness over footway junctions,
transferred to cells by nearest-node snap. That ranked busy streets as prime
habitat links, made green space with no footway invisible, and produced
scattered single-cell corridors with nothing adjacent to them. Paths now appear
only in observation-effort correction (section on effort), where they belong:
they model where observers walk, not where wildlife can move.

Metrics:

- `betweenness_centrality`: raw dispersal-limited betweenness on the graph
  above, capped at `CONN_DISPERSAL_M` effective metres (1 unit = 1 m through
  ideal habitat). The cap is both an ecological statement — dispersal is
  bounded, organisms do not route across an entire city — and what keeps the
  computation tractable.
- `corridor_importance`: `betweenness_centrality` expressed as a percentile
  rank among the cells that carry any route at all, so it spans 0–1. Cells with
  no route through them stay at 0 rather than being ranked up into the lower
  percentiles: they are not weak corridors, they are not corridors. This is the
  value used for intervention ranking.

The percentile step matters for more than presentation. Raw betweenness is a
tiny, heavily skewed number — on the old path graph Amsterdam's maximum was
0.0187 against a median of 0 — so every absolute threshold downstream
(`corridor_importance > 0.7` for the corridor intervention,
`> 0.25` for the corridor pressure note) was unreachable and had never once
fired. Ranking restores a scale those thresholds can express.

### 9a. Derived ecological network

The 20 m cells are the analytical surface, but they are not the map's primary
representation. `pipeline/04_connectivity/network_derive.R` reduces them to a
simplified network — habitat-core nodes joined by corridors — which is what the
connectivity layer draws at overview and transition zoom. The cells themselves
fade in only at analytical zoom (`NETWORK_REGIME.handover` in
`lib/layer-styles.ts`).

The order is nodes first, then routes between them. The reverse order — take the
high-importance cells, skeletonise, draw every branch — was the previous
implementation and is structurally incapable of producing a city-scale network:
cutting the graph at the importance threshold *before* deriving topology means no
corridor can cross degraded ground, so every high-importance blob becomes its own
island. Porto came out as 130 disconnected components and 420 segments with a
median length of 84 m.

**Routing surface.** Corridors are routed on a graph built from *every* grid cell,
walls included at `CONN_MAX_RESISTANCE` (`build_routing_graph()`). The betweenness
graph cannot serve: it drops cells below `CONN_MIN_PERMEABILITY`, which leaves it
in 520–1375 disconnected components with its largest holding 8–20% of cells, so
four candidate connections in five were unreachable. Whether a corridor should
cross weak ground is decided by the cost ceilings below, not by a missing edge.

Derivation, per city:

1. **Habitat cores.** Cells at or above `NET_CORE_IMPORTANCE` are grouped into
   connected areas. An area of at least `NET_CORE_MIN_AREA_HA` earns exactly one
   node, placed at the core's centre among its more permeable cells — not at its
   most important cell, since `corridor_importance` peaks at bottlenecks and would
   pull the node off the patch onto the pinch point leading out of it. Tier comes
   from area (`NET_MAJOR_AREA_HA` / `NET_SECONDARY_AREA_HA`).
2. **Node budget.** Cores are kept largest-area first, up to
   `NET_NODES_PER_KM2 × AOI km²`, clamped to `[NET_NODES_MIN, NET_NODES_MAX]`.
   Keyed to a cell-count threshold instead, Porto drew 160 secondary nodes against
   Amsterdam's 84 for no ecological reason and the two maps stopped being
   comparable.
3. **Candidate connections.** Delaunay neighbours of the node set, capped at
   `NET_MAX_LINK_M` straight-line separation (k-nearest as a fallback when
   triangulation is unavailable). All-pairs routing is affordable at this node
   count but yields a bundle of near-parallel routes that pruning then has to
   undo; Delaunay also guarantees the candidate set is connected before the
   distance cap is applied.
4. **Routing.** One least-cost path per candidate over the routing surface, one
   Dijkstra per source node. Cost is in effective metres, so `cost ÷ geometric
   length` is the route's mean resistance. A route is rejected above
   `NET_MAX_ROUTE_RESISTANCE` or `NET_MAX_ROUTE_COST_M`. Because every node pair
   has *some* least-cost path, these ceilings are what stop the map trading
   true-but-trivial fragments for clean-looking fictions.
5. **Pruning.** The backbone is a minimum spanning tree over route cost. A
   non-tree link survives only if it costs less than `NET_REDUNDANCY_RATIO` of the
   detour the tree forces *and* reuses no more than `NET_MAX_ROUTE_OVERLAP` of the
   cells already covered.
6. **Scoring.** Each corridor gets one class from its whole route's mean
   resistance: `strongest | strong | moderate | weak` (`NET_STRENGTH_BREAKS`).
   There is no `fragmented` class — step 4 rejects a route that bad, and a
   corridor that is broken rather than merely poor is described by its bottlenecks
   instead of by its average. Mean `corridor_importance` is *not* usable here: the
   route now crosses cells that carry no betweenness at all, where importance is 0
   by definition, and averaging those collapses every score to the floor.
7. **Bottlenecks.** A contiguous run of cells below
   `NET_BOTTLENECK_PERMEABILITY` covering at least `NET_BOTTLENECK_MIN_M` is
   carved out of the line as its own section, sharing the corridor's `corridorId`
   and quality class but marked `kind = "bottleneck"`. Every other section keeps
   the corridor's single dominant colour, so the line does not flicker between
   classes along its length. Sections below `NET_MIN_SECTION_M` are absorbed into
   their longer neighbour.
8. **Geometry.** Corner-cut (`NET_SMOOTH_PASSES`) to relax the 60° zigzag of a hex
   centroid path into a curve, then Douglas-Peucker at `NET_SIMPLIFY_M`. The
   tolerance has to stay well under the 20 m cell pitch — at 6 m it ate the
   curvature the smoother had just produced and left a 240 m corridor as four
   vertices.

**Hierarchy is styling, not generation.** One network is produced per city; each
corridor carries a `rank` (`primary | secondary | minor`) derived from the tiers
it connects, and `corridorLineOpacity()` reveals ranks progressively across zoom.
Generating three networks for three scales would mean three things that can
disagree. Rank gates by significance rather than by quality on purpose: a weak
corridor between two major cores is a finding worth seeing at city scale.

| | corridors | sections | nodes (major/secondary/stepping) | median route |
|---|---|---|---|---|
| amsterdam | 34 | 66 | 31 (6/8/17) | 720 m |
| porto | 49 | 85 | 40 (7/23/10) | 680 m |
| yokohama | 8 | 10 | 9 (5/3/1) | 1060 m |

Amsterdam previously emitted 211 segments (median 92 m) and 404 nodes; Porto 420
segments and 822 nodes. The edge GeoJSON is now about 5 KB per city.

Yokohama is genuinely sparse rather than misconfigured: it has no NIR coverage, so
permeability falls back to the near-binary WorldCover fractions (see the
permeability paragraph above), which
concentrates `corridor_importance` in few cells and leaves only nine habitat cores
above `NET_CORE_MIN_AREA_HA`.

Barriers are reported as bottleneck sections on the corridors they interrupt,
which is what the legend's break symbol now refers to. A **named** barrier — this
specific road, this railway — still needs a roads/rail loader at the connectivity
stage, which does not exist yet; roads are currently only read per-tile in
`02_habitat`.

`fragmentation_index`, `node_importance`, `edge_density`, `patch_isolation`, and
`patch_size_distribution` exist as placeholder fields in the pipeline but are
**not yet computed** (they are always null). They are intentionally not surfaced
in any user-facing metric, layer, or score until they are actually implemented
(see the connectivity backlog). Do not treat them as real values.

Limitations:

- Habitat quality is a generic permeability proxy.
- Species-specific movement is not modelled.
- Betweenness favours shortest paths and may not capture all ecological corridors.
- Habitat thresholds should be sensitivity-tested.

## 10. Intervention Ranking

Intervention ranking is computed in `pipeline/05_residuals/residuals.R`.

Current implementation:

```text
underperformance_i = max(0, ecological_residual_i - median(ecological_residual))

intervention_score_i =
  (underperformance_i * 0.5) * (corridor_importance_i * 0.5)
```

Cells are ranked descending by `intervention_score`.

Interpretation:

- `underperformance` is the residual floored at the **sampled median**, so a cell
  that is no worse than typical for its city contributes nothing rather than a
  negative score. The floor moved off zero when the fit moved to a log link: the
  raw gap is positive in 82% of Porto's sampled cells (§7), so a zero floor
  excluded little. At the median floor, 50.0% of Porto's sampled cells carry a
  positive underperformance, which is what makes the ranking discriminate.
  This floor only became selective once the residual was centred (section 6.1):
  while the residual was positive in 99.99% of sampled cells, flooring at zero
  excluded nothing and the ranking reduced to habitat quality × corridor
  importance — it selected the best habitat on corridors rather than the largest
  shortfall. Expect substantially fewer candidate cells after the change, and
  re-check the top-20 list against `species_richness` before publishing it.
- Higher score: stronger combination of underperformance and corridor relevance
- A cell needs both: no corridor importance means no intervention score, however
  large the gap
- Only positive-scoring cells are candidates for top intervention exports

This replaces the older weighted-sum formula:

```text
0.55 * normalised_underperformance + 0.45 * corridor_importance
```

Do not use the older formula unless the R implementation is intentionally
changed at the same time.

Counterfactual connectivity estimate:

- Computed for the top cells only.
- The target cell is locally upgraded to habitat quality `1.0`.
- A local connectivity graph is rerun.
- Reported as approximate percentage connectivity gain.

Limitations:

- The counterfactual is local and approximate.
- It is not a full restoration simulation.
- It is computationally expensive at large scale.

## 11. PMTiles And Presentation

PMTiles do not define methodology. They carry lightweight, precomputed values
from R for viewport-based rendering.

### Which cells enter the tileset

A cell is written to `hexgrid.pmtiles` if it meets any one of three tests
(`hexgrid_render` in `pipeline/06_export/export.R`):

1. it falls inside a named green space (OSM `leisure=park|nature_reserve|garden`);
2. its highest WorldCover vegetation fraction — tree, shrub, grass or the
   combined green class — is at least 0.10;
3. at least `CIR_VEG_RENDER_THRESHOLD` (0.15) of its 0.5 m colour-infrared
   pixels are vegetated, where a national CIR orthophoto exists.

Tests 2 and 3 are not decoration. OSM does not map rooftop gardens, courtyard
lawns, planted verges or wildflower strips, and a 10 m WorldCover pixel cannot
resolve them either, so without the CIR test those cells are absent from the
map entirely rather than merely uncoloured. A cell that fails all three is not
drawn on any layer, so this filter governs the vegetation layer as much as it
governs the park layers.

`hexgrid.pmtiles` carries the fields listed in `PMTILES_REQUIRED_FIELDS`
(`pipeline/06_export/export.R`), which is the authoritative list and is enforced
at export time. As of the current export that is:

- identity and attribution: `cellId`, `parkId`, `parkName`
- scores: `natureGapScore`, `impactScore` (legacy), `expectedRichness`,
  `ecologicalResidual`, `ecologicalResidualNormalized`, `interventionRank`
- habitat and context: `habitatQuality`, `observedRichness`,
  `corridorImportance`, `betweennessCentrality`, `treeCover`, `canopyHeightIdx`,
  `heatExposure`, `meanLst`, `lstIdx`, `landUseGreen`, `landUseClass`, `nObs`
- render-normalised companions (`[-1, 1]` diverging or `[0, 1]` unit, used
  directly by MapLibre expressions): `natureGapScoreNorm`, `residualNorm`,
  `expectedNorm`, `habitatQualityNorm`, `corridorImportanceNorm`,
  `betweennessNorm`, `treeCoverNorm`, `ndviNorm`, `lstNorm`,
  `disturbanceNorm`, `interventionRankNorm`
- data state: `isUnsampled`, `true` on unsampled cells and absent otherwise.
  Those cells carry zeros in the biodiversity-inference fields (§5), and zero is
  the diverging ramp's midpoint, so without the flag they render as *near
  expected* — 47,650 of the 67,439 hexes drawn for Porto (70.7%, measured on
  the 2026-10-01 export). `withUnsampledFallback()` in `src/lib/layer-styles.ts`
  greys flagged features on the Nature Gap, residual and intervention layers.

The derived ecological network ships separately as
`connectivity-network-edges.geojson` / `-nodes.geojson`, not in PMTiles.

One exception to the render filter above: when the opportunity gap (§15) ran,
every other cell also enters the tiles, flagged `opportunityOnly` and carrying
only the opportunity fields. The filter keeps green cells because the other
layers describe what is there; the opportunity gap describes what greening
would add, and the built-up cells the filter drops hold about half of Porto's
gap (46%; median 3.7 species against 2.0 in rendered cells). Every other layer filters
those cells out, so they change nothing else on the map. The larger tileset is
kept under the upload cap by sharding (`SHARD_TILES`), not by lowering the
maximum zoom.

PMTiles must not include:

- raw observations
- species arrays
- pressure arrays
- full intervention descriptions
- formulas
- recomputed metrics

MapLibre may style and filter PMTiles properties. It must not compute ecological
metrics.

## 12. Database Responsibilities

PostgreSQL/PostGIS may:

- store transactional records
- store R-computed cell outputs
- enforce relationships, roles, RLS, and auditability
- assign live observations to the nearest canonical 20 m hex cell
- expose detail rows to the frontend

PostgreSQL/PostGIS must not:

- compute expected richness
- compute effort correction
- compute ecological residual
- compute intervention ranking
- replace R as the scientific source of truth

## 13. Known Biases And Caveats

1. Urban bias: records cluster near dense residential areas and popular parks.
2. Taxonomic bias: iNaturalist and GBIF skew toward visible and charismatic taxa.
3. Temporal mismatch: satellite imagery and field records rarely align exactly.
4. Data sparsity: unsampled cells are excluded, not treated as zero biodiversity.
5. Uncalibrated defaults: habitat index weights, `SPECIES_AREA_Z`,
   `OBS_UNKNOWN_ACCURACY_WEIGHT`, connectivity and network constants are shared
   across all cities and calibrated against none of them. Their effect on the published intervention ranking is measured in
   [sensitivity-analysis.md](sensitivity-analysis.md): the habitat weights and
   `SPECIES_AREA_Z` barely move it, but **`CONN_MAX_RESISTANCE` does** — at
   R = 100 the ranking reorders substantially. The pipeline now reports this per
   cell rather than leaving it as a caveat: `corridor_importance` is recomputed
   across `CONN_ENSEMBLE_R` = {5, 10, 20, 30, 50, 100}, the full residual chain
   is re-run at each value, and `rank_stability` records the share of runs
   placing the cell in the top `RANK_STABILITY_TOP_N`. Share of the baseline
   top-20 stable across every R:

   | City | stable / 20 | mean stability |
   | --- | --- | --- |
   | Yokohama | 12 | 0.85 |
   | Porto | 10 | 0.84 |
   | Amsterdam | 4 | 0.69 |
   | Gent | **0** | 0.49 |

   No cell in Gent's baseline top-20 survives every value of R. Filter on
   `rank_stability`; `intervention_rank` alone is a single-R result and must not
   be presented as robust. The ensemble quantifies this dependence — it does not
   remove it and does not make the ranking more accurate, because
   `CONN_MAX_RESISTANCE` remains uncalibrated. There is no single correct value:
   dispersal cost through built ground differs by orders of magnitude between
   taxa, and this graph stands in for all of them at once.

   Expected richness is fitted per city (section 6), which also means it is not
   comparable between cities. Four cities are configured (`porto`, `amsterdam`,
   `yokohama`, `gent`); NIR/CIR coverage exists for Porto, Amsterdam and Gent,
   so Yokohama falls back to WorldCover fractions for permeability.
6. Effort enters the expected-richness model twice: once as a fixed offset
   (`survey_effort_units`) and once as a free covariate
   (`accessibility_component`), both derived from `path_local_m`. Since
   `observed_richness` is also effort-corrected, `ecological_residual` is a
   difference between two effort-laden quantities and partly maps pedestrian
   access rather than ecology. Accessibility is the dominant predictor in three
   of four cities. See section 6.1 — identified, not yet corrected.
7. OSM dependency: path, green-space, lighting, and road completeness vary by region.
8. Structured-survey dependence: live app surveys enter through the
   `pipeline_observations_export` view and must be exported before Step 03 for
   the latest approved records to affect the run.

## 14. Reproducibility Requirements

Every pipeline run should record:

- `CITY_ID`
- processing date/time
- CRS
- bbox
- `CELL_SIZE`
- the fitted expected-richness model at both scales, from
  `expected_richness_model.json`: family (`quasipoisson`), link (`log`), the
  offset column, formula, response, terms, training row count, coefficients,
  dispersion, explained deviance, and `fallback` / `fallbackReason` when the fit
  was refused. Also carried in the export manifest under
  `metricDefinitions.expectedRichness.model`.
- `SPECIES_AREA_Z` (the patch-scale area exponent; still an assumption).
  `SPECIES_AREA_C` is recorded for provenance only — it no longer affects any
  output.
- the Nature Gap score centring parameters at both scales, from
  `score_scaling.json`: per-term median, spread, quantile bounds, n, and
  `clampedShare`, plus the term weights. The score is within-city relative and
  these parameters are recomputed per run, so they are part of the published
  number, not metadata about it. Also carried in the manifest under
  `metricDefinitions.natureGapScore.scaling`, with the band breaks under
  `bandBreaks`.
- the residual window at both scales and the observation coverage (§7.1), in the
  manifest under `metricDefinitions.ecologicalResidual.window` and
  `metricDefinitions.observedRichness.coverage`, with `RESIDUAL_WINDOW_LAMBDA`.
- `RESIDUAL_PRESSURE_CUTOFF` (sampled p75 of the residual, used for the
  detail-panel pressure string)
- `MAX_EXPECTED_RICHNESS` (exported for transparency; scales nothing at either
  scale)
- `MIN_PATH_M` and `PATH_RADIUS_M` (effort-correction thresholds)
- the observation quality gates (section 3.1): `OBS_MAX_ACCURACY_M`,
  `OBS_UNKNOWN_ACCURACY_WEIGHT`, `OBS_DROP_OBSCURED`, `OBS_YEAR_MIN`,
  `OBS_EXCLUDE_BASIS`, and the per-gate drop counts reported by
  `apply_obs_quality_gates()`
- `CONN_*` and `NET_*` (connectivity and derived-network constants)
- the opportunity gap record (§15), `opportunity_model.json`: settings
  (`OPPORTUNITY_*`), data window and record counts, species counted, the
  introduced species left out with their evidence, the greener-quarter
  thresholds per land use with how close the matches were, the
  standardisation, every species' coefficients, and the validation with
  pass/fail
- source data dates or versions
- PMTiles source-layer name
- exported `cell_id` count
- active `dataset_id`
- `generated_at`
- PostgreSQL import result counts

These values should be auditable alongside the imported `cell_attributes` and
the Storage artefacts used by the frontend.

## 15. Opportunity Gap

Computed in `pipeline/05_opportunity/opportunity_gap.R` (settings: the
"Opportunity gap" block in `config.R`), recorded in `opportunity_model.json`,
validated in `pipeline/sensitivity/prototype_opportunity_gap.R`.

### 15.1 Why a different question

The ecological residual (§7) asks what is missing from a place, and the records
cannot answer that (§7.1). Three further attempts on Porto failed the same way
(2026-10-05):

- A spatial smooth on richness (`sensitivity/prototype_spatial_gap.R`). With
  effort read from the records rather than path length, habitat stopped
  predicting richness at all, so the surface meant "fewer species per record
  than nearby", not a shortfall against habitat.
- Occupancy models with visit-based detection
  (`sensitivity/prototype_occupancy_gap.R`), for every taxon group. None passed
  the time-holdout, observer-split, effort and coverage tests: species flagged
  missing in 2019–2022 were recorded afterwards at three times the rate of other
  unrecorded species, and a block needs 50–100+ visits before a typical
  species' absence means anything — 64 of Porto's 555 bird blocks have that.
- The same with richer habitat layers, re-fetched iNaturalist records grouped by
  observer, and a 125 m GPS gate: unchanged.

What the records do support is the citywide relationship between habitat and
species, pooled over every block, and the habitat layers cover every cell. The
opportunity gap uses only that: not what a place lacks, but what it would gain.

### 15.2 Method

- **Visits.** One observer on one date in one 250 m block is a visit; the
  species of one taxon group recorded on it are its list. A record without an
  observer is a visit of its own. Records from 2019, quality-gated by
  `load_obs_for_tiling()` (§3.1) except for GPS accuracy, gated at 125 m —
  half a block — instead of the 30 m set for the 20 m cell.
- **Species models.** One single-season occupancy model per species recorded at
  10 or more blocks (MacKenzie et al. 2002), with list length and season as
  detection covariates — the standard treatment of opportunistic records that
  are not complete lists (van Strien et al. 2013). Occupancy covariates, block
  means standardised across blocks: trees, grass/shrub, canopy height, 0.5 m
  vegetated fraction, water, water proximity, corridor importance, built cover,
  block size, heat anomaly, artificial light, noise, traffic. Weak normal
  penalties (sd 5 on intercepts, 2.5 on slopes) keep sparse species off the
  boundary. Fitted by maximum penalised likelihood with an analytic gradient.
- **Groups.** Every group counts: birds, other vertebrates
  (`classify_taxon_group()` labels mammals, reptiles, amphibians and fish
  together as "mammal"), plants (with mosses and liverworts), insects (with
  spiders), fungi (with lichens), and "other" — what the classifier leaves
  unclassified: molluscs, crustaceans, myriapods, worms, algae. Until 2026-10-06
  the classifier counted iNaturalist's catch-all "Animalia" (woodlice,
  centipedes, crabs) as vertebrates — 6 of Porto's 16 — and left GBIF's fungus,
  moss, reptile and cartilaginous-fish classes unclassified (about 33,000
  records across the four cities); both are fixed. The per-group species counts
  in cell details come from the habitat tiles and follow at the next full
  re-tile (`run_tiled_processing(force = TRUE)`).
  Each group carries a per-city label from its own records test (§15.4), so the
  map can say how much of each number has been checked against what people
  actually found.
- **Rare species.** A species recorded at fewer than 10 blocks cannot be
  modelled — one or two sightings do not say where else it lives. In Porto
  that is 88% of native species, though only 6% of records. Instead of being
  dropped, every recorded native species the models do not count is listed per
  cell where it was found within the window (up to 10 names, rarest first, from
  every record passing the §3.1 gates, not only the model's window). A fact, not
  a prediction.
- **Per cell.** Each 20 m cell reads the covariates averaged over the cells within
  125 m — about one block's area, the scale the models were fitted at — with the
  window's cell count rescaled to block units for the size term. Expected
  species = the sum of occupancy probabilities over the counted species.
- **Greener places like it.** Each window's greenness is the mean of its trees,
  grass/shrub, canopy height and 0.5 m vegetation, standardised as in the
  models. A window below the 75th percentile of greenness among windows with the
  same land use (`land_use_class()`, as the Land use layer) is compared with the
  25 windows of that land use's greener quarter most like it in water, water
  proximity, noise, traffic, light and window size (nearest neighbours on the
  models' standardised scale, `FNN`). Opportunity gap = the mean of their
  expected species − expected species here, per species and summed per group,
  with the three species gaining most named where each gains at least 0.01 in
  occupancy probability. A window already in the greener quarter has no gap; one
  whose land use has fewer than 25 greener windows has none computed (8 cells in
  Porto). What comes with greener places in the city is left free to differ:
  the four measures together, built cover, heat and corridor importance.
- **Why matching, not raising each measure.** The first version (2026-10-06)
  raised each of the four measures to the 75th percentile separately, taking
  the gain from built cover. They move together in the data (tree cover and
  canopy height r 0.84 in Porto), so that built places that do not exist, where
  the models' partial effects ran backwards: woodland birds lost species when
  trees were added, and 15% of Porto's cells and 32% of Gent's came out below
  −1. Comparing with real places keeps every comparison where the models were
  fitted and tested; it halved those shares.
- **Pressures are matched, not a lever.** Heat, light, noise and traffic
  cannot be told apart across blocks (noise–traffic r 0.83 in Porto, 0.86 in
  Gent; variance inflation up to 6.2), and lowering them gave *fewer* species in
  places — verge-dwelling species along road corridors showing through, not harm
  undone. Light, noise and traffic are held alike by the matching; heat is not,
  because greener places are cooler.

### 15.3 Introduced species

Never fitted and never counted — their records still lengthen the lists that
measure everyone else's detection, because visits are built from every record
first. `introduced_species.R` takes the Global Register of
Introduced and Invasive Species checklist of the city's country as the
authority, and fills it from species iNaturalist flags as introduced inside the
city only where another country's register also lists them — iNaturalist alone
flags mallard and greater white-toothed shrew in Porto, both native. Portugal's
national register folds in the Azores and Madeira: a national species also on an
island register and not flagged by iNaturalist in the city is kept as native
(Perez's frog, Moorish gecko). Which species count follows each country's
register — Belgium's lists the feral pigeon, Portugal's does not. Names are
matched on binomials; synonyms are not resolved.

Japan's register lists the Japanese white-eye, native to mainland Japan, most
likely for the Ogasawara Islands; Japan needs the same island correction before
Yokohama can be assessed (§15.4).

### 15.4 Labels and validation

Every run re-tests each group and labels it; nothing is withheld:

- **checked** — per well-recorded block (a present species would have been
  recorded at least once with probability ≥ 0.5, median over the group's
  species), the group's expected species predict its recorded species beyond
  effort: partial Spearman ρ ≥ 0.2 with p < 0.05 after removing log visits,
  expectations cross-validated 5-fold by block.
- **mismatch** — tested on 20 or more well-recorded blocks and did not match.
  Not a lack of data: Porto's plants have about 10,000 records, but they pile up
  where botanists and gardens are; whether the model or the records are wrong
  there, this data cannot say.
- **insufficient** — fewer than 20 well-recorded blocks: too few records to test.

Two citywide diagnostics are recorded beside the labels: *signal* (in
well-recorded blocks, cross-validated occupancy separates recorded from
unrecorded species better than occupancy permuted within species, 200
permutations; also per group) and *direction* (woodland birds gain in greener
places like theirs, built-up birds have a positive built-cover coefficient). Before the
labels, Porto and Gent passed all three tests for birds and other vertebrates in
the prototype, and the stage reproduces them to the 4th decimal.

2026-10-06 runs, with the corrected taxon groups (ρ in brackets):

| | Porto | Gent | Amsterdam | Yokohama |
| --- | --- | --- | --- | --- |
| Native species counted | 255 | 498 | 484 | 44 |
| Introduced species left out | 75 | 488 | 106 | 11 |
| Birds | checked (0.41) | checked (0.49) | checked (0.38) | **mismatch** (−0.04) |
| Other vertebrates | checked (0.34) | checked (0.28) | checked (0.56) | insufficient (none modelled) |
| Plants | **mismatch** (−0.28) | checked (0.39) | insufficient | insufficient |
| Insects | **mismatch** (0.05) | checked (0.42) | insufficient | insufficient |
| Fungi | **mismatch** (0.34) | **mismatch** (0.02) | insufficient | insufficient |
| Other invertebrates | checked (0.25) | **mismatch** (0.26) | insufficient | insufficient |
| Checked groups' share of all change (gains and losses) | 41% | 93% | 23% | 0% |
| Signal: median AUC (null 97.5%) | 0.608 (0.514) | 0.626 (0.510) | 0.588 (0.515) | 0.640 (0.549) |
| Direction checks right | 8 of 9 | 7 of 8 | 8 of 9 | 0 of 0 |
| Opportunity gap per cell: median / p90 | 3.3 / 11.6 | 2.2 / 27.5 | 0.0 / 12.9 | 0.0 / 2.0 |
| Cells with a gap below zero / below −1 | 10% / 7% | 19% / 16% | 40% / 37% | 5% / 2% |
| Same, first version (raising each measure) | 28% / 16% | 40% / 32% | 36% / 30% | 5% / 1% |
| Rare native species listed (records) | 1,874 (8,267) | 2,255 (9,003) | 2,808 (12,844) | 1,586 (5,487) |

Correcting the groups also removed double counts: a fungus recorded through
both iNaturalist (Fungi) and GBIF (its class, then unclassified) had been
modelled once in each group (Porto 262 → 255 species). Yokohama's one
"vertebrate" was an invertebrate, which leaves it no checked group. A *mismatch*
with ρ ≥ 0.2, as for Porto's fungi, failed on p ≥ 0.05: too few well-recorded
blocks to be sure.

Gent's plant and insect records come largely from naturalists who log many
species per outing, and behave like surveys; Porto's are mostly single photos.
Amsterdam loses most of its records to the 125 m GPS gate (698,000 of 1.17
million), leaving too few well-recorded blocks to test plants and insects.
Yokohama has 3,630 bird records in the window, and its direction species are
European, none of which occur there.

### 15.5 Interpretation and limits

- The parts labelled mismatch or insufficient are shown, not checked: the map
  must say which share of a number is which, and a city's figure is only as
  firm as its checked share.
- It covers the common species of each city (those recorded at 10 or more
  blocks); rare species are listed where found, which reflects where people
  looked as much as where they live.
- It is an opportunity, not a deficit. Zero means the place is already in the
  greener quarter of its land use — not that nothing is missing there.
- A negative gap means greener places like this one hold fewer of the species
  expected here. In Gent these are mostly species-rich open, rough or wet
  ground — grasshopper and marsh warblers, coltsfoot, peacock butterfly — whose
  species would lose out to trees; in Porto, species of pavements and walls. In
  Amsterdam the plants (*insufficient* there) lose species of open ground, walls
  and verges — common stork's-bill, oxeye daisy, wall lichen — more than the
  birds gain, so the city's net gap is below zero while its checked groups gain
  (birds: median +1.7, below zero in 11% of cells).
- It compares places, it does not predict the effect of planting: greener
  places differ from this one in everything that comes with greenness in the
  city, and in anything the covariates do not measure.
- Gains are expected species (summed occupancy probabilities), not species that
  will arrive.
- Habitat-based and correlational: it cannot see a place degraded for other
  reasons (management, pollution, predation), and the relationships are not
  experiments.
- Neighbouring cells share most of their window, so the surface is smooth by
  design; per-cell values are indicative, area summaries firmer.
- "Greener" is the top quarter of greenness within the same land use, and
  "alike" the 25 nearest in six covariates — choices, not calibrations. Gaps
  barely depend on the number matched (cell ranks agree at ρ 0.97 for 10 and
  0.98 for 50 in Porto); comparing with places just at the 75th percentile
  instead of the whole greener quarter gives smaller gaps (Porto median 0.3).
- Assumes each block's community is stable over the record window.
- Effort is corrected with visits and list length, not path density (AGENTS.md
  records the exception). App records enter as visits like any other; a
  structured survey's complete-list status is not used yet.

### 15.6 On the map

The opportunity gap is the **Nature gap** layer, first in the list and open by
default, drawn with viridis: gains run from green through teal and blue to deep
purple up to the city's 90th-percentile gap; gaps between −1 and +0.5 read as
"no clear gain"; at or below −1 viridis's last colour, yellow, reads "already
richer than greener places like it"; cells without a comparison are grey. A legend switch draws `opportunityGap` (all groups, the default) or
`opportunityGapChecked` (checked groups only), and the legend states the
city's checked share of the change. The panel gives expected species, the gap,
its checked part, every group with its label and top species, and the rare
species found nearby; `opportunityOnly` cells show this alone. Every other layer
leaves `opportunityOnly` cells out. The record-based Nature Gap score (§8) and
the ecological residual layer are out of the layer list while every city's
residual window is observation-dominated (§8.4).
