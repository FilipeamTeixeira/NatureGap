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

REPO_ROOT <- if (basename(PIPELINE_ROOT) == "pipeline") dirname(PIPELINE_ROOT) else PIPELINE_ROOT

load_env_file <- function(path) {
  if (!file.exists(path)) return(invisible(FALSE))
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nzchar(lines) & !startsWith(lines, "#")]
  for (line in lines) {
    line <- sub("^export[[:space:]]+", "", line)
    key <- sub("=.*$", "", line)
    value <- sub("^[^=]*=", "", line)
    key <- trimws(key)
    value <- trimws(value)
    value <- sub("^['\"]", "", value)
    value <- sub("['\"]$", "", value)
    if (nzchar(key) && !nzchar(Sys.getenv(key, unset = ""))) {
      do.call(Sys.setenv, stats::setNames(list(value), key))
    }
  }
  invisible(TRUE)
}

database_url <- function() {
  value <- Sys.getenv("DATABASE_URL", unset = "")
  if (!nzchar(value)) value <- Sys.getenv("database_URL", unset = "")
  trimws(value)
}

describe_database_url <- function(value = database_url()) {
  if (!nzchar(value)) return("<not set>")
  redacted <- sub("://([^:/@]+):([^@]+)@", "://\\1:***@", value)
  if (nchar(redacted) > 90) {
    paste0(substr(redacted, 1, 87), "...")
  } else {
    redacted
  }
}

parse_database_url <- function(value = database_url()) {
  if (!nzchar(value)) stop("DATABASE_URL is not set", call. = FALSE)
  match <- regexec("^postgres(?:ql)?://([^:]+):([^@]+)@([^:/?]+)(?::([0-9]+))?/([^?]+)(?:\\?(.*))?$", value)
  parts <- regmatches(value, match)[[1]]
  if (length(parts) == 0L) {
    stop("DATABASE_URL must look like postgresql://user:password@host:port/database?sslmode=require", call. = FALSE)
  }

  query <- if (length(parts) >= 7L) parts[[7L]] else ""
  params <- list()
  if (nzchar(query)) {
    for (item in strsplit(query, "&", fixed = TRUE)[[1]]) {
      kv <- strsplit(item, "=", fixed = TRUE)[[1]]
      if (length(kv) == 2L) params[[kv[[1L]]]] <- kv[[2L]]
    }
  }

  list(
    user = utils::URLdecode(parts[[2L]]),
    password = utils::URLdecode(parts[[3L]]),
    host = parts[[4L]],
    port = if (nzchar(parts[[5L]])) as.integer(parts[[5L]]) else 5432L,
    dbname = parts[[6L]],
    sslmode = if (!is.null(params$sslmode) && nzchar(params$sslmode)) params$sslmode else "require"
  )
}

connect_database <- function(value = database_url()) {
  if (!requireNamespace("DBI", quietly = TRUE) || !requireNamespace("RPostgres", quietly = TRUE)) {
    stop("Packages 'DBI' and 'RPostgres' are required for PostgreSQL access.", call. = FALSE)
  }

  cfg <- parse_database_url(value)
  DBI::dbConnect(
    RPostgres::Postgres(),
    dbname = cfg$dbname,
    host = cfg$host,
    port = cfg$port,
    user = cfg$user,
    password = cfg$password,
    sslmode = cfg$sslmode
  )
}

for (env_file in c(
  file.path(REPO_ROOT, ".env.local"),
  file.path(REPO_ROOT, ".env"),
  file.path(PIPELINE_ROOT, ".env.local"),
  file.path(PIPELINE_ROOT, ".env")
)) {
  load_env_file(env_file)
}

DATA_IMPORT <- file.path(PIPELINE_ROOT, "data", "raw")

# ── City identity ─────────────────────────────────────────────────────────────
# CITY_ID must be a stable slug — it is used as a primary-key prefix in
# Supabase and as the folder name in Storage (pipeline-export/<CITY_ID>/).
# Changing it later means migrating existing database rows.

CITY_ID      <- "yokohama-honmoku"
CITY_NAME    <- "Honmoku, Yokohama"
CITY_COUNTRY <- "Japan"

# CITY_ID      <- "amsterdam-schimmelstraat"
# CITY_NAME    <- "Amsterdam"
# CITY_COUNTRY <- "The Netherlands"

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
#
# BBOX_CITY <- c(
#   xmin = 4.854712,
#   ymin = 52.366756,
#   xmax = 4.870934,
#   ymax = 52.372259
# )


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
# Raster inputs are downloaded/prepared by the scripts listed below before
# ingest reads them. Shared raster inputs live under pipeline/data/raw/.

AUTO_DOWNLOAD_RASTER_INPUTS <- TRUE

RASTER_INPUT_DOWNLOADERS <- file.path(
  PIPELINE_ROOT,
  c(
    "00_download/download_worldcover.R",
    "00_download/download_sentinel2.R",
    "00_download/download_landsat_temp.R"
  )
)

WC_FILE <- file.path(
  DATA_IMPORT, "worldcover",
  paste0("worldcover_", CITY_ID, ".tif")
)

