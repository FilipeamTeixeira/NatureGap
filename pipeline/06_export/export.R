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

score_color <- function(score) {
  case_when(
    is.na(score) ~ "#fbbf24",
    score <= -20 ~ "#dc2626",
    score <= -10 ~ "#f59e0b",
    score < 5    ~ "#fbbf24",
    score < 15   ~ "#22c55e",
    TRUE         ~ "#16a34a"
  )
}

make_slug <- function(value) {
  value |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("[^a-z0-9]+", "-") |>
    stringr::str_replace_all("(^-|-$)", "")
}

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

# ── 2. Park polygons → GeoJSON ───────────────────────────────────────────────

green_path <- here::here("data/raw/osm_green_spaces.gpkg")
if (file.exists(green_path)) {
  green_raw <- st_read(green_path, quiet = TRUE) |>
    st_transform(4326) |>
    st_collection_extract("POLYGON")

  if (!"osm_id" %in% names(green_raw)) green_raw$osm_id <- seq_len(nrow(green_raw))
  if (!"name" %in% names(green_raw)) green_raw$name <- NA_character_
  if (!"name:ja" %in% names(green_raw)) green_raw[["name:ja"]] <- NA_character_

  green <- green_raw |>
    mutate(
      source_id = coalesce(as.character(osm_id), as.character(row_number())),
      name = coalesce(as.character(name), paste("Green space", source_id)),
      nameJa = coalesce(as.character(.data[["name:ja"]]), name),
      id = make_slug(coalesce(name, source_id)),
      wardId = NA_character_
    ) |>
    select(id, name, nameJa, wardId)

  parks_path <- file.path(DATA_EXPORT, "parks.geojson")
  st_write(green, parks_path, delete_dsn = TRUE)
  cat(sprintf("Written: %s\n", parks_path))
} else {
  message("Skipping parks.geojson — data/raw/osm_green_spaces.gpkg not found")
}

# ── 3. Vector grid → GeoJSON (for PostGIS import + frontend cells) ───────────

grid <- st_read(file.path(DATA_PROC, "grid_residuals.gpkg"), quiet = TRUE) |>
  st_transform(4326) |>
  select(
    cell_id, habitat_quality, ndvi_mean, green_fraction, lst_rank,
    corridor_importance, fragmentation_index, patch_area_ha,
    n_obs, species_richness, richness_corrected, taxonomic_shannon,
    expected_richness, ecological_residual, impact_score, composite, intervention_rank,
    is_habitat
  )

geojson_path <- file.path(DATA_EXPORT, "grid_yokohama.geojson")
st_write(grid, geojson_path, delete_dsn = TRUE)
cat(sprintf("Written: %s\n", geojson_path))

hexgrid <- grid |>
  transmute(
    cellId = as.character(cell_id),
    parkId = "yokohama-grid",
    parkName = "Yokohama analysis grid",
    wardId = NA_character_,
    score = as.integer(impact_score),
    color = score_color(impact_score)
  )

hexgrid_path <- file.path(DATA_EXPORT, "hexgrid.geojson")
st_write(hexgrid, hexgrid_path, delete_dsn = TRUE)
cat(sprintf("Written: %s\n", hexgrid_path))

# ── 4. Top interventions → JSON (for Supabase) ───────────────────────────────

top <- read_csv(file.path(DATA_PROC, "top_interventions.csv"), show_col_types = FALSE)
jsonlite::write_json(top, file.path(DATA_EXPORT, "top_interventions.json"), pretty = TRUE)
cat("Written: top_interventions.json\n")

city_stats <- list(
  "yokohama-grid" = list(
    impactScore = as.integer(round(stats::median(grid$impact_score, na.rm = TRUE))),
    habitatQuality = as.integer(round(mean(grid$habitat_quality, na.rm = TRUE) * 100)),
    observedRichness = as.integer(round(sum(grid$richness_corrected, na.rm = TRUE))),
    expectedRichness = as.integer(round(sum(grid$expected_richness, na.rm = TRUE))),
    status = "as-expected",
    habitatPotential = "moderate",
    observerEffortScore = round(mean(grid$n_obs / pmax(grid$green_fraction, 0.1), na.rm = TRUE), 1),
    taxonomicDiversity = round(mean(grid$taxonomic_shannon, na.rm = TRUE), 1),
    species = list(
      list(type = "plant", count = 0),
      list(type = "bird", count = 0),
      list(type = "insect", count = 0),
      list(type = "mammal", count = 0),
      list(type = "fungi", count = 0)
    ),
    corridorImportance = as.integer(round(mean(grid$corridor_importance, na.rm = TRUE) * 100)),
    fragmentationIndex = as.integer(round(mean(grid$fragmentation_index, na.rm = TRUE) * 100)),
    pressures = list("Pipeline export is city-grid level; park aggregation is not yet configured."),
    trendData = rep(as.integer(round(stats::median(grid$impact_score, na.rm = TRUE))), 12),
    interventions = list()
  )
)

jsonlite::write_json(city_stats, file.path(DATA_EXPORT, "park-stats.json"), pretty = TRUE, auto_unbox = TRUE)
cat("Written: park-stats.json\n")

# ── 5. PostGIS import (run after uploading to Supabase) ──────────────────────
# ogr2ogr -f "PostgreSQL" PG:"host=... dbname=... user=... password=..." \
#   data/export/grid_yokohama.geojson -nln naturegap_cells -nlt POLYGON \
#   -lco GEOMETRY_NAME=geom -lco FID=cell_id

cat("\nExport complete. Upload data/export/ to Supabase Storage.\n")
cat("Then run the PostGIS import command from the comment above.\n")
