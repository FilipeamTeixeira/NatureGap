# NatureGap — Shared pipeline configuration
#
# Everything that is identical for every city lives in this file. The handful of
# values that actually change per city live in one small file each under
# pipeline/cities/ (CITY_ID, CRS, OSM relation, regional PBF, extra downloaders).
#
# Run a city:
#   CITY <- "porto-center"
#   source("config.R")
#   source("run_pipeline.R")
#
#   # or from the shell, without editing anything:
#   NATUREGAP_CITY=porto-center Rscript run_pipeline.R
#
# Add a city:
#   1. Copy pipeline/cities/porto-center.R to pipeline/cities/<city-id>.R
#   2. Edit the values in it (nothing else needs editing)
#   3. Run it as above

library(here)
library(sf)
library(jsonlite)

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
    sslmode = cfg$sslmode,
    gssencmode = "disable"
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

#START_STEP <- 1

# ── City selection ────────────────────────────────────────────────────────────
# The city is chosen by the CITY variable if it is already defined, otherwise by
# the NATUREGAP_CITY environment variable, otherwise DEFAULT_CITY. CITY is the
# file name (without .R) under pipeline/cities/ and matches CITY_ID.

CITIES_DIR   <- file.path(PIPELINE_ROOT, "cities")
DEFAULT_CITY <- "yokohama-honmoku"

CITY <- local({
  if (exists("CITY", envir = globalenv(), inherits = FALSE)) {
    slug <- get("CITY", envir = globalenv())
    if (is.character(slug) && length(slug) == 1L && nzchar(slug)) return(slug)
  }
  slug <- trimws(Sys.getenv("NATUREGAP_CITY", unset = ""))
  if (nzchar(slug)) slug else DEFAULT_CITY
})

CITY_FILE <- file.path(CITIES_DIR, paste0(CITY, ".R"))
if (!file.exists(CITY_FILE)) {
  stop(sprintf(
    "Unknown city '%s'. Available: %s",
    CITY,
    paste(sub("\\.R$", "", list.files(CITIES_DIR, pattern = "\\.R$")), collapse = ", ")
  ), call. = FALSE)
}

# Drop optional values left behind by a previously loaded city, so switching
# cities in one R session cannot inherit the previous city's settings.
local({
  optional <- c("relation_id", "bbox", "BBOX_CITY", "halo_m", "tile_size_m",
                "RASTER_DOWNLOADERS_EXTRA")
  stale <- intersect(optional, ls(envir = globalenv()))
  if (length(stale)) rm(list = stale, envir = globalenv())
})

source(CITY_FILE)

local({
  required <- c("CITY_ID", "CITY_NAME", "CITY_COUNTRY", "CRS_LOCAL", "city",
                "REGIONAL_PBF", "aoi_mode")
  missing <- required[!vapply(required, exists, logical(1))]
  if (length(missing)) {
    stop(sprintf("%s does not define: %s", CITY_FILE, paste(missing, collapse = ", ")),
         call. = FALSE)
  }
})

# ── OSM regional extract (aoi + osmium) ───────────────────────────────────────
# The AOI polygon drives tiling (01_ingest/tile_registry.R) and the analysis
# bounding box below. Boundaries are cached under data/boundaries/.

if (!exists("halo_m"))      halo_m      <- 750    # buffer used for tile halos
if (!exists("tile_size_m")) tile_size_m <- 2000   # core tile edge length before buffering

regional_pbf <- file.path(PIPELINE_ROOT, "data", "raw", "regional", REGIONAL_PBF)

BOUNDARIES_DIR <- file.path(PIPELINE_ROOT, "data", "boundaries")
dir.create(BOUNDARIES_DIR, recursive = TRUE, showWarnings = FALSE)
if (!exists("CONFIG_AOI_HELPERS_LOADED")) {
  source(file.path(PIPELINE_ROOT, "config_aoi_helpers.R"))
}

aoi <- load_city_aoi(
  city = city,
  aoi_mode = aoi_mode,
  boundaries_dir = BOUNDARIES_DIR,
  relation_id = if (aoi_mode == "relation" && exists("relation_id")) relation_id else NULL,
  bbox = if (aoi_mode == "bbox" && exists("bbox")) bbox else NULL
)

if (!file.exists(regional_pbf)) {
  warning("[config] regional_pbf not found: ", regional_pbf, call. = FALSE)
}

