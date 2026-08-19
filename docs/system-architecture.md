# NatureGap System Architecture

This document describes the current NatureGap architecture and the intended
implementation contract. The system is an existing production-style Next.js,
TypeScript, Supabase, R, PostGIS, PMTiles, and MapLibre application. Extend it
incrementally; do not redesign the stack.

## 1. Architecture Boundary

NatureGap has three separated systems:

```text
Analytical system:
  R pipeline
    -> reads raw spatial, biodiversity, and approved observation inputs
    -> computes all ecological and spatial metrics
    -> exports PMTiles, PostGIS import artefacts, and UI JSON

Persistence system:
  PostgreSQL/PostGIS
    -> stores users, roles, observations, surveys, moderation, suggestions
    -> stores R-computed cell outputs
    -> assigns live records to the canonical 20 m hex grid
    -> does not recompute ecological metrics

Presentation system:
  Next.js + MapLibre
    -> streams PMTiles
    -> renders live citizen-science points
    -> applies styling, filtering, interaction, and detail lookup
    -> does not compute ecological metrics
```

PMTiles are rendering products only. PostgreSQL/PostGIS is the authoritative
store for full cell-detail values after the R pipeline writes or imports them.
MapLibre displays values already computed by R.

## 2. End-To-End Data Flow

The intended production flow is:

```text
Raw spatial and biodiversity data
  -> R pipeline
  -> hexgrid.pmtiles + cell_attributes import + UI JSON
  -> Supabase Storage + PostgreSQL/PostGIS
  -> MapLibre PMTiles rendering
  -> User map interaction
  -> Supabase cell_attributes lookup
  -> Detail panel
```

Citizen-science writes use a separate transactional flow:

```text
User
  -> Next.js UI
  -> Supabase Auth session
  -> Supabase Edge Function
  -> PostgreSQL/PostGIS observation tables
  -> PostGIS assigns nearest canonical 20 m cell_id
  -> approved records become input to a later R pipeline run
```

No ecological metric should bypass the R pipeline. The allowed exception is
PostGIS cell assignment for live records, because it is spatial attribution,
not ecological analysis.

## 3. Current Repository Components

Frontend:

- `src/app/page.tsx`: main map, layer controls, detail panel, citizen-science panel
- `src/components/map/MapView.tsx`: MapLibre map and PMTiles vector rendering
- `src/lib/pmtiles-storage.ts`: Supabase Storage PMTiles URL construction
- `src/lib/layer-styles.ts`: MapLibre paint expressions for already-computed properties
- `src/lib/cell-detail.ts`: click-time `cell_attributes` lookup and display fallback
- `src/lib/citizen-science.ts`: live survey/sighting fetches and Edge Function calls
- `src/lib/storage-fetch.ts`: Supabase Storage JSON loader for pipeline JSON artefacts
- `src/lib/green-spaces.ts`: `parks.geojson` loader for park click zones
- `src/lib/data.ts`: live business-data reads (`conservation_actions`,
  `city_layer_stats`, plus `global_stats`/`wards`/`community_events`, which are
  not in current migrations and return empty)

R pipeline:

- `pipeline/config.R`: shared constants, paths, env loading, geometry helpers
- `pipeline/cities/<city>.R`: the per-city values (`CITY_ID`, `CRS_LOCAL`, OSM
  relation, regional PBF, extra raster downloaders) — everything else is shared
- `pipeline/run_pipeline.R`: the runner; stages below execute in this order
- `pipeline/00_download/*.R`: raster acquisition (WorldCover, Sentinel-2,
  Landsat LST, canopy height, PlanetScope, PT/NL CIR orthophoto NIR)
- `pipeline/01_ingest/tile_registry.R`: AOI tiling for the tiled passes
- `pipeline/01_ingest/ingest.R`: raw environmental and biodiversity ingest
- `pipeline/01_ingest/export_supabase_observations.R`: approved app observations
  out of `pipeline_observations_export` into `raw/supabase_observations.gpkg`
