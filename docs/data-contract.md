# Data Contract - R Pipeline, PMTiles, PostGIS, Frontend

This document defines the artefacts produced by `pipeline/06_export/export.R`
and consumed by Supabase Storage, PostgreSQL/PostGIS, and the Next.js frontend.

The production render path is PMTiles. Click-time cell detail is served from
Storage `cell-details` shards, with lightweight PMTiles properties as the
fallback. PostgreSQL/PostGIS remains for observations, surveys, moderation,
and optional pipeline metadata/import compatibility.

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

## Compression

GeoJSON products and cell-detail shards are written **gzipped**, with `.gz`
appended to the logical name (`parks.geojson.gz`). These are text formats that
repeat every key name on every feature, so they compress 20–35x; uncompressed,
a single city's export can exceed the entire Supabase free-tier storage budget.

| File | Compressed |
| --- | --- |
| `cell_attributes.geojson` (and `-part-NNN` chunks) | yes |
| `parks.geojson` | yes |
| `connectivity-network-edges.geojson` (and chunks) | yes |
| `connectivity-network-nodes.geojson` (and chunks) | yes |
| `cell-details/cell-details-NNN.json` | yes |
| `hexgrid.pmtiles` | no — already compressed internally |
| `manifest.json`, `current.json`, `*.manifest.json` | no — see below |
| `park-stats.json`, `top_interventions.json`, `city_layer_stats.json` | no |

Rules:

- **Manifests are never compressed.** They are the bootstrap that tells a
  reader which files exist, so they cannot themselves require knowing how they
  were written. They are a few KB regardless.
- **Upload the bytes as-is.** Supabase Storage serves stored bytes verbatim;
  there is no `Content-Encoding` negotiation to rely on. Do not set that header
  and do not decompress before upload.
- **The `.gz` suffix is the signal to decompress.** Readers key off it:
  `fetchStorageJson` (`src/lib/pipeline-manifest.ts`) pipes through
  `DecompressionStream`, and `read_geojson_text`
  (`pipeline/07_import/import_to_postgres.R`) uses `gzfile()`.
- **Both spellings resolve.** `resolveDatasetFile` prefers a `.gz` manifest
  entry and falls back to the plain name, so datasets published before
  compression keep working unchanged.

Compression is lossless — no rounding, no dropped fields, no coordinate
precision change. Writes are also marginally *faster*, because the I/O saved
outweighs the compression cost.

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

Required feature properties are declared in `PMTILES_REQUIRED_FIELDS`
(`pipeline/06_export/export.R`) and validated before the tiles are written.
That list is authoritative; it currently holds 32 fields. Shape:

```json
{
  "cellId": "porto-center-1234",
  "parkId": "jardim-da-cordoaria",
  "parkName": "Jardim da Cordoaria",
  "natureGapScore": 31.4,
  "impactScore": 31,
  "expectedRichness": 34.8,
  "ecologicalResidual": 22.4,
  "ecologicalResidualNormalized": 0.62,
  "habitatQuality": 52,
  "observedRichness": 12.4,
  "nObs": 41,
  "corridorImportance": 71,
  "betweennessCentrality": 12,
  "treeCover": 38,
  "canopyHeightIdx": 0.31,
  "heatExposure": 64,
  "meanLst": 31.2,
  "lstIdx": 36,
  "landUseGreen": 45,
  "landUseClass": "tree",
  "interventionRank": 8,

  "natureGapScoreNorm": 0.58,
  "residualNorm": 0.61,
  "expectedNorm": 0.44,
  "habitatQualityNorm": 0.52,
  "corridorImportanceNorm": 0.71,
  "betweennessNorm": 0.12,
  "treeCoverNorm": 0.38,
  "ndviNorm": 0.41,
  "lstNorm": 0.64,
  "disturbanceNorm": 0.55,
  "interventionRankNorm": 0.84
}
```

Scales:

- `habitatQuality`, `corridorImportance`, `betweennessCentrality`, `treeCover`,
  `heatExposure`, `lstIdx`, `landUseGreen` are `0`–`100` integer percentages.
- The `*Norm` fields are the render-ready companions MapLibre styles directly:
  `[-1, 1]` for the diverging metrics (`natureGapScoreNorm`, `residualNorm`),
  `[0, 1]` for the rest.