# ── Spatial extent (WGS84) ────────────────────────────────────────────────────
# BBOX_CITY  — the analysis domain; the hex grid is built inside this box.
# BBOX_FETCH — the window for iNaturalist / GBIF API calls.
#              Can be wider than BBOX_CITY to capture edge observations.
# Derived from aoi's own extent (not hardcoded) so raster downloads, which are
# all bbox-scoped, cover the same area build_core_tiles() clips from the
# relation — otherwise tiles outside a smaller hardcoded box get no raster
# data and drop out of habitat_quality entirely. A city file may still set
# BBOX_CITY itself to analyse a sub-area of its AOI.

if (!exists("BBOX_CITY")) {
  aoi_bbox <- sf::st_bbox(sf::st_transform(aoi, 4326))
  BBOX_CITY <- c(
    xmin = unname(aoi_bbox["xmin"]),
    ymin = unname(aoi_bbox["ymin"]),
    xmax = unname(aoi_bbox["xmax"]),
    ymax = unname(aoi_bbox["ymax"])
  )
}

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
# Fetched with id_above cursor pagination, so these are real ceilings rather
# than aspirations: the previous &page= paging hit the v1 API's hard limit of
# page * per_page <= 10000 and silently truncated every city to 10,000 records
# (Porto's bbox holds 20,806 verifiable observations). Both fetchers now warn
# when a bbox holds more than was downloaded.
INAT_MAX_RESULTS    <- 100000L  # total cap for bbox cursor pagination
# occ_search cannot page past offset 100,000; beyond that GBIF needs a
# credentialed occ_download. This is that ceiling, not a chosen sample size.
# At 300 records per request a full 100k fetch is ~334 sequential calls, so
# lower it deliberately if ingest runtime matters more than completeness.
GBIF_MAX_RESULTS    <- 100000L
# osmdata defaults to overpass.kumi.systems, which is often overloaded and
# retries with 60 s backoff. Prefer overpass-api.de; fall back if it is busy:
# https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances

OVERPASS_URL <- "https://overpass-api.de/api/interpreter"
OVERPASS_FALLBACK_URLS <- c(
  "https://lz4.overpass-api.de/api/interpreter",
  "https://z.overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
)
OVERPASS_RETRIES      <- 5L    # attempts per endpoint before moving on
OVERPASS_RETRY_WAIT   <- 45L   # seconds between retries (Overpass rate-limits)
OVERPASS_QUERY_DELAY  <- 20L   # pause between successive Overpass queries

# Re-use existing OSM extracts on re-runs instead of hitting Overpass again.
OSM_SKIP_IF_EXISTS   <- TRUE

# ── Grid resolution ───────────────────────────────────────────────────────────
# Primary spatial unit. All modelling, analysis, storage, and display use this
# single 20 m hex grid; do not introduce secondary analytical grid resolutions.

CELL_SIZE <- 20   # metres

# ── Path accessibility / survey effort ───────────────────────────────────────
# Effort correction uses OSM pedestrian path density. A 20 m hex is ~350 m², so
# a path centreline only clips a narrow ribbon of cells: testing for a strict
# intersection marks a cell one hex off a footway as unsampled even though it is
# plainly observable from that footway. Measure path length in a neighbourhood
# around the cell centroid instead, and require a real minimum length so a stray
# OSM geometry fragment cannot pass as an access point.
PATH_RADIUS_M <- 40   # neighbourhood radius for path length (~2 hex rings)
MIN_PATH_M    <- 50   # minimum path length in that neighbourhood to count as sampled

