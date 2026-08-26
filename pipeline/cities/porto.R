# Porto — city-specific values only.
# Everything else comes from pipeline/config.R.
#
#   CITY <- "porto"; source("config.R"); source("run_pipeline.R")

# ── City identity ─────────────────────────────────────────────────────────────
# CITY_ID must be a stable slug — it is used as a primary-key prefix in
# Supabase and as the folder name in Storage (pipeline-export/<CITY_ID>/).
# Changing it later means migrating existing database rows.

CITY_ID      <- "porto"
CITY_NAME    <- "Porto"
CITY_COUNTRY <- "Portugal"

# Metre-based CRS — ETRS89 / Portugal TM06
CRS_LOCAL <- "EPSG:3763"

# ── OSM regional extract (aoi + osmium) ───────────────────────────────────────
city         <- "porto"                      # boundary cache + data/tiles/<city>/
REGIONAL_PBF <- "portugal-latest.osm.pbf"    # under data/raw/regional/

aoi_mode    <- "relation"                    # "relation", "bbox", or "file"
relation_id <- 3372453L                      # Porto
# bbox <- c(xmin = ..., ymin = ..., xmax = ..., ymax = ...)  # set aoi_mode <- "bbox" to use
# aoi_file  <- "data/boundaries/custom/porto.geojson"   # set aoi_mode <- "file" to use
#                                              # GeoJSON preferred (.shp/.gpkg also read),
#                                              # path relative to pipeline/, must have a CRS
# aoi_layer <- "layer_name"                    # optional, only for multi-layer .gpkg

# ── Tileset sharding ──────────────────────────────────────────────────────────
# "yes" publishes the hex tileset as several PMTiles archives instead of one,
# for a city whose single archive cannot fit the Storage upload cap even at the
# zoom floor. Analysis is unaffected — one AOI, one hex lattice, one
# connectivity graph, one set of legend percentiles; only the published tiles
# are split, by cell centroid, into equal-count contiguous blocks.
SHARD_TILES   <- "no"
# SHARD_TILES_N <- 2                           # archives to split into (default 2)

# ── Analysis extent (WGS84) ───────────────────────────────────────────────────
# Optional: without this, config.R derives BBOX_CITY from the AOI extent.
# Porto analyses the city centre, not the full municipality relation.

#BBOX_CITY <- c(
#  xmin = -8.653278,
#  ymin = 41.140140,
#  xmax = -8.572168,
#  ymax = 41.177104
#)

# ── Optional raster sources ───────────────────────────────────────────────────
# The DGT CIR downloader is added automatically by config.R, from
# CIR_DOWNLOADER_BY_COUNTRY — CITY_COUNTRY is "Portugal".
RASTER_DOWNLOADERS_EXTRA <- c(
  "00_download/download_canopy_height.R"
)
