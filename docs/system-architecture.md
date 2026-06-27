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
- `src/lib/data.ts`: live business-data reads for tables not yet covered by current migrations

R pipeline:

- `pipeline/config.R`: city, CRS, bbox, cell size, paths, constants
- `pipeline/01_ingest/ingest.R`: raw environmental and biodiversity ingest
- `pipeline/02_habitat/habitat_model.R`: habitat, stressor, and path-density features
- `pipeline/03_observations/observation_layer.R`: observation standardisation and effort correction
- `pipeline/04_connectivity/connectivity.R`: graph connectivity metrics
- `pipeline/05_residuals/residuals.R`: expected richness, residuals, intervention ranking
- `pipeline/06_export/export.R`: PMTiles, PostGIS import, and UI JSON exports

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

The current R pipeline contains a structured-survey weighting field, but the
approved Supabase observation export into R is not yet fully implemented. That
import contract is part of the pipeline contract below.

### `survey_records`

Species/count records inside structured surveys.

- `survey_id -> structured_surveys.id`
- `species_id -> species_reference.id`
- Spatial context comes through the parent survey

### `cell_attributes`

Canonical 20 m hex grid and R-computed cell outputs.

- `geometry geometry(Polygon, 4326)`
- Referenced by live observations and structured surveys
- Stores expected richness, effort-corrected richness, ecological residual,
  stressors, connectivity, ranking, detail-panel JSON fields, and timestamps
- Required before live observation assignment works

Versioning model:

- Historical R outputs are stored in `pipeline_cell_attributes` using
  `(city_id, dataset_id, cell_id)`.
- The app-compatible active projection remains `cell_attributes`.
- Active datasets are promoted through `promote_pipeline_dataset(...)`.
- Composite indexes cover city/dataset and city/rank lookups.

### `conservation_actions`

Reference table for admin-managed action types.

Current conflict:

- The frontend `take-action` page reads `recommended_actions`.
- Current migrations define `conservation_actions`.

Smallest correction:

- Either migrate the frontend to `conservation_actions`, or add and document
  `recommended_actions` as a separate content table. Do not keep both as
  overlapping sources of truth.

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
- Default city: `yokohama-honmoku`
- R local CRS for Yokohama: `EPSG:6674`
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

Current gap:

- The current R pipeline reads iNaturalist and GBIF files.
- The Supabase-to-R approved observation export is not yet implemented.

Required import contract:

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

`pipeline/02_habitat/habitat_model.R`

- Builds the 20 m grid
- Computes habitat features, stressor features, path length, and habitat quality
- Writes `grid_habitat.gpkg` and `habitat_quality.tif`

`pipeline/03_observations/observation_layer.R`

- Standardises observations
- Assigns observations to canonical cells
- Computes raw richness, effort summaries, taxonomic summaries, temporal bias,
  and `effort_corrected_richness`
- Marks pathless cells as unsampled instead of zero-valued
- Applies higher structured-survey weight once the Supabase import exists

`pipeline/04_connectivity/connectivity.R`

- Builds the hex adjacency graph
- Computes corridor importance, fragmentation, node importance, and connectivity score

`pipeline/05_residuals/residuals.R`

- Computes expected richness
- Computes ecological residual
- Computes impact score
- Computes intervention score, rank, and counterfactual connectivity estimate

`pipeline/06_export/export.R`

- Generates `hexgrid.pmtiles`
- Generates `cell_attributes.geojson` for PostGIS import
- Generates `parks.geojson`, `park-stats.json`, and `top_interventions.json`
- Prints the Supabase Storage upload target

## 7. Derived Metrics

Every derived metric has one source of truth: the R pipeline.

### `effort_corrected_richness`

Source: `pipeline/03_observations/observation_layer.R`

```text
species_richness / log(1 + path_km)
```

Cells with `path_km <= 0` are `is_unsampled = true` and have `NA` corrected
richness for residual inference.

### `expected_richness`

Source: `pipeline/05_residuals/residuals.R`

```text
MAX_EXPECTED_RICHNESS * (
  0.65 * habitat_quality
  + 0.20 * corridor_importance
  + 0.15 * accessibility_component
)
```

### `ecological_residual`

Source: `pipeline/05_residuals/residuals.R`

```text
expected_richness - effort_corrected_richness
```

- Positive residual: below expectation, habitat pressure
- Negative residual: above expectation, potential refuge
- Unsampled cells: `NA`

### `impact_score`

Source: `pipeline/05_residuals/residuals.R`

Current implementation scales and inverts ecological residual:

```text
impact_score = round(-ecological_residual / max_abs_residual * 50)
```

- Negative impact score: worse than expected
- Positive impact score: better than expected

Do not treat `impact_score` and `ecological_residual` as the same sign.

### `intervention_score`

Source: `pipeline/05_residuals/residuals.R`

Current implementation:

```text
(ecological_residual * 0.5) * (corridor_importance * 0.5)
```