# ── Habitat-resistance connectivity ──────────────────────────────────────────
# Corridors run on a hex-adjacency graph weighted by habitat resistance, NOT on
# the pedestrian path network. Paths model *observer effort* (where people walk,
# hence where records come from) and stay confined to the effort correction
# above; they are not a model of where wildlife can move. Reusing them for
# corridors ranked busy streets as prime habitat links and made green space with
# no footway invisible. See docs/methodology.md section 9.
#
# Permeability is vegetation discounted by built cover:
#   permeability = vegetation * (1 - built_fraction_wc)
# docs/methodology.md originally specified resistance as 1 - habitat_quality.
# That does not work: habitat_quality is an NDVI-led blend with almost no
# dynamic range (Amsterdam IQR 0.436-0.598) and it scores a cell that is 87.5%
# built and 3.3% vegetated at 0.515. Resistance built from it spans only ~8.6
# to ~11.7 city-wide — a near-uniform lattice, on which betweenness degenerates
# into geometry and scatters isolated "corridor" cells. Measured on Amsterdam:
# 1 - habitat_quality left 205 isolated top-decile cells; the formula above
# leaves 5.
#
# Resistance is floored at 1 so ideal habitat still costs its real length in
# metres, rising linearly to CONN_MAX_RESISTANCE at zero permeability.
# Zero-cost edges would make shortest paths degenerate, so the floor is
# structural, not cosmetic.
CONN_MAX_RESISTANCE   <- 20    # step cost at permeability = 0, relative to ideal = 1

# Cells at or below this permeability are walls: nothing disperses through
# them, so they are dropped from the graph rather than carried as very-high-cost
# nodes. In a dense city this is most of the grid (Amsterdam keeps 16.5k of
# 53.9k cells), which is both ecologically correct and what makes the job cheap.
# Walls leave the corridor ranking as NA, not as a weak-but-present value.
CONN_MIN_PERMEABILITY <- 0.05

# Dispersal cutoff in effective metres (1 unit = 1 m through ideal habitat).
# Unbounded betweenness assumes an organism routes across the entire AOI to
# reach anywhere else; real dispersal is limited, and on a 259k-cell grid the
# unbounded computation does not finish. 500 m suits small urban birds,
# pollinators and generalist mammals — roughly 25 cells of ideal habitat.
CONN_DISPERSAL_M      <- 500


# ── Derived ecological network (nodes + corridor centrelines) ─────────────────
# The 20 m cells remain the analytical surface; this is the simplified network
# drawn on top of them at overview and transition zooms.
#
# Nodes are habitat cores — connected areas of high-corridor-importance cells,
# one node per core, tiered by area. Corridors are least-cost routes between
# neighbouring nodes across the *whole* resistance surface, so a route may pass
# through degraded ground; the cost ceilings below are what stop that becoming a
# fictional connection across the city.
#
# The earlier version cut the graph at NET_CORE_IMPORTANCE *before* deriving any
# topology, which made a city-scale network structurally impossible: Porto came
# out as 130 disconnected islands and 420 segments with a median length of 84 m.
NET_CORE_IMPORTANCE     <- 0.5   # corridor_importance floor for habitat-core membership
NET_CORE_MIN_AREA_HA    <- 0.4   # smaller cores cannot anchor a node at all
NET_MAJOR_AREA_HA       <- 8     # core area that earns a major node
NET_SECONDARY_AREA_HA   <- 2     # ... and a secondary node

# Node count scales with AOI extent, not with how green the city happens to be.
# Keyed to a cell-count threshold instead, Porto drew 160 secondary nodes against
# Amsterdam's 84 for no ecological reason, and the two maps stopped being
# comparable.
NET_NODES_PER_KM2       <- 1.5
NET_NODES_MIN           <- 12
NET_NODES_MAX           <- 40

# Candidate connections: Delaunay neighbours only (k-nearest as a fallback when
# triangulation is unavailable). All-pairs routing would be affordable at this
# node count but produces a bundle of near-parallel routes between everything,
# which pruning then has to undo. Delaunay also guarantees the candidate set is
# connected before the distance ceiling is applied.
NET_CANDIDATE_K         <- 4     # fallback neighbours per node
NET_MAX_LINK_M          <- 2500  # straight-line ceiling on a candidate pair

# Cost ceilings — the counterweight to routing through degraded ground. Cost is
# in effective metres (1 = 1 m of ideal habitat, up to CONN_MAX_RESISTANCE
# through a near-wall), so cost / geometric length is the route's mean
# resistance. Without a ceiling, every node pair has *some* least-cost path and
# the map trades true-but-trivial fragments for clean-looking fictions.
NET_MAX_ROUTE_RESISTANCE <- 14     # reject a route whose mean resistance exceeds this
NET_MAX_ROUTE_COST_M     <- 40000  # ... or whose absolute effective cost does

