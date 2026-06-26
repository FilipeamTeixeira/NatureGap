# NatureGap

An open-source web tool that helps residents, schools, and local groups understand the ecological health of their neighbourhood and take meaningful action.

Unlike generic environmental dashboards, NatureGap produces a spatially explicit **residual map** — the gap between expected and observed nature — and translates that into ranked, location-specific interventions rather than generic advice.

**First city: Yokohama, Japan.**

---

## What makes it different

| Feature | What it does |
|---|---|
| **Residual analysis** | Compares expected biodiversity (habitat model) with observed (citizen science), cell by cell |
| **Effort correction** | Species richness corrected by accessible pedestrian path length on the 20m hex grid |
| **Graph-theoretic corridors** | Betweenness centrality drives intervention ranking — "restoring *this* cell reduces fragmentation most efficiently" |
| **LiDAR canopy** | Uses actual canopy height (Yokohama open LiDAR) rather than spectral greenness alone |
| **Fully open source** | Methodology, pipeline, and application code are all public |

---

## Repository structure

```
/pipeline        # R scripts: data ingestion → modelling → export
  /01_ingest     # iNaturalist, GBIF, OSM, Sentinel-2, Landsat, LiDAR
  /02_habitat    # Habitat quality index per 20m hex cell
  /03_observations  # Effort-corrected species richness per cell
  /04_connectivity  # Landscape connectivity graph (igraph)
  /05_residuals  # Ecological residual + intervention ranking
  /06_export     # COG → PMTiles, GeoJSON → PostGIS

/app             # Next.js 16 frontend (this directory)
  /src/app       # App Router pages
  /src/components  # Map, layer controls, detail panel
  /src/lib       # Types, utilities, mock data

/docs            # Methodology, data sources, index construction, limitations
/data            # Sample outputs and test data (git-ignored except /sample)
```

---

## Running the frontend

```bash
npm install
npm run dev       # http://localhost:3000
npm run build
npm start
```

**Tech stack:** Next.js 16 · TypeScript · Tailwind CSS v4 · MapLibre GL JS · Supabase

---

## Running the R pipeline

### Requirements

```r
install.packages(c(
  "sf", "terra", "stars", "lidR",
  "landscapemetrics", "igraph", "gdistance",
  "rgbif", "rinat", "osmdata",
  "tidyverse", "vegan", "here", "jsonlite"
))
```

### Execution order

```bash
Rscript pipeline/01_ingest/ingest.R
Rscript pipeline/02_habitat/habitat_model.R
Rscript pipeline/03_observations/observation_layer.R
Rscript pipeline/04_connectivity/connectivity.R
Rscript pipeline/05_residuals/residuals.R
Rscript pipeline/06_export/export.R
```

### Data sources

| Source | What it provides | Access |
|---|---|---|
| iNaturalist | Species sightings | Free API via `rinat` |
| GBIF | Aggregated biodiversity records | Free API via `rgbif` |
| OpenStreetMap | Green spaces, path network | Free via `osmdata` |
| Copernicus / Sentinel-2 | NDVI | Free (registration required) |
| Landsat 8/9 | Land surface temperature | Free via USGS EarthExplorer |
| Yokohama LiDAR | Canopy height model | [Yokohama Open Data](https://data.city.yokohama.lg.jp/) |

---

## Methodology notes

See [`/docs/methodology.md`](docs/methodology.md) for:
- Habitat quality index construction and weights
- Observation effort correction formula
- Connectivity graph construction and betweenness interpretation
- Ecological residual definition and limitations
- Known biases and caveats

---

## Deployment

1. Run the R pipeline to produce processed outputs
2. Upload raster layers to Supabase Storage as PMTiles
3. Import vector grid to Supabase (PostGIS) via `ogr2ogr`
4. Set environment variables (`.env.local`):

```
NEXT_PUBLIC_SUPABASE_URL=...
NEXT_PUBLIC_SUPABASE_ANON_KEY=...
NEXT_PUBLIC_MAPTILER_KEY=...   # optional — CARTO Positron works without a key
```

5. Deploy frontend to Vercel or any Node.js host

---

## Contributing

Contributions welcome. Please read [`/docs/contributing.md`](docs/contributing.md) before opening a PR.

Areas especially needing help:
- Second city implementation (European city)
- LiDAR processing pipeline documentation
- Habitat model calibration against independent biodiversity surveys
- Mobile observation quick-log feature

---

## License

MIT — methodology, pipeline, and application code.
Data sources retain their own licences (CC-BY for iNaturalist/GBIF research-grade observations).
