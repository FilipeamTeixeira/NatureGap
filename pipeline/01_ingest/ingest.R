# NatureGap — Step 01: Data Ingestion
# Pulls raw data from open sources and writes to data/raw/
#
# Sources:
#   - iNaturalist  (REST API — research + needs_id / “Verifiable”)
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
library(jsonlite)
library(rgbif)
library(osmdata)
library(tidyverse)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

dir.create(DATA_RAW, recursive = TRUE, showWarnings = FALSE)

config_path_exists <- function(path) {
  !is.null(path) && length(path) == 1L && !is.na(path) && nzchar(path) && file.exists(path)
}

fetch_osm_sf <- function(query_fn, label) {
  fallback_urls <- if (exists("OVERPASS_FALLBACK_URLS")) {
    OVERPASS_FALLBACK_URLS
  } else {
    c(
      "https://overpass-api.de/api/interpreter",
      "https://overpass.kumi.systems/api/interpreter"
    )
  }
  primary_url <- if (exists("OVERPASS_URL")) {
    OVERPASS_URL
  } else {
    "https://overpass-api.de/api/interpreter"
  }
  max_retries <- if (exists("OVERPASS_RETRIES")) OVERPASS_RETRIES else 3L
  retry_wait  <- if (exists("OVERPASS_RETRY_WAIT")) OVERPASS_RETRY_WAIT else 45L

  urls <- unique(c(primary_url, fallback_urls))
  last_err <- NULL

  for (url in urls) {
    set_overpass_url(url)
    for (attempt in seq_len(max_retries)) {
      cat(sprintf(
        "  → Fetching %s via %s (attempt %d/%d)\n",
        label, url, attempt, max_retries
      ))
      result <- tryCatch(
        query_fn(),
        error = function(e) {
          last_err <<- e
          NULL
        }
      )
      if (!is.null(result)) return(result)

      err_msg <- conditionMessage(last_err)
      is_transient <- grepl(
        "504|502|503|429|timeout|timed out|Gateway|Too Many|rate limit|overloaded",
        err_msg, ignore.case = TRUE
      )
      if (attempt < max_retries && is_transient) {
        cat(sprintf(
          "    … transient error, waiting %ds before retry: %s\n",
          retry_wait, err_msg
        ))
        Sys.sleep(retry_wait)
      } else {
        break
      }
    }
    warning(sprintf(
      "%s failed on %s after %d attempt(s): %s",
      label, url, max_retries, conditionMessage(last_err)
    ), call. = FALSE)
  }
  stop(sprintf(
    "All Overpass endpoints failed for %s. Last error: %s\n",
    label, conditionMessage(last_err)
  ), call. = FALSE)
}

osm_cache_ok <- function(path, min_features = 1L) {
  if (!file.exists(path)) return(FALSE)
  tryCatch({
    sf_obj <- st_read(path, quiet = TRUE)
    nrow(sf_obj) >= min_features
  }, error = function(e) FALSE)
}

city_raster_ext <- function() {
  ext(BBOX_CITY["xmin"], BBOX_CITY["xmax"], BBOX_CITY["ymin"], BBOX_CITY["ymax"])
}

crop_to_city <- function(r) {
  crop(r, city_raster_ext())
}

#' Reduce a possibly multi-band NDVI stack to a single layer for the pipeline.
prepare_ndvi_raster <- function(r) {
  if (nlyr(r) == 1L) {
    out <- r[[1]]
  } else {
    cat(sprintf(
      "  → NDVI source has %d bands — using mean across bands\n",
      nlyr(r)
    ))
    out <- app(r, fun = mean, na.rm = TRUE)
  }
  names(out) <- "ndvi"
  out
}

# ── 1. iNaturalist observations ───────────────────────────────────────────────
# rinat only accepts quality=c("casual","research") and silently drops needs_id.
# The public API supports quality_grade=research,needs_id (iNat “Verifiable”).