# EMC-BUILT (Copernicus impervious surface fraction):
#   Download manually: https://human-settlement.emergency.copernicus.eu/
#   File name expected by the pipeline: EMC_CITY_ID.tif
#   Example: EMC_yokohama-honmoku.tif

EMC_FILE <- file.path(
  PIPELINE_ROOT, "data", "raw", "emc_built",
  paste0("EMC_", CITY_ID, ".tif")
)

NDVI_RES_M <- 10L

S2_NDVI_FILE <- file.path(
  DATA_IMPORT, "sentinel2",
  paste0("ndvi_", CITY_ID, ".tif")
)

S2_SAFE_DIR <- file.path(DATA_IMPORT, "sentinel2")
S2_RED_BAND_PATTERN <- "B04_10m\\.jp2$"
S2_NIR_BAND_PATTERN <- "B08_10m\\.jp2$"

LST_FILE <- file.path(
  DATA_IMPORT, "landsat",
  paste0("lst_", CITY_ID, ".tif")
)

LST_DIR           <- file.path(DATA_IMPORT, "landsat")
LST_BAND_PATTERN  <- "(^[Ll][Ss][Tt]_.*\\.tif$|ST_B10\\.TIF$)"
LST_DN_SCALE      <- 0.00341802
LST_DN_OFFSET     <- 149

CANOPY_HEIGHT_FILE <- file.path(
  DATA_IMPORT, "lidar",
  paste0("canopy_height_", CITY_ID, ".tif")
)

LIDAR_VARIANCE_FILE <- file.path(
  DATA_IMPORT, "lidar",
  paste0("lidar_variance_", CITY_ID, ".tif")
)

# ── Derived data paths ────────────────────────────────────────────────────────
# Each city gets its own sub-folder so cities never overwrite each other's data.
# data/raw/ is shared for source rasters; city-specific outputs live under
# data/CITY_ID/.

DATA_ROOT   <- file.path(PIPELINE_ROOT, "data", CITY_ID)
DATA_RAW    <- file.path(DATA_ROOT, "raw")
DATA_PROC   <- file.path(DATA_ROOT, "processed")
DATA_EXPORT <- file.path(DATA_ROOT, "export")

for (d in c(DATA_RAW, DATA_PROC, DATA_EXPORT)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

# Processed ingest outputs (written by 01_ingest, read by 02+)
RAW_LANDCOVER  <- file.path(DATA_RAW, "landcover.tif")
RAW_IMPERVIOUS <- file.path(DATA_RAW, "impervious.tif")
RAW_NDVI       <- file.path(DATA_RAW, "ndvi.tif")
RAW_LST        <- file.path(DATA_RAW, "lst.tif")
RAW_CANOPY_HEIGHT <- file.path(DATA_RAW, "canopy_height.tif")
RAW_LIDAR_VARIANCE <- file.path(DATA_RAW, "lidar_variance.tif")
RAW_INAT       <- file.path(DATA_RAW, "inat_observations.gpkg")
RAW_GBIF       <- file.path(DATA_RAW, "gbif_observations.gpkg")
RAW_SUPABASE_OBS <- file.path(DATA_RAW, "supabase_observations.gpkg")
RAW_OSM_GREEN  <- file.path(DATA_RAW, "osm_green_spaces.gpkg")
RAW_NATIONAL_GREEN <- file.path(DATA_RAW, "national_green_spaces.gpkg")
RAW_OSM_PATHS  <- file.path(DATA_RAW, "osm_paths.gpkg")
RAW_OSM_ROADS  <- file.path(DATA_RAW, "osm_roads.gpkg")
RAW_OSM_RAIL   <- file.path(DATA_RAW, "osm_rail.gpkg")
RAW_OSM_LAMPS  <- file.path(DATA_RAW, "osm_street_lamps.gpkg")
RAW_OSM_LIT_ROADS <- file.path(DATA_RAW, "osm_lit_roads.gpkg")
RAW_OSM_AMENITIES <- file.path(DATA_RAW, "osm_amenities.gpkg")
RAW_OSM_WATER  <- file.path(DATA_RAW, "osm_water.gpkg")

# Processed pipeline outputs
PROC_HEX_CELLS <- file.path(DATA_PROC, "hex_cells.gpkg")
PROC_HEX_CELLS_DISPLAY <- file.path(DATA_PROC, "hex_cells_display.gpkg")
PROC_GREEN_SPACES <- file.path(DATA_PROC, "green_spaces.gpkg")
PROC_GRID_HABITAT <- file.path(DATA_PROC, "grid_habitat.gpkg")
PROC_GRID_OBS     <- file.path(DATA_PROC, "grid_observations.gpkg")
PROC_GRID_CONN    <- file.path(DATA_PROC, "grid_connectivity.gpkg")
PROC_CONNECTIVITY_GRAPH <- file.path(DATA_PROC, "connectivity_graph.rds")
PROC_GREEN_SPACES_AGG <- file.path(DATA_PROC, "green_spaces.gpkg")
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