- `pipeline/02_spatial/spatial_base.R`: whole-AOI hex grid and green spaces
- `pipeline/02_habitat/process_tile.R`: the tiled worker — habitat, stressor,
  path length, observation standardisation, effort correction
- `pipeline/02_habitat/habitat_model.R`: drives the tiled pass, writes
  `grid_habitat.gpkg` and `habitat_quality.tif`
- `pipeline/03_observations/observation_layer.R`: observed-richness contract
  checks, `grid_observations.gpkg`, per-cell taxa JSON
- `pipeline/04_connectivity/connectivity.R`: graph connectivity metrics
- `pipeline/04_connectivity/network_derive.R`: derived node/corridor network
- `pipeline/05_residuals/residuals.R`: expected richness, residuals, Nature Gap
  score, intervention ranking
- `pipeline/05_patch/patch_aggregation.R`: patch (park) aggregation and
  patch-scale expected richness
- `pipeline/06_export/export.R`: PMTiles, Storage products, and UI JSON exports
- `pipeline/07_import/import_to_postgres.R`: optional PostgreSQL dataset import
- `pipeline/07_import/prune_stale_storage.R`: removes superseded Storage objects

Supabase:

- `supabase/migrations/*`: schema, RLS, audit, spatial assignment, cell detail columns
- `supabase/functions/*`: authenticated write/review APIs

Obsolete architecture references to `src/lib/park-data.ts`, `src/lib/hex-grid.ts`,
`hexgrid.geojson` rendering, or `cells.json` enrichment are not current.

## 4. Database Layer

### `user_roles`

Application role mapping for Supabase Auth users.

- `user_id -> auth.users.id`
- `granted_by -> auth.users.id`
- Used by RLS helpers, Edge Functions, and frontend advisory UI
- No `profiles` table exists in current migrations

### `species_reference`

Taxonomic reference table.

- Referenced by `quick_sightings.species_id`
- Referenced by `survey_records.species_id`
- Stores `region_plausibility` JSONB for range and season checks
- Stores `requires_photo_on_first_record`

### `survey_points`

Approved, pending, or rejected locations for structured surveys.

- `geometry geometry(Point, 4326)`
- `suggested_by -> auth.users.id`
- `approved_by -> auth.users.id`
- Referenced by `structured_surveys.survey_point_id`
- Structured surveys can only start at approved points

### `quick_sightings`

Opportunistic, presence-only observations.

- Raw point geometry is preserved
- `gps_accuracy_m` is stored and used in quality flags
- `cell_id -> cell_attributes.cell_id`
- Duplicate sightings within 30 minutes are flagged for review
- First record of a species, when required by `species_reference`, requires a photo

### `structured_surveys`

Protocol-based surveys with timing and habitat indicators.

- `survey_point_id -> survey_points.id`
- `user_id -> auth.users.id`
- `cell_id -> cell_attributes.cell_id`
- Location is inherited from the survey point
- Habitat indicators are stored as JSONB
- Structured surveys are intended to have higher R pipeline weight than quick sightings

Structured-survey weighting is implemented end to end: the export view
`pipeline_observations_export` →
`pipeline/01_ingest/export_supabase_observations.R` →
`raw/supabase_observations.gpkg` → `pipeline/02_habitat/process_tile.R`, which
assigns `observation_weight` 3 to `structured_survey`, 0 to `quick_sighting`,
and 1 otherwise. The export step runs only when
`SUPABASE_OBSERVATIONS_ENABLED="1"`. See the pipeline contract below.

### `survey_records`

Species/count records inside structured surveys.

- `survey_id -> structured_surveys.id`
- `species_id -> species_reference.id`
- Spatial context comes through the parent survey

### `cell_attributes`

Canonical 20 m hex grid and R-computed cell outputs.

- `geometry geometry(Polygon, 4326)`
- Referenced by live observations and structured surveys
- Stores expected richness, effort-corrected richness, ecological residual
  (expected − observed), Nature Gap score, stressors, connectivity, ranking,
  detail-panel JSON fields, and timestamps
- Required before live observation assignment works

Versioning model:

- Historical R outputs are stored in `pipeline_cell_attributes` using
  `(city_id, dataset_id, cell_id)`.
