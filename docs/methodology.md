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
- impact score
- connectivity metrics
- intervention score and ranking
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

- Local processing for Yokohama: JGD2011 / Japan Plane Rectangular CS VI, `EPSG:6674`
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

- The current R pipeline reads iNaturalist and GBIF raw files.
- The Supabase export of approved quick sightings and structured surveys into R
  is still a required implementation step.
- Until that export exists, app observations are transactional records and map
  overlays, not model inputs.

Eligibility rules for app observations before R import:

- Exclude rejected records.
- Exclude records with pending or confirmed quality flags.
- Preserve raw geometry.
- Preserve GPS accuracy.
- Preserve structured-survey effort and habitat indicators.
- Preserve the assigned 20 m `cell_id` when available.

## 4. Habitat Quality Index

Habitat quality is computed in `pipeline/02_habitat/habitat_model.R`.

Current conceptual formula:

```text
habitat_quality =
  0.35 * ndvi_idx
  + 0.30 * green_idx
  + 0.20 * lst_idx
  + 0.15 * (1 - path_idx)
```

Sub-indexes:

| Sub-index | Source | Transformation | Rationale |
| --- | --- | --- | --- |
| `ndvi_idx` | Sentinel-2 B4/B8 | Rescaled NDVI | Photosynthetically active vegetation |
| `green_idx` | OSM green space and landcover fractions | Cell-area fraction | Accessible or mapped green cover |
| `lst_idx` | Landsat ST_B10 | Inverted heat rank | Cooler cells are less heat-stressed |
| `path_idx` | OSM footways, paths, tracks | Path density | High path density proxies disturbance/accessibility |

Related stressor features may include impervious fraction, road/rail noise
proxy, light pollution proxy, water proximity, and disturbance index.

Limitations:

- Weights are expert-assigned and not yet empirically calibrated.
- NDVI does not distinguish native vegetation from ornamental or invasive cover.
- OSM completeness varies by city.
- LST is date-sensitive; multi-date composites would be more robust.

Where a national CIR orthophoto is available (Portugal DGT Ortos, Netherlands
PDOK luchtfoto CIR), ingest also writes `veg_fraction` (share of 0.5 m pixels
with DN-based NDVI ≥ 0.2) and `ndvi_texture` (within-hex SD of that NDVI).
These are supplementary hex attributes. They do **not** enter `habitat_quality`,
which continues to use Sentinel-2 `ndvi_idx` so cities stay comparable.

## 5. Observer Effort Correction

Effort correction is computed in `pipeline/03_observations/observation_layer.R`.

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
  `0` only for render-only PMTiles fields that cannot style nulls reliably.
- Patch-level `observed_richness` is aggregated from the same cell-level
  `observed_richness` field, weighted by cell/patch overlap, so patch and hex
  values use the same pipeline semantics.

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

Expected richness is modelled at two levels.

### 6.1 Per-hex expected index (`pipeline/05_residuals/residuals.R`)

A relative, index-like value per 20 m hex, used only for the hex-level map
layers and the per-hex ecological residual:

```text
expected_richness_i =
  MAX_EXPECTED_RICHNESS * (
    0.65 * habitat_quality_i
    + 0.20 * corridor_importance_i
    + 0.15 * accessibility_component_i
  )
```

Where:

- `MAX_EXPECTED_RICHNESS = 350`
- `accessibility_component_i = log1p(path_local_m_i) / log1p(max_path_local_m)`
  clamped to `[0, 1]`, and `0` for unsampled cells

This is a within-city relative index for hex comparison, not a species count and
not calibrated per city.

### 6.2 Patch (park) expected richness (`pipeline/05_patch/patch_aggregation.R`)

Per-park expected richness must scale with total park area — larger areas
support more species (the species-area relationship), all else equal. It is
therefore computed **once per patch** from total patch area using a power law,
not by averaging the per-hex index (an area-weighted average does not scale with
size, so a small park and a large park of similar per-hex quality would
otherwise get nearly the same expected richness):

```text
expected_richness_patch =
  SPECIES_AREA_C * (patch_area_m2 ^ SPECIES_AREA_Z) * quality_modifier
```

Where:

- `patch_area_m2` is the park's total area.
- `quality_modifier` is the area-weighted mean of `habitat_quality_index`,
  `corridor_importance`, and accessibility across the park's hexes, clamped to
  `[0, 1]`. Averaging is appropriate here because these are intensive
  properties, not counts.
- `SPECIES_AREA_Z = 0.25` is the species-area exponent. **This value is an
  assumption informed by general species-area relationship literature, not
  calibrated to Yokohama or Amsterdam specifically, and not sourced to a
  specific citation.** It is set within the commonly cited 0.2–0.3 range pending
  a proper literature review / local calibration.
- `SPECIES_AREA_C = 12` is a scaling constant chosen so `expected_richness`
  lands in a plausible range across the actual park-area distribution in both
  cities (roughly 20 m² to 3.4×10⁵ m²). It is a tuning constant, not a
  measured quantity.

Limitations:

- `SPECIES_AREA_Z` and `SPECIES_AREA_C` are documented assumptions, not
  calibrated or cited values.
- `MAX_EXPECTED_RICHNESS` (per-hex index) is not calibrated per city.
- Regional species-pool constraints are not yet modelled.

## 7. Ecological Residual

Ecological residual is computed in `pipeline/05_residuals/residuals.R`.

Formula:

```text
ecological_residual_raw_i =
  observed_richness_i - expected_richness_i

ecological_residual_normalized_i =
  (ecological_residual_raw_i - city_mean(ecological_residual_raw)) /
  city_stddev(ecological_residual_raw)
```

