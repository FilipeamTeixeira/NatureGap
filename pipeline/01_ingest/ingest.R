# NatureGap — Step 01: Data Ingestion
# Pulls raw data from open sources and writes to data/raw/
#
# Sources:
#   - iNaturalist  (rinat)
#   - GBIF         (rgbif)
#   - OpenStreetMap (osmdata)
#   - ESA WorldCover 10m landcover classification (from data/to_import/)
#   - EMC-BUILT impervious surface fraction       (from data/to_import/)
#
# Optional (manual download required — see comments in sections 6 & 7):
#   - Sentinel-2 NDVI
#   - Landsat LST

library(sf)
library(terra)
library(rinat)
library(rgbif)
library(osmdata)
library(tidyverse)

# ── Configuration ─────────────────────────────────────────────────────────────

# Yokohama city extent (WGS84) — used for raster crop and habitat grid
BBOX_CITY <- c(xmin = 139.640415, ymin = 35.415460, xmax = 139.672859, ymax = 35.430148)

# Narrower fetch window for API calls (observation density is high enough here)
BBOX_FETCH <- c(xmin = 139.640415, ymin = 35.415460, xmax = 139.672859, ymax = 35.430148)

CRS_LOCAL    <- "EPSG:6674"   # JGD2011 / Japan Plane Rectangular CS VI
DATA_RAW     <- here::here("data/raw")
DATA_TO_IMP  <- here::here("data/to_import")

dir.create(DATA_RAW, recursive = TRUE, showWarnings = FALSE)

# ── 1. iNaturalist observations ───────────────────────────────────────────────

cat("Fetching iNaturalist observations...\n")
inat_obs <- get_inat_obs(
  bounds     = c(BBOX_FETCH["ymin"], BBOX_FETCH["xmin"],
                 BBOX_FETCH["ymax"], BBOX_FETCH["xmax"]),
  maxresults = 10000,
  quality    = "research"
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
  decimalLatitude  = paste(BBOX_FETCH["ymin"], BBOX_FETCH["ymax"], sep = ","),
  decimalLongitude = paste(BBOX_FETCH["xmin"], BBOX_FETCH["xmax"], sep = ","),
  hasCoordinate    = TRUE,
  limit            = 10000
)$data

gbif_sf <- gbif_raw |>
  filter(!is.na(decimalLongitude), !is.na(decimalLatitude)) |>
  st_as_sf(coords = c("decimalLongitude", "decimalLatitude"), crs = 4326) |>
  st_transform(CRS_LOCAL)

st_write(gbif_sf, file.path(DATA_RAW, "gbif_observations.gpkg"), delete_dsn = TRUE)
cat(sprintf("  → %d GBIF records written\n", nrow(gbif_sf)))

# ── 3. OpenStreetMap: green spaces + path network ─────────────────────────────

cat("Fetching OpenStreetMap features...\n")
osm_bbox <- c(BBOX_FETCH["xmin"], BBOX_FETCH["ymin"],
              BBOX_FETCH["xmax"], BBOX_FETCH["ymax"])

osm_green <- opq(bbox = osm_bbox) |>
  add_osm_feature(key = "leisure",
                  value = c("park", "nature_reserve", "garden")) |>
  osmdata_sf()

green_polygons <- osm_green$osm_polygons |> st_transform(CRS_LOCAL)
st_write(green_polygons, file.path(DATA_RAW, "osm_green_spaces.gpkg"), delete_dsn = TRUE)

osm_paths <- opq(bbox = osm_bbox) |>
  add_osm_feature(key = "highway",
                  value = c("path", "footway", "pedestrian", "steps", "track")) |>
  osmdata_sf()

path_lines <- osm_paths$osm_lines |> st_transform(CRS_LOCAL)
st_write(path_lines, file.path(DATA_RAW, "osm_paths.gpkg"), delete_dsn = TRUE)
cat("  → OSM features written\n")

# ── 4. ESA WorldCover 10m landcover classification ───────────────────────────
#
# Source: data/to_import/worldcover/ESA_WorldCover_10m_2021_v200_N33E138_Map.tif
# CRS:    WGS84 (EPSG:4326)
# Classes (values stored in pixel):
#   10  Tree cover         20  Shrubland           30  Grassland
#   40  Cropland           50  Built-up            60  Bare/Sparse vegetation
#   70  Snow and ice       80  Permanent water     90  Herbaceous wetland
#   95  Mangroves         100  Moss and lichen
#
# Output: data/raw/landcover.tif (cropped to Yokohama, kept in WGS84)

wc_path <- file.path(DATA_TO_IMP, "worldcover",
                     "ESA_WorldCover_10m_2021_v200_N33E138_Map.tif")