- The app-compatible active projection remains `cell_attributes`.
- Active datasets are promoted through `promote_pipeline_dataset(...)`.
- Composite indexes cover city/dataset and city/rank lookups.

### `conservation_actions`

Reference table for admin-managed action types.

- Defined in `supabase/migrations/20260626095500_observation_database_layer.sql`
- Read by `fetchActions()` in `src/lib/data.ts`, rendered by
  `src/app/take-action/page.tsx`
- There is no `recommended_actions` table and no frontend reference to one; the
  earlier duplication between the two names is resolved

### `suggestions`

Unified suggestion queue.

- `submitted_by -> auth.users.id`
- `reviewed_by -> auth.users.id`
- Uses status flags; records are not hard deleted
- Can represent survey point, species, action, local note, and habitat-photo suggestions

### `flags`

Auditable moderation and quality-control records.

- `record_type` + `record_id` target records validated by trigger
- `flagged_by -> auth.users.id`
- `reviewed_by -> auth.users.id`
- Analysis views exclude rejected records and pending/confirmed flags

### `audit_log`

Append-only audit table populated by triggers.

- Tracks inserts and updates on domain tables
- Hard deletes are blocked by trigger

## 5. Spatial System

The canonical spatial unit is the 20 m hex cell.

```text
R:
  sf::st_make_grid(area, cellsize = 20, square = FALSE)
    -> local metre CRS during processing
    -> cell_id
    -> R-computed metrics
    -> EPSG:4326 export for web and PostGIS

PostGIS:
  cell_attributes.geometry
    -> nearest-cell assignment for live records
    -> spatial integrity and lookup

PMTiles:
  hexgrid.pmtiles
    -> render-only vector tiles
    -> lightweight feature properties
```

Current grid facts:

- Resolution: 20 m
- Shape: hexagons
- Cities configured: `yokohama-honmoku`, `amsterdam-schimmelstraat`,
  `porto-center`
- Default city in the R pipeline: `yokohama-honmoku` (`DEFAULT_CITY` in
  `pipeline/config.R`)
- Default city in the frontend: `porto-center` (`CITY.id` in
  `src/lib/config.ts`, with `NEXT_PUBLIC_PIPELINE_CITY_IDS` selecting which
  Storage datasets are loaded)
- R local CRS: `EPSG:6674` (Yokohama), `EPSG:28992` (Amsterdam), `EPSG:3763`
  (Porto)
- Web/PostGIS CRS: `EPSG:4326`
- Frontend source-layer: `hexgrid`

PostGIS cell assignment functions use `cell_attributes` and centroids to assign
live observations and structured surveys to the nearest canonical cell. This is
an allowed database responsibility. It must not become ecological metric
calculation.

## 6. R Pipeline Contract

The R pipeline is the only source of truth for scientific values.

### Inputs

External and environmental inputs:

- iNaturalist observations
- GBIF observations
- OSM green spaces, paths, roads, rail, lighting, amenities, water
- WorldCover
- EMC-BUILT impervious surface
- Sentinel-2 NDVI
- Landsat LST

Application observation inputs:

- Approved/non-rejected quick sightings
- Approved structured surveys and survey records
- Record flags and review state
- GPS accuracy
- Structured-survey effort metadata and habitat indicators

Current state:

- The R pipeline reads iNaturalist and GBIF files, plus
  `raw/supabase_observations.gpkg` when the Supabase export has run.
- The Supabase-to-R approved observation export is implemented
  (`pipeline_observations_export` +
  `pipeline/01_ingest/export_supabase_observations.R`) and gated behind
  `SUPABASE_OBSERVATIONS_ENABLED`.

Import contract:

```text
approved_observations.gpkg or approved_observations.csv
  observation_id
  observation_source: inat | gbif | quick_sighting | structured_survey
  taxon_name
  taxon_group
  observed_on
  geometry or lng/lat
  gps_accuracy_m
  cell_id, if already assigned
  survey_id, nullable
  survey_duration_seconds, nullable
  structured_effort_weight, nullable
  habitat_indicators, nullable JSON
  review_status
  has_pending_or_confirmed_flag
```