# Pruning. The backbone is a minimum spanning tree over route cost; a non-tree
# link survives only if it is much cheaper than the detour the tree forces, and
# only if it does not retrace a route already kept.
NET_REDUNDANCY_RATIO    <- 0.6   # keep an extra link at < this fraction of the tree detour
NET_MAX_ROUTE_OVERLAP   <- 0.5   # ... unless it reuses more than this share of kept cells

# Corridor quality, as mean resistance along the route. Interpretive breaks, not
# sourced: they divide the 1-CONN_MAX_RESISTANCE cost scale into classes that
# separate "runs through habitat" from "runs through the built fabric". There is
# no "fragmented" class — NET_MAX_ROUTE_RESISTANCE rejects a route that bad, and
# a corridor that is broken rather than merely poor is described by its
# bottleneck sections instead of by its average.
NET_STRENGTH_BREAKS     <- c(3, 6, 10)  # strongest | strong | moderate | weak

# Bottlenecks: a run of genuinely hostile cells inside an otherwise useful
# corridor. Carved out of the line as its own section, so the corridor keeps one
# dominant colour and the interruption is explicit rather than being averaged
# away or repainted every few metres.
# 120 m is ~6 cells: an arterial road and its verges, not a gap between shrubs.
# At 60 m two thirds of corridors carried a break and the line went back to
# changing colour every few hundred metres.
NET_BOTTLENECK_PERMEABILITY <- 0.2
NET_BOTTLENECK_MIN_M        <- 120
NET_MIN_SECTION_M           <- 40  # absorb shorter sections into their neighbour

# Geometry. The simplify tolerance has to stay well under the 20 m cell pitch:
# at 6 m Douglas-Peucker ate the curvature the smoother had just produced and
# left a 240 m corridor as four vertices, i.e. a polyline of straight dashes.
NET_SMOOTH_PASSES       <- 2     # corner-cutting passes on centreline geometry
NET_SIMPLIFY_M          <- 2     # Douglas-Peucker tolerance after smoothing

# Shared st_make_grid() phase anchor. spatial_base.R (whole-AOI grid) and
# process_tile.R (per-tile halo grid) must both offset from this exact point,
# or adjacent tiles' hexagons fall out of phase and leave a seam along every
# core_tiles.gpkg boundary.
HEX_GRID_ORIGIN <- sf::st_bbox(
  sf::st_transform(
    sf::st_as_sfc(sf::st_bbox(c(
      xmin = unname(BBOX_CITY["xmin"]), ymin = unname(BBOX_CITY["ymin"]),
      xmax = unname(BBOX_CITY["xmax"]), ymax = unname(BBOX_CITY["ymax"])
    ), crs = 4326)),
    CRS_LOCAL
  )
)[c("xmin", "ymin")]

# ...but offset alone is NOT enough to pin the phase, which is why the seam
# survived HEX_GRID_ORIGIN. sf:::make_hex_grid() reduces the anchor modulo
# dx (= cellsize/sqrt(3)) while the hex *centre* lattice repeats every 3*dx,
# so the surviving phase is floor((anchor - extent_corner)/dx) %% 3 — a
# function of each tile's own extent, not of the anchor. With flat_topped =
# FALSE (st_make_grid's default) that axis is output Y, so north-south
# neighbouring tiles drift by 5.77 m or 11.55 m. Snap the extent corner onto
# the lattice period first and offset then lands at phase zero everywhere.
#
# Pass the result straight to st_make_grid(square = FALSE, offset = origin).
# Takes origin/cell_size explicitly rather than reading the globals so it
# stays safe to call inside the furrr tile workers.
hex_lattice_extent <- function(x, origin, cell_size) {
  bb <- sf::st_bbox(x)
  # x period is 2*dy = cell_size; y period is 3*dx = sqrt(3)*cell_size.
  period <- c(cell_size, sqrt(3) * cell_size)
  # The -0.5 keeps the corner half a period away from make_hex_grid()'s own
  # floor() boundary: sqrt(3)*cell_size / (cell_size/sqrt(3)) is not exactly
  # 3 in doubles, so landing on an exact multiple flips the phase back on
  # floating-point noise. Grow the far corner so the snap never clips cells.
  sf::st_as_sfc(sf::st_bbox(
    c(
      xmin = origin[[1]] + (floor((bb[["xmin"]] - origin[[1]]) / period[1]) - 0.5) * period[1],
      ymin = origin[[2]] + (floor((bb[["ymin"]] - origin[[2]]) / period[2]) - 0.5) * period[2],
      xmax = bb[["xmax"]] + period[1],
      ymax = bb[["ymax"]] + period[2]
    ),
    crs = sf::st_crs(bb)
  ))
}

