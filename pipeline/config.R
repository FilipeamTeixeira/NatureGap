# NatureGap — City configuration
#
# Edit this file to analyse a new area, then run run_pipeline.R.
# Every city-specific variable lives here; the pipeline scripts read them
# and never need to be edited themselves.
#
# To add a second city:
#   1. Copy this file to e.g. config_amsterdam.R
#   2. Edit all values below
#   3. Run: source("pipeline/config_amsterdam.R"); source("pipeline/run_pipeline.R")

library(here)

# pipeline.Rproj lives in pipeline/, so here() may be the pipeline folder or the
# repo root. Resolve paths from the directory that contains 01_ingest/.
PIPELINE_ROOT <- local({
  root <- here::here()
  if (dir.exists(file.path(root, "01_ingest"))) return(root)
  nested <- file.path(root, "pipeline")
  if (dir.exists(file.path(nested, "01_ingest"))) return(nested)
  stop("Cannot locate pipeline directory (expected 01_ingest/)")
})

DATA_IMPORT <- file.path(PIPELINE_ROOT, "data", "to_import")

# ── City identity ─────────────────────────────────────────────────────────────
# CITY_ID must be a stable slug — it is used as a primary-key prefix in
# Supabase and as the folder name in Storage (pipeline-export/<CITY_ID>/).
# Changing it later means migrating existing database rows.

CITY_ID      <- "yokohama-honmoku"
CITY_NAME    <- "Honmoku, Yokohama"
CITY_COUNTRY <- "Japan"

# ── Spatial extent (WGS84) ────────────────────────────────────────────────────
# BBOX_CITY  — the analysis domain; the hex grid is built inside this box.
# BBOX_FETCH — the window for iNaturalist / GBIF API calls.
#              Can be wider than BBOX_CITY to capture edge observations.

BBOX_CITY <- c(
  xmin = 139.640415,
  ymin = 35.415460,
  xmax = 139.672859,
  ymax = 35.430148
)

BBOX_FETCH <- c(
  xmin = unname(BBOX_CITY["xmin"]) - 0.004,
  ymin = unname(BBOX_CITY["ymin"]) - 0.004,
  xmax = unname(BBOX_CITY["xmax"]) + 0.004,
  ymax = unname(BBOX_CITY["ymax"]) + 0.004
)   # slightly wider than analysis domain to capture edge observations

# ── Observation ingest ────────────────────────────────────────────────────────
# iNaturalist "Verifiable" on the website ≈ research + needs_id (not casual).
# Fetched via api.inaturalist.org (rinat does not support needs_id).
INAT_QUALITY_GRADES <- c("research", "needs_id")
INAT_MAX_RESULTS    <- 10000L   # total cap for bbox pagination
GBIF_MAX_RESULTS    <- 10000L
# osmdata defaults to overpass.kumi.systems, which is often overloaded and
# retries with 60 s backoff. Prefer overpass-api.de; fall back if it is busy:
# https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances

OVERPASS_URL <- "https://overpass-api.de/api/interpreter"
OVERPASS_FALLBACK_URLS <- c(
  "https://overpass.kumi.systems/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
)
OVERPASS_RETRIES     <- 3L    # attempts per endpoint before moving on
OVERPASS_RETRY_WAIT  <- 45L   # seconds between retries (Overpass rate-limits)

# Re-use existing OSM extracts on re-runs instead of hitting Overpass again.
OSM_SKIP_IF_EXISTS   <- TRUE

# ── Local projection ──────────────────────────────────────────────────────────
# Use a metre-based CRS for your analysis area:
#   Japan          EPSG:6674  (JGD2011 / Japan Plane Rectangular CS VI)
#   Western Europe EPSG:3035  (ETRS89-LAEA)
#   UK             EPSG:27700 (British National Grid)
#   US (general)   EPSG:5070  (Albers Equal-Area Conic)
#   UTM zones      EPSG:32600 + zone number (e.g. 32654 for Yokohama)

CRS_LOCAL <- "EPSG:6674"

# ── Grid resolution ───────────────────────────────────────────────────────────
# Primary spatial unit. All modelling, analysis, storage, and display use this
# single 20 m hex grid; do not introduce secondary analytical grid resolutions.

CELL_SIZE <- 20   # metres

# ── Biodiversity index parameters ───────────────────────────────────────────
# Upper bound for expected species richness at habitat_quality = 1.0.
# Used in residuals.R and exported to the frontend for transparency.
# This is an index, not a calibrated species distribution model.

MAX_EXPECTED_RICHNESS <- 350L

# ── Input raster files ────────────────────────────────────────────────────────
# Paths are relative to PIPELINE_ROOT (see pipeline/data/to_import/).
#
# WorldCover (ESA 10 m land cover):
#   Download: https://esa-worldcover.org/
#   Tile name example for Japan: ESA_WorldCover_10m_2021_v200_N33E138_Map.tif

WC_FILE <- file.path(
  DATA_IMPORT, "worldcover",
  "ESA_WorldCover_10m_2021_v200_N33E138_Map.tif"
)

# EMC-BUILT (Copernicus impervious surface fraction):
#   Download: https://human-settlement.emergency.copernicus.eu/
#   File name example: EMC_BUILT_S_E2022_GLOBE_R2025A_54009_10_V1_0_R5_C31.tif

