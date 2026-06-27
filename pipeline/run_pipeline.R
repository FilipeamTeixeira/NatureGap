# NatureGap — Master pipeline runner
#
# Usage:
#   Rscript run_pipeline.R
#   # or inside RStudio with the pipeline.Rproj open:
#   source("run_pipeline.R")
#
# To run a different city config:
#   source("config_amsterdam.R")
#   source("run_pipeline.R")
#
# To run only from a specific numbered folder (e.g. skip 01_ingest):
#   START_STEP <- 2
#   source("run_pipeline.R")
#   # or from the shell:
#   Rscript run_pipeline.R 2

library(here)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

args <- commandArgs(trailingOnly = TRUE)
cli_start <- if (length(args) >= 1L) {
  suppressWarnings(as.integer(args[[1L]]))
} else {
  NA_integer_
}
START_STEP <- if (length(cli_start) == 1L && !is.na(cli_start)) {
  cli_start
} else if (exists("START_STEP")) {
  START_STEP
} else {
  1L
}

steps <- list(
  list(n = 1L, folder = "01_ingest", label = "Ingest", file = "01_ingest/ingest.R"),
  list(n = 1L, folder = "01_ingest", label = "Supabase observations", file = "01_ingest/export_supabase_observations.R"),
  list(n = 2L, folder = "02_spatial", label = "Spatial base", file = "02_spatial/spatial_base.R"),
  list(n = 2L, folder = "02_habitat", label = "Habitat model", file = "02_habitat/habitat_model.R"),
  list(n = 3L, folder = "03_observations", label = "Observations", file = "03_observations/observation_layer.R"),
  list(n = 4L, folder = "04_connectivity", label = "Connectivity", file = "04_connectivity/connectivity.R"),
  list(n = 5L, folder = "05_residuals", label = "Residuals", file = "05_residuals/residuals.R"),
  list(n = 5L, folder = "05_patch", label = "Patch aggregation", file = "05_patch/patch_aggregation.R"),
  list(n = 6L, folder = "06_export", label = "Export", file = "06_export/export.R"),
  list(n = 7L, folder = "07_import", label = "Spatial PostgreSQL import", file = "07_import/import_spatial_outputs.R"),
  list(n = 7L, folder = "07_import", label = "PostgreSQL import", file = "07_import/import_to_postgres.R")
)

TOTAL_STEPS <- max(vapply(steps, \(step) step$n, integer(1)))

for (step_idx in seq_along(steps)) {
  step <- steps[[step_idx]]
  if (step$n < START_STEP) next

  cat(sprintf("\n%s\n", strrep("─", 60)))
  cat(sprintf("  Step %02d / %02d — %s — %s\n", step$n, TOTAL_STEPS, step$folder, step$label))
  cat(sprintf("%s\n\n", strrep("─", 60)))

  t0 <- proc.time()
  source(here::here(step$file), local = FALSE)
  elapsed <- round((proc.time() - t0)[["elapsed"]])

  cat(sprintf("\n  ✓ Step %02d — %s done in %d s\n", step$n, step$folder, elapsed))
}

cat(sprintf("\n%s\n", strrep("═", 60)))
cat(sprintf("  Pipeline complete for city: %s\n", CITY_ID))
cat(sprintf("  Export folder: %s\n", DATA_EXPORT))
if (exists("DATA_VERSION")) {
  cat(sprintf("  Dataset version: %s\n", DATA_VERSION))
  cat(sprintf("  Upload to Supabase Storage: pipeline-export/%s/%s/\n", CITY_ID, DATA_VERSION))
  cat(sprintf("  Active pointer: pipeline-export/%s/current.json\n", CITY_ID))
} else {
  cat(sprintf("  Upload to Supabase Storage: pipeline-export/%s/<DATA_VERSION>/\n", CITY_ID))
}
cat(sprintf("%s\n", strrep("═", 60)))
