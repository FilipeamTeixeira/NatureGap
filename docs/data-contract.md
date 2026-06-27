# Data Contract - R Pipeline, PMTiles, PostGIS, Frontend

This document defines the artefacts produced by `pipeline/06_export/export.R`
and consumed by Supabase Storage, PostgreSQL/PostGIS, and the Next.js frontend.

The production render path is PMTiles. Full analytical/detail values are stored
in PostgreSQL `cell_attributes`. GeoJSON exports are import/support artefacts,
not the canonical MapLibre hex rendering source.

## Output Location

Pipeline exports are written under the configured city export directory:

```text
pipeline/data/<CITY_ID>/export/
```

Current implemented upload target:

```text
pipeline-export/<CITY_ID>/
```

Recommended scalable upload target:

```text
pipeline-export/<CITY_ID>/<DATA_VERSION>/
pipeline-export/<CITY_ID>/current.json
```

`CITY_ID` must be stable. It is used in Storage paths and as the prefix for
exported cell IDs.

## `hexgrid.pmtiles`

Canonical 20 m hex rendering artefact for MapLibre.

Produced by:

- `pipeline/06_export/export.R`
- Source: `processed/grid_residuals.gpkg`
- Tool: `tippecanoe`

Required vector tile source-layer:

```text
hexgrid
```

Required feature properties:

```json
{
  "cellId": "yokohama-honmoku-123",
  "parkId": "honmoku-sancho",
  "parkName": "Honmoku Sancho Park",
  "impactScore": -14,
  "expectedRichness": 104.2,
  "ecologicalResidual": 28.3,
  "habitatQuality": 52,
  "observedRichness": 75.9,
  "corridorImportance": 71,
  "treeCover": 38,
  "heatExposure": 64,
  "landUseGreen": 45,
  "interventionRank": 8
}
```

Constraints:

- CRS: WGS-84 tile coordinates as produced by PMTiles/vector tiles.
- Source-layer name must be exactly `hexgrid`.
- `cellId` must match PostgreSQL `cell_attributes.cell_id`.
- Properties must stay lightweight.
- Do not include species arrays, pressures, intervention descriptions, or
  other detail-panel JSON in PMTiles.

Frontend consumers:

- `src/components/map/MapView.tsx`
- `src/lib/pmtiles-storage.ts`
- `src/lib/layer-styles.ts`

## `cell_attributes.geojson`

PostGIS import/support artefact for full per-cell values.

Produced by:

- `pipeline/06_export/export.R`
- Source: `processed/cell_attributes.gpkg` joined with detail fields from
  `processed/grid_residuals.gpkg`

Used for:

- Importing/upserting PostgreSQL `cell_attributes`
- Click-time detail lookup through `src/lib/cell-detail.ts`

Required properties include:

```json
{
  "cell_id": "yokohama-honmoku-123",
  "expected_richness": 104.2,
  "effort_corrected_richness": 75.9,
  "ecological_residual": -28.3,
  "nature_gap_score": -14,
  "impact_score": -14,
  "habitat_quality": 52,
  "habitat_quality_index": 0.52,
  "species_richness_raw": 18,
  "observed_richness": 75.9,
  "max_expected_richness": 350,
  "is_unsampled": false,
  "temporal_bias_flag": false,
  "path_km": 0.18,
  "n_obs": 41,
  "n_survey_dates": 5,
  "habitat_potential": "moderate",
  "observer_effort_score": 227.8,
  "taxonomic_diversity": 1.4,
  "corridor_importance": 0.71,
  "intervention_rank": 8,
  "heat_exposure": 0.64,
  "fragmentation": 0.84,
  "connectivity_score": 0.52,
  "tree_cover": 38,
  "land_use_green": 45,
  "species": [],
  "pressures": [],
  "interventions": []
}
```

Constraints:

- CRS: WGS-84, EPSG:4326.
- Geometry type: polygon.
- `cell_id` must be unique within a city/version.
- `cell_id` must match PMTiles `cellId`.
- Unsampled cells must preserve `is_unsampled = true` and use null/NA for
  residual inference fields where appropriate.
- JSON array fields should be valid arrays, not encoded free text.

Database import:

- Historical rows are stored in `pipeline_cell_attributes` keyed by
  `(city_id, dataset_id, cell_id)`.
- The current app-compatible projection remains `cell_attributes`, updated only
  by `import_pipeline_dataset(...)` / `promote_pipeline_dataset(...)`.
