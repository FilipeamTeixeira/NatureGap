# NatureGap — Step 02: Habitat Modelling (tiled)
#
# Runs per-tile habitat metrics via process_tile.R and writes citywide outputs.

library(sf)
library(terra)
library(here)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

dir.create(DATA_PROC, recursive = TRUE, showWarnings = FALSE)

source(here::here("02_habitat", "process_tile.R"), local = FALSE)

tiles_dir <- file.path(PIPELINE_ROOT, "data", "tiles", city)
if (!file.exists(file.path(tiles_dir, "core_tiles.gpkg"))) {
  stop(
    "Tile registry not found at ", file.path(tiles_dir, "core_tiles.gpkg"),
    " — run 01_ingest/tile_registry.R first.",
    call. = FALSE
  )
}

grid <- get_tiled_results()

cat(sprintf(
  "Habitat quality: min=%.3f, mean=%.3f, max=%.3f\n",
  min(grid$habitat_quality, na.rm = TRUE),
  mean(grid$habitat_quality, na.rm = TRUE),
  max(grid$habitat_quality, na.rm = TRUE)
))

st_write(grid, PROC_HEX_CELLS, delete_dsn = TRUE)
st_write(grid, PROC_GRID_HABITAT, delete_dsn = TRUE)
cat(sprintf("Written: %s\n", PROC_HEX_CELLS))
cat(sprintf("Written: %s\n", PROC_GRID_HABITAT))

hab_rast <- terra::rasterize(
  terra::vect(grid),
  terra::rast(terra::ext(terra::vect(grid)), res = CELL_SIZE, crs = CRS_LOCAL),
  field = "habitat_quality"
)
writeRaster(hab_rast, PROC_HABITAT_TIF, overwrite = TRUE)
cat("Written: habitat_quality.tif\n")