Only records eligible for analysis should enter the R calculations. Rejected
records and records with pending or confirmed quality flags are excluded.

### Stage Responsibilities

`pipeline/01_ingest/ingest.R`

- Downloads or reads raw external datasets
- Writes raw GPKG/raster inputs
- Does not compute final ecological metrics

`pipeline/02_spatial/spatial_base.R`

- Builds the whole-AOI 20 m hex grid and the green-space layer, phase-anchored on
  `HEX_GRID_ORIGIN` so per-tile grids stay in phase with it

`pipeline/02_habitat/habitat_model.R` (driving `02_habitat/process_tile.R`)

- Runs the tiled pass over `core_tiles.gpkg`
- Computes habitat features, stressor features, path length, and habitat quality
- Standardises iNaturalist, GBIF and approved Supabase observations, assigns them
  to cells, and applies `observation_weight` (structured survey 3, quick
  sighting 0)
- Computes raw richness, effort summaries, taxonomic summaries, temporal bias,
  `survey_effort_units` and `effort_corrected_richness`
- Marks cells under `MIN_PATH_M` of neighbourhood path as unsampled instead of
  zero-valued
- Writes `grid_habitat.gpkg` and `habitat_quality.tif`

`pipeline/03_observations/observation_layer.R`

- Enforces the observed-richness contract: a sampled cell must carry
  `survey_effort_units` and `observed_richness`; an unsampled cell must carry
  neither. Violations stop the run.
- Writes `grid_observations.gpkg` and `cell_taxa.json`

`pipeline/04_connectivity/connectivity.R`

- Builds the hex adjacency graph, weighted by habitat resistance (vegetation
  discounted by built cover), keeping only cells above the permeability floor
- Computes dispersal-limited betweenness and derives `corridor_importance` from
  it as a percentile rank; `connectivity_score` and `node_importance` are views
  on the same two values
- Builds a **second** graph over every cell, walls included at maximum
  resistance (`build_routing_graph()`), used only for corridor routing — the
  betweenness graph is too fragmented to route across, having dropped the walls
- Derives the simplified network in `network_derive.R`: habitat-core nodes, then
  least-cost corridors between neighbouring nodes, scored and pruned (see
  docs/methodology.md section 9a)
- Caches in two steps: `connectivity_graph_up_to_date()` covers the expensive
  betweenness half, `connectivity_up_to_date()` adds the network's own tuning, so
  retuning `NET_*` rebuilds the network without recomputing betweenness
- Does **not** compute `fragmentation_index`, `edge_density`, `patch_isolation`
  or `patch_size_distribution` — these remain `NA` placeholders (see
  docs/methodology.md section 9)

`pipeline/05_residuals/residuals.R`

- Computes expected richness (species-area law at hex area)
- Computes ecological residual (expected − observed) and its normalisations
- Computes Nature Gap score (and the legacy `impact_score`)
- Computes intervention score, rank, and counterfactual connectivity estimate

`pipeline/05_patch/patch_aggregation.R`

- Aggregates cell outputs to green-space patches by cell/patch overlap
- Computes patch expected richness from total patch area with the same
  species-area law (see docs/methodology.md section 6.2)

`pipeline/06_export/export.R`

- Generates `hexgrid.pmtiles`
- Generates `cell_attributes.geojson` for PostGIS import
- Generates `parks.geojson`, `park-stats.json`, `top_interventions.json`,
  `city_layer_stats.json`, the `cell-details` shards and their manifest, and the
  connectivity network edge/node GeoJSON
- Writes the versioned `manifest.json` and the city's `current.json`
- Prints the Supabase Storage upload target

## 7. Derived Metrics

Every derived metric has one source of truth: the R pipeline.

### `effort_corrected_richness`

Source: `pipeline/02_habitat/process_tile.R` (`finish_citywide_metrics()`),
contract-checked by `pipeline/03_observations/observation_layer.R`

```text
species_richness / log(1 + path_local_m)
```

