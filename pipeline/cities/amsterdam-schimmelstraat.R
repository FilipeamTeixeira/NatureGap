# Amsterdam — city-specific values only.
# Everything else comes from pipeline/config.R.
#
#   CITY <- "amsterdam-schimmelstraat"; source("config.R"); source("run_pipeline.R")

# ── City identity ─────────────────────────────────────────────────────────────
# CITY_ID must be a stable slug — it is used as a primary-key prefix in
# Supabase and as the folder name in Storage (pipeline-export/<CITY_ID>/).
# Changing it later means migrating existing database rows.

CITY_ID      <- "amsterdam-schimmelstraat"
CITY_NAME    <- "Amsterdam"
CITY_COUNTRY <- "The Netherlands"

# Metre-based CRS — Amersfoort / RD New
CRS_LOCAL <- "EPSG:28992"

# ── OSM regional extract (aoi + osmium) ───────────────────────────────────────
city         <- "noord-holland"                  # boundary cache + data/tiles/<city>/
REGIONAL_PBF <- "noord-holland-latest.osm.pbf"   # under data/raw/regional/

aoi_mode    <- "relation"                        # "relation" or "bbox"
relation_id <- c(11960504L, 15419236L)           # Amsterdam. Add adjacent relation IDs
                                                 # here (e.g. Amstelveen, Diemen) — all
                                                 # IDs are unioned into one AOI polygon.
# bbox <- c(xmin = ..., ymin = ..., xmax = ..., ymax = ...)  # set aoi_mode <- "bbox" to use

# ── Optional raster sources ───────────────────────────────────────────────────
RASTER_DOWNLOADERS_EXTRA <- c(
  "00_download/download_canopy_height.R",
  "00_download/download_planetscope_ndvi.R",
  "00_download/download_nl_cir_ndvi.R"
)