- Biodiversity-inference fields (`natureGapScore`, `ecologicalResidual`,
  `observedRichness`, `residualNorm`, `natureGapScoreNorm`,
  `interventionRankNorm`) are zeroed for unsampled cells because vector tiles
  cannot style nulls reliably; the true `null` survives in
  `cell_attributes.geojson` and the `cell-details` shards.
- `vegFraction` and `ndviTexture` also ride along where CIR NDVI exists. They
  are supplementary, not in the required list.

Constraints:

- CRS: WGS-84 tile coordinates as produced by PMTiles/vector tiles.
- Source-layer name must be exactly `hexgrid`.
- `cellId` must match the same stable ID used in Storage cell-detail shards.
- Properties must stay lightweight.
- Do not include species arrays, pressures, intervention descriptions, or
  other detail-panel JSON in PMTiles.

Frontend consumers:

- `src/components/map/MapView.tsx`
- `src/lib/pmtiles-storage.ts`
- `src/lib/layer-styles.ts`

## `cell_attributes.geojson`

Storage/archive artefact for full per-cell values. It may also be used for
PostGIS import compatibility, but the frontend does not require it in
PostgreSQL.

Produced by:

- `pipeline/06_export/export.R`
- Source: `processed/cell_attributes.gpkg` joined with detail fields from
  `processed/grid_residuals.gpkg`

Used for:

- Archival/debug inspection of full cell outputs
- Optional PostgreSQL import for legacy or operator workflows
- Building sharded Storage detail payloads used by `src/lib/cell-detail.ts`

Required properties include:

```json
{
  "cell_id": "porto-center-1234",
  "expected_richness": 34.8,
  "effort_corrected_richness": 12.4,
  "survey_effort_units": 5.2,
  "ecological_residual": 22.4,
  "ecological_residual_normalized": 0.62,
  "nature_gap_score": 31.4,
  "impact_score": 31,
  "habitat_quality": 52,
  "habitat_quality_index": 0.52,
  "species_richness_raw": 18,
  "observed_richness": 12.4,
  "max_expected_richness": 350,
  "is_unsampled": false,
  "temporal_bias_flag": false,
  "path_km": 0.18,
  "path_local_m": 182.4,
  "n_obs": 41,
  "n_survey_dates": 5,
  "habitat_potential": "moderate",
  "observer_effort_score": 227.8,
  "taxonomic_diversity": 1.4,
  "corridor_importance": 0.71,
  "intervention_rank": 8,
  "heat_exposure": 0.64,
  "connectivity_score": 0.52,
  "tree_cover": 38,
  "land_use_green": 45,
  "species": [],
  "pressures": [],
  "interventions": []
}
```

Notes on specific fields:

- `expected_richness` comes from the species-area law at hex area
  (`SPECIES_AREA_C * 400^SPECIES_AREA_Z * quality_blend`), so its ceiling is
  about `53.7`. `max_expected_richness` (350) is carried for transparency and no
  longer scales it.
- `ecological_residual` is `expected_richness - observed_richness`: positive
  means fewer species recorded than the habitat predicts.
- `impact_score` is a legacy field, `round(bio_residual_norm * 50)` — the
  biodiversity term of `nature_gap_score` on its own.
- `fragmentation_index`, `node_importance`, `edge_density`, `patch_isolation`
  and `patch_size_distribution` exist as columns but are always null; do not
  publish them as values.

`observed_richness` definition:

- `observed_richness = species_richness / survey_effort_units`
- `survey_effort_units = log1p(path_local_m)`
- `path_local_m` is OSM pedestrian path length, in metres, within
  `PATH_RADIUS_M` (40 m) of the cell centroid — not just the length clipped by
  the cell itself. A 20 m hex is ~350 m², so a strict per-cell intersection
  marks a cell one hex off a footway as unsampled; the neighbourhood measure
  does not. `path_km` remains the per-cell intersected length and is exported
  for transparency, but no longer drives effort correction.
- effort is measured in metres. `log1p` of a length in kilometres is inert at
  this cell size (`log1p(x) ≈ x` for `x` ≈ 0.02), which turned the correction
  into division by a near-zero denominator.
- `effort_corrected_richness` is the backwards-compatible canonical alias used
  in residual calculations.
- sampled cells with no observations export `observed_richness = 0`;
  unsampled cells export `observed_richness = null`.
- patch/green-space outputs aggregate this same cell-level field using
  cell-overlap weights; they must not recompute a city-specific variant.