parse_inat_location <- function(loc) {
  if (length(loc) == 0L || is.na(loc[1])) {
    return(c(lat = NA_real_, lon = NA_real_))
  }
  if (is.numeric(loc) && length(loc) >= 2L) {
    return(c(lat = as.numeric(loc[1]), lon = as.numeric(loc[2])))
  }
  text <- as.character(loc[1])
  if (!nzchar(text)) return(c(lat = NA_real_, lon = NA_real_))
  parts <- strsplit(text, ",", fixed = TRUE)[[1]]
  if (length(parts) < 2L) return(c(lat = NA_real_, lon = NA_real_))
  c(lat = as.numeric(parts[1]), lon = as.numeric(parts[2]))
}

normalize_inat_results <- function(df) {
  coords <- lapply(df$location, parse_inat_location)
  common <- if ("taxon.preferred_common_name" %in% names(df)) {
    coalesce(df$taxon.preferred_common_name, df$species_guess)
  } else {
    df$species_guess
  }

  tibble(
    id                = df$id,
    scientific_name   = df$taxon.name,
    common_name       = common,
    iconic_taxon_name = df$taxon.iconic_taxon_name,
    observed_on       = df$observed_on,
    latitude          = vapply(coords, `[[`, numeric(1), "lat"),
    longitude         = vapply(coords, `[[`, numeric(1), "lon"),
    quality_grade     = df$quality_grade
  )
}

fetch_inat_for_bbox <- function(bounds) {
  grades <- if (exists("INAT_QUALITY_GRADES")) {
    INAT_QUALITY_GRADES
  } else {
    c("research", "needs_id")
  }
  quality_param <- paste(grades, collapse = ",")
  max_total <- if (exists("INAT_MAX_RESULTS")) INAT_MAX_RESULTS else 10000L
  per_page  <- 200L

  swlat <- bounds[1]
  swlng <- bounds[2]
  nelat <- bounds[3]
  nelng <- bounds[4]

  parts <- list()
  page <- 1L
  fetched <- 0L
  api_total <- NA_integer_

  repeat {
    url <- paste0(
      "https://api.inaturalist.org/v1/observations?",
      "swlat=", swlat,
      "&swlng=", swlng,
      "&nelat=", nelat,
      "&nelng=", nelng,
      "&quality_grade=", utils::URLencode(quality_param, reserved = TRUE),
      "&per_page=", per_page,
      "&page=", page,
      "&order=asc",
      "&order_by=id"
    )
    cat(sprintf(
      "  → iNaturalist API (quality=%s, page=%d, per_page=%d)…\n",
      quality_param, page, per_page
    ))

    resp <- tryCatch(
      jsonlite::fromJSON(url, flatten = TRUE),
      error = function(e) {
        warning(sprintf("iNat API request failed on page %d: %s", page, conditionMessage(e)),
                call. = FALSE)
        NULL
      }
    )
    if (is.null(resp) || is.null(resp$results) || nrow(resp$results) == 0L) break

    if (is.na(api_total)) api_total <- as.integer(resp$total_results)
    batch <- normalize_inat_results(resp$results)
    parts[[length(parts) + 1L]] <- batch
    fetched <- fetched + nrow(batch)

    if (nrow(batch) < per_page || fetched >= api_total || fetched >= max_total) break
    page <- page + 1L
    Sys.sleep(0.25)
  }

  if (length(parts) == 0) return(NULL)

  combined <- bind_rows(parts)
  if ("id" %in% names(combined)) {
    combined <- combined |> distinct(id, .keep_all = TRUE)
  }

  if (!is.na(api_total) && api_total > nrow(combined)) {
    warning(sprintf(
      "iNat bbox has %d verifiable observations but only %d were downloaded (INAT_MAX_RESULTS=%d)",
      api_total, nrow(combined), max_total
    ), call. = FALSE)
  }

  combined
}

cat("Fetching iNaturalist observations…\n")
bounds_inat <- c(
  unname(BBOX_FETCH["ymin"]), unname(BBOX_FETCH["xmin"]),
  unname(BBOX_FETCH["ymax"]), unname(BBOX_FETCH["xmax"])
)
inat_obs <- fetch_inat_for_bbox(bounds_inat)

if (is.null(inat_obs) || nrow(inat_obs) == 0) {
  warning("No iNaturalist observations returned for this bbox")
  inat_sf <- st_sf(geometry = st_sfc(crs = 4326))
} else {
  inat_sf <- inat_obs |>
    filter(!is.na(longitude), !is.na(latitude)) |>
    st_as_sf(coords = c("longitude", "latitude"), crs = 4326) |>
    st_transform(CRS_LOCAL)
}

