# NatureGap — City configuration
#
# Edit this file to analyse a new area, then run run_pipeline.R.
# Every city-specific variable lives here; the pipeline scripts read them
# and never need to be edited themselves.
#
# To add a second city:
#   1. Copy this file to e.g. config_amsterdam.R
#   2. Edit all values below
#   3. Run: source("config_amsterdam.R"); source("run_pipeline.R")

library(here)

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

BBOX_FETCH <- BBOX_CITY   # set to a different box if observations are sparse

# ── Overpass API ──────────────────────────────────────────────────────────────
OVERPASS_URL <- "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
OVERPASS_FALLBACK_URLS <- c(
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter"
)

# ── Local projection ──────────────────────────────────────────────────────────
# Use a metre-based CRS for your analysis area:
#   Japan          EPSG:6674  (JGD2011 / Japan Plane Rectangular CS VI)
#   Western Europe EPSG:3035  (ETRS89-LAEA)
#   UK             EPSG:27700 (British National Grid)
#   US (general)   EPSG:5070  (Albers Equal-Area Conic)
#   UTM zones      EPSG:32600 + zone number (e.g. 32654 for Yokohama)

CRS_LOCAL <- "EPSG:6674"

# ── Grid resolution ───────────────────────────────────────────────────────────
# Smaller = finer detail but slower to process and heavier to upload.
# Typical values: 25 m (very fine), 50 m (fine), 100 m (standard).

CELL_SIZE <- 20   # metres

# ── Input raster files ────────────────────────────────────────────────────────
# Paths are relative to the repo root (here::here()).
#
# WorldCover (ESA 10 m land cover):
#   Download: https://esa-worldcover.org/
#   Tile name example for Japan: ESA_WorldCover_10m_2021_v200_N33E138_Map.tif

WC_FILE <- file.path(
  DATA_IMPORT, "worldcover",
  "ESA_WorldCover_10m_2021_v200_N33E138_Map.tif"
)

EMC_FILE <- file.path(
  DATA_IMPORT, "emc_built",
  "EMC_BUILT_S_E2022_GLOBE_R2025A_54009_10_V1_0_R5_C31.tif"
)

NDVI_RES_M <- 10L

S2_NDVI_FILE <- file.path(
  DATA_IMPORT, "sentinel2",
  "ndvi_yokohama_honmoku_10m.tif"
)

S2_SAFE_DIR <- file.path(DATA_IMPORT, "sentinel2")
S2_RED_BAND_PATTERN <- "B04_10m\\.jp2$"
S2_NIR_BAND_PATTERN <- "B08_10m\\.jp2$"

LST_FILE <- file.path(
  DATA_IMPORT, "landsat",
  "LC09_L2SP_107035_20230715_20230718_02_T1_ST_B10.TIF"
)

LST_DIR           <- file.path(DATA_IMPORT, "landsat")
LST_BAND_PATTERN  <- "ST_B10\\.TIF$"
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

RAW_LANDCOVER  <- file.path(DATA_RAW, "landcover.tif")
RAW_IMPERVIOUS <- file.path(DATA_RAW, "impervious.tif")
RAW_NDVI       <- file.path(DATA_RAW, "ndvi.tif")
RAW_LST        <- file.path(DATA_RAW, "lst.tif")
RAW_INAT       <- file.path(DATA_RAW, "inat_observations.gpkg")
RAW_GBIF       <- file.path(DATA_RAW, "gbif_observations.gpkg")
RAW_OSM_GREEN  <- file.path(DATA_RAW, "osm_green_spaces.gpkg")
RAW_OSM_PATHS  <- file.path(DATA_RAW, "osm_paths.gpkg")

PROC_GRID_HABITAT <- file.path(DATA_PROC, "grid_habitat.gpkg")
PROC_GRID_OBS     <- file.path(DATA_PROC, "grid_observations.gpkg")
PROC_GRID_CONN    <- file.path(DATA_PROC, "grid_connectivity.gpkg")
PROC_GRID_RESID   <- file.path(DATA_PROC, "grid_residuals.gpkg")
PROC_TOP_INTER    <- file.path(DATA_PROC, "top_interventions.csv")
PROC_HABITAT_TIF  <- file.path(DATA_PROC, "habitat_quality.tif")

# ── Mark config as loaded ─────────────────────────────────────────────────────
# Each pipeline script checks for this flag before re-sourcing config.
CONFIG_LOADED <- TRUE

message(sprintf("[config] City: %s (%s) | Cell size: %d m | CITY_ID: %s",
                CITY_NAME, CRS_LOCAL, CELL_SIZE, CITY_ID))
