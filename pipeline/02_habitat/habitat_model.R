# NatureGap — Step 02: Habitat Modelling
# Produces the expected nature layer — what biodiversity you would expect
# if observer effort were uniform across the city.
#
# Primary data sources (from step 01):
#   data/raw/ndvi.tif           — Sentinel-2 NDVI
#   data/raw/canopy_height.tif  — LiDAR canopy height, metres
#   data/raw/lst.tif            — Landsat surface temperature
#   data/raw/lidar_variance.tif — optional precomputed LiDAR variance
#   data/raw/osm_paths.gpkg
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

rescale01 <- function(x) {
  x <- as.numeric(x)
  rng <- range(x, na.rm = TRUE)
  if (!all(is.finite(rng)) || diff(rng) == 0) return(rep(0, length(x)))
  pmin(1, pmax(0, (x - rng[1]) / diff(rng)))
}

fixed_rescale01 <- function(x, min_value, max_value) {
  x <- as.numeric(x)
  pmin(1, pmax(0, (x - min_value) / (max_value - min_value)))
}

percent_rank01 <- function(x) {
  x <- as.numeric(x)
  out <- rep(NA_real_, length(x))
  ok <- !is.na(x)
  n <- sum(ok)
  if (n == 0L) return(out)
  if (n == 1L) {
    out[ok] <- 0
    return(out)
  }
  out[ok] <- (rank(x[ok], ties.method = "average") - 1) / (n - 1)
  out
}

empty_sf <- function(crs = CRS_LOCAL) {
  st_sf(geometry = st_sfc(crs = crs))
}

read_optional_sf <- function(path, label) {
  if (!file.exists(path)) {
    message(sprintf("%s not found — using empty layer", label))
    return(empty_sf())
  }
  out <- tryCatch(st_read(path, quiet = TRUE), error = function(e) empty_sf())
  if (nrow(out) == 0L) return(empty_sf())
  st_transform(out, CRS_LOCAL)
}

line_density_by_cell <- function(lines, grid, weight_col = NULL, default_weight = 1) {
  if (nrow(lines) == 0L) return(rep(0, nrow(grid)))
  lines <- suppressWarnings(st_collection_extract(lines, "LINESTRING", warn = FALSE))
  if (nrow(lines) == 0L) return(rep(0, nrow(grid)))
  if (!is.null(weight_col) && weight_col %in% names(lines)) {
    lines$.weight <- as.numeric(lines[[weight_col]])
  } else {
    lines$.weight <- default_weight
  }
  inter <- suppressWarnings(st_intersection(lines |> select(.weight), grid |> select(cell_id)))
  if (nrow(inter) == 0L) return(rep(0, nrow(grid)))
  inter$weighted_len_m <- as.numeric(st_length(inter)) * replace_na(inter$.weight, default_weight)
  density <- inter |>
    st_drop_geometry() |>
    group_by(cell_id) |>
    summarise(weighted_len_m = sum(weighted_len_m), .groups = "drop")
  out <- rep(0, nrow(grid))
  out[match(density$cell_id, grid$cell_id)] <- density$weighted_len_m
  out / (as.numeric(st_area(grid)) / 10000)
}

point_density_by_cell <- function(points, grid) {
  if (nrow(points) == 0L) return(rep(0, nrow(grid)))
  points <- suppressWarnings(st_collection_extract(points, "POINT", warn = FALSE))
  if (nrow(points) == 0L) return(rep(0, nrow(grid)))
  points_geom <- st_sf(geometry = st_geometry(points), crs = st_crs(points))
  joined <- st_join(points_geom, grid |> select(cell_id), join = st_within, left = FALSE)
  if (nrow(joined) == 0L) return(rep(0, nrow(grid)))
  counts <- joined |>
    st_drop_geometry() |>
    count(cell_id, name = "n")
  out <- rep(0, nrow(grid))
  out[match(counts$cell_id, grid$cell_id)] <- counts$n
  out / (as.numeric(st_area(grid)) / 10000)
}

