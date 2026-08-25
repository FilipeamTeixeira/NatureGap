# Amsterdam — city-specific values only.
# Everything else comes from pipeline/config.R.
#
#   CITY <- "amsterdam"; source("config.R"); source("run_pipeline.R")

# ── City identity ─────────────────────────────────────────────────────────────
# CITY_ID must be a stable slug — it is used as a primary-key prefix in
# Supabase and as the folder name in Storage (pipeline-export/<CITY_ID>/).
# Changing it later means migrating existing database rows.

CITY_ID      <- "amsterdam"
CITY_NAME    <- "Amsterdam"
CITY_COUNTRY <- "The Netherlands"

# Metre-based CRS — Amersfoort / RD New
CRS_LOCAL <- "EPSG:28992"

# ── OSM regional extract (aoi + osmium) ───────────────────────────────────────
city         <- "noord-holland"                  # boundary cache + data/tiles/<city>/
REGIONAL_PBF <- "noord-holland-latest.osm.pbf"   # under data/raw/regional/

aoi_mode    <- "relation"                        # "relation", "bbox", or "file"
relation_id <- c(11960504L, 15419236L, 15419239L, 15419240L)           # Amsterdam. Add adjacent relation IDs
                                                 # here (e.g. Amstelveen, Diemen) — all
                                                 # IDs are unioned into one AOI polygon.
# bbox <- c(xmin = ..., ymin = ..., xmax = ..., ymax = ...)  # set aoi_mode <- "bbox" to use
# aoi_file  <- "data/boundaries/custom/amsterdam.geojson"   # set aoi_mode <- "file" to use
#                                              # GeoJSON preferred (.shp/.gpkg also read),
#                                              # path relative to pipeline/, must have a CRS
# aoi_layer <- "layer_name"                    # optional, only for multi-layer .gpkg

# West - 15419236
# Centrum - 11960504
# Zuid - 15419239
# Oost - 15419240

# ── Tileset sharding ──────────────────────────────────────────────────────────
# "yes" publishes the hex tileset as several PMTiles archives instead of one,
# for a city whose single archive cannot fit the Storage upload cap even at the
# zoom floor. Analysis is unaffected — one AOI, one hex lattice, one
# connectivity graph, one set of legend percentiles; only the published tiles
# are split, by cell centroid, into equal-count contiguous blocks.
SHARD_TILES   <- "no"
# SHARD_TILES_N <- 2                           # archives to split into (default 2)

# ── Optional raster sources ───────────────────────────────────────────────────
# The PDOK CIR downloader is added automatically by config.R, from
# CIR_DOWNLOADER_BY_COUNTRY — CITY_COUNTRY is "The Netherlands".
#
# No PlanetScope here. Amsterdam's high-resolution greenness already comes from
# CIR (~1,385 px per 20 m hex vs PlanetScope's ~39), and PlanetScope's output is
# never read by ingest. See CIR_DOWNLOADER_BY_COUNTRY in config.R.
RASTER_DOWNLOADERS_EXTRA <- c(
  "00_download/download_canopy_height.R"
)
