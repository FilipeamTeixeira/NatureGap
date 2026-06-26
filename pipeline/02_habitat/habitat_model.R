# NatureGap — Step 02: Habitat Modelling
# Produces the expected nature layer — what biodiversity you would expect
# if observer effort were uniform across the city.
#
# Primary data sources (from step 01):
#   data/raw/landcover.tif      — ESA WorldCover 10m landcover classification
#   data/raw/impervious.tif     — EMC-BUILT impervious surface fraction (0–1)
#   data/raw/osm_green_spaces.gpkg
#   data/raw/osm_paths.gpkg
#
# Optional (uncomment if available from step 01):
#   data/raw/ndvi.tif           — Sentinel-2 NDVI
#   data/raw/lst.tif            — Landsat surface temperature
#
# Outputs:
#   data/processed/grid_habitat.gpkg   — cell grid with habitat index fields
#   data/processed/habitat_quality.tif — raster for PMTiles conversion

library(sf)
library(terra)
library(tidyverse)
library(landscapemetrics)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

dir.create(DATA_PROC, recursive = TRUE, showWarnings = FALSE)

# WorldCover class codes
WC_TREE     <- 10L
WC_SHRUB    <- 20L
WC_GRASS    <- 30L
WC_CROP     <- 40L
WC_BUILT    <- 50L
WC_BARE     <- 60L
WC_SNOW     <- 70L
WC_WATER    <- 80L
WC_WETLAND  <- 90L
WC_MANGROVE <- 95L
WC_MOSS     <- 100L

# All classes that count as "vegetated" for the habitat index
WC_GREEN <- c(WC_TREE, WC_SHRUB, WC_GRASS, WC_WETLAND, WC_MANGROVE)

# ── 1. Build reference grid ───────────────────────────────────────────────────

bb <- unname(BBOX_CITY)

bbox_sf <- st_bbox(
  c(xmin = bb[1],
    ymin = bb[2],
    xmax = bb[3],
    ymax = bb[4]),
  crs = 4326
) |>
  st_as_sfc() |>
  st_transform(CRS_LOCAL)

grid <- st_make_grid(bbox_sf, cellsize = CELL_SIZE, square = FALSE) |>
  st_as_sf() |>
  mutate(cell_id = row_number())

cat(sprintf("Grid: %d cells at %dm resolution\n", nrow(grid), CELL_SIZE))

# ── 2. ESA WorldCover: vegetation class fractions per cell ───────────────────
# Each 250m × 250m cell contains ~625 WorldCover pixels (10m).
# Extract all pixel values and tabulate class fractions.
#
# Derived fields:
#   tree_fraction      — proportion of cell with class 10 (tree cover)
#   shrub_fraction     — proportion with class 20 (shrubland)
#   grass_fraction     — proportion with class 30 (grassland)
#   built_fraction_wc  — proportion with class 50 (built-up, from WorldCover)
#   green_fraction_wc  — proportion with any of: tree, shrub, grass, wetland, mangrove

lc_path <- RAW_LANDCOVER

if (file.exists(lc_path)) {
  cat("Extracting WorldCover class fractions...\n")

  lc <- rast(lc_path) |> project(CRS_LOCAL, method = "near")

  # Extract all pixels for each grid cell (method = "simple" → centroid assignment)
  lc_vals <- terra::extract(lc, vect(grid))
  # Column 1 = ID (row index in grid), column 2 = class value

  lc_fracs <- lc_vals |>
    as_tibble() |>
    rename(row_idx = ID, lc_class = 2) |>
    filter(!is.na(lc_class)) |>
    group_by(row_idx) |>
    summarise(
      tree_fraction      = mean(lc_class == WC_TREE),
      shrub_fraction     = mean(lc_class == WC_SHRUB),
      grass_fraction     = mean(lc_class == WC_GRASS),
      built_fraction_wc  = mean(lc_class == WC_BUILT),
      green_fraction_wc  = mean(lc_class %in% WC_GREEN),
      .groups = "drop"
    ) |>
    mutate(cell_id = grid$cell_id[row_idx]) |>
    select(-row_idx)

  grid <- grid |> left_join(lc_fracs, by = "cell_id") |>
    mutate(across(c(tree_fraction, shrub_fraction, grass_fraction,
                    built_fraction_wc, green_fraction_wc),
                  \(x) replace_na(x, 0)))
} else {
  message("WorldCover not found — run step 01 first. Filling with NA.")
  grid <- grid |>
    mutate(tree_fraction = NA_real_, shrub_fraction = NA_real_,
           grass_fraction = NA_real_, built_fraction_wc = NA_real_,
           green_fraction_wc = NA_real_)
}

# ── 3. EMC-BUILT: impervious surface fraction per cell ───────────────────────
# Provides higher-accuracy built-up fraction than WorldCover alone.
# Values already normalised to 0–1 by step 01.

imp_path <- RAW_IMPERVIOUS

if (file.exists(imp_path)) {
  cat("Extracting impervious surface fractions...\n")
  imp  <- rast(imp_path) |> project(CRS_LOCAL, method = "bilinear")
  imp_mean <- terra::extract(imp, vect(grid), fun = mean, na.rm = TRUE)
  grid$impervious_fraction <- replace_na(imp_mean[[2]], 0)
} else {
  message("Impervious raster not found — run step 01 first. Filling with NA.")
  grid$impervious_fraction <- NA_real_
}

