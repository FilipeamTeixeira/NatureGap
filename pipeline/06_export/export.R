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

DATA_ROOT <- if (dir.exists(here::here("pipeline/data"))) {
  here::here("pipeline/data")
} else {
  here::here("data")
}

DATA_RAW    <- file.path(DATA_ROOT, "raw")
DATA_PROC   <- file.path(DATA_ROOT, "processed")
DATA_EXPORT <- file.path(DATA_ROOT, "export")
dir.create(DATA_EXPORT, recursive = TRUE, showWarnings = FALSE)

run_pmtiles_convert <- function(input_path, output_path) {
  pmtiles_bin <- Sys.which("pmtiles")
  if (!nzchar(pmtiles_bin)) {
    stop("pmtiles CLI not found on PATH. Install it before running export.R.", call. = FALSE)
  }

  args <- shQuote(c("convert", input_path, output_path))
  cat(sprintf("Running: %s %s\n", pmtiles_bin, paste(args, collapse = " ")))
  status <- system2(pmtiles_bin, args = args)
  if (!identical(status, 0L)) {
    stop(sprintf("pmtiles convert failed with exit status %s", status), call. = FALSE)
  }
}

run_gdal_translate_mbtiles <- function(input_path, output_path) {
  gdal_translate_bin <- Sys.which("gdal_translate")
  if (!nzchar(gdal_translate_bin)) {
    stop("gdal_translate not found on PATH. Install GDAL before running export.R.", call. = FALSE)
  }

  if (file.exists(output_path)) unlink(output_path)
  args <- shQuote(c(
    "-of", "MBTILES",
    "-ot", "Byte",
    "-scale", "0", "1", "0", "255",
    "-co", "TILE_FORMAT=PNG",
    input_path,
    output_path
  ))
  cat(sprintf("Running: %s %s\n", gdal_translate_bin, paste(args, collapse = " ")))
  status <- system2(gdal_translate_bin, args = args)
  if (!identical(status, 0L)) {
    stop(sprintf("gdal_translate MBTiles export failed with exit status %s", status), call. = FALSE)
  }
}

run_gdaladdo <- function(input_path) {
  gdaladdo_bin <- Sys.which("gdaladdo")
  if (!nzchar(gdaladdo_bin)) {
    stop("gdaladdo not found on PATH. Install GDAL before running export.R.", call. = FALSE)
  }

  args <- shQuote(c("-r", "average", input_path, "2", "4", "8", "16"))
  cat(sprintf("Running: %s %s\n", gdaladdo_bin, paste(args, collapse = " ")))
  status <- system2(gdaladdo_bin, args = args)
  if (!identical(status, 0L)) {
    stop(sprintf("gdaladdo failed with exit status %s", status), call. = FALSE)
  }
}

write_geojson <- function(value, output_path) {
  if (file.exists(output_path)) unlink(output_path)
  st_write(value, output_path, delete_dsn = FALSE)
}

# Colour scale — must stay in sync with SCORE_COLORS in src/lib/config.ts
# and IMPACT_LEGEND in src/lib/utils.ts
score_color <- function(score) {
  case_when(
    is.na(score) ~ "#B8C9AE",   # treat missing as "as expected"
    score < -20  ~ "#C95B4B",   # much worse than expected
    score < -10  ~ "#E8A44C",   # worse than expected
    score <   5  ~ "#B8C9AE",   # as expected
    score <  15  ~ "#73A56D",   # better than expected
    TRUE         ~ "#2E6F40"    # much better than expected
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
  "habitat_quality" = file.path(DATA_PROC, "habitat_quality.tif")
  # Optional layers (uncomment once available from step 01):
  # "ndvi"          = file.path(DATA_RAW,  "ndvi.tif"),
  # "lst"           = file.path(DATA_RAW,  "lst.tif")
  # Note: landcover.tif and impervious.tif are categorical / fractional rasters
  # better served as vector tile attributes rather than PMTiles; they are
  # embedded as cell properties in hexgrid.geojson (step 3 below).
)

for (layer_name in names(raster_layers)) {
  input_tif <- raster_layers[[layer_name]]
  if (!file.exists(input_tif)) {
    message(sprintf("Skipping %s — file not found", input_tif))
    next
  }

  cog_path    <- file.path(DATA_EXPORT, paste0(layer_name, "_cog.tif"))
  mbtiles_path <- file.path(DATA_EXPORT, paste0(layer_name, ".mbtiles"))
  pmtiles_path <- file.path(DATA_EXPORT, paste0(layer_name, ".pmtiles"))

  # Reproject to WGS84 (required for PMTiles web serving)
  r <- rast(input_tif) |> project("EPSG:4326")
  writeRaster(r, cog_path, gdal = c("COMPRESS=DEFLATE", "TILED=YES",
                                     "BLOCKXSIZE=512", "BLOCKYSIZE=512",
                                     "COPY_SRC_OVERVIEWS=YES"),
              overwrite = TRUE)

  # Convert COG → MBTiles → PMTiles (pmtiles CLI expects MBTiles input)
  run_gdal_translate_mbtiles(cog_path, mbtiles_path)
  run_gdaladdo(mbtiles_path)
  run_pmtiles_convert(mbtiles_path, pmtiles_path)
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
  write_geojson(green, parks_path)
  cat(sprintf("Written: %s\n", parks_path))
} else {
  message(sprintf("Skipping parks.geojson — %s not found", green_path))
}

# ── 3. Vector grid → GeoJSON (for PostGIS import + frontend cells) ───────────

grid_raw <- st_read(file.path(DATA_PROC, "grid_residuals.gpkg"), quiet = TRUE) |>
  st_transform(4326)

if (!"is_habitat" %in% names(grid_raw)) {
  grid_raw$is_habitat <- grid_raw$habitat_quality > 0
}
if (!"species_richness" %in% names(grid_raw)) {
  grid_raw$species_richness <- grid_raw$richness_corrected
}
if (!"taxonomic_shannon" %in% names(grid_raw) && "species_shannon" %in% names(grid_raw)) {
  grid_raw$taxonomic_shannon <- grid_raw$species_shannon
}

grid <- grid_raw |>
  select(
    # Core
    cell_id, habitat_quality, impact_score, composite, intervention_rank, is_habitat,
    # Landcover (WorldCover + EMC-BUILT — NA when step 01 rasters not available)
    any_of(c("tree_fraction", "shrub_fraction", "grass_fraction",
             "built_fraction_wc", "green_fraction_wc",
             "impervious_fraction", "osm_green_fraction")),
    # Legacy optional fields (present only when Sentinel-2/Landsat was run)
    any_of(c("ndvi_mean", "lst_rank")),
    # Connectivity
    corridor_importance, fragmentation_index, patch_area_ha,
    # Biodiversity observations
    n_obs, species_richness, richness_corrected, taxonomic_shannon,
    # Residuals
    expected_richness, ecological_residual
  )

geojson_path <- file.path(DATA_EXPORT, "grid_yokohama.geojson")
write_geojson(grid, geojson_path)
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
write_geojson(hexgrid, hexgrid_path)
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
