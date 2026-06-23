# NatureGap — Step 01: Data Ingestion
# Pulls raw data from open sources and writes to data/raw/
#
# Sources:
#   - iNaturalist  (rinat)
#   - GBIF         (rgbif)
#   - OpenStreetMap (osmdata)
#   - Sentinel-2 NDVI (terra + GDAL)
#   - Landsat LST  (terra)
#   - Yokohama LiDAR (lidR)  — if available

library(sf)
library(terra)
library(rinat)
library(rgbif)
library(osmdata)
library(tidyverse)

# ── Configuration ─────────────────────────────────────────────────────────────

CITY       <- "Yokohama"
BBOX       <- c(xmin = 139.48, ymin = 35.30, xmax = 139.70, ymax = 35.60) # WGS84
CELL_SIZE  <- 250   # metres
CRS_LOCAL  <- "EPSG:6674"  # JGD2011 / Japan Plane Rectangular CS VI (Yokohama)
DATA_RAW   <- here::here("data/raw")
dir.create(DATA_RAW, recursive = TRUE, showWarnings = FALSE)

# ── 1. iNaturalist observations ───────────────────────────────────────────────

cat("Fetching iNaturalist observations...\n")
inat_obs <- get_inat_obs(
  bounds  = c(BBOX["ymin"], BBOX["xmin"], BBOX["ymax"], BBOX["xmax"]),
  maxresults = 10000,
  quality  = "research"
)

inat_sf <- inat_obs |>
  filter(!is.na(longitude), !is.na(latitude)) |>
  st_as_sf(coords = c("longitude", "latitude"), crs = 4326) |>
  st_transform(CRS_LOCAL)

st_write(inat_sf, file.path(DATA_RAW, "inat_observations.gpkg"), delete_dsn = TRUE)
cat(sprintf("  → %d iNaturalist records written\n", nrow(inat_sf)))

# ── 2. GBIF observations ──────────────────────────────────────────────────────

cat("Fetching GBIF observations...\n")
gbif_raw <- occ_search(
  decimalLatitude  = paste(BBOX["ymin"], BBOX["ymax"], sep = ","),
  decimalLongitude = paste(BBOX["xmin"], BBOX["xmax"], sep = ","),
  hasCoordinate = TRUE,
  limit = 10000
)$data

gbif_sf <- gbif_raw |>
  filter(!is.na(decimalLongitude), !is.na(decimalLatitude)) |>
  st_as_sf(coords = c("decimalLongitude", "decimalLatitude"), crs = 4326) |>
  st_transform(CRS_LOCAL)

st_write(gbif_sf, file.path(DATA_RAW, "gbif_observations.gpkg"), delete_dsn = TRUE)
cat(sprintf("  → %d GBIF records written\n", nrow(gbif_sf)))

# ── 3. OpenStreetMap: green spaces + path network ─────────────────────────────

cat("Fetching OpenStreetMap features...\n")
osm_bbox <- c(BBOX["xmin"], BBOX["ymin"], BBOX["xmax"], BBOX["ymax"])

# Green spaces (parks, nature reserves, etc.)
osm_green <- opq(bbox = osm_bbox) |>
  add_osm_feature(key = "leisure", value = c("park", "nature_reserve", "garden")) |>
  osmdata_sf()

green_polygons <- osm_green$osm_polygons |>
  st_transform(CRS_LOCAL)
st_write(green_polygons, file.path(DATA_RAW, "osm_green_spaces.gpkg"), delete_dsn = TRUE)

# Path / footway network (for observer effort correction)
osm_paths <- opq(bbox = osm_bbox) |>
  add_osm_feature(key = "highway",
                  value = c("path", "footway", "pedestrian", "steps", "track")) |>
  osmdata_sf()

path_lines <- osm_paths$osm_lines |>
  st_transform(CRS_LOCAL)
st_write(path_lines, file.path(DATA_RAW, "osm_paths.gpkg"), delete_dsn = TRUE)
cat("  → OSM features written\n")

# ── 4. Sentinel-2 NDVI ────────────────────────────────────────────────────────
# NOTE: Download a cloud-free Sentinel-2 L2A tile for Yokohama manually from
# Copernicus Browser (https://browser.dataspace.copernicus.eu/) and place it at:
#   data/raw/sentinel2/T54SUE_*.SAFE
# Then uncomment below.

# sentinel_dir <- file.path(DATA_RAW, "sentinel2")
# s2 <- rast(list.files(sentinel_dir, pattern = "B0[48]_10m\\.jp2$", recursive = TRUE, full.names = TRUE))
# ndvi <- (s2[[2]] - s2[[1]]) / (s2[[2]] + s2[[1]])
# names(ndvi) <- "ndvi"
# writeRaster(ndvi, file.path(DATA_RAW, "ndvi.tif"), overwrite = TRUE)
# cat("  → NDVI raster written\n")

# ── 5. Landsat LST ────────────────────────────────────────────────────────────
# NOTE: Download Landsat 8/9 Collection 2 Level-2 product for path/row 107/035
# from https://earthexplorer.usgs.gov/ and place the ST_B10 band at:
#   data/raw/landsat/LC09_*_ST_B10.TIF

# lst_file <- list.files(file.path(DATA_RAW, "landsat"), pattern = "ST_B10\\.TIF$", full.names = TRUE)[1]
# lst <- rast(lst_file) * 0.00341802 + 149 - 273.15  # scale to Celsius
# names(lst) <- "lst_celsius"
# writeRaster(lst, file.path(DATA_RAW, "lst.tif"), overwrite = TRUE)
# cat("  → LST raster written\n")

cat("\nIngestion complete. Check data/raw/ for outputs.\n")
