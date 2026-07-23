# NatureGap — Step 03: Biodiversity Observation Layer (tiled)
#
# Uses the same per-tile run as habitat_model.R (cached) and writes observation outputs.

library(sf)
library(here)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

source(here::here("02_habitat", "process_tile.R"), local = FALSE)

grid_obs <- get_tiled_results()

sampled_missing_observed <- grid_obs |>
  st_drop_geometry() |>
  filter(!is_unsampled & (is.na(survey_effort_units) | is.na(observed_richness)))

if (nrow(sampled_missing_observed) > 0L) {
  stop(sprintf(
    "Observed richness contract violation: %d sampled cells lack survey_effort_units or observed_richness.",
    nrow(sampled_missing_observed)
  ), call. = FALSE)
}

unsampled_with_observed <- grid_obs |>
  st_drop_geometry() |>
  filter(is_unsampled & (!is.na(survey_effort_units) | !is.na(observed_richness)))

if (nrow(unsampled_with_observed) > 0L) {
  stop(sprintf(
    "Observed richness contract violation: %d unsampled cells have non-null effort-normalised richness.",
    nrow(unsampled_with_observed)
  ), call. = FALSE)
}

cell_taxa_out <- build_cell_taxa_json(grid_obs, get_tiled_obs())
cat(sprintf("Written: %s (%d cells with taxa)\n", PROC_CELL_TAXA, length(cell_taxa_out)))

st_write(grid_obs, PROC_GRID_OBS, delete_dsn = TRUE)
cat(sprintf("Written: grid_observations.gpkg (%d cells)\n", nrow(grid_obs)))