if (file.exists(wc_path)) {
  cat("Processing ESA WorldCover...\n")
  lc_raw  <- rast(wc_path)
  lc_ext  <- ext(BBOX_CITY["xmin"], BBOX_CITY["xmax"],
                 BBOX_CITY["ymin"], BBOX_CITY["ymax"])
  lc_crop <- crop(lc_raw, lc_ext)
  writeRaster(lc_crop, file.path(DATA_RAW, "landcover.tif"), overwrite = TRUE,
              datatype = "INT1U")
  cat(sprintf("  → WorldCover written: %d × %d pixels at %.0fm resolution\n",
              nrow(lc_crop), ncol(lc_crop),
              mean(res(lc_crop)) * 111319.5))
} else {
  warning(sprintf(
    "WorldCover not found: %s\n  Download from https://esa-worldcover.org/",
    wc_path
  ))
}

# ── 5. EMC-BUILT impervious surface fraction ──────────────────────────────────
#
# Source: data/to_import/emc_built/EMC_BUILT_S_E2022_GLOBE_R2025A_54009_10_V1_0_R5_C31.tif
# CRS:    ESRI:54009 (World Mollweide) — must be reprojected before use
# Values: built-up surface area in m² per 10m pixel (max = 100 for fully built)
#         Divide by 100 to get fraction 0–1.
#         The divisor is auto-detected from the raster max (handles 0–100 and 0–10000 scales).
#
# Output: data/raw/impervious.tif (cropped + reprojected to WGS84, values 0–1)

emc_path <- file.path(DATA_TO_IMP, "emc_built",
                      "EMC_BUILT_S_E2022_GLOBE_R2025A_54009_10_V1_0_R5_C31.tif")

if (file.exists(emc_path)) {
  cat("Processing EMC-BUILT impervious surface...\n")
  emc_raw <- rast(emc_path)

  # Project the city bounding box into the raster's native CRS for cropping
  city_bbox_vect <- vect(
    cbind(c(BBOX_CITY["xmin"], BBOX_CITY["xmax"]),
          c(BBOX_CITY["ymin"], BBOX_CITY["ymax"])),
    type = "points", crs = "EPSG:4326"
  ) |> project(crs(emc_raw))

  emc_extent <- ext(city_bbox_vect) * 1.05   # 5 % buffer against projection edge effects

  emc_crop   <- crop(emc_raw, emc_extent)

  # Reproject to WGS84 using bilinear interpolation (continuous values)
  emc_wgs84  <- project(emc_crop, "EPSG:4326", method = "bilinear")

  # Normalise to 0–1 fraction; auto-detect scale (R2023 uses 0–100, older 0–10000)
  raw_max    <- global(emc_wgs84, "max", na.rm = TRUE)[[1]]
  scale_fac  <- if (raw_max > 1000) 10000 else 100
  impervious <- clamp(emc_wgs84 / scale_fac, 0, 1)
  names(impervious) <- "impervious_fraction"

  writeRaster(impervious, file.path(DATA_RAW, "impervious.tif"), overwrite = TRUE,
              datatype = "FLT4S")
  cat(sprintf(
    "  → Impervious surface written (scale factor: %g, city mean: %.2f)\n",
    scale_fac, global(impervious, "mean", na.rm = TRUE)[[1]]
  ))
} else {
  warning(sprintf(
    "EMC-BUILT not found: %s\n  Download from https://human-settlement.emergency.copernicus.eu/",
    emc_path
  ))
}

# ── 6. Sentinel-2 NDVI (optional — manual download required) ─────────────────
# Download a cloud-free Sentinel-2 L2A tile for Yokohama from:
#   https://browser.dataspace.copernicus.eu/
# Place the .SAFE folder at: data/raw/sentinel2/T54SUE_*.SAFE
# Then uncomment and run.

# sentinel_dir <- file.path(DATA_RAW, "sentinel2")
# s2_bands <- list.files(sentinel_dir, pattern = "B0[48]_10m\\.jp2$",
#                        recursive = TRUE, full.names = TRUE)
# s2 <- rast(s2_bands)
# ndvi <- (s2[[2]] - s2[[1]]) / (s2[[2]] + s2[[1]])
# names(ndvi) <- "ndvi"
# writeRaster(ndvi, file.path(DATA_RAW, "ndvi.tif"), overwrite = TRUE)
# cat("  → NDVI raster written\n")

# ── 7. Landsat LST (optional — manual download required) ─────────────────────
# Download Landsat 8/9 Collection 2 Level-2 product for path/row 107/035 from:
#   https://earthexplorer.usgs.gov/
# Place the ST_B10 band at: data/raw/landsat/LC09_*_ST_B10.TIF
# Then uncomment and run.

# lst_file <- list.files(file.path(DATA_RAW, "landsat"),
#                        pattern = "ST_B10\\.TIF$", full.names = TRUE)[1]
# lst <- rast(lst_file) * 0.00341802 + 149 - 273.15   # DN → Celsius
# names(lst) <- "lst_celsius"
# writeRaster(lst, file.path(DATA_RAW, "lst.tif"), overwrite = TRUE)
# cat("  → LST raster written\n")

cat("\nIngestion complete. Check data/raw/ for outputs.\n")

