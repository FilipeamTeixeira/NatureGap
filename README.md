# NatureGap

An open-source web tool that helps residents, schools, and local groups understand the ecological health of their neighbourhood and take meaningful action.

Unlike generic environmental dashboards, NatureGap produces a spatially explicit **residual map** — the gap between expected and observed nature — and translates that into ranked, location-specific interventions rather than generic advice.

**Cities analysed:** Porto (Portugal), Amsterdam (Netherlands), Honmoku/Yokohama (Japan). Porto is the frontend's default city.

---

## What makes it different

| Feature | What it does |
|---|---|
| **Residual analysis** | Compares expected biodiversity (habitat model) with observed (citizen science), cell by cell on a 20 m hex grid |
| **Effort correction** | Species richness divided by `log1p` of pedestrian path length within 40 m of each cell; cells with under 50 m of path are excluded, not scored zero |
| **Graph-theoretic corridors** | Dispersal-limited betweenness on a habitat-resistance graph, reduced to a node/corridor network — "restoring *this* cell improves connectivity most efficiently" |
| **Fully open source** | Methodology, pipeline, and application code are all public |

The headline metric is the **Nature Gap score**: positive means fewer species are recorded than the habitat predicts (pressure), negative means more (surplus). See [`docs/methodology.md`](docs/methodology.md) §8.

---

## Repository structure

```
/pipeline          # R scripts: download → ingest → modelling → export → import
  /00_download     # WorldCover, Sentinel-2, Landsat LST, canopy height,
                   #   PlanetScope, PT/NL CIR orthophoto NIR
  /01_ingest       # Tile registry, iNaturalist, GBIF, OSM, approved app observations
  /02_spatial      # 20 m hex grid and green-space base layers
  /02_habitat      # Tiled worker: habitat quality, stressors, path length,
                   #   observation standardisation, effort correction
  /03_observations # Observed-richness contract checks and taxa JSON
  /04_connectivity # Habitat-resistance graph (igraph) + derived corridor network
  /05_residuals    # Expected richness, ecological residual, Nature Gap score,
                   #   intervention ranking
  /05_patch        # Park/patch aggregation and patch-scale expected richness
  /06_export       # PMTiles, GeoJSON, cell-detail shards, manifests
  /07_import       # Optional PostgreSQL import and stale-object pruning
  /cities          # One small file per city (CITY_ID, CRS, OSM relation, extras)
  config.R         # Everything shared across cities
  run_pipeline.R   # The runner

/src               # Next.js frontend (App Router)
  /app             # Pages and API routes
  /components      # Map, layer controls, detail panels, citizen science
  /lib             # Types, config, styling expressions, data access

/supabase          # Migrations (schema, RLS, audit) and Edge Functions
/scripts           # Staging, storage sync, migration helpers
/docs              # Methodology, system architecture, data contract, runbook
/pipeline-export   # Staged Storage payloads per city (data itself is git-ignored)
```

---

## Running the frontend

```bash
npm install
npm run dev       # http://localhost:3000
npm run build
npm start
npm run lint
```

**Tech stack:** Next.js 16 · React 19 · TypeScript · Tailwind CSS v4 · MapLibre GL JS · PMTiles · Supabase

---

## Running the R pipeline

### Requirements

```r
install.packages(c(
  "sf", "terra", "igraph", "vegan",
  "rgbif", "osmdata", "rstac", "openeo", "httr2", "aws.s3", "arrow",
  "tidyverse", "lubridate", "here", "jsonlite", "furrr",
  "DBI", "RPostgres"
))
# forestdata (canopy height) is only needed for cities that enable it
```

External tools: `tippecanoe` (PMTiles generation), `node` (PMTiles validation),
`osmium` (regional OSM extracts), and the Supabase CLI for migrations.

### Execution

The whole pipeline runs through one entry point:

```bash
cd pipeline
Rscript run_pipeline.R                      # default city (yokohama-honmoku)
NATUREGAP_CITY=porto-center Rscript run_pipeline.R
Rscript run_pipeline.R 2                    # start from step 2, skipping ingest
```