# ── Biodiversity index parameters ───────────────────────────────────────────
# Legacy transparency field only. It no longer scales expected richness at
# either scale; it is exported so consumers can see the historical ceiling.
# This is an index, not a calibrated species distribution model.

MAX_EXPECTED_RICHNESS <- 350L

# ── Expected richness model ──────────────────────────────────────────────────
# expected_richness is the *conditional expectation of the observed quantity*,
# fitted per city, so that ecological_residual = expected - observed is a real
# residual with the same units on both sides.
#
# The fit is a quasi-Poisson GLM with a log link and log(effort) as an offset —
# the standard form for a count observed under varying effort. It replaced OLS on
# the pre-divided ratio, which predicted a negative richness for 19.5% of Porto's
# sampled cells (clamped to 0, making the residual there just -observed) and
# understated the relationship badly: OLS R² 0.0148 against explained deviance
# 0.1987 at hex scale, 0.0532 against 0.2771 at patch scale. Note that because a
# log link minimises deviance rather than squared error, the raw gap is NOT
# centred on the response scale — it is positive in ~90% of sampled cells, which
# is why nature_gap_score centres each term itself (score_scaling.R) and why
# underperformance is floored at the sampled median rather than at zero.
#
# It replaces a fixed weighted-index formula that multiplied a [0,1] quality
# blend by an arbitrary constant. At hex scale that constant was
# SPECIES_AREA_C * (CELL_SIZE^2)^SPECIES_AREA_Z ≈ 53.7, which put "expected" on
# a ~20-per-cell scale while observed richness (species per log-metre of path)
# sits near 0.05. Subtracting the second from the first is not a leftover of
# anything: measured on the 2026-08-19 exports, ecological_residual correlated
# with expected_richness at 0.999 in all three cities, observations accounted
# for 0.1-0.3% of its variance, and it was positive in 99.99% of sampled cells.
# See docs/methodology.md §6 and §7.
#
# Below these sample sizes the fit is refused and a constant rate is used
# instead (sum(response) / sum(exposure), the constant-rate MLE). That keeps both
# sides in the same units and is recorded as a fallback in PROC_EXPECTED_MODEL
# rather than failing silently.
EXPECTED_MODEL_MIN_CELLS   <- 30L   # sampled hexes required to fit at hex scale
EXPECTED_MODEL_MIN_PATCHES <- 8L    # sampled patches required to fit at patch scale

# Species-area power law parameters. Used by patch_aggregation.R only: patch
# area genuinely varies, so an area term is meaningful there. SPECIES_AREA_Z is
# retained as the documented ASSUMPTION for the exponent (it sits within the
# general 0.2–0.3 species-area range and is not calibrated or sourced here —
# see docs/methodology.md §6.2). SPECIES_AREA_C is no longer used: the patch
# model fits the area term's coefficient from the data instead of asserting a
# tuning constant. It is kept for reproducibility records and back-compatibility.
SPECIES_AREA_Z <- 0.25
SPECIES_AREA_C <- 12

# ── Input raster files ────────────────────────────────────────────────────────
# Raster inputs are downloaded/prepared by the scripts listed below before
# ingest reads them. Shared raster inputs live under pipeline/data/raw/.
# A city adds optional sources (canopy height, PlanetScope) through
# RASTER_DOWNLOADERS_EXTRA in its own file.

AUTO_DOWNLOAD_RASTER_INPUTS <- TRUE

if (!exists("RASTER_DOWNLOADERS_EXTRA")) RASTER_DOWNLOADERS_EXTRA <- character(0)

RASTER_INPUT_DOWNLOADERS <- file.path(
  PIPELINE_ROOT,
  c(
    "00_download/download_worldcover.R",
    "00_download/download_sentinel2.R",
    "00_download/download_landsat_temp.R",
    RASTER_DOWNLOADERS_EXTRA
  )
)

# PLANETSCOPE NDVI Data

PLANET_NDVI_FILE <- file.path(
  DATA_IMPORT, "planetscope",
  paste0("planet_ndvi_", CITY_ID, ".tif")
)

# CANOPY HEIGHT META/WRI Data