Interpretation:

- `ecological_residual` stores the raw observed-minus-expected value for
  backend analytics.
- `ecological_residual_normalized` stores the city-wise standardized residual
  used by MapLibre residual styling.
- Positive normalized residual: above expectation, potential refuge
- Negative normalized residual: below expectation, habitat pressure, restoration priority
- Near zero: observed richness aligns with expectation
- Unsampled: `NA`

Map visualisation may clamp `ecological_residual_normalized * 25` to
`[-50, 50]`. Raw backend values are not clamped.

## 8. Nature Gap Score

Nature Gap score is computed in `pipeline/05_residuals/residuals.R`.

Current implementation:

```text
nature_gap_score_i =
  (
    0.50 * clamp(ecological_residual_normalized_i / 2, -1, 1) +
    0.30 * (1 - habitat_quality_i) +
    0.20 * (1 - corridor_importance_i)
  ) * 100
```

Interpretation:

- Negative Nature Gap score: ecosystem under pressure
- Positive Nature Gap score: ecological surplus
- Zero: near expected or no finite residual range

This is intentionally separate from `ecological_residual`. PMTiles expose
`natureGapScore` for decision-score styling and
`ecologicalResidualNormalized` for residual styling, while detail panels can
also show raw `ecologicalResidual`.

Current color/status thresholds:

| Impact score range | Status |
| --- | --- |
| `< -20` | `much-worse` |
| `< -10` | `worse` |
| `< 5` | `as-expected` |
| `< 15` | `better` |
| `>= 15` | `much-better` |

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
Amsterdam and are close to binary, so corridors are blockier there).

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
isolated top-decile "corridor" cells; the formulation above leaves 15.

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
simplified network — nodes joined by corridor centrelines — which is what the
connectivity layer draws at overview and transition zoom. The cells themselves
fade in only at analytical zoom (`NETWORK_REGIME.handover` in
`lib/layer-styles.ts`).

Derivation, per city:

1. Cells at or above `NET_MIN_IMPORTANCE` are grouped into **connected areas**
   with `igraph::components()` on the habitat graph.
2. Each area is reduced to a **skeleton** by farthest-point growth: take the two
   most remote cells and the least-cost path between them as the trunk, then
   repeatedly attach the most remote unattached cell to the existing skeleton by
   its least-cost path, pruning branches shorter than `NET_MIN_BRANCH_CELLS`.
   Every centreline is therefore a least-cost path through the resistance
   surface, so a corridor that follows a canal bank or park edge does so as a
   consequence of the habitat data, never because that feature was used as
   geometry.
3. Degree-2 runs are contracted into one polyline per corridor **segment**, then
   corner-cut (`NET_SMOOTH_PASSES`) to relax the 60° zigzag of a hex centroid
   path into a curve.
4. **Nodes**: one per connected area, tiered by area size
   (`NET_MAJOR_CELLS` / `NET_SECONDARY_CELLS`); plus junctions (degree ≥ 3,
   promoted to major at degree ≥ 4) and corridor endpoints. Areas too small to
   skeletonise (`NET_MIN_COMPONENT_CELLS`) become a single stepping stone rather
   than an invented corridor.
5. Segments are classed `strongest | strong | moderate | weak | fragmented` by
   mean `corridor_importance` along their cells.

Node tiering is deliberately not a function of score alone: a large connected
area earns one major node, and a busy junction earns one on its own merit. An
earlier version gave every terminal of a large area that area's tier, which
produced 55 "major" nodes in Amsterdam instead of 5.

Amsterdam yields 143 connected areas → 211 corridor segments (25.3 km) and 404
nodes (5 major, 84 secondary, 315 stepping stones), about 108 KB of line
GeoJSON. This replaces `corridor-links.geojson`, which emitted one line per hex
adjacency — roughly 32,000 segments that rendered as a dense mesh rather than a
network.

Not yet derived: **connectivity breaks** where a road or railway severs a
corridor. That needs a roads/rail loader at the connectivity stage, which does
not exist yet — roads are currently only read per-tile in `02_habitat`. The
legend deliberately omits a break symbol until the data behind it exists.

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
intervention_score_i =
  (ecological_residual_i * 0.5) * (corridor_importance_i * 0.5)
```

Cells are ranked descending by `intervention_score`.

Interpretation:

- Higher score: stronger combination of underperformance and corridor relevance
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

`hexgrid.pmtiles` may include:

- `cellId`
- `impactScore`
- `expectedRichness`
- `ecologicalResidual`
- `habitatQuality`
- `observedRichness`
- `corridorImportance`
- `treeCover`
- `heatExposure`
- `landUseGreen`
- `interventionRank`

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
5. Single-city calibration: Yokohama defaults require re-validation for new cities.
6. OSM dependency: path, green-space, lighting, and road completeness vary by region.
7. Structured-survey dependence: live app surveys enter through the
   `pipeline_observations_export` view and must be exported before Step 03 for
   the latest approved records to affect the run.

## 14. Reproducibility Requirements

Every pipeline run should record:

- `CITY_ID`
- processing date/time
- CRS
- bbox
- `CELL_SIZE`
- `MAX_EXPECTED_RICHNESS`
- `SPECIES_AREA_Z` and `SPECIES_AREA_C` (patch expected-richness assumptions)
- source data dates or versions
- PMTiles source-layer name
- exported `cell_id` count
- active `dataset_id`
- `generated_at`
- PostgreSQL import result counts

These values should be auditable alongside the imported `cell_attributes` and
the Storage artefacts used by the frontend.
