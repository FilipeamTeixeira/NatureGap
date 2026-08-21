# Honmoku, Yokohama — city-specific values only.
# Everything else comes from pipeline/config.R.
#
#   CITY <- "yokohama"; source("config.R"); source("run_pipeline.R")

# ── City identity ─────────────────────────────────────────────────────────────
# CITY_ID must be a stable slug — it is used as a primary-key prefix in
# Supabase and as the folder name in Storage (pipeline-export/<CITY_ID>/).
# Changing it later means migrating existing database rows.

CITY_ID      <- "yokohama"
CITY_NAME    <- "Yokohama"
CITY_COUNTRY <- "Japan"

# Metre-based CRS — JGD2011 / Japan Plane Rectangular CS VI
CRS_LOCAL <- "EPSG:6674"

# ── OSM regional extract (aoi + osmium) ───────────────────────────────────────
city         <- "yokohama"        # boundary cache + data/tiles/<city>/
REGIONAL_PBF <- "kanto-latest.osm.pbf"    # under data/raw/regional/

aoi_mode    <- "relation"                 # "relation" or "bbox"
relation_id <- c(2689447L, 2689464L, 2689468L, 2689452L)                # Yokohama

#Naka-ku: 2689447
#Isogo-ku: 2689464
#Nishi-ku: 2689468
#Minami-ku: 2689452

# bbox <- c(xmin = ..., ymin = ..., xmax = ..., ymax = ...)  # set aoi_mode <- "bbox" to use



# ── Optional raster sources ───────────────────────────────────────────────────
RASTER_DOWNLOADERS_EXTRA <- c(
  "00_download/download_canopy_height.R"
)