EMC_FILE <- file.path(
  DATA_IMPORT, "emc_built",
  "EMC_BUILT_S_E2022_GLOBE_R2025A_54009_10_V1_0_R5_C31.tif"
)

# Sentinel-2 NDVI (optional — manual download required)
# Download from https://browser.dataspace.copernicus.eu/ (tile T54SUE for Yokohama)
#
# Two options (ingest prefers S2_NDVI_FILE when it exists):
#   1. Pre-computed NDVI GeoTIFF — set S2_NDVI_FILE below (export at NDVI_RES_M)
#   2. Raw L2A .SAFE product     — place under S2_SAFE_DIR and set S2_NDVI_FILE to NA

NDVI_RES_M <- 10L

S2_NDVI_FILE <- file.path(
  DATA_IMPORT, "sentinel2",
  "ndvi_yokohama_honmoku_10m.tif"
)

S2_SAFE_DIR <- file.path(DATA_IMPORT, "sentinel2")
S2_RED_BAND_PATTERN <- "B04_10m\\.jp2$"
S2_NIR_BAND_PATTERN <- "B08_10m\\.jp2$"

# Landsat LST (optional — manual download required)
# Use a prepared LST raster when available, or download Landsat 8/9 Collection 2
# Level-2 ST_B10 from https://earthexplorer.usgs.gov/.
# Path/row for Yokohama: 107/035. Set LST_FILE to NA to skip.

LST_FILE <- file.path(
  DATA_IMPORT, "landsat",
  "LST_yokohama-honmoku.tif"
)

LST_DIR           <- file.path(DATA_IMPORT, "landsat")
LST_BAND_PATTERN  <- "(^LST_.*\\.tif$|ST_B10\\.TIF$)"
LST_DN_SCALE      <- 0.00341802
LST_DN_OFFSET     <- 149

# ── Derived data paths ────────────────────────────────────────────────────────
# Each city gets its own sub-folder so cities never overwrite each other's data.
# to_import/ is shared (rasters are large and often cover multiple cities).

DATA_ROOT   <- file.path(PIPELINE_ROOT, "data", CITY_ID)
DATA_RAW    <- file.path(DATA_ROOT, "raw")
DATA_PROC   <- file.path(DATA_ROOT, "processed")
DATA_EXPORT <- file.path(DATA_ROOT, "export")
DATA_TO_IMP <- DATA_IMPORT

for (d in c(DATA_RAW, DATA_PROC, DATA_EXPORT)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

# Processed ingest outputs (written by 01_ingest, read by 02+)
RAW_LANDCOVER  <- file.path(DATA_RAW, "landcover.tif")
RAW_IMPERVIOUS <- file.path(DATA_RAW, "impervious.tif")
RAW_NDVI       <- file.path(DATA_RAW, "ndvi.tif")
RAW_LST        <- file.path(DATA_RAW, "lst.tif")
RAW_INAT       <- file.path(DATA_RAW, "inat_observations.gpkg")
RAW_GBIF       <- file.path(DATA_RAW, "gbif_observations.gpkg")
RAW_OSM_GREEN  <- file.path(DATA_RAW, "osm_green_spaces.gpkg")
RAW_OSM_PATHS  <- file.path(DATA_RAW, "osm_paths.gpkg")
RAW_OSM_ROADS  <- file.path(DATA_RAW, "osm_roads.gpkg")
RAW_OSM_RAIL   <- file.path(DATA_RAW, "osm_rail.gpkg")
RAW_OSM_LAMPS  <- file.path(DATA_RAW, "osm_street_lamps.gpkg")
RAW_OSM_LIT_ROADS <- file.path(DATA_RAW, "osm_lit_roads.gpkg")
RAW_OSM_AMENITIES <- file.path(DATA_RAW, "osm_amenities.gpkg")
RAW_OSM_WATER  <- file.path(DATA_RAW, "osm_water.gpkg")

# Processed pipeline outputs
PROC_GRID_HABITAT <- file.path(DATA_PROC, "grid_habitat.gpkg")
PROC_GRID_OBS     <- file.path(DATA_PROC, "grid_observations.gpkg")
PROC_GRID_CONN    <- file.path(DATA_PROC, "grid_connectivity.gpkg")
PROC_GRID_RESID   <- file.path(DATA_PROC, "grid_residuals.gpkg")
PROC_CELL_ATTR    <- file.path(DATA_PROC, "cell_attributes.gpkg")
PROC_TOP_INTER    <- file.path(DATA_PROC, "top_interventions.csv")
PROC_HABITAT_TIF  <- file.path(DATA_PROC, "habitat_quality.tif")
PROC_CELL_TAXA    <- file.path(DATA_PROC, "cell_taxa.json")

# ── Mark config as loaded ─────────────────────────────────────────────────────
# Each pipeline script checks for this flag before re-sourcing config.
CONFIG_LOADED <- TRUE

message(sprintf("[config] City: %s (%s) | Cell size: %d m | CITY_ID: %s",
                CITY_NAME, CRS_LOCAL, CELL_SIZE, CITY_ID))