Stages run in order: tile registry → ingest → Supabase observation export →
spatial base → habitat → observations → connectivity → residuals → patch
aggregation → export → optional PostgreSQL import. Individual stages can be
sourced on their own once `config.R` has been loaded:

```r
CITY <- "porto-center"
source("config.R")
source("04_connectivity/connectivity.R")
```

Adding a city means copying one file in `pipeline/cities/` and editing its
values — nothing else needs changing.

### Data sources

| Source | What it provides | Access |
|---|---|---|
| iNaturalist | Species sightings (research + needs_id) | Free API |
| GBIF | Aggregated biodiversity records | Free API via `rgbif` |
| OpenStreetMap | Green spaces, paths, roads, rail, lighting, amenities, water | Free via `osmdata` / regional PBF + `osmium` |
| Copernicus / Sentinel-2 | NDVI (10 m) | Free (registration required) |
| Landsat 8/9 | Land surface temperature, three seasonal windows | Free via USGS |
| ESA WorldCover | Land-cover fractions per cell | Free |
| Copernicus EMC-BUILT | Impervious/built surface fraction | Free (manual download) |
| Meta/WRI canopy height | Canopy height index | Free (optional per city) |
| PlanetScope | High-resolution NDVI | Licensed (optional per city) |
| Portugal DGT / Netherlands PDOK | CIR orthophoto NIR → `veg_fraction`, `ndvi_texture` | Free, national (optional per city) |
| Supabase | Approved quick sightings and structured surveys | This project's database |

---

## Methodology notes

See [`docs/methodology.md`](docs/methodology.md) for:
- Habitat quality index construction and weights
- Observation effort correction formula
- Expected richness (species-area law), ecological residual, Nature Gap score
- Connectivity graph, betweenness interpretation, and the derived corridor network
- Intervention ranking
- Known biases and caveats

See also [`docs/system-architecture.md`](docs/system-architecture.md) (component
and database contract), [`docs/data-contract.md`](docs/data-contract.md)
(exported artefacts and field semantics), and
[`docs/pipeline-runbook.md`](docs/pipeline-runbook.md) (publishing and promotion).

---

## Deployment

1. Run the R pipeline to produce a versioned dataset per city
2. Upload `pipeline-export/<city>/` to the Supabase Storage bucket `pipeline-export`
3. Optionally import into PostgreSQL and promote the active dataset
   (`npm run sync:pipeline-from-storage`)
4. Set environment variables (`.env.local`; see `.env.example` for the full set):

```
NEXT_PUBLIC_SUPABASE_URL=...
NEXT_PUBLIC_SUPABASE_ANON_KEY=...
NEXT_PUBLIC_PIPELINE_CITY_IDS=porto-center,amsterdam-schimmelstraat,yokohama-honmoku
NEXT_PUBLIC_CITIZEN_PHOTO_BUCKET=citizen-photos
DATABASE_URL=...            # R pipeline / import only
```

The basemap is OpenFreeMap Positron, so no map-tile API key is needed.

5. Deploy the frontend to Vercel or any Node.js host

Publishing and dataset promotion are documented step by step in
[`docs/pipeline-runbook.md`](docs/pipeline-runbook.md).

---

## Contributing

Contributions welcome. Please open an issue describing the change before opening
a PR, and keep changes minimal and localised — this is a running system.

Areas especially needing help:
- Habitat model calibration against independent biodiversity surveys
- A cited or locally calibrated species-area exponent (currently an assumption)
- Named barrier detection (roads/rail) at the connectivity stage
- Mobile observation quick-log feature

---

## Licence

Dual-licensed:

- **Code** (Next.js app, R pipeline, SQL, Edge Functions) — MIT, see [`LICENSE`](LICENSE)
- **Documentation and data** (`docs/`, the methodology, and exported pipeline
  data products) — [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/),
  see [`LICENSE-CC-BY-SA-4.0.txt`](LICENSE-CC-BY-SA-4.0.txt)

Attribute as: *NatureGap contributors, CC BY-SA 4.0*.

Input data retains its own licences: iNaturalist and GBIF research-grade
observations are CC-BY, OpenStreetMap is ODbL, and satellite and orthophoto
products carry their providers' terms (Copernicus, USGS/NASA, Portugal DGT,
Netherlands PDOK).
