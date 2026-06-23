# NatureGap — Step 02: Habitat Modelling
# Produces the expected nature layer — what biodiversity you would expect
# if observer effort were uniform across the city.
#
# Outputs:
#   data/processed/grid_habitat.gpkg   — cell grid with habitat index fields
#   data/processed/habitat_quality.tif — raster for PMTiles conversion

library(sf)
library(terra)
library(tidyverse)
library(landscapemetrics)

DATA_RAW  <- here::here("data/raw")
DATA_PROC <- here::here("data/processed")
dir.create(DATA_PROC, recursive = TRUE, showWarnings = FALSE)

BBOX      <- c(xmin = 139.48, ymin = 35.30, xmax = 139.70, ymax = 35.60)
CRS_LOCAL <- "EPSG:6674"
CELL_SIZE <- 250  # metres

# ── 1. Build reference grid ───────────────────────────────────────────────────
# Create a regular square grid over the Yokohama bounding box

bbox_sf <- st_bbox(c(xmin = BBOX["xmin"], ymin = BBOX["ymin"],
                     xmax = BBOX["xmax"], ymax = BBOX["ymax"]),
                   crs = 4326) |>
  st_as_sfc() |>
  st_transform(CRS_LOCAL)

grid <- st_make_grid(bbox_sf, cellsize = CELL_SIZE, square = TRUE) |>
  st_as_sf() |>
  mutate(cell_id = row_number())

cat(sprintf("Grid: %d cells at %dm resolution\n", nrow(grid), CELL_SIZE))

# ── 2. NDVI mean per cell ─────────────────────────────────────────────────────
# Requires data/raw/ndvi.tif (from step 01)

if (file.exists(file.path(DATA_RAW, "ndvi.tif"))) {
  ndvi <- rast(file.path(DATA_RAW, "ndvi.tif")) |> project(CRS_LOCAL)
  ndvi_mean <- terra::extract(ndvi, vect(grid), fun = mean, na.rm = TRUE, ID = TRUE)
  grid$ndvi_mean <- ndvi_mean$ndvi
} else {
  message("NDVI raster not found — skipping. Run step 01 first.")
  grid$ndvi_mean <- NA_real_
}

# ── 3. LST percentile rank per cell ──────────────────────────────────────────

if (file.exists(file.path(DATA_RAW, "lst.tif"))) {
  lst <- rast(file.path(DATA_RAW, "lst.tif")) |> project(CRS_LOCAL)
  lst_mean <- terra::extract(lst, vect(grid), fun = mean, na.rm = TRUE, ID = TRUE)
  grid$lst_celsius <- lst_mean$lst_celsius
  grid$lst_rank    <- rank(grid$lst_celsius, na.last = "keep") / sum(!is.na(grid$lst_celsius))
} else {
  message("LST raster not found — skipping. Run step 01 first.")
  grid$lst_celsius <- NA_real_
  grid$lst_rank    <- NA_real_
}

# ── 4. Green space area fraction per cell ────────────────────────────────────

green <- st_read(file.path(DATA_RAW, "osm_green_spaces.gpkg"), quiet = TRUE)

green_area <- st_intersection(green, grid) |>
  mutate(area_m2 = as.numeric(st_area(geometry))) |>
  st_drop_geometry() |>
  group_by(cell_id) |>
  summarise(green_area_m2 = sum(area_m2))

cell_area <- CELL_SIZE^2

grid <- grid |>
  left_join(green_area, by = "cell_id") |>
  mutate(
    green_area_m2 = replace_na(green_area_m2, 0),
    green_fraction = pmin(green_area_m2 / cell_area, 1)
  )

# ── 5. Path density per cell (for observer effort denominator) ────────────────

paths <- st_read(file.path(DATA_RAW, "osm_paths.gpkg"), quiet = TRUE)

path_length <- st_intersection(paths, grid) |>
  mutate(len_m = as.numeric(st_length(geometry))) |>
  st_drop_geometry() |>
  group_by(cell_id) |>
  summarise(path_length_m = sum(len_m))

grid <- grid |>
  left_join(path_length, by = "cell_id") |>
  mutate(path_length_m = replace_na(path_length_m, 0),
         path_km = path_length_m / 1000)

# ── 6. Composite habitat quality index ───────────────────────────────────────
# Weighted combination of sub-indices (0–1 each):
#   - NDVI (greenness)       weight 0.35
#   - Green fraction         weight 0.30
#   - LST inverse rank       weight 0.20  (cooler = better)
#   - Path density penalty   weight 0.15  (more paths = more accessible = less wild)
#
# NOTE: weights are provisional and documented as such.

grid <- grid |>
  mutate(
    ndvi_idx    = pmax(0, pmin(1, (replace_na(ndvi_mean, 0) + 0.2) / 1.2)),
    green_idx   = green_fraction,
    lst_idx     = 1 - replace_na(lst_rank, 0.5),
    path_idx    = pmin(path_km / 2, 1),   # penalise high path density (proxy for urbanisation)
    habitat_quality = 0.35 * ndvi_idx +
                      0.30 * green_idx +
                      0.20 * lst_idx  +
                      0.15 * (1 - path_idx)
  )

st_write(grid, file.path(DATA_PROC, "grid_habitat.gpkg"), delete_dsn = TRUE)
cat(sprintf("Written: %s\n", file.path(DATA_PROC, "grid_habitat.gpkg")))

# ── 7. Export habitat quality raster for PMTiles ─────────────────────────────

hab_rast <- rasterize(vect(grid), rast(ext(vect(grid)), res = CELL_SIZE, crs = CRS_LOCAL),
                      field = "habitat_quality")
writeRaster(hab_rast, file.path(DATA_PROC, "habitat_quality.tif"), overwrite = TRUE)
cat("Written: habitat_quality.tif\n")
