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

## Scheduled Dataset Refresh (periodic, versioned, verify-then-promote)

Scores update on a **fixed schedule**, not continuously. This keeps every
published version dated and reproducible, and puts a human checkpoint before
anything new goes live. The infrastructure already exists — `public.pipeline_datasets`
(one `is_active` row per city) and `public.promote_pipeline_dataset(city_id,
dataset_id)` (admin-only). This section documents how to use it deliberately.

### Cadence

- Run the full pipeline **quarterly** (matching the recommended species-reference
  reseed cadence). Do not pursue live/continuous updates.

### Before every scheduled run

- Confirm `SUPABASE_OBSERVATIONS_ENABLED="1"` in the run's environment. If it is
  unset or `"0"`, approved structured surveys are **not** pulled and no
  citizen-submitted data reaches the run — regardless of how much the feature
  has been used. This must be set deliberately for scheduled runs (see
  `.env.example`).

### What each scheduled run does (one combined pass)

1. Re-pull GBIF and iNaturalist records fresh for the run.
2. Pull every structured survey that reached **`approved`** status since the last
   run (requires `SUPABASE_OBSERVATIONS_ENABLED="1"`).
3. Recompute every score from this single combined snapshot.
4. Write the result as a **new row in `pipeline_datasets`** with a fresh
   `dataset_id`, leaving **`is_active = FALSE`**. Nothing is published yet.

### Publishing (manual promotion step)

5. An **Approver/Admin** spot-checks the new dataset's numbers against the
   previous active version (a handful of parks; confirm nothing looks broken),
   then promotes it:

   ```sql
   select public.promote_pipeline_dataset('<city_id>', '<new_dataset_id>');
   ```

   This flips `is_active` to TRUE for that `dataset_id` (and FALSE for the prior
   one) — the actual "publish" step. This is the same Approver role that signs
   off on the structured surveys feeding the run: publishing a dataset and
   approving its input surveys are the same kind of decision.

Datasets are immutable and never hard-deleted; superseded versions simply stop
being active.