Cells with under `MIN_PATH_M` (50 m) of pedestrian path within `PATH_RADIUS_M`
(40 m) of the centroid are `is_unsampled = true` and have `NA` corrected
richness for residual inference.

### `expected_richness`

Source: `pipeline/05_residuals/residuals.R`

```text
SPECIES_AREA_C * (CELL_SIZE ^ 2) ^ SPECIES_AREA_Z * (
  0.65 * habitat_quality
  + 0.20 * corridor_importance
  + 0.15 * accessibility_component
)
```

`SPECIES_AREA_C = 12`, `SPECIES_AREA_Z = 0.25`, so the area term is a constant
`≈ 53.7` per 20 m hex. `MAX_EXPECTED_RICHNESS` (350) is exported for
transparency but no longer scales this. Patch-level expected richness uses the
same law with total patch area (`pipeline/05_patch/patch_aggregation.R`).

### `ecological_residual`

Source: `pipeline/05_residuals/residuals.R`

```text
expected_richness - effort_corrected_richness
```

- **Positive** residual: below expectation, ecosystem under pressure
- **Negative** residual: above expectation, ecological surplus
- Unsampled cells: `NA`

The residual is a gap, not a surplus: expected minus observed. The patch-level
residual in `pipeline/05_patch/patch_aggregation.R` uses the same orientation.

### `nature_gap_score`

Source: `pipeline/05_residuals/residuals.R`

Current implementation:

```text
bio_residual_norm = clamp(ecological_residual / max_abs_residual, -1, 1)

nature_gap_score =
  (
    0.50 * bio_residual_norm +
    0.30 * (1 - habitat_quality) +
    0.20 * (1 - corridor_importance)
  ) * 100
```

- **Positive** Nature Gap score: ecosystem under pressure
- **Negative** Nature Gap score: ecological surplus
- Range `[-50, +100]`

Band edges for status/colour live in `SCORE_THRESHOLDS` (`src/lib/config.ts`)
and are documented in docs/methodology.md section 8.

`impact_score` (`round(bio_residual_norm * 50)`) is still exported as a legacy
field carrying the biodiversity term alone. Do not treat `nature_gap_score`,
`impact_score` and `ecological_residual` as the same metric.

### `intervention_score`

Source: `pipeline/05_residuals/residuals.R`

Current implementation:

```text
underperformance = max(0, ecological_residual)

(underperformance * 0.5) * (corridor_importance * 0.5)
```

The residual is floored at zero first, so an over-performing cell scores 0
rather than negative. This replaces the older weighted-sum formula.
Documentation and UI copy should refer to this implementation until the model is
intentionally changed.

### Detail-panel fields

Fields such as `habitat_potential`, `observer_effort_score`, `taxonomic_diversity`,
`pressures`, `species`, and `interventions` are exported by
`pipeline/06_export/export.R` into `cell_attributes.geojson` and imported into
PostgreSQL. Frontend derivations in `src/lib/cell-detail.ts` are local/demo
fallbacks only and are not authoritative science.

## 8. PMTiles Workflow

PMTiles are the canonical map-rendering artefact for the 20 m hex grid.

### Generation

`pipeline/06_export/export.R` generates `hexgrid.pmtiles` from the R residual
grid using `tippecanoe`.

Required properties are declared once, in `PMTILES_REQUIRED_FIELDS`
(`pipeline/06_export/export.R`), and validated at export time — that list is
authoritative and currently holds 32 fields: identity (`cellId`, `parkId`,
`parkName`), scores (`natureGapScore`, `impactScore`, `expectedRichness`,
`ecologicalResidual`, `ecologicalResidualNormalized`, `interventionRank`),
context (`habitatQuality`, `observedRichness`, `corridorImportance`,
`betweennessCentrality`, `treeCover`, `canopyHeightIdx`, `heatExposure`,
`meanLst`, `lstIdx`, `landUseGreen`, `landUseClass`, `nObs`) and the
render-normalised companions MapLibre styles directly (`natureGapScoreNorm`,
`residualNorm`, `expectedNorm`, `habitatQualityNorm`, `corridorImportanceNorm`,
`betweennessNorm`, `treeCoverNorm`, `ndviNorm`, `lstNorm`, `disturbanceNorm`,
`interventionRankNorm`). See docs/methodology.md section 11.