st_write(inat_sf, RAW_INAT, delete_dsn = TRUE)
cat(sprintf("  → %d iNaturalist records written\n", nrow(inat_sf)))
if ("quality_grade" %in% names(inat_sf)) {
  print(table(inat_sf$quality_grade))
}

# ── 2. GBIF observations ──────────────────────────────────────────────────────

fetch_gbif_for_bbox <- function(bounds, max_total = 10000L) {
  page_size <- 300L
  offset <- 0L
  parts <- list()

  repeat {
    remaining <- max_total - offset
    if (remaining <= 0L) break
    batch <- min(page_size, remaining)

    cat(sprintf("  → GBIF offset %d…\n", offset))
    res <- tryCatch(
      occ_search(
        decimalLatitude  = paste(bounds["ymin"], bounds["ymax"], sep = ","),
        decimalLongitude = paste(bounds["xmin"], bounds["xmax"], sep = ","),
        hasCoordinate    = TRUE,
        limit            = batch,
        start            = offset
      ),
      error = function(e) {
        warning(sprintf("GBIF fetch failed at offset %d: %s", offset, conditionMessage(e)),
                call. = FALSE)
        NULL
      }
    )

    if (is.null(res) || is.null(res$data) || nrow(res$data) == 0) break
    parts[[length(parts) + 1L]] <- res$data
    offset <- offset + nrow(res$data)
    if (nrow(res$data) < batch) break
  }

  if (length(parts) == 0) return(NULL)
  out <- bind_rows(parts)
  if ("key" %in% names(out)) {
    out |> distinct(key, .keep_all = TRUE)
  } else if ("occurrenceID" %in% names(out)) {
    out |> distinct(occurrenceID, .keep_all = TRUE)
  } else {
    out
  }
}

cat("Fetching GBIF observations…\n")
gbif_max <- if (exists("GBIF_MAX_RESULTS")) GBIF_MAX_RESULTS else 10000L
gbif_raw <- fetch_gbif_for_bbox(BBOX_FETCH, gbif_max)

if (is.null(gbif_raw) || nrow(gbif_raw) == 0) {
  warning("No GBIF observations returned for this bbox")
  gbif_sf <- st_sf(geometry = st_sfc(crs = 4326))
} else {
  gbif_sf <- gbif_raw |>
    filter(!is.na(decimalLongitude), !is.na(decimalLatitude)) |>
    st_as_sf(coords = c("decimalLongitude", "decimalLatitude"), crs = 4326) |>
    st_transform(CRS_LOCAL)
}

st_write(gbif_sf, RAW_GBIF, delete_dsn = TRUE)
cat(sprintf("  → %d GBIF records written\n", nrow(gbif_sf)))

# ── 3. OpenStreetMap: green spaces + path network ─────────────────────────────

cat("Fetching OpenStreetMap features...\n")

skip_osm <- exists("OSM_SKIP_IF_EXISTS") &&
  isTRUE(OSM_SKIP_IF_EXISTS) &&
  osm_cache_ok(RAW_OSM_GREEN) &&
  osm_cache_ok(RAW_OSM_PATHS, min_features = 0L)

if (skip_osm) {
  cat("  → Using cached OSM files (OSM_SKIP_IF_EXISTS=TRUE)\n")
  cat(sprintf("    %s\n    %s\n", RAW_OSM_GREEN, RAW_OSM_PATHS))
} else {
  # Use BBOX_CITY (analysis domain) — smaller than BBOX_FETCH when they differ.
  osm_bbox <- c(BBOX_CITY["xmin"], BBOX_CITY["ymin"],
                BBOX_CITY["xmax"], BBOX_CITY["ymax"])

  osm_green <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "leisure",
                      value = c("park", "nature_reserve", "garden")) |>
      osmdata_sf()
  }, "OSM green spaces")

  green_polygons <- if (!is.null(osm_green$osm_polygons)) {
    osm_green$osm_polygons |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM green space polygons returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(green_polygons, RAW_OSM_GREEN, delete_dsn = TRUE)
  cat(sprintf("  → %d green space polygons written\n", nrow(green_polygons)))

  osm_paths <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "highway",
                      value = c("path", "footway", "pedestrian", "steps", "track")) |>
      osmdata_sf()
  }, "OSM paths")

  path_lines <- if (!is.null(osm_paths$osm_lines)) {
    osm_paths$osm_lines |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM path lines returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(path_lines, RAW_OSM_PATHS, delete_dsn = TRUE)
  cat(sprintf("  → %d path lines written\n", nrow(path_lines)))
}

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