- `dataset_id` is the UTC run identifier in `YYYYMMDDTHHMMSSZ` format.

## `parks.geojson`

Vegetation polygon layer used for park-level click zones and park attribution.

Produced by:

- `pipeline/06_export/export.R`
- Source: `raw/osm_green_spaces.gpkg`, when available

Example:

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {
        "id": "honmoku-sancho",
        "name": "Honmoku Sancho Park",
        "nameJa": "Honmoku Sancho Park",
        "wardId": null
      },
      "geometry": {
        "type": "Polygon",
        "coordinates": [
          [[139.6566, 35.4228], [139.6598, 35.4221], [139.6566, 35.4228]]
        ]
      }
    }
  ]
}
```

Constraints:

- CRS: WGS-84, EPSG:4326.
- Rings must be closed.
- `id` must be stable because PMTiles `parkId` and `park-stats.json` refer to it.
- If OSM names cannot produce an ASCII slug, use a stable fallback ID.

Frontend consumer:

- `src/lib/green-spaces.ts`

## `park-stats.json`

Park or analysis-area aggregate statistics.

Produced by:

- `pipeline/06_export/export.R`
- Source: R-computed cell outputs aggregated by park ID

Example:

```json
{
  "honmoku-sancho": {
    "impactScore": -14,
    "habitatQuality": 52,
    "habitatQualityIndex": 0.52,
    "speciesRichnessRaw": 68,
    "observedRichness": 68,
    "effortCorrectedRichness": 68,
    "expectedRichness": 104,
    "maxExpectedRichness": 350,
    "ecologicalResidual": 36,
    "status": "worse",
    "habitatPotential": "moderate",
    "observerEffortScore": 2.3,
    "taxonomicDiversity": 1.9,
    "species": [
      { "type": "plant", "count": 27 },
      { "type": "bird", "count": 21 },
      { "type": "insect", "count": 13 },
      { "type": "mammal", "count": 5 },
      { "type": "fungi", "count": 2 }
    ],
    "corridorImportance": 71,
    "fragmentationIndex": 84,
    "pressures": ["Low survey effort"],
    "interventions": [
      {
        "id": "yokohama-honmoku-123-rank-8",
        "title": "Create or restore habitat corridor",
        "description": "Ranked #8 for intervention priority.",
        "impact": "medium",
        "category": "corridor"
      }
    ]
  }
}
```

Schema notes:

- `status`: `much-worse | worse | as-expected | better | much-better`
- `habitatPotential`: `low | moderate | high`
- `species[].type`: `plant | bird | insect | mammal | fungi`
- `interventions[].impact`: `high | medium | low`
- `interventions[].category`: `canopy | corridor | pollinator | water | ground`

Frontend validation:

- `src/lib/data-validation.ts`
- `src/lib/types.ts`

## `top_interventions.json`

Ranked intervention candidate export.

Produced by:

- `pipeline/06_export/export.R`
- Source: `processed/top_interventions.csv`

Use:

- Audit/debugging and future UI features
- Not required for MapLibre rendering
- Not the source of click-time detail once interventions are imported into
  `cell_attributes`

## Storage Manifest Contract

Each city publishes immutable versioned products and a stable active pointer:

```json
{
  "cityId": "yokohama-honmoku",
  "dataVersion": "20260627T120000Z",
  "generatedAt": "2026-06-27T12:00:00Z",
  "sourceLayer": "hexgrid",
  "files": {
    "hexgrid": "20260627T120000Z/hexgrid.pmtiles",
    "parks": "20260627T120000Z/parks.geojson",
    "parkStats": "20260627T120000Z/park-stats.json",
    "cellAttributes": "20260627T120000Z/cell_attributes.geojson",
    "topInterventions": "20260627T120000Z/top_interventions.json"
  }
}
```

The frontend discovers active datasets by listing city folders, reading
`current.json`, then resolving products through the versioned `manifest.json`.

## Exported Products

| Product | Producer | Consumer | Contract |
| --- | --- | --- | --- |
| `hexgrid.pmtiles` | `pipeline/06_export/export.R` | MapLibre | Rendering only; source-layer `hexgrid`; required lightweight render fields only |
| `parks.geojson` | `pipeline/06_export/export.R` | Storage + PostgreSQL import | WGS84 polygons, stable `id`, no ecological metrics |
| `cell_attributes.geojson` | `pipeline/06_export/export.R` | PostgreSQL import | Authoritative ecological cell outputs with `city_id`, `dataset_id`, `generated_at` |
| `park-stats.json` | `pipeline/06_export/export.R` | Frontend detail data | UI statistics generated by R |
| `top_interventions.json` | `pipeline/06_export/export.R` | Audit/debug | Ranked R output, not required for rendering |
| `manifest.json` | `pipeline/06_export/export.R` | Import + frontend discovery | Product paths, counts, source-layer, render fields, database contract |
| `current.json` | `pipeline/06_export/export.R` | Frontend discovery | Stable pointer to the active immutable version |

## PostgreSQL Import Contract

`pipeline/07_import/import_to_postgres.R` reads the versioned manifest and calls:

```sql
public.import_pipeline_dataset(
  city_id,
  dataset_id,
  generated_at,
  storage_prefix,
  manifest_path,
  source_layer,
  cell_attributes_geojson,
  green_spaces_geojson,
  activate
)
```

The SQL function:

- validates `dataset_id` format;
- validates FeatureCollection shape;
- rejects missing geometries;
- rejects missing or duplicate `cell_id` values;
- rejects missing or duplicate green-space IDs;
- upserts `pipeline_datasets`;
- upserts immutable `pipeline_cell_attributes`;
- upserts immutable `pipeline_green_spaces`;
- promotes active `cell_attributes` and `green_spaces` when `activate = true`.

Re-running the same import for the same `(city_id, dataset_id)` is repeatable:
rows are updated in place and no duplicates are created.

## Observation Import Contract For R

Approved app observations must be exported into R before citizen science can
affect model outputs.

Required logical fields:

| Field | Description |
| --- | --- |
| `observation_id` | Stable source record ID |
| `observation_source` | `inat`, `gbif`, `quick_sighting`, or `structured_survey` |
| `taxon_name` | Scientific or reference taxon name used for richness |
| `taxon_group` | App taxon group |
| `observed_on` | Observation date |
| `geometry` or `lng`/`lat` | Raw point location |
| `gps_accuracy_m` | GPS accuracy for weighting/quality |
| `cell_id` | Existing app cell assignment, nullable |
| `survey_id` | Parent structured survey, nullable |
| `survey_duration_seconds` | Structured-survey effort, nullable |
| `structured_effort_weight` | Higher structured-survey weight, nullable |
| `habitat_indicators` | Structured-survey habitat indicators, nullable JSON |
| `review_status` | Moderation status |
| `has_pending_or_confirmed_flag` | Exclusion flag |

Only approved records are exported to R. Rejected, submitted, flagged-review,
and records with pending or confirmed quality flags are excluded from analytical
calculations.

Implemented workflow:

- PostgreSQL exposes `pipeline_observations_export`.
- `pipeline/01_ingest/export_supabase_observations.R` reads that view and
  writes `raw/supabase_observations.gpkg`.
- `pipeline/03_observations/observation_layer.R` reads this file alongside
  iNaturalist and GBIF.
- `observation_source = quick_sighting` is presence-only and receives
  `observation_weight = 0`.
- `observation_source = structured_survey` receives higher analytical weight.

## Metric Semantics

`ecological_residual`:

```text
effort_corrected_richness - expected_richness
```

- Positive means above expectation, ecological surplus.
- Negative means below expectation, ecosystem under pressure.

`natureGapScore`:

- Composite of normalised ecological residual, habitat quality deficit, and connectivity deficit.
- Negative means ecosystem under pressure.
- Positive means ecological surplus.

Do not use one field as an alias for the other.

## Local Development Data

Local/static files may be used as demo fixtures only. Production rendering uses
PMTiles from Supabase Storage and detail lookup from PostgreSQL.

| Layer | Current production source | Local/demo source |
| --- | --- | --- |
| 20 m hex rendering | `hexgrid.pmtiles` in Supabase Storage | none guaranteed |
| Cell detail | PostgreSQL `cell_attributes` | PMTiles properties fallback only |
| Park polygons | `parks.geojson` in Supabase Storage | `src/data/green-spaces.json` if used |
| Park stats | `park-stats.json` in Supabase Storage | `src/data/park-stats.json` |

The canonical frontend types are in `src/lib/types.ts`,
`src/lib/cell-detail.ts`, and `src/lib/green-spaces.ts`.