CANOPY_HEIGHT_FILE <- file.path(
  DATA_IMPORT, "canopy_height",
  paste0("canopy_height_", CITY_ID, ".tif")
)

WC_FILE <- file.path(
  DATA_IMPORT, "worldcover",
  paste0("worldcover_", CITY_ID, ".tif")
)

# EMC-BUILT (Copernicus impervious surface fraction):
#   Download manually: https://human-settlement.emergency.copernicus.eu/dataDownload.php?ds=EMCbuiltS
#   File name expected by the pipeline: EMC_CITY_ID.tif
#   Example: EMC_porto-center.tif

EMC_FILE <- file.path(
  PIPELINE_ROOT, "data", "raw", "emc_built",
  paste0("EMC_", CITY_ID, ".tif")
)

NDVI_RES_M <- 10L

S2_NDVI_FILE <- file.path(
  DATA_IMPORT, "sentinel2",
  paste0("ndvi_", CITY_ID, ".tif")
)

# Country CIR orthophoto NDVI (Portugal DGT / Netherlands PDOK). DN-based,
# not reflectance-based — do not write this over RAW_NDVI / ndvi_idx.
# Produced by download_pt_ortho_ndvi.R or download_nl_cir_ndvi.R.
CIR_NDVI_FILE <- file.path(
  DATA_IMPORT, "nir",
  paste0("ndvi_", CITY_ID, ".tif")
)
# Pixels with CIR NDVI >= this count as vegetated when building veg_fraction.
# This is a DN threshold on an 8-bit visual product, not a reflectance NDVI cut.
CIR_VEG_NDVI_THRESHOLD <- 0.2

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

