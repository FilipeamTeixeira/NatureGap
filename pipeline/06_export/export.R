# NatureGap — Step 06: Export for Visualisation
# Converts processed outputs to web-ready formats:
#   - PMTiles (from Cloud-Optimised GeoTIFF) for raster layers
#   - GeoJSON / PostGIS import for vector layers
#
# Prerequisites:
#   - pmtiles CLI: `pip install pmtiles` or `brew install felt/tap/tippecanoe`
#   - GDAL >= 3.1 for COG output
#   - Supabase project with PostGIS enabled

library(sf)
library(terra)
library(tidyverse)

DATA_PROC  <- here::here("data/processed")
DATA_EXPORT <- here::here("data/export")
dir.create(DATA_EXPORT, recursive = TRUE, showWarnings = FALSE)

# ── 1. Rasters → Cloud-Optimised GeoTIFF → PMTiles ───────────────────────────

raster_layers <- c(
  "habitat_quality"    = file.path(DATA_PROC, "habitat_quality.tif")
  # add ndvi.tif, lst.tif etc. here as they are produced
)

for (layer_name in names(raster_layers)) {
  input_tif <- raster_layers[[layer_name]]
  if (!file.exists(input_tif)) {
    message(sprintf("Skipping %s — file not found", input_tif))
    next
  }

  cog_path    <- file.path(DATA_EXPORT, paste0(layer_name, "_cog.tif"))
  pmtiles_path <- file.path(DATA_EXPORT, paste0(layer_name, ".pmtiles"))

  # Reproject to WGS84 (required for PMTiles web serving)
  r <- rast(input_tif) |> project("EPSG:4326")
  writeRaster(r, cog_path, gdal = c("COMPRESS=DEFLATE", "TILED=YES",
                                     "BLOCKXSIZE=512", "BLOCKYSIZE=512",
                                     "COPY_SRC_OVERVIEWS=YES"),
              overwrite = TRUE)

  # Convert COG → PMTiles (requires pmtiles CLI on PATH)
  cmd <- sprintf("pmtiles convert %s %s", cog_path, pmtiles_path)
  cat(sprintf("Running: %s\n", cmd))
  system(cmd)
}

# ── 2. Vector grid → GeoJSON (for PostGIS import) ────────────────────────────

grid <- st_read(file.path(DATA_PROC, "grid_residuals.gpkg"), quiet = TRUE) |>
  st_transform(4326) |>
  select(
    cell_id, habitat_quality, ndvi_mean, green_fraction, lst_rank,
    corridor_importance, fragmentation_index, patch_area_ha,
    n_obs, species_richness, richness_corrected, taxonomic_shannon,
    expected_richness, ecological_residual, composite, intervention_rank,
    is_habitat
  )

geojson_path <- file.path(DATA_EXPORT, "grid_yokohama.geojson")
st_write(grid, geojson_path, delete_dsn = TRUE)
cat(sprintf("Written: %s\n", geojson_path))

# ── 3. Top interventions → JSON (for Supabase) ───────────────────────────────

top <- read_csv(file.path(DATA_PROC, "top_interventions.csv"), show_col_types = FALSE)
jsonlite::write_json(top, file.path(DATA_EXPORT, "top_interventions.json"), pretty = TRUE)
cat("Written: top_interventions.json\n")

# ── 4. PostGIS import (run after uploading to Supabase) ──────────────────────
# ogr2ogr -f "PostgreSQL" PG:"host=... dbname=... user=... password=..." \
#   data/export/grid_yokohama.geojson -nln naturegap_cells -nlt POLYGON \
#   -lco GEOMETRY_NAME=geom -lco FID=cell_id

cat("\nExport complete. Upload data/export/ to Supabase Storage.\n")
cat("Then run the PostGIS import command from the comment above.\n")
