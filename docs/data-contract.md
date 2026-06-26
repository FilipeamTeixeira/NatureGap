# Data Contract - Frontend and R Pipeline

This document defines the files the R pipeline should produce for the frontend.
All production files are written to `data/export/` and can then be uploaded to
Supabase Storage.

## `parks.geojson`

Vegetation polygon layer used for park-level click zones and as the mask for
hex/cell data.

Produced by: `pipeline/06_export/export.R` from `data/raw/osm_green_spaces.gpkg`
when that raw OSM file exists.

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {
        "id": "honmoku-sancho",
        "name": "Honmoku Sancho Park",
        "nameJa": "本牧山頂公園",
        "wardId": "naka"
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
- `id` must be stable because `hexgrid.geojson` and `park-stats.json` refer to it.

## `hexgrid.geojson`

Canonical 20 m hex cell layer rendered by MapLibre. This is the same grid used
for modelling, observation attribution, storage, and display; no secondary
analytical grid is persisted.

Produced by: `pipeline/06_export/export.R` from `data/processed/grid_residuals.gpkg`.

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {
        "cellId": "honmoku-sancho-12-8",
        "parkId": "honmoku-sancho",
        "parkName": "Honmoku Sancho Park",
        "wardId": "naka",
        "score": -14,
        "color": "#f59e0b"
      },
      "geometry": {
        "type": "Polygon",
        "coordinates": [
          [[139.6441, 35.4192], [139.6442, 35.4191], [139.6441, 35.4192]]
        ]
      }
    }
  ]
}
```

Score definition:

```text
ecological_residual = expected_richness - effort_corrected_richness
```

Positive values mean habitat pressure: effort-corrected richness is below
expected richness. Negative values indicate potential refuges.

Color mapping must match `src/lib/utils.ts` (`getScoreColor`) and `IMPACT_LEGEND`.

| Score range | Color | Meaning |
| --- | --- | --- |
| `< -20` | `#C95B4B` | Much worse than expected |
| `< -10` | `#E8A44C` | Worse than expected |
| `< 5`   | `#B8C9AE` | As expected |
| `< 15`  | `#73A56D` | Better than expected |
| `>= 15` | `#2E6F40` | Much better than expected |

## `park-stats.json`

Park or analysis-area statistics used by the detail panel. The development file
lives at `src/data/park-stats.json` and is validated at runtime.

Produced by: `pipeline/06_export/export.R`. Current pipeline export includes a
city-grid aggregate placeholder until true park aggregation is configured.

```json
{
  "honmoku-sancho": {
    "impactScore": -14,
    "habitatQuality": 52,
    "observedRichness": 68,
    "expectedRichness": 104,
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
    "pressures": [
      "Low observer effort"
    ],
    "trendData": [-18, -17, -17, -16, -18, -16, -15, -14, -15, -14, -14, -14],
    "interventions": [
      {
        "id": "i1",
        "title": "Remove invasive understorey",
        "description": "Manual removal of invasive understorey.",
        "impact": "high",
        "category": "ground"
      }
    ]
  }
}
```

Schema notes:
- `status`: `much-worse | worse | as-expected | better | much-better`.
- `habitatPotential`: `low | moderate | high`.
- `species[].type`: `plant | bird | insect | mammal | fungi`.
- `interventions[].category`: `canopy | corridor | pollinator | water | ground`.

## Local Development Data

| Layer | Development source | Production source |
| --- | --- | --- |
| Park polygons | `src/data/green-spaces.json` | `parks.geojson` |
| 20 m hex grid | `hexgrid.geojson` fallback/public asset | `hexgrid.geojson` |
| Park stats | `src/data/park-stats.json` | `park-stats.json` |

The canonical frontend types are in `src/lib/types.ts` and
`src/lib/green-spaces.ts`.
