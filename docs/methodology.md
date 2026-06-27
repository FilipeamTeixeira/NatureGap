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

## 5. Observer Effort Correction

Effort correction is computed in `pipeline/03_observations/observation_layer.R`.

Problem:

Citizen-science observations cluster where people walk. Raw richness therefore
confounds biodiversity with observer effort.

Current formula:

```text
effort_corrected_richness_i =
  species_richness_i / log(1 + path_km_i)
```

Where:

- `species_richness_i` is the distinct species count in cell `i`.
- `path_km_i` is OSM pedestrian path length in cell `i`.

Unsampled rule:

```text
if path_km_i <= 0:
  is_unsampled_i = true
  effort_corrected_richness_i = NA
```

Unsampled cells are excluded from residual inference. They are not zero-richness
cells.

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

Expected richness is computed in `pipeline/05_residuals/residuals.R`.

Current formula:

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
- `accessibility_component_i = log1p(path_km_i) / log1p(max_path_km)`
  clamped to `[0, 1]`

Expected richness is an index-like estimate for relative comparison. It is not
a calibrated species distribution model.

Limitations:

- The relationship is linear and provisional.
- `MAX_EXPECTED_RICHNESS` is not calibrated per city.
- Regional species-pool constraints are not yet modelled.

## 7. Ecological Residual

Ecological residual is computed in `pipeline/05_residuals/residuals.R`.

Formula:

```text
ecological_residual_i =
  effort_corrected_richness_i - expected_richness_i
```

Interpretation:

- Positive residual: above expectation, potential refuge
- Negative residual: below expectation, habitat pressure, restoration priority
- Near zero: observed richness aligns with expectation
- Unsampled: `NA`

Do not reuse this field for public-facing composite scores.

## 8. Nature Gap Score

Nature Gap score is computed in `pipeline/05_residuals/residuals.R`.

Current implementation:

```text
nature_gap_score_i =
  (
    0.50 * ecological_residual_i / max(abs(ecological_residual)) +
    0.30 * (1 - habitat_quality_i) +
    0.20 * (1 - corridor_importance_i)
  ) * 100
```

Interpretation:

- Negative Nature Gap score: ecosystem under pressure
- Positive Nature Gap score: ecological surplus
- Zero: near expected or no finite residual range

This is intentionally separate from `ecological_residual`. PMTiles expose
`natureGapScore` for user-facing styling, while detail panels can also show
`ecologicalResidual`.

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

- Nodes: 20 m hex centroids
- Edges: neighbouring 20 m hexes within the configured adjacency distance
- Edge weight: habitat resistance derived from `1 - habitat_quality`
- Graph engine: `igraph`

Metrics:

- `corridor_importance`: normalised betweenness centrality
- `fragmentation_index`: neighbourhood habitat fragmentation
- `node_importance`: graph node importance
- `connectivity_score`: combined connectivity indicator

Conceptual connectivity score:

```text
0.60 * corridor_importance
+ 0.25 * node_importance
+ 0.15 * (1 - fragmentation_index)
```

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
- source data dates or versions
- PMTiles source-layer name
- exported `cell_id` count
- active `dataset_id`
- `generated_at`
- PostgreSQL import result counts

These values should be auditable alongside the imported `cell_attributes` and
the Storage artefacts used by the frontend.