This replaces the older weighted-sum formula. Documentation and UI copy should
refer to this implementation until the model is intentionally changed.

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

Required properties:

- `cellId`
- `parkId`
- `parkName`
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

Required vector tile source-layer:

```text
hexgrid
```

PMTiles must remain lightweight. Do not include large detail-panel JSON,
species lists, pressure arrays, or intervention descriptions. Those belong in
PostgreSQL `cell_attributes`.

### Storage

Current implemented path:

```text
pipeline-export/<CITY_ID>/hexgrid.pmtiles
```

Recommended scalable path:

```text
pipeline-export/<CITY_ID>/<DATA_VERSION>/hexgrid.pmtiles
pipeline-export/<CITY_ID>/<DATA_VERSION>/parks.geojson
pipeline-export/<CITY_ID>/<DATA_VERSION>/park-stats.json
pipeline-export/<CITY_ID>/<DATA_VERSION>/cell_attributes.geojson
pipeline-export/<CITY_ID>/<DATA_VERSION>/top_interventions.json
pipeline-export/<CITY_ID>/current.json
```

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
3. Import or upsert `cell_attributes.geojson` into PostgreSQL.
4. Upload `hexgrid.pmtiles`, `parks.geojson`, `park-stats.json`, and supporting JSON to Supabase Storage.
5. Validate PMTiles and PostgreSQL have matching `cellId` values for sampled cells.
6. Promote the version by updating the active manifest or configured dataset path.
7. Smoke test MapLibre rendering and click-time `cell_attributes` lookup.

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

The R pipeline is the only producer of ecological outputs. PostgreSQL validates
and stores those outputs, PMTiles remain rendering-only, and MapLibre performs
presentation, filtering, and interaction only.

## 11. Scalability Requirements

The architecture should support multiple cities, countries, millions of
observations, and repeated yearly or seasonal updates.

Implemented scale controls:

- Add explicit `city_id`, `dataset_id`, and `generated_at` to pipeline outputs
  and database imports.
- Keep immutable Storage versions and promote an active version through a
  manifest or database setting.
- Add current-run indexes for `cell_attributes`.
- Add observation indexes for `(cell_id, timestamp)`, `(user_id, timestamp)`,
  and duplicate-detection lookups.
- Keep PMTiles as viewport-streamed rendering products.
- Keep detail payloads in PostgreSQL, not PMTiles.

Do not introduce another analytical grid. Do not add frontend or SQL ecological
recalculation to solve scale problems.

## 12. Known Current Gaps

- Supabase approved observations are exported to R through
  `pipeline_observations_export` and
  `pipeline/01_ingest/export_supabase_observations.R`.
- Structured-survey weighting is connected to live Supabase exports through the
  R observation source contract.
- PMTiles generation and Storage discovery use versioned `manifest.json` and
  stable `current.json` pointers.
- `conservation_actions` and frontend `recommended_actions` are inconsistent.
- `global_stats`, `wards`, `community_events`, and `recommended_actions` are
  queried by frontend code but are not present in the inspected migrations.
- `cell_attributes` has city/version metadata; historical versions live in
  `pipeline_cell_attributes`.
- Numeric constraints on detail fields are weaker than the model contract.

## 13. Implementation Roadmap

1. Documentation alignment
   - Purpose: remove obsolete GeoJSON/cells render contract and document current PMTiles/PostGIS flow
   - Affected files: `docs/system-architecture.md`, `docs/data-contract.md`, `docs/methodology.md`
   - Dependencies: none
   - Difficulty: small
   - Breaking: no

2. PMTiles manifest
   - Purpose: replace hardcoded dataset discovery with active version discovery
   - Affected files: `pipeline/06_export/export.R`, `src/lib/pmtiles-storage.ts`, `src/lib/config.ts`
   - Dependencies: documentation alignment
   - Difficulty: medium
   - Breaking: no, if current paths remain as fallback

3. R-to-Postgres import contract
   - Purpose: make `cell_attributes` import repeatable and auditable
   - Affected files: pipeline export scripts, Supabase migration/import scripts
   - Dependencies: PMTiles manifest optional
   - Difficulty: medium
   - Breaking: no, if additive

4. Approved observation export for R
   - Purpose: include quick sightings and structured surveys in the analytical pipeline
   - Affected files: SQL view/export script, `pipeline/03_observations/observation_layer.R`
   - Dependencies: analysis eligibility rules
   - Difficulty: medium to large
   - Breaking: no

5. Multi-city and versioned cell attributes
   - Purpose: scale beyond one active city/run
   - Affected files: Supabase migrations, R export/import, `src/lib/cell-detail.ts`
   - Dependencies: import contract
   - Difficulty: medium
   - Breaking: potentially, unless introduced with defaults and compatibility views

6. Action table reconciliation
   - Purpose: remove duplicate action concepts
   - Affected files: migration or frontend action reads
   - Dependencies: product choice between `conservation_actions` and `recommended_actions`
   - Difficulty: medium
   - Breaking: no, if fallback remains

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
