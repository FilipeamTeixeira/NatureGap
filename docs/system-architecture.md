# NatureGap System Architecture

## 1. End-To-End Overview

```text
User
  -> Next.js UI
  -> Supabase Auth session
  -> Supabase Edge Function or Supabase client query
  -> Postgres/PostGIS tables
  -> R pipeline reads external biodiversity/environment data separately
  -> R computes 20m hex outputs
  -> Outputs go to:
       - Postgres: cell_attributes
       - Supabase Storage: pipeline-export/<CITY_ID>/*
       - public fallback assets: public/pipeline/<CITY_ID>/*
  -> Frontend loads Storage/public GeoJSON + JSON
  -> MapLibre renders hex layers, survey layers, sightings, and points
```

### Main Flow

1. Users open the Next.js App Router frontend.
2. Static ecological layers are loaded from Supabase Storage bucket `pipeline-export`, with fallback to `public/pipeline/yokohama-honmoku`.
3. Users authenticate through Supabase Auth via `/login`.
4. Authenticated users interact with citizen-science UI.
5. Citizen-science writes go through Supabase Edge Functions:
   - `submit-quick-sighting`
   - `start-structured-survey`
   - `submit-structured-survey`
   - `add-survey-record`
   - `submit-suggestion`
   - `flag-record`
6. Edge Functions validate input, check roles, and write to Postgres/PostGIS.
7. Postgres triggers assign observations to the nearest canonical 20m hex cell using `cell_attributes`.
8. R pipeline independently ingests iNaturalist, GBIF, OSM, WorldCover, EMC-BUILT, Sentinel-2, Landsat.
9. R produces processed grid datasets and frontend export artefacts.
10. Frontend renders:
    - precomputed 20m hex grid and metrics from Storage/public files
    - live citizen-science points from Supabase tables

## 2. Database Layer

### `user_roles`

Purpose: application role mapping for Supabase Auth users.

Relationships:

- `user_id -> auth.users.id`
- `granted_by -> auth.users.id`

Spatial role: none.

Analysis/UI use:

- Used by RLS helper functions: `is_admin`, `is_surveyor`, `is_taxonomist`, `is_contributor`
- Used by frontend to decide available citizen-science UI
- Used by Edge Functions for backend role checks

Profiles:

- No `profiles` table exists in current migrations.
- Role state lives in `user_roles`.

### `species_reference`

Purpose: taxonomic authority/reference table.

Relationships:

- Referenced by `quick_sightings.species_id`
- Referenced by `survey_records.species_id`

Spatial role:

- No geometry.
- Contains `region_plausibility` JSONB for range/season plausibility checks.

Analysis/UI use:

- UI uses it for species selection.
- Edge Functions use it to validate taxon group and first-photo rules.
- Taxonomists/admins can edit it.

### `survey_points`

Purpose: approved/pending/rejected locations where structured surveys can happen.

Relationships:

- `suggested_by -> auth.users.id`
- `approved_by -> auth.users.id`
- Referenced by `structured_surveys.survey_point_id`

Spatial role:

- `geometry geometry(Point, 4326)`
- Used to assign structured surveys to nearest 20m hex cell.

Analysis/UI use:

- UI displays approved survey points on the map.
- Structured surveys can only start at approved points.

### `quick_sightings`

Purpose: opportunistic citizen observations, presence-only, lower analytical weight.

Relationships:

- `user_id -> auth.users.id`
- `species_id -> species_reference.id`
- `cell_id -> cell_attributes.cell_id`

Spatial role:

- Raw GPS point stored in `geometry geometry(Point, 4326)`
- `cell_id` stores nearest canonical 20m hex.

Analysis/UI use:

- UI displays quick sightings.
- Analysis views exclude rejected/flagged records.
- Backend flags low GPS accuracy and plausibility problems.

### `structured_surveys`

Purpose: protocol-based surveys with timing and habitat indicators.

Relationships:

- `survey_point_id -> survey_points.id`
- `user_id -> auth.users.id`
- `cell_id -> cell_attributes.cell_id`

Spatial role:

- No direct geometry column.
- Spatial location inherited from `survey_points.geometry`.
- Trigger assigns nearest 20m hex cell.