distance_weighted_points <- function(points, centroids, radius_m, decay_m) {
  if (nrow(points) == 0L) return(rep(0, nrow(centroids)))
  points <- suppressWarnings(st_collection_extract(points, "POINT", warn = FALSE))
  if (nrow(points) == 0L) return(rep(0, nrow(centroids)))
  idx <- st_nearest_feature(centroids, points)
  d <- as.numeric(st_distance(centroids, points[idx, ], by_element = TRUE))
  if_else(d <= radius_m, exp(-d / decay_m), 0)
}

distance_weighted_lines <- function(lines, centroids, radius_m, decay_m, weights = NULL) {
  if (nrow(lines) == 0L) return(rep(0, nrow(centroids)))
  lines <- suppressWarnings(st_collection_extract(lines, "LINESTRING", warn = FALSE))
  if (nrow(lines) == 0L) return(rep(0, nrow(centroids)))
  if (is.null(weights)) weights <- rep(1, nrow(lines))
  idx <- st_nearest_feature(centroids, lines)
  d <- as.numeric(st_distance(centroids, lines[idx, ], by_element = TRUE))
  if_else(d <= radius_m, exp(-d / decay_m) * weights[idx], 0)
}

nearest_proximity <- function(features, centroids, radius_m) {
  if (nrow(features) == 0L) return(rep(0, nrow(centroids)))
  idx <- st_nearest_feature(centroids, features)
  d <- as.numeric(st_distance(centroids, features[idx, ], by_element = TRUE))
  if_else(d <= radius_m, pmax(0, 1 - d / radius_m), 0)
}

road_weight <- function(highway) {
  x <- tolower(as.character(highway))
  dplyr::case_when(
    x %in% c("motorway", "trunk") ~ 5,
    x == "primary" ~ 4,
    x == "secondary" ~ 3,
    x == "tertiary" ~ 2,
    x %in% c("residential", "unclassified") ~ 1,
    x %in% c("service", "living_street") ~ 0.6,
    TRUE ~ 1
  )
}

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

# ── 1. Load canonical spatial base grid ──────────────────────────────────────

if (!file.exists(PROC_HEX_CELLS)) {
  stop("hex_cells.gpkg not found — run step 02 spatial base first.", call. = FALSE)
}

grid <- st_read(PROC_HEX_CELLS, quiet = TRUE) |>
  st_transform(CRS_LOCAL) |>
  select(cell_id, any_of("green_space_id"))

cat(sprintf("Grid: %d cells at %dm resolution\n", nrow(grid), CELL_SIZE))

# ── 2. ESA WorldCover: vegetation class fractions per cell ───────────────────
# Each 20 m hex contains several WorldCover pixels (10m). Extract all pixel
# values and tabulate class fractions.
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
# Provides fine-grained park boundary data to supplement WorldCover at 20 m.

green <- st_read(RAW_OSM_GREEN, quiet = TRUE)
cell_area <- CELL_SIZE^2

inter <- suppressWarnings(st_intersection(green, grid))

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

inter <- suppressWarnings(st_intersection(paths, grid))

inter$len_m <- as.numeric(st_length(st_geometry(inter)))

path_length <- inter |>
  st_drop_geometry() |>
  group_by(cell_id) |>
  summarise(path_length_m = sum(len_m), .groups = "drop")

grid <- grid |>
  left_join(path_length, by = "cell_id") |>
  mutate(
    path_length_m = replace_na(path_length_m, 0),
    path_km       = path_length_m / 1000,
    is_unsampled  = path_km <= 0
  ) |>
  select(-path_length_m)

# ── 6. Required ecological raster indices ───────────────────────────────────
# Missing required rasters remain NA. No proxy substitution is applied.