Required vector tile source-layer:

```text
hexgrid
```

PMTiles must remain lightweight. Do not include large detail-panel JSON,
species lists, pressure arrays, or intervention descriptions. Those belong in
Storage `cell-details` shards.

### Storage

Current implemented path:

```text
pipeline-export/<CITY_ID>/hexgrid.pmtiles
```

Recommended scalable path:

```text
pipeline-export/<CITY_ID>/<DATA_VERSION>/hexgrid.pmtiles
pipeline-export/<CITY_ID>/<DATA_VERSION>/parks.geojson.gz
pipeline-export/<CITY_ID>/<DATA_VERSION>/park-stats.json
pipeline-export/<CITY_ID>/<DATA_VERSION>/cell_attributes.geojson.gz
pipeline-export/<CITY_ID>/<DATA_VERSION>/cell-details.manifest.json
pipeline-export/<CITY_ID>/<DATA_VERSION>/cell-details/cell-details-*.json.gz
pipeline-export/<CITY_ID>/<DATA_VERSION>/top_interventions.json
pipeline-export/<CITY_ID>/current.json
```

GeoJSON products and cell-detail shards are gzipped; `hexgrid.pmtiles` is
already internally compressed and manifests stay plain. See
[Compression](data-contract.md#compression).

`current.json` should identify the active immutable version:

```json
{
  "cityId": "yokohama-honmoku",
  "dataVersion": "20260627T120000Z",
  "hexgrid": "20260627T120000Z/hexgrid.pmtiles",
  "sourceLayer": "hexgrid",
  "generatedAt": "2026-06-27T12:00:00Z"
}
```

The current frontend uses configured dataset IDs in `src/lib/config.ts` and
constructs public Storage URLs in `src/lib/pmtiles-storage.ts`. Moving to
`current.json` is the smallest scalable discovery improvement.

### MapLibre Discovery And Rendering

Current rendering:

- `MapView` registers the PMTiles protocol
- `listHexPmtilesDatasets()` builds public Storage URLs
- MapLibre adds vector sources with `pmtiles://<public-url>`
- Hex fill layers use source-layer `hexgrid`

MapLibre may style, filter, show popups, and pass `cellId` to the detail
lookup. It must not calculate ecological metrics.

### Update Workflow

1. Run the R pipeline for a city.
2. Validate `hexgrid.pmtiles` exists, is non-empty, and contains source-layer `hexgrid`.
3. Upload `hexgrid.pmtiles`, `parks.geojson`, `park-stats.json`, `cell-details` shards, and supporting JSON to Supabase Storage.
4. Promote the version by updating `<CITY_ID>/current.json`.
5. Optionally register/import pipeline metadata into PostgreSQL for legacy/operator workflows.
6. Smoke test MapLibre rendering and click-time Storage detail lookup.

## 9. Frontend Contract

The frontend is a presentation and interaction layer.

Allowed:

- PMTiles streaming
- MapLibre style expressions over precomputed properties
- Visibility toggles
- Selection and hover state
- Supabase lookup by `cell_id`
- Local demo fallbacks when Supabase is not configured

Not allowed:

- Computing expected richness
- Computing effort correction
- Computing ecological residual
- Computing intervention ranking
- Treating PMTiles properties as the full analytical record

Current live point overlays are fetched from Supabase tables and rendered as
GeoJSON sources. This is acceptable because those overlays are transactional
records, not ecological model outputs.

## 10. Supabase Storage And Fallbacks

Current Storage bucket:

```text
pipeline-export
```

Current photo bucket:

```text
citizen-photos
```

Current code supports Supabase Storage JSON loading and PMTiles URL construction.
The previous public fallback path `public/pipeline/<CITY_ID>` is no longer a
complete production contract. Public assets may remain as local/demo fixtures,
but they are not the canonical production flow.

## 10.1 Complete Data Pipeline Contract

Canonical production flow:

```text
Raw spatial data + approved Supabase observations
↓
R pipeline
↓
Versioned pipeline products
↓
PostgreSQL import and active dataset promotion
↓
Supabase Storage upload
↓
Frontend manifest discovery
↓
MapLibre rendering + backend detail lookup
```

The R pipeline is the only producer of ecological outputs. Supabase Storage is
the published frontend data plane: PMTiles carry lightweight render/click
properties, Storage JSON carries heavy detail payloads, and MapLibre performs
presentation, filtering, and interaction only.

## 11. Scalability Requirements

The architecture should support multiple cities, countries, millions of
observations, and repeated yearly or seasonal updates.

Implemented scale controls:

- Add explicit `city_id`, `dataset_id`, and `generated_at` to pipeline outputs
  and database imports.
- Keep immutable Storage versions and promote an active version through a
  manifest or database setting.
- Keep PostgreSQL imports optional for pipeline products that are already
  published through Storage.
- Add observation indexes for `(cell_id, timestamp)`, `(user_id, timestamp)`,
  and duplicate-detection lookups.
- Keep PMTiles as viewport-streamed rendering products.
- Keep heavy detail payloads in Storage shards, not PMTiles.

Do not introduce another analytical grid. Do not add frontend or SQL ecological
recalculation to solve scale problems.

## 12. Implemented, And Still Open

Implemented (previously listed here as gaps):

- Supabase approved observations are exported to R through
  `pipeline_observations_export` and
  `pipeline/01_ingest/export_supabase_observations.R`, gated on
  `SUPABASE_OBSERVATIONS_ENABLED`.
- Structured-survey weighting is connected to those exports through the R
  observation source contract (structured survey 3, quick sighting 0).
- PMTiles generation and Storage discovery use versioned `manifest.json` and
  stable `current.json` pointers.
- `conservation_actions` is the single action table; the frontend reads it
  directly and no `recommended_actions` reference remains.
- `city_layer_stats` exists (migration `20260628120000_per_city_normalisation`)
  and carries the per-metric percentile bounds the legends stretch to.
- `cell_attributes` has city/version metadata for optional legacy imports;
  historical versions live in `pipeline_cell_attributes`.

Still open:

- `global_stats`, `wards`, and `community_events` are queried by
  `src/lib/data.ts` but are not present in current migrations, so those reads
  return empty.
- `fragmentation_index`, `node_importance`, `edge_density`, `patch_isolation`
  and `patch_size_distribution` are placeholder `NA` fields (see
  docs/methodology.md section 9).
- Named barriers (a specific road or railway interrupting a corridor) need a
  roads/rail loader at the connectivity stage; only bottleneck sections exist.
- Numeric constraints on detail fields are weaker than the model contract.

## 13. Implementation Roadmap

Items 1–4 are done: the documentation describes the current PMTiles/Storage
flow, dataset discovery runs through `current.json` + `manifest.json`, the
PostgreSQL import contract is `import_pipeline_dataset()` /
`promote_pipeline_dataset()`, and approved app observations reach R through
`pipeline_observations_export`. The remaining items:

5. Multi-city and versioned cell attributes
   - Purpose: scale beyond one active city/run
   - Affected files: Supabase migrations, R export/import, `src/lib/cell-detail.ts`
   - Dependencies: import contract
   - Difficulty: medium
   - Breaking: potentially, unless introduced with defaults and compatibility views

6. Missing content tables
   - Purpose: back `global_stats`, `wards`, and `community_events` with real
     migrations, or remove the frontend reads
   - Affected files: Supabase migrations or `src/lib/data.ts` consumers
   - Dependencies: product decision on whether those surfaces stay
   - Difficulty: medium
   - Breaking: no

7. Constraints and indexes
   - Purpose: improve data integrity and query performance
   - Affected files: Supabase migrations
   - Dependencies: city/version model
   - Difficulty: medium
   - Breaking: no, after data precheck

8. Validation scripts
   - Purpose: verify PMTiles source-layer/properties and `cell_attributes` parity
   - Affected files: pipeline validation scripts or tests
   - Dependencies: PMTiles and import contracts
   - Difficulty: medium
   - Breaking: no