Analysis/UI use:

- UI starts/stops timer and submits habitat indicators.
- Higher statistical weight concept exists in pipeline design; current external R observation pipeline uses GBIF/iNat files and has fields for structured survey weighting.

### `survey_records`

Purpose: species/count records inside structured surveys.

Relationships:

- `survey_id -> structured_surveys.id`
- `species_id -> species_reference.id`

Spatial role:

- No direct geometry.
- Spatial context inherited through parent survey.

Analysis/UI use:

- Multiple records per survey.
- Used by Edge Functions for duplicate/plausibility flags.

### `cell_attributes`

Purpose: canonical 20m hex grid attributes and model outputs.

Relationships:

- Referenced by `quick_sightings.cell_id`
- Referenced by `structured_surveys.cell_id`

Spatial role:

- `geometry geometry(Polygon, 4326)`
- Canonical persisted spatial key for the app.

Analysis/UI use:

- Stores per-cell metrics:
  - expected richness
  - effort-corrected richness
  - residual
  - stressors
  - connectivity
  - ranking
- Required before observation ingestion works, because triggers find nearest cells from this table.

### `conservation_actions`

Purpose: reference table for action types.

Relationships: none.

Spatial role: none.

Analysis/UI use:

- Current frontend `take-action` page uses `recommended_actions`, not this table.
- `conservation_actions` exists as domain/reference data for admin-managed actions.

### `flags`

Purpose: auditable moderation/quality-control flags.

Relationships:

- `flagged_by -> auth.users.id`
- `reviewed_by -> auth.users.id`
- `record_type` + `record_id` validated by trigger against target tables.

Spatial role: none directly.

Analysis/UI use:

- Analysis views exclude records with pending/confirmed flags.
- Admins/taxonomists can review flags.

### `suggestions`

Purpose: unified suggestion queue.

Relationships:

- `submitted_by -> auth.users.id`
- `reviewed_by -> auth.users.id`

Spatial role:

- Can represent survey point suggestions via JSON payload, but table itself has no geometry.

Analysis/UI use:

- Backend queue for suggested species/actions/survey points/local notes/habitat photos.
- Admin reviews lifecycle.

## 3. Spatial System

### Canonical Grid

```text
R pipeline:
  sf::st_make_grid(area, cellsize = 20, square = FALSE)
      -> 20m hex polygons
      -> cell_id
      -> model metrics
      -> cell_attributes / hexgrid.geojson / cells.json
```

Current grid facts:

- Resolution: 20m
- Shape: hexagons
- R CRS during processing: `EPSG:6674`
- Export/PostGIS display CRS: `EPSG:4326`
- Database geometry: `cell_attributes.geometry geometry(Polygon, 4326)`

### Observation Assignment

Database assignment:

- `find_cell_id_for_point(lng, lat)`:
  - builds WGS84 point
  - compares it to `st_centroid(cell_attributes.geometry)`
  - transforms both to EPSG:3857 for distance ordering
  - returns nearest `cell_id`

- `find_cell_id_for_survey_point(point_id)`:
  - reads `survey_points.geometry`
  - finds nearest `cell_attributes` centroid
  - returns nearest `cell_id`

Triggers:

- `quick_sightings_assign_cell_id`
- `structured_surveys_assign_cell_id`

R assignment:

- External iNat/GBIF observations are snapped to nearest 20m hex centroid in `pipeline/03_observations/observation_layer.R`.
- Raw observation geometry is preserved in source GPKGs.

### Raster To Vector

R uses:

- `terra::rast`
- `terra::extract`
- `terra::project`
- `terra::crop`
- `sf::st_make_grid`
- `sf::st_intersection`
- `sf::st_join`

Raster sources are projected/extracted into the 20m hex grid:

- WorldCover -> class fractions per cell
- EMC-BUILT -> impervious fraction
- Sentinel-2 NDVI -> mean NDVI per cell
- Landsat LST -> heat rank per cell
- Habitat raster output -> `habitat_quality.tif`

### Connectivity Graph

In `pipeline/04_connectivity/connectivity.R`:

```text
20m hex centroids
  -> neighbours within CELL_SIZE * 1.15
  -> igraph graph
  -> edge weights from habitat resistance
  -> betweenness centrality
  -> corridor_importance
  -> fragmentation_index
  -> connectivity_score
```

Packages used:

- `sf`
- `terra`
- `igraph`
- `landscapemetrics`
- optional `gdistance` check exists, but graph computation is currently igraph-based.

## 4. R Pipeline

### Configuration

File: `pipeline/config.R`

Defines:

- `CITY_ID = yokohama-honmoku`
- BBOX
- CRS
- `CELL_SIZE = 20`
- input raster paths
- raw/processed/export paths
- output filenames

### Stage 01: Ingestion

File: `pipeline/01_ingest/ingest.R`

Inputs:

- iNaturalist API
- GBIF API
- OSM Overpass
- WorldCover raster
- EMC-BUILT raster
- Sentinel-2 NDVI
- Landsat LST

Outputs:

- `raw/inat_observations.gpkg`
- `raw/gbif_observations.gpkg`
- `raw/osm_green_spaces.gpkg`
- `raw/osm_paths.gpkg`
- `raw/osm_roads.gpkg`
- `raw/osm_rail.gpkg`
- `raw/osm_street_lamps.gpkg`
- `raw/osm_lit_roads.gpkg`
- `raw/osm_amenities.gpkg`
- `raw/osm_water.gpkg`
- `raw/landcover.tif`
- `raw/impervious.tif`
- `raw/ndvi.tif`
- `raw/lst.tif`

Dependencies:

- `sf`
- `terra`
- `rgbif`
- `osmdata`
- `jsonlite`
- `tidyverse`

### Stage 02: Habitat / Stressors

File: `pipeline/02_habitat/habitat_model.R`

Inputs:

- raw rasters
- OSM layers

Main computations:

- WorldCover fractions
- impervious fraction
- OSM green fraction
- pedestrian path length
- NDVI mean
- LST rank / heat exposure
- road/rail noise proxy
- light pollution proxy
- disturbance index
- water proximity
- habitat quality

Outputs:

- `processed/grid_habitat.gpkg`
- `processed/habitat_quality.tif`

### Stage 03: Observation Layer

File: `pipeline/03_observations/observation_layer.R`

Inputs:

- `raw/inat_observations.gpkg`
- `raw/gbif_observations.gpkg`
- `processed/grid_habitat.gpkg`

Main computations:

- standardise observations
- snap observations to nearest 20m hex centroid
- species richness per cell
- observation effort summaries
- weekend-only temporal bias flag
- Shannon diversity
- taxon group counts
- `effort_corrected_richness = raw_species_count / log(1 + path_km)`
- cells with `path_km <= 0` marked unsampled

Outputs:

- `processed/grid_observations.gpkg`
- `processed/cell_taxa.json`

### Stage 04: Connectivity

File: `pipeline/04_connectivity/connectivity.R`

Inputs:

- `processed/grid_habitat.gpkg`

Main computations:

- habitat cell threshold
- hex adjacency graph
- edge resistance from habitat quality
- patch IDs
- edge density
- patch isolation
- patch size distribution
- betweenness centrality
- corridor importance
- fragmentation index
- node importance
- connectivity score

Output:

- `processed/grid_connectivity.gpkg`

### Stage 05: Residuals / Ranking

File: `pipeline/05_residuals/residuals.R`

Inputs:

- `grid_habitat.gpkg`
- `grid_observations.gpkg`
- `grid_connectivity.gpkg`

Main computations:

- expected richness
- ecological residual
- impact score
- intervention score
- intervention rank
- top 20 counterfactual connectivity gain
- primary intervention action

Outputs:

- `processed/grid_residuals.gpkg`
- `processed/cell_attributes.gpkg`
- `processed/top_interventions.csv`

### Stage 06: Export

File: `pipeline/06_export/export.R`

Inputs:

- `grid_residuals.gpkg`
- `cell_attributes.gpkg`
- `top_interventions.csv`
- `cell_taxa.json`
- OSM green spaces

Outputs:

- `export/hexgrid.geojson`
- `export/cell_attributes.geojson`
- `export/parks.geojson`
- `export/cells.json`
- `export/cells.manifest.json`
- chunked `cells-part-*.json` when needed
- `export/park-stats.json`
- `export/top_interventions.json`

Purpose:

- Convert modelling outputs into frontend-ready JSON/GeoJSON.
- Chunk large files around Supabase Storage size limits.

## 5. Frontend Architecture

### App Router

Main pages:

- `src/app/page.tsx`: main map + citizen science UI
- `src/app/login/page.tsx`: Supabase email/password auth
- `src/app/take-action/page.tsx`
- `src/app/community/page.tsx`
- `src/app/about/page.tsx`

Shared layout:

- `src/app/layout.tsx`
- `src/components/layout/Navbar.tsx`

### Supabase Client

File: `src/lib/supabase.ts`

- Creates browser Supabase client if env vars exist.
- Returns `null` fallback when env is absent.

Env vars:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- optional `NEXT_PUBLIC_CITIZEN_PHOTO_BUCKET`

### Map Rendering

File: `src/components/map/MapView.tsx`

Uses:

- `maplibre-gl`
- GeoJSON sources:
  - `hexgrid`
  - `parks`
  - `survey-points`
  - `quick-sightings`
  - `structured-surveys`
  - `ward-labels`

Hex overlays are multiple MapLibre fill layers over one GeoJSON source.

Layer styles live in:

- `src/lib/layer-styles.ts`

Rendered overlays include:

- impact
- expected richness
- ecological residual
- intervention rank
- habitat quality
- tree cover
- observed biodiversity
- connectivity
- heat exposure
- land use
- cell grid
- survey points
- quick sightings
- structured surveys

### Frontend Data Loading

Pipeline files:

- `src/lib/storage-fetch.ts` loads from Supabase Storage bucket `pipeline-export`.
- Fallback is `/public/pipeline/<CITY_ID>/`.
- Manifest/chunk support exists.

Cell stats:

- `src/lib/park-data.ts`
- Loads `cells.json`, `cells.manifest.json`, `park-stats.json`.

Hex grid:

- `src/lib/hex-grid.ts`
- Loads `hexgrid.geojson`.
- Clips/filters to park polygons.
- Enriches features with `cells.json` stats.

Park polygons:

- `src/lib/green-spaces.ts`
- Loads `parks.geojson`.

Citizen science:

- `src/lib/citizen-science.ts`
- Fetches:
  - current role
  - species reference
  - survey points
  - quick sightings
  - structured surveys
- Invokes Edge Functions for writes.

## 6. Data Storage Strategy

### PostgreSQL/PostGIS

Stores transactional and canonical spatial data:

- users/roles
- observations
- structured surveys
- survey records
- species reference
- survey points
- suggestions
- flags
- conservation actions
- `cell_attributes`

Why Postgres:

- RLS
- auditability
- relational integrity
- PostGIS spatial functions
- Edge Function writes

### Supabase Storage

Bucket: `pipeline-export`

Stores frontend-ready static model artefacts:

```text
pipeline-export/yokohama-honmoku/
  hexgrid.geojson
  parks.geojson
  park-stats.json
  cells.json
  cells.manifest.json
  cells-part-*.json
  cell_attributes.geojson
  top_interventions.json
  PMTiles artefacts if produced/uploaded
```

Bucket: `citizen-photos`

Stores user-uploaded photos:

- quick sighting photos
- invasive species habitat photos

### Public Fallback Assets

Folder:

```text
public/pipeline/yokohama-honmoku/
```

Used when Supabase Storage fetch fails or Supabase is not configured.

### PMTiles

README and project context reference PMTiles as manually uploaded artefacts. Current inspected MapLibre implementation renders hex layers from GeoJSON + JSON stats rather than directly loading PMTiles in `MapView.tsx`.

So the current system has two display concepts:

```text
Current frontend implementation:
  GeoJSON hexgrid + cells.json -> MapLibre GeoJSON source/layers

Documented/manual artefact workflow:
  PMTiles -> Supabase Storage -> map display, if wired/used externally
```

## 7. Derived Calculations

### `effort_corrected_richness`