grid$ndvi_mean <- NA_real_
grid$ndvi_idx <- NA_real_
grid$canopy_height_m <- NA_real_
grid$canopy_height_idx <- NA_real_
grid$lst_rank  <- NA_real_
grid$lst_idx <- NA_real_
grid$lst_celsius <- NA_real_
grid$lidar_variance <- NA_real_
grid$lidar_variance_idx <- NA_real_

if (file.exists(RAW_NDVI)) {
  cat("Extracting NDVI per cell...\n")
  ndvi <- rast(RAW_NDVI) |> project(CRS_LOCAL, method = "bilinear")
  ndvi_mean <- terra::extract(ndvi, vect(grid), fun = mean, na.rm = TRUE)
  grid$ndvi_mean <- replace_na(ndvi_mean[[2]], NA_real_)
  grid$ndvi_idx <- fixed_rescale01(grid$ndvi_mean, -0.2, 1.0)
} else {
  message("NDVI raster not found — ndvi_idx set to NA.")
}

canopy_path <- if (file.exists(RAW_CANOPY_HEIGHT)) {
  RAW_CANOPY_HEIGHT
} else if (exists("CANOPY_HEIGHT_FILE") && file.exists(CANOPY_HEIGHT_FILE)) {
  CANOPY_HEIGHT_FILE
} else {
  NA_character_
}

lidar_variance_path <- if (file.exists(RAW_LIDAR_VARIANCE)) {
  RAW_LIDAR_VARIANCE
} else if (exists("LIDAR_VARIANCE_FILE") && file.exists(LIDAR_VARIANCE_FILE)) {
  LIDAR_VARIANCE_FILE
} else {
  NA_character_
}

if (!is.na(canopy_path)) {
  cat("Extracting LiDAR canopy height per cell...\n")
  canopy <- rast(canopy_path) |> project(CRS_LOCAL, method = "bilinear")
  canopy_mean <- terra::extract(canopy, vect(grid), fun = mean, na.rm = TRUE)
  grid$canopy_height_m <- replace_na(canopy_mean[[2]], NA_real_)
  grid$canopy_height_idx <- fixed_rescale01(pmin(grid$canopy_height_m, 20), 0, 20)

  canopy_var <- terra::extract(canopy, vect(grid), fun = stats::var, na.rm = TRUE)
  grid$lidar_variance <- replace_na(canopy_var[[2]], NA_real_)
} else {
  message("LiDAR canopy height raster not found — canopy_height_idx set to NA.")
}

if (file.exists(RAW_LST)) {
  cat("Extracting LST per cell...\n")
  lst <- rast(RAW_LST) |> project(CRS_LOCAL, method = "bilinear")
  lst_mean <- terra::extract(lst, vect(grid), fun = mean, na.rm = TRUE)
  grid$lst_celsius <- replace_na(lst_mean[[2]], NA_real_)
  grid$lst_rank <- percent_rank01(grid$lst_celsius)
  grid$lst_idx <- 1 - grid$lst_rank
} else {
  message("LST raster not found — lst_idx set to NA.")
}

if (!is.na(lidar_variance_path)) {
  cat("Extracting precomputed LiDAR variance per cell...\n")
  lidar_variance <- rast(lidar_variance_path) |> project(CRS_LOCAL, method = "bilinear")
  lidar_variance_mean <- terra::extract(lidar_variance, vect(grid), fun = mean, na.rm = TRUE)
  grid$lidar_variance <- replace_na(lidar_variance_mean[[2]], NA_real_)
}

grid$lidar_variance_idx <- if (all(is.na(grid$lidar_variance))) {
  rep(NA_real_, nrow(grid))
} else {
  rescale01(grid$lidar_variance)
}

grid <- grid |>
  mutate(
    heat_exposure = lst_rank
  )

# ── 7. Environmental stressors on 20 m hex cells ─────────────────────────────

cell_centroids <- suppressWarnings(st_centroid(grid))
cell_area_ha <- as.numeric(st_area(grid)) / 10000