wc_path <- WC_FILE

if (file.exists(wc_path)) {
  cat("Processing ESA WorldCover...\n")
  lc_raw  <- rast(wc_path)
  lc_crop <- crop_to_city(lc_raw)
  writeRaster(lc_crop, RAW_LANDCOVER, overwrite = TRUE,
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

emc_path <- EMC_FILE

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

  writeRaster(impervious, RAW_IMPERVIOUS, overwrite = TRUE,
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

# ── 6. Sentinel-2 NDVI (optional) ───────────────────────────────────────────
# Configure paths in pipeline/config.R (S2_NDVI_FILE or S2_SAFE_DIR).

ndvi_written <- FALSE

if (config_path_exists(S2_NDVI_FILE)) {
  cat(sprintf("Processing pre-computed NDVI: %s\n", S2_NDVI_FILE))
  ndvi_crop <- crop_to_city(rast(S2_NDVI_FILE)) |> prepare_ndvi_raster()
  writeRaster(ndvi_crop, RAW_NDVI, overwrite = TRUE, datatype = "FLT4S")
  ndvi_written <- TRUE
  cat(sprintf("  → NDVI written (%d m resolution configured)\n", NDVI_RES_M))
} else if (config_path_exists(S2_SAFE_DIR)) {
  b4 <- list.files(S2_SAFE_DIR, pattern = S2_RED_BAND_PATTERN,
                   recursive = TRUE, full.names = TRUE)
  b8 <- list.files(S2_SAFE_DIR, pattern = S2_NIR_BAND_PATTERN,
                   recursive = TRUE, full.names = TRUE)
  if (length(b4) > 0L && length(b8) > 0L) {
    cat(sprintf("Building NDVI from Sentinel-2 SAFE in %s\n", S2_SAFE_DIR))
    red <- rast(b4[1])
    nir <- rast(b8[1])
    ndvi <- (nir - red) / (nir + red)
    names(ndvi) <- "ndvi"
    ndvi_crop <- crop_to_city(ndvi)
    writeRaster(ndvi_crop, RAW_NDVI, overwrite = TRUE, datatype = "FLT4S")
    ndvi_written <- TRUE
    cat(sprintf("  → NDVI written from %s / %s\n", basename(b4[1]), basename(b8[1])))
  }
}

if (!ndvi_written) {
  message(
    "Skipping NDVI — set S2_NDVI_FILE or add a .SAFE product under S2_SAFE_DIR in config.R"
  )
}

# ── 7. Landsat LST (optional) ───────────────────────────────────────────────
# Configure LST_FILE (or LST_DIR + LST_BAND_PATTERN) in pipeline/config.R.

lst_written <- FALSE
lst_source  <- NA_character_

if (config_path_exists(LST_FILE)) {
  lst_source <- LST_FILE
} else if (config_path_exists(LST_DIR)) {
  matches <- list.files(LST_DIR, pattern = LST_BAND_PATTERN, full.names = TRUE)
  if (length(matches) > 0L) lst_source <- matches[1]
}

if (!is.na(lst_source)) {
  cat(sprintf("Processing Landsat LST: %s\n", lst_source))
  lst_raw <- rast(lst_source) * LST_DN_SCALE + LST_DN_OFFSET - 273.15
  names(lst_raw) <- "lst_celsius"
  lst_crop <- crop_to_city(lst_raw)
  writeRaster(lst_crop, RAW_LST, overwrite = TRUE, datatype = "FLT4S")
  lst_written <- TRUE
  cat("  → LST raster written (°C)\n")
} else {
  message("Skipping LST — set LST_FILE or add ST_B10 under LST_DIR in config.R")
}

cat("\nIngestion complete. Check data/raw/ for outputs.\n")