File: `pipeline/03_observations/observation_layer.R`

Concept:

```text
raw_species_count / log(1 + path_km)
```

Depends on:

- distinct species count per cell
- pedestrian path length from OSM
- unsampled cells where path length is zero

Stored in:

- `grid_observations.gpkg`
- `grid_residuals.gpkg`
- `cell_attributes.gpkg`
- `cell_attributes.geojson`
- `cells.json`

Used by:

- residual calculation
- detail panel values
- pressure text

### `expected_richness`

File: `pipeline/05_residuals/residuals.R`

Formula structure:

```text
MAX_EXPECTED_RICHNESS * (
  0.65 * habitat_quality
  + 0.20 * corridor_importance
  + 0.15 * accessibility_component
)
```

Depends on:

- habitat quality
- corridor importance
- path accessibility

Stored in:

- `grid_residuals.gpkg`
- `cell_attributes`
- frontend JSON exports

Used by:

- residual layer
- expected richness layer
- detail panels

### `ecological_residual`

File: `pipeline/05_residuals/residuals.R`

Formula:

```text
expected_richness - effort_corrected_richness
```

Positive means observed richness is below expectation.

Stored in:

- `grid_residuals.gpkg`
- `cell_attributes`
- `cells.json`

Used by:

- impact score
- residual layer
- intervention score
- pressure explanations

### `heat_exposure`

File: `pipeline/02_habitat/habitat_model.R`

Derived from:

- Landsat LST raster
- per-cell mean LST
- percentile/rank style scaling

Stored in:

- `grid_habitat.gpkg`
- downstream processed GPKGs
- `cell_attributes`
- frontend layer property `heatExposure`

### `noise` / Noise Index

File: `pipeline/02_habitat/habitat_model.R`

Derived from:

- OSM road density
- road class weighting
- rail density/proximity components

Stored as:

- `noise` in pipeline outputs
- `noise` in `cell_attributes`

Frontend naming:

- Database/pipeline uses `noise`
- User-facing concept is noise index.

### `light_pollution`

File: `pipeline/02_habitat/habitat_model.R`

Derived from:

- OSM `highway=street_lamp`
- `lit=yes` road segments
- point/line density and distance weighting

Stored in:

- `grid_habitat.gpkg`
- `cell_attributes`

### `disturbance_index`

File: `pipeline/02_habitat/habitat_model.R`

Derived from:

- pedestrian path density
- OSM amenity proximity/density

Stored in:

- `grid_habitat.gpkg`
- `cell_attributes`

### `fragmentation_index`

File: `pipeline/04_connectivity/connectivity.R`

Derived from:

- habitat neighbour count
- edge density
- patch isolation
- patch size distribution

Stored in:

- `grid_connectivity.gpkg`
- `grid_residuals.gpkg`
- `cell_attributes`
- `cells.json` as `fragmentationIndex`

### `connectivity_score`

File: `pipeline/04_connectivity/connectivity.R`

Formula structure:

```text
0.60 * corridor_importance
+ 0.25 * node_importance
+ 0.15 * (1 - fragmentation_index)
```

Stored in:

- `grid_connectivity.gpkg`
- `cell_attributes`

### `intervention_score`

File: `pipeline/05_residuals/residuals.R`

Formula:

```text
(ecological_residual * 0.5) * (corridor_importance * 0.5)
```

Stored in:

- `grid_residuals.gpkg`
- `cell_attributes.gpkg`
- `top_interventions.csv`

Used by:

- intervention ranking
- top 20 counterfactual simulation
- exported intervention descriptions

## 8. Roles And Permissions

### Roles

```text
contributor
  -> quick sightings
  -> flags

surveyor
  -> structured surveys
  -> survey records
  -> suggestions
  -> survey points

taxonomist
  -> species reference
  -> species corrections
  -> flag review in backend support migration

admin
  -> full control via RLS/helpers
```

### Database Enforcement

RLS helpers:

- `current_app_role()`
- `has_app_role(role)`
- `is_admin()`
- `is_taxonomist()`
- `is_surveyor()`
- `is_contributor()`

RLS examples:

- contributors can insert quick sightings
- surveyors can insert structured surveys and survey records
- taxonomists/admins can edit species reference
- admins control approvals
- audit log visible only to admins
- cell attributes readable to authenticated users, writable by admins

### Backend Enforcement

Edge Functions call:

- `requireAuth(req)`
- `assertRole(role, allowedRoles)`

Examples:

- `submit-quick-sighting`: contributor
- `start-structured-survey`: surveyor
- `submit-structured-survey`: surveyor
- `add-survey-record`: surveyor
- `upsert-species-reference`: taxonomist
- `review-suggestion`: admin
- `review-flag`: admin/taxonomist

### Frontend Enforcement

The citizen-science panel checks role for UI availability:

- contributor/admin: quick sightings
- surveyor/admin: structured surveys
- unauthenticated users see sign-in prompt

Frontend role is advisory. Actual permission enforcement is RLS + Edge Functions.

## 9. Critical Dependencies And Hidden Coupling

### R Pipeline To Postgres Coupling

`cell_attributes.cell_id` is the core coupling point.

```text
R pipeline cell_id
  -> exported cell_attributes
  -> Postgres cell_attributes.cell_id
  -> quick_sightings.cell_id
  -> structured_surveys.cell_id
  -> frontend cells.json cellId
  -> MapLibre hexgrid feature properties
```

If cell IDs differ between R exports, Postgres imports, and frontend JSON, observation attribution and map enrichment diverge.

### R Pipeline To Frontend Coupling

Frontend expects specific JSON property names:

- `cellId`
- `parkId`
- `score`
- `color`
- `habitatQuality`
- `expectedRichness`
- `ecologicalResidual`
- `observedRichness`
- `corridorImportance`
- `treeCover`
- `heatExposure`
- `landUseGreen`

These are produced in `pipeline/06_export/export.R` and consumed by:

- `src/lib/hex-grid.ts`
- `src/lib/park-data.ts`
- `src/lib/layer-styles.ts`

### Duplicated Logic

Color/score thresholds exist in both systems:

- R export: `score_color()` in `pipeline/06_export/export.R`
- frontend config/styles:
  - `src/lib/config.ts`
  - `src/lib/layer-styles.ts`
  - utility color logic

Role logic exists in:

- SQL RLS helpers
- Edge Function `assertRole`
- frontend conditional UI

Spatial cell assignment exists in:

- Postgres functions for live observations
- R nearest-centroid assignment for external biodiversity observations

### Fallback Systems

Frontend data loading has fallbacks:

```text
Supabase Storage pipeline-export
  -> public/pipeline/<CITY_ID>
  -> bundled src/data/park-stats.json for park stats only
```

Supabase client also has a fallback:

- if env vars are missing, `supabase` is `null`
- UI/data loaders return empty/local fallback values

### Current Inconsistencies

- Migrations define `conservation_actions`, but frontend `take-action` reads `recommended_actions`.
- Frontend `data.ts` reads `global_stats`, `wards`, `community_events`, `recommended_actions`; these tables are not in the inspected migrations.
- README mentions PMTiles/COG/PostGIS upload, while current map implementation primarily uses GeoJSON/JSON files from Storage/public fallback.
- No `profiles` table exists; user identity beyond Auth is represented by `user_roles`.
- The R pipeline has alternate config files (`config_yokohama.R`, `config_yokohama_2.R`), but active pipeline scripts load `config.R`.

## 10. Mental Model Summary

```text
Transactional system:
  Supabase Auth
    -> user_roles
    -> Edge Functions
    -> Postgres/PostGIS observation tables
    -> RLS + audit + moderation

Analytical system:
  R pipeline
    -> external biodiversity/environment data
    -> 20m hex grid
    -> habitat + effort + residual + stressor + connectivity metrics
    -> cell_attributes + frontend export files

Presentation system:
  Next.js
    -> Supabase Storage/public JSON+GeoJSON
    -> Supabase live citizen-science queries
    -> MapLibre layers
    -> detail panels and citizen-science forms
```

The central architectural idea is that **20m hex cells are the shared spatial contract**. The database uses them for live observation attribution, the R pipeline uses them for all modelling, and the frontend uses them for rendering and interaction.