roads <- read_optional_sf(RAW_OSM_ROADS, "OSM roads")
rail <- read_optional_sf(RAW_OSM_RAIL, "OSM rail")
lamps <- read_optional_sf(RAW_OSM_LAMPS, "OSM street lamps")
lit_roads <- read_optional_sf(RAW_OSM_LIT_ROADS, "OSM lit roads")
amenities <- read_optional_sf(RAW_OSM_AMENITIES, "OSM amenities")
water <- read_optional_sf(RAW_OSM_WATER, "OSM water")

if (nrow(roads) > 0L) {
  roads$.road_weight <- road_weight(roads$highway)
}

road_density <- line_density_by_cell(roads, grid, ".road_weight")
rail_density <- line_density_by_cell(rail, grid, default_weight = 3)
road_proximity <- distance_weighted_lines(
  roads,
  cell_centroids,
  radius_m = 150,
  decay_m = 60,
  weights = if (nrow(roads) > 0L) roads$.road_weight else NULL
)
rail_proximity <- distance_weighted_lines(
  rail,
  cell_centroids,
  radius_m = 200,
  decay_m = 80,
  weights = rep(3, nrow(rail))
)

lamp_density <- point_density_by_cell(lamps, grid)
lamp_proximity <- distance_weighted_points(lamps, cell_centroids, radius_m = 80, decay_m = 30)
lit_road_density <- line_density_by_cell(lit_roads, grid)

path_density <- (grid$path_km * 1000) / pmax(cell_area_ha, 0.0001)
amenity_proximity <- distance_weighted_points(amenities, cell_centroids, radius_m = 120, decay_m = 50)

water_prox <- nearest_proximity(water, cell_centroids, radius_m = 250)
permeable_fraction <- pmin(1, pmax(0, 1 - replace_na(grid$impervious_fraction, 0)))

grid <- grid |>
  mutate(
    noise = rescale01(
      0.55 * rescale01(road_density) +
        0.20 * rescale01(road_proximity) +
        0.20 * rescale01(rail_density) +
        0.05 * rescale01(rail_proximity)
    ),
    light_pollution = rescale01(
      0.50 * rescale01(lamp_density) +
        0.30 * rescale01(lamp_proximity) +
        0.20 * rescale01(lit_road_density)
    ),
    osm_disturbance_idx = rescale01(
      0.60 * rescale01(path_density) +
        0.40 * rescale01(amenity_proximity)
    ),
    disturbance_idx = if_else(
      is.na(lidar_variance_idx),
      NA_real_,
      (osm_disturbance_idx + lidar_variance_idx) / 2
    ),
    disturbance_index = disturbance_idx,
    water_proximity = rescale01(
      0.70 * water_prox +
        0.30 * permeable_fraction
    )
  )

# ── 8. Composite habitat quality index ───────────────────────────────────────

grid <- grid |>
  mutate(
    habitat_quality = 0.35 * replace_na(ndvi_idx, 0) +
                      0.30 * replace_na(canopy_height_idx, 0) +
                      0.20 * replace_na(lst_idx, 0) +
                      0.15 * (1 - replace_na(disturbance_idx, 1))
  )

cat(sprintf(
  "Habitat quality: min=%.3f, mean=%.3f, max=%.3f\n",
  min(grid$habitat_quality),
  mean(grid$habitat_quality),
  max(grid$habitat_quality)
))

st_write(grid, PROC_HEX_CELLS, delete_dsn = TRUE)
st_write(grid, PROC_GRID_HABITAT, delete_dsn = TRUE)
cat(sprintf("Written: %s\n", PROC_HEX_CELLS))
cat(sprintf("Written: %s\n", PROC_GRID_HABITAT))

# ── 9. Export habitat quality raster for PMTiles ─────────────────────────────

hab_rast <- rasterize(
  vect(grid),
  rast(ext(vect(grid)), res = CELL_SIZE, crs = CRS_LOCAL),
  field = "habitat_quality"
)
writeRaster(hab_rast, PROC_HABITAT_TIF, overwrite = TRUE)
cat("Written: habitat_quality.tif\n")