Constraints:

- CRS: WGS-84, EPSG:4326.
- Geometry type: polygon.
- `cell_id` must be unique within a city/version.
- `cell_id` must match PMTiles `cellId`.
- Unsampled cells must preserve `is_unsampled = true` and use null/NA for
  residual inference fields where appropriate.
- `is_unsampled = path_local_m < MIN_PATH_M` (50 m). The floor keeps a stray
  OSM geometry fragment from passing as an access point.
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

## `connectivity-network-edges.geojson` / `connectivity-network-nodes.geojson`

The derived ecological network (see methodology §9a). Produced by
`04_connectivity/network_derive.R`, exported by `06_export/export.R`, served
through `src/app/api/vector/[cityId]/[layer]/route.ts` and validated by
`src/lib/vector-normalization.ts`.

**Edges** are `LineString` sections. A corridor is one or more sections sharing a
`corridorId`: extra sections exist only where the route is genuinely interrupted,
so a break can be marked without the line changing quality class along its length.

| Property | Type | Notes |
| --- | --- | --- |
| `corridorId` | string | `cor_N`. Shared by every section of one corridor. |
| `sectionIndex` | number | 1-based position along the corridor. |
| `kind` | enum | `corridor \| bottleneck`. Unknown values fall back to `corridor`. |
| `strength` | enum | `strongest \| strong \| moderate \| weak` — the whole route's class, carried by every section including bottlenecks. Unknown values fall back to `weak`. |
| `rank` | enum | `primary \| secondary \| minor`, from the node tiers connected. Drives the zoom hierarchy, so unknown values fall back to `minor` (revealed last), never `primary`. |
| `fromNode` / `toNode` | string | `cellId` of the corridor's endpoint nodes. |
| `lengthM` | number | Geometric length of the **whole route**, not of this section. |
| `meanResistance` | number | Effective cost ÷ geometric length, `1`–`CONN_MAX_RESISTANCE`. |
| `bottlenecks` | number | Count of bottleneck sections on the route. |
| `importance` | number | `0`–`1` route quality derived from `meanResistance`; carries line width. |

**Nodes** are `Point` features, one per habitat core.

| Property | Type | Notes |
| --- | --- | --- |
| `cellId` | string | The 20 m cell the node sits on. |
| `tier` | enum | `major \| secondary \| stepping-stone`. Unknown values fall back to `stepping-stone`. |
| `degree` | number | Corridors meeting at this node, after pruning. |
| `coreCells` | number | Cells in the habitat core this node stands for. |
| `areaHa` | number | Area of that core in hectares — what the tier is derived from. |
| `importance` | number | `corridor_importance` of the node's own cell, `0`–`1`. |

Constraints:

- CRS: WGS-84, EPSG:4326.
- `strength`, `rank`, `kind` and `tier` arrive **pre-classified**; the frontend
  re-derives none of them and buckets unknown values rather than passing them
  through, so a bad value cannot reach a MapLibre `match` expression.
- Sections of one corridor share a vertex at each boundary, so the rendered line
  is continuous.

## `park-stats.json`

Park or analysis-area aggregate statistics.

Produced by:

- `pipeline/06_export/export.R`
- Source: R-computed cell outputs aggregated by park ID

Example:

```json
{
  "jardim-da-cordoaria": {
    "natureGapScore": 31.4,
    "impactScore": 31,
    "habitatQuality": 52,
    "habitatQualityIndex": 0.52,
    "speciesRichnessRaw": 68,
    "observedRichness": 41.2,
    "effortCorrectedRichness": 41.2,
    "expectedRichness": 77.6,
    "maxExpectedRichness": 350,
    "ecologicalResidual": 36.4,
    "status": "much-worse",
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
    "pressures": ["Low survey effort"],
    "interventions": [
      {
        "id": "porto-center-1234-rank-8",
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

- `status`: `much-worse | worse | as-expected | better | much-better`, derived
  from `natureGapScore` against `SCORE_THRESHOLDS` (`src/lib/config.ts`) —
  higher score, worse status
- patch `expectedRichness` uses total patch area in the species-area law, so it
  is not comparable with the per-hex ceiling of ~53.7
- `fragmentationIndex` is not exported; the underlying field is never computed
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
    "parks": "20260627T120000Z/parks.geojson.gz",
    "parkStats": "20260627T120000Z/park-stats.json",
    "cellAttributes": "20260627T120000Z/cell_attributes.geojson.gz",
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
| `parks.geojson.gz` | `pipeline/06_export/export.R` | Storage frontend | WGS84 polygons, stable `id`, no ecological metrics; gzip |
| `cell_attributes.geojson.gz` | `pipeline/06_export/export.R` | Storage/archive + optional PostgreSQL import | Full ecological cell outputs with `city_id`, `dataset_id`, `generated_at`; gzip |
| `cell-details.manifest.json` + `cell-details/*.json.gz` | `pipeline/06_export/export.R` | Frontend cell detail | Sharded per-cell detail keyed by `cell_id`; shards gzip, manifest plain |
| `park-stats.json` | `pipeline/06_export/export.R` | Frontend detail data | UI statistics generated by R |
| `top_interventions.json` | `pipeline/06_export/export.R` | Audit/debug | Ranked R output, not required for rendering |
| `manifest.json` | `pipeline/06_export/export.R` | Import + frontend discovery | Product paths, counts, source-layer, render fields, database contract |
| `current.json` | `pipeline/06_export/export.R` | Frontend discovery | Stable pointer to the active immutable version |

## Optional PostgreSQL Import Contract

The frontend does not require `cell_attributes` rows for map rendering or cell
detail when Storage `current.json`, PMTiles, and `cell-details` shards are
available.

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
- `pipeline/02_habitat/process_tile.R` reads this file alongside iNaturalist and
  GBIF during the tiled observation pass (`03_observations/observation_layer.R`
  then contract-checks the result).
- The export step runs only when `SUPABASE_OBSERVATIONS_ENABLED="1"` (or
  `SUPABASE_OBSERVATIONS_REQUIRED="1"`) is set for the run.
- `observation_source = quick_sighting` is presence-only and receives
  `observation_weight = 0`.
- `observation_source = structured_survey` receives `observation_weight = 3`;
  anything else defaults to `1`.

## Metric Semantics

`ecological_residual`:

```text
expected_richness - observed_richness
```

- Raw backend analytics value — a gap, not a surplus.
- **Positive** means field-observed richness is **below** model expectation
  (pressure, restoration candidate).
- **Negative** means field-observed richness is above model expectation.
- Same orientation at patch level (`pipeline/05_patch/patch_aggregation.R`).

`ecological_residual_normalized`:

```text
(ecological_residual - city_mean(ecological_residual)) /
city_stddev(ecological_residual)
```

- City-wise standardized residual, exported for analytics and detail panels.
- Stored backend values are not clamped.

`residualNorm` / `natureGapScoreNorm`:

```text
norm_diverging(x) = clamp(x / max(|p10(x)|, |p90(x)|), -1, 1)
```

- The render fields MapLibre actually styles for the residual and Nature Gap
  layers. `ecological_residual_normalized` is **not** used for styling.
- `src/lib/layer-styles.ts` colours `+1` red and `-1` green, following the sign
  convention above.

`natureGapScore`:

- Decision score: `0.50 * clamp(residual / max|residual|, -1, 1)
  + 0.30 * (1 - habitat_quality) + 0.20 * (1 - corridor_importance)`, ×100.
- **Positive** means ecosystem under pressure.
- **Negative** means ecological surplus.
- Range `[-50, +100]`; band edges live in `SCORE_THRESHOLDS`
  (`src/lib/config.ts`).

`impactScore`:

- Legacy field: `round(clamp(residual / max|residual|, -1, 1) * 50)`, i.e. the
  biodiversity term of `natureGapScore` alone. Prefer `natureGapScore`.

Do not use one field as an alias for another.

## Local Development Data

Local/static files may be used as demo fixtures only. Production rendering and
detail lookup use Supabase Storage.

| Layer | Current production source | Local/demo source |
| --- | --- | --- |
| 20 m hex rendering | `hexgrid.pmtiles` in Supabase Storage | none guaranteed |
| Cell detail | `cell-details` shards in Supabase Storage + PMTiles clicked-feature properties | PMTiles properties fallback only |
| Park polygons | `parks.geojson` in Supabase Storage | `src/data/green-spaces.json` if used |
| Park stats | `park-stats.json` in Supabase Storage | `src/data/park-stats.json` |

The canonical frontend types are in `src/lib/types.ts`,
`src/lib/cell-detail.ts`, and `src/lib/green-spaces.ts`.
