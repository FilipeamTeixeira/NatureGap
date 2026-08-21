# Gent — city-specific values only.
# Everything else comes from pipeline/config.R.
#
#   CITY <- "gent"; source("config.R"); source("run_pipeline.R")

# ── City identity ─────────────────────────────────────────────────────────────
# CITY_ID must be a stable slug — it is used as a primary-key prefix in
# Supabase and as the folder name in Storage (pipeline-export/<CITY_ID>/).
# Changing it later means migrating existing database rows.

CITY_ID      <- "gent"
CITY_NAME    <- "Gent"
CITY_COUNTRY <- "Belgium"

# Metre-based CRS — BD72 / Belgian Lambert 72. Required by the Digitaal
# Vlaanderen CIR downloader, which serves EPSG:31370 and does not reproject
# (see CIR_EXPECTED_CRS in config.R).
CRS_LOCAL <- "EPSG:31370"

# ── OSM regional extract (aoi + osmium) ───────────────────────────────────────
city         <- "gent"                       # boundary cache + data/tiles/<city>/
REGIONAL_PBF <- "belgium-latest.osm.pbf"     # under data/raw/regional/

aoi_mode    <- "relation"                    # "relation" or "bbox"
relation_id <- 897671L                       # Gent (municipality, admin_level 8)
# bbox <- c(xmin = ..., ymin = ..., xmax = ..., ymax = ...)  # set aoi_mode <- "bbox" to use

# ── Analysis extent (WGS84) ───────────────────────────────────────────────────
# Optional: without this, config.R derives BBOX_CITY from the AOI extent.
#
# Set here deliberately. The Gent municipality relation spans roughly 19 x 23 km
# (it reaches out to the Kanaalzone and the rural deelgemeenten), which at the
# CIR downloader's 0.5 m/px works out to ~300 tiles and several GB of imagery —
# over that script's MAX_TILES guard. This box is the contiguous urban core plus
# its immediate green belt: Bourgoyen-Ossemeersen in the west, Gentbrugse
# Meersen in the south-east, the Blaarmeersen, and the inner city.
#
# To analyse the whole municipality instead, comment this out and raise
# MAX_TILES / TARGET_GSD_M in 00_download/download_be_flanders_cir_ndvi.R.
BBOX_CITY <- c(
  xmin = 3.660,
  ymin = 51.010,
  xmax = 3.780,
  ymax = 51.090
)

# ── Optional raster sources ───────────────────────────────────────────────────
# The Digitaal Vlaanderen CIR downloader is added automatically by config.R,
# from CIR_DOWNLOADER_BY_COUNTRY — CITY_COUNTRY is "Belgium".
#
# No PlanetScope here: CIR already gives ~1,385 px per 20 m hex, and
# PlanetScope's output is never read by ingest. See CIR_DOWNLOADER_BY_COUNTRY
# in config.R.
RASTER_DOWNLOADERS_EXTRA <- c(
  "00_download/download_canopy_height.R"
)
