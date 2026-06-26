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
# To run only from a specific step (e.g. skip ingest):
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
  list(n = 1L, label = "Ingest",        file = "01_ingest/ingest.R"),
  list(n = 2L, label = "Habitat model", file = "02_habitat/habitat_model.R"),
  list(n = 3L, label = "Observations",  file = "03_observations/observation_layer.R"),
  list(n = 4L, label = "Connectivity",  file = "04_connectivity/connectivity.R"),
  list(n = 5L, label = "Residuals",     file = "05_residuals/residuals.R"),
  list(n = 6L, label = "Export",        file = "06_export/export.R")
)

for (step in steps) {
  if (step$n < START_STEP) next

  cat(sprintf("\n%s\n", strrep("─", 60)))
  cat(sprintf("  Step %d / %d — %s\n", step$n, length(steps), step$label))
  cat(sprintf("%s\n\n", strrep("─", 60)))

  t0 <- proc.time()
  source(here::here(step$file), local = FALSE)
  elapsed <- round((proc.time() - t0)[["elapsed"]])

  cat(sprintf("\n  ✓ Step %d done in %d s\n", step$n, elapsed))
}

cat(sprintf("\n%s\n", strrep("═", 60)))
cat(sprintf("  Pipeline complete for city: %s\n", CITY_ID))
cat(sprintf("  Export folder: %s\n", DATA_EXPORT))
cat(sprintf("  Upload to Supabase Storage: pipeline-export/%s/\n", CITY_ID))
cat(sprintf("%s\n", strrep("═", 60)))
