# Pipeline Runbook

## Restore Map Tiles From Existing Exports

Use this when `pipeline/data/<city>/export/hexgrid.pmtiles` already exists and
you only need the Storage bucket in the current manifest-based structure.

```bash
npm run stage:pipeline-export -- --city yokohama-honmoku --version 20260627T120000Z
```

This creates:

```text
pipeline-export/
  yokohama-honmoku/
    current.json
    20260627T120000Z/
      manifest.json
      hexgrid.pmtiles
      parks.geojson
      park-stats.json
      cell_attributes.geojson
      top_interventions.json
```

Upload the contents into the Supabase Storage bucket named `pipeline-export`.
Inside the bucket, object paths should start with the city id:

```text
yokohama-honmoku/current.json
yokohama-honmoku/20260627T120000Z/manifest.json
yokohama-honmoku/20260627T120000Z/hexgrid.pmtiles
```

Do not include another leading `pipeline-export/` folder inside the bucket.

## Configure R/PostgreSQL

Copy `.env.example` to `.env.local` and set:

```text
DATABASE_URL="postgresql://..."
```

The R pipeline automatically reads:

```text
.env.local
.env
pipeline/.env.local
pipeline/.env
```

By default, the R pipeline does not connect to PostgreSQL. This keeps the
PMTiles/export path usable even when Supabase database access is unavailable.

Leave these unset or set to `"0"` for normal manual-upload runs:

```text
SUPABASE_OBSERVATIONS_ENABLED="0"
POSTGRES_IMPORT_ENABLED="0"
SUPABASE_OBSERVATIONS_REQUIRED="0"
POSTGRES_IMPORT_REQUIRED="0"
```

Enable database-backed steps only when you explicitly want them:

```text
SUPABASE_OBSERVATIONS_ENABLED="1"
POSTGRES_IMPORT_ENABLED="1"
```

Use strict flags only when you want the run to fail if Supabase observation
export or PostgreSQL import cannot happen:

```text
SUPABASE_OBSERVATIONS_REQUIRED="1"
POSTGRES_IMPORT_REQUIRED="1"
```

Leave all four flags as `"0"` when you are only regenerating local map products.

## Full Pipeline Refresh

Run this when you want to regenerate ecological outputs and import them into
PostgreSQL:

```bash
cd pipeline
Rscript run_pipeline.R
```

The full run:

1. Exports approved Supabase observations only when
   `SUPABASE_OBSERVATIONS_ENABLED="1"` or
   `SUPABASE_OBSERVATIONS_REQUIRED="1"`.
2. Runs the R ecological pipeline.
3. Generates PMTiles and versioned manifests.
4. Imports `cell_attributes` and `green_spaces` into PostgreSQL only when
   `POSTGRES_IMPORT_ENABLED="1"` or `POSTGRES_IMPORT_REQUIRED="1"`.
5. Updates local `pipeline-export/<city>/current.json`.

Approved observations only affect R outputs after a full pipeline refresh.