# ── 4. OSM green space: supplemental area fraction ───────────────────────────
# Provides fine-grained park boundary data to supplement WorldCover at 250m.

green <- st_read(RAW_OSM_GREEN, quiet = TRUE)
cell_area <- CELL_SIZE^2

inter <- st_intersection(green, grid)

inter$area_m2 <- as.numeric(st_area(st_geometry(inter)))

green_area <- inter |>
  st_drop_geometry() |>
  group_by(cell_id) |>
  summarise(green_area_m2 = sum(area_m2), .groups = "drop")

grid <- grid |>
  left_join(green_area, by = "cell_id") |>
  mutate(
    green_area_m2 = replace_na(green_area_m2, 0),
    osm_green_fraction = pmin(green_area_m2 / cell_area, 1)
  ) |>
  select(-green_area_m2)

# ── 5. OSM path density (observer effort denominator) ────────────────────────

paths <- st_read(RAW_OSM_PATHS, quiet = TRUE)

inter <- st_intersection(paths, grid)

inter$len_m <- as.numeric(st_length(st_geometry(inter)))

path_length <- inter |>
  st_drop_geometry() |>
  group_by(cell_id) |>
  summarise(path_length_m = sum(len_m), .groups = "drop")

grid <- grid |>
  left_join(path_length, by = "cell_id") |>
  mutate(
    path_length_m = replace_na(path_length_m, 0),
    path_km       = path_length_m / 1000
  ) |>
  select(-path_length_m)

# ── 6. Optional: NDVI and LST ────────────────────────────────────────────────
# Paths configured in pipeline/config.R (RAW_NDVI, RAW_LST).

grid$ndvi_mean <- NA_real_
grid$lst_rank  <- NA_real_

if (file.exists(RAW_NDVI)) {
  cat("Extracting NDVI per cell...\n")
  ndvi <- rast(RAW_NDVI) |> project(CRS_LOCAL, method = "bilinear")
  ndvi_mean <- terra::extract(ndvi, vect(grid), fun = mean, na.rm = TRUE)
  grid$ndvi_mean <- replace_na(ndvi_mean[[2]], NA_real_)
}

if (file.exists(RAW_LST)) {
  cat("Extracting LST per cell...\n")
  lst <- rast(RAW_LST) |> project(CRS_LOCAL, method = "bilinear")
  lst_mean <- terra::extract(lst, vect(grid), fun = mean, na.rm = TRUE)
  grid$lst_celsius <- replace_na(lst_mean[[2]], NA_real_)
  n_lst <- sum(!is.na(grid$lst_celsius))
  if (n_lst > 0L) {
    grid$lst_rank <- rank(grid$lst_celsius, na.last = "keep") / n_lst
  }
}

# ── 7. Composite habitat quality index ───────────────────────────────────────
#
# Combines WorldCover vegetation classes and impervious surface into a
# single 0–1 quality index per cell.
#
# Component               Weight   Source
# ─────────────────────── ──────   ─────────────────────────────────────────
# Tree cover fraction        0.35   WorldCover class 10 (tree cover)
# Green fraction             0.25   WorldCover any vegetated class
# Imperviousness (inverted)  0.25   EMC-BUILT (high imperviousness = low quality)
# OSM green fraction         0.15   Parks / reserves from OSM (supplemental)
#
# Weights are provisional; see docs/methodology.md for calibration notes.

# Safe fallbacks: if a source is missing, use OSM green fraction as proxy
safe_tree   <- if_else(!is.na(grid$tree_fraction),     grid$tree_fraction,     grid$osm_green_fraction * 0.5)
safe_green  <- if_else(!is.na(grid$green_fraction_wc), grid$green_fraction_wc, grid$osm_green_fraction)
safe_imp    <- if_else(!is.na(grid$impervious_fraction),
                       grid$impervious_fraction,
                       replace_na(grid$built_fraction_wc, 0))

grid <- grid |>
  mutate(
    habitat_quality = 0.35 * safe_tree  +
                      0.25 * safe_green +
                      0.25 * (1 - safe_imp) +
                      0.15 * osm_green_fraction
  )

cat(sprintf(
  "Habitat quality: min=%.3f, mean=%.3f, max=%.3f\n",
  min(grid$habitat_quality,  na.rm = TRUE),
  mean(grid$habitat_quality, na.rm = TRUE),
  max(grid$habitat_quality,  na.rm = TRUE)
))

st_write(grid, PROC_GRID_HABITAT, delete_dsn = TRUE)
cat(sprintf("Written: %s\n", PROC_GRID_HABITAT))

# ── 8. Export habitat quality raster for PMTiles ─────────────────────────────

hab_rast <- rasterize(
  vect(grid),
  rast(ext(vect(grid)), res = CELL_SIZE, crs = CRS_LOCAL),
  field = "habitat_quality"
)
writeRaster(hab_rast, PROC_HABITAT_TIF, overwrite = TRUE)
cat("Written: habitat_quality.tif\n")