# Sub-windows of the same growing season used for Sentinel-2 NDVI
# (2023-04-01–2023-09-30, see download_sentinel2.R). Split into seasons so a
# single unusual weather event on one acquisition date can't dominate the
# thermal composite — each window is queried and processed independently.
LST_SEASON_WINDOWS <- c(
  "2023-04-01/2023-05-31",  # spring
  "2023-06-01/2023-08-31",  # summer
  "2023-09-01/2023-09-30"   # early autumn
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
RAW_CIR_NDVI   <- file.path(DATA_RAW, "cir_ndvi.tif")
RAW_VEG_FRACTION <- file.path(DATA_RAW, "veg_fraction.tif")
RAW_LST        <- file.path(DATA_RAW, "lst.tif")
RAW_INAT       <- file.path(DATA_RAW, "inat_observations.gpkg")
RAW_GBIF       <- file.path(DATA_RAW, "gbif_observations.gpkg")
RAW_SUPABASE_OBS <- file.path(DATA_RAW, "supabase_observations.gpkg")
RAW_OSM_GREEN  <- file.path(DATA_RAW, "osm_green_spaces.gpkg")
RAW_OSM_GROUND_VEG <- file.path(DATA_RAW, "osm_ground_veg.gpkg")
RAW_NATIONAL_GREEN <- file.path(DATA_RAW, "national_green_spaces.gpkg")
RAW_OSM_PATHS  <- file.path(DATA_RAW, "osm_paths.gpkg")
RAW_OSM_ROADS  <- file.path(DATA_RAW, "osm_roads.gpkg")
RAW_OSM_RAIL   <- file.path(DATA_RAW, "osm_rail.gpkg")
RAW_OSM_LAMPS  <- file.path(DATA_RAW, "osm_street_lamps.gpkg")
RAW_OSM_LIT_ROADS <- file.path(DATA_RAW, "osm_lit_roads.gpkg")
RAW_OSM_AMENITIES <- file.path(DATA_RAW, "osm_amenities.gpkg")
RAW_OSM_WATER  <- file.path(DATA_RAW, "osm_water.gpkg")
RAW_OSM_WATER_POLY <- file.path(DATA_RAW, "osm_water_poly.gpkg")

# Processed pipeline outputs
PROC_HEX_CELLS <- file.path(DATA_PROC, "hex_cells.gpkg")
PROC_HEX_CELLS_DISPLAY <- file.path(DATA_PROC, "hex_cells_display.gpkg")
PROC_GREEN_SPACES <- file.path(DATA_PROC, "green_spaces.gpkg")
PROC_GRID_HABITAT <- file.path(DATA_PROC, "grid_habitat.gpkg")
PROC_GRID_OBS     <- file.path(DATA_PROC, "grid_observations.gpkg")
PROC_GRID_CONN    <- file.path(DATA_PROC, "grid_connectivity.gpkg")
PROC_CONNECTIVITY_GRAPH <- file.path(DATA_PROC, "connectivity_graph.rds")
PROC_NETWORK_NODES <- file.path(DATA_PROC, "connectivity_network_nodes.gpkg")
PROC_NETWORK_EDGES <- file.path(DATA_PROC, "connectivity_network_edges.gpkg")
PROC_GREEN_SPACES_AGG <- file.path(DATA_PROC, "green_spaces_agg.gpkg")
PROC_GRID_RESID   <- file.path(DATA_PROC, "grid_residuals.gpkg")
PROC_CELL_ATTR    <- file.path(DATA_PROC, "cell_attributes.gpkg")
PROC_TOP_INTER    <- file.path(DATA_PROC, "top_interventions.csv")
PROC_HABITAT_TIF  <- file.path(DATA_PROC, "habitat_quality.tif")
PROC_CELL_TAXA    <- file.path(DATA_PROC, "cell_taxa.json")
# Fitted expected-richness model record (hex + patch blocks), written by
# 05_residuals and 05_patch, read by 06_export for the manifest.
PROC_EXPECTED_MODEL <- file.path(DATA_PROC, "expected_richness_model.json")
# Nature Gap score centring parameters (hex + patch blocks), written by
# 05_residuals and 05_patch, read by 06_export for the manifest. The score is
# within-city relative, so these are part of the published number.
PROC_SCORE_SCALING <- file.path(DATA_PROC, "score_scaling.json")

# ── Robust geometry helpers ────────────────────────────────────────────────────
# st_intersection()/st_union() on real-world OSM geometry against the hex grid
# can throw a GEOS TopologyException ("Ring edge missing") even when both
# inputs pass st_is_valid() — this is a numerical precision issue in the
# intersection algorithm itself (OSM coordinates carry far more decimal
# precision than a 20m hex grid needs), not just an input-validity problem.
# Snapping both operands to 1mm precision before validating fixes this in
# nearly all cases; a zero-width buffer is a last-resort fallback that forces
# GEOS to rebuild geometry topology from scratch. Available everywhere via
# config.R rather than duplicated per-file — use these in place of raw
# st_intersection()/st_union() wherever hex cells meet OSM-derived polygons.

# No leading dot: future/globals treats dot-prefixed names as hidden and
# won't auto-export them to multisession workers.
geom_precision_snap <- function(x, snap_precision_m = 0.001) {
  x |>
    sf::st_set_precision(1 / snap_precision_m) |>
    sf::st_make_valid()
}

safe_st_intersection <- function(x, y, snap_precision_m = 0.001, y_prepared = FALSE) {
  x_safe <- geom_precision_snap(x, snap_precision_m)
  # y_prepared lets callers reuse an already validity/precision-fixed y across
  # many calls (e.g. the same hex grid) instead of repeating that work each time.
  y_safe <- if (y_prepared) y else geom_precision_snap(y, snap_precision_m)
  tryCatch(
    sf::st_intersection(x_safe, y_safe),
    error = function(e) {
      message(
        "[safe_st_intersection] failed after validity+precision fix: ",
        conditionMessage(e), " — retrying with a zero-width buffer."
      )
      sf::st_intersection(sf::st_buffer(x_safe, 0), sf::st_buffer(y_safe, 0))
    }
  )
}

safe_st_union <- function(x, snap_precision_m = 0.001) {
  x_safe <- geom_precision_snap(x, snap_precision_m)
  tryCatch(
    sf::st_union(x_safe),
    error = function(e) {
      message(
        "[safe_st_union] failed after validity+precision fix: ",
        conditionMessage(e), " — retrying with a zero-width buffer."
      )
      sf::st_union(sf::st_buffer(x_safe, 0))
    }
  )
}

# ── Mark config as loaded ─────────────────────────────────────────────────────
# Each pipeline script checks for this flag before re-sourcing config.
CONFIG_LOADED <- TRUE

message(sprintf("[config] City: %s (%s) | Cell size: %d m | CITY_ID: %s | aoi_mode: %s",
                CITY_NAME, CRS_LOCAL, CELL_SIZE, CITY_ID, aoi_mode))
