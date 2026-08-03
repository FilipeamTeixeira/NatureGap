# NatureGap — Step 01: Data Ingestion
# Pulls raw data from open sources and writes to data/raw/
#
# Sources:
#   - iNaturalist  (REST API — research + needs_id / “Verifiable”)
#   - GBIF         (rgbif)
#   - OpenStreetMap (osmdata)
#   - ESA WorldCover 10m landcover classification (from data/raw/)
#   - EMC-BUILT impervious surface fraction       (from data/raw/)
#
# Raster inputs are prepared by download_*.R scripts when
# AUTO_DOWNLOAD_RASTER_INPUTS is enabled in config.R.

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

run_raster_input_downloaders <- function() {
  if (!exists("AUTO_DOWNLOAD_RASTER_INPUTS") || !isTRUE(AUTO_DOWNLOAD_RASTER_INPUTS)) {
    return(invisible(FALSE))
  }

  if (!exists("RASTER_INPUT_DOWNLOADERS") || length(RASTER_INPUT_DOWNLOADERS) == 0L) {
    return(invisible(FALSE))
  }

  cat("Preparing raster inputs...\n")
  for (script in RASTER_INPUT_DOWNLOADERS) {
    if (!file.exists(script)) {
      warning("Raster downloader not found: ", script)
      next
    }
    cat(sprintf("  -> %s\n", basename(script)))
    source(script, local = FALSE)
  }

  invisible(TRUE)
}

# fetch_osm_sf <- function(query_fn, label) {
#   fallback_urls <- if (exists("OVERPASS_FALLBACK_URLS")) {
#     OVERPASS_FALLBACK_URLS
#   } else {
#     c(
#       "https://overpass-api.de/api/interpreter",
#       "https://overpass.kumi.systems/api/interpreter"
#     )
#   }
#   primary_url <- if (exists("OVERPASS_URL")) {
#     OVERPASS_URL
#   } else {
#     "https://overpass-api.de/api/interpreter"
#   }
#   max_retries <- if (exists("OVERPASS_RETRIES")) OVERPASS_RETRIES else 3L
#   retry_wait  <- if (exists("OVERPASS_RETRY_WAIT")) OVERPASS_RETRY_WAIT else 45L
#
#   urls <- unique(c(primary_url, fallback_urls))
#   last_err <- NULL
#
#   for (url in urls) {
#     set_overpass_url(url)
#     for (attempt in seq_len(max_retries)) {
#       cat(sprintf(
#         "  → Fetching %s via %s (attempt %d/%d)\n",
#         label, url, attempt, max_retries
#       ))
#       result <- tryCatch(
#         query_fn(),
#         error = function(e) {
#           last_err <<- e
#           NULL
#         }
#       )
#       if (!is.null(result)) return(result)
#
#       err_msg <- conditionMessage(last_err)
#       is_transient <- grepl(
#         "504|502|503|429|timeout|timed out|Gateway|Too Many|rate limit|overloaded",
#         err_msg, ignore.case = TRUE
#       )
#       if (attempt < max_retries && is_transient) {
#         cat(sprintf(
#           "    … transient error, waiting %ds before retry: %s\n",
#           retry_wait, err_msg
#         ))
#         Sys.sleep(retry_wait)
#       } else {
#         break
#       }
#     }
#     warning(sprintf(
#       "%s failed on %s after %d attempt(s): %s",
#       label, url, max_retries, conditionMessage(last_err)
#     ), call. = FALSE)
#   }
#   stop(sprintf(
#     "All Overpass endpoints failed for %s. Last error: %s\n",
#     label, conditionMessage(last_err)
#   ), call. = FALSE)
# }


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
  max_retries <- if (exists("OVERPASS_RETRIES")) OVERPASS_RETRIES else 5L
  base_wait   <- if (exists("OVERPASS_RETRY_WAIT")) OVERPASS_RETRY_WAIT else 45L

  urls <- unique(c(primary_url, fallback_urls))
  last_err <- NULL

  for (url in urls) {
    # FIX: Wrap set_overpass_url in tryCatch.
    # It makes an HTTP validation request that will crash the script if it hits a 429 or 504.
    url_setup_success <- tryCatch({
      set_overpass_url(url)
      TRUE
    }, error = function(e) {
      last_err <<- e
      FALSE
    })

    # If the URL validation fails, skip to the next fallback link
    if (!url_setup_success) {
      warning(sprintf(
        "Could not connect to %s during setup: %s",
        url, conditionMessage(last_err)
      ), call. = FALSE)
      next
    }

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
      is_rate_limited <- grepl("429|Too Many|rate limit", err_msg, ignore.case = TRUE)
      if (attempt < max_retries && is_transient) {
        retry_wait <- if (is_rate_limited) {
          base_wait * (2 ^ (attempt - 1))
        } else {
          base_wait
        }
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

osm_cache_resolved_path <- function(path) {
  candidates <- c(path)
  if (grepl("osm_water_polygons\\.gpkg$", path)) {
    candidates <- c(candidates, sub("osm_water_polygons\\.gpkg$", "osm_water_poly.gpkg", path))
  }
  for (p in candidates) {
    if (file.exists(p)) return(p)
  }
  path
}

osm_cache_ok <- function(path, min_features = 1L) {
  resolved <- osm_cache_resolved_path(path)
  if (!file.exists(resolved)) return(FALSE)
  tryCatch({
    sf_obj <- st_read(resolved, quiet = TRUE)
    nrow(sf_obj) >= min_features
  }, error = function(e) FALSE)
}

.overpass_queries_this_run <- 0L

overpass_pause_before_query <- function() {
  delay <- if (exists("OVERPASS_QUERY_DELAY")) OVERPASS_QUERY_DELAY else 20L
  if (.overpass_queries_this_run > 0L && is.numeric(delay) && delay > 0) {
    cat(sprintf("  … pausing %ds before next Overpass query\n", as.integer(delay)))
    Sys.sleep(delay)
  }
  .overpass_queries_this_run <<- .overpass_queries_this_run + 1L
  invisible(NULL)
}

# osmdata_sf() splits results across $osm_polygons (simple way-mapped areas)
# and $osm_multipolygons (relations — used for larger/irregular parks, and
# anything with an interior hole/courtyard). Every OSM polygon fetch in this
# file was only reading $osm_polygons, silently missing anything mapped as a
# relation. Cast both to MULTIPOLYGON before combining so a single fetch
# doesn't end up with mixed POLYGON/MULTIPOLYGON geometry types, which can
# behave inconsistently in later st_* operations and st_write.
combine_osm_polygons <- function(osm_result) {
  polys  <- osm_result$osm_polygons
  multis <- osm_result$osm_multipolygons

  polys  <- if (!is.null(polys)  && nrow(polys)  > 0L) sf::st_cast(polys,  "MULTIPOLYGON") else NULL
  multis <- if (!is.null(multis) && nrow(multis) > 0L) sf::st_cast(multis, "MULTIPOLYGON") else NULL

  combined <- if (is.null(polys) && is.null(multis)) {
    return(NULL)
  } else if (is.null(polys)) {
    multis
  } else if (is.null(multis)) {
    polys
  } else {
    dplyr::bind_rows(polys, multis)
  }

  # Real-world OSM relations frequently have minor topology issues
  # (self-intersections, unclosed rings) that st_cast alone does not
  # repair. Fix these before the result reaches any st_intersection/
  # st_union call downstream, or GEOS throws a TopologyException.
  sf::st_make_valid(combined)
}

use_osm_cache <- function(path, min_features, label) {
  skip <- exists("OSM_SKIP_IF_EXISTS") && isTRUE(OSM_SKIP_IF_EXISTS)
  if (!skip || !osm_cache_ok(path, min_features)) return(FALSE)
  cat(sprintf("  → Using cached %s (%s)\n", label, osm_cache_resolved_path(path)))
  TRUE
}

city_raster_ext <- function(r) {
  bbox_poly <- st_as_sfc(
    st_bbox(
      c(
        xmin = unname(BBOX_CITY["xmin"]),
        ymin = unname(BBOX_CITY["ymin"]),
        xmax = unname(BBOX_CITY["xmax"]),
        ymax = unname(BBOX_CITY["ymax"])
      ),
      crs = 4326
    )
  )

  raster_crs <- crs(r)
  if (!is.na(raster_crs) && nzchar(raster_crs)) {
    bbox_poly <- st_transform(bbox_poly, raster_crs)
  }

  ext(vect(bbox_poly))
}

crop_to_city <- function(r) {
  city_ext <- city_raster_ext(r)
  raster_ext <- as.vector(ext(r))
  crop_ext <- as.vector(city_ext)
  names(raster_ext) <- names(crop_ext) <- c("xmin", "xmax", "ymin", "ymax")
  overlaps <- raster_ext["xmin"] <= crop_ext["xmax"] &&
    raster_ext["xmax"] >= crop_ext["xmin"] &&
    raster_ext["ymin"] <= crop_ext["ymax"] &&
    raster_ext["ymax"] >= crop_ext["ymin"]

  if (!overlaps) {
    stop(
      sprintf(
        "Raster extent does not overlap %s after CRS alignment. Raster CRS: %s",
        CITY_ID,
        crs(r)
      ),
      call. = FALSE
    )
  }

  crop(r, city_ext)
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

run_raster_input_downloaders()

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

# Use BBOX_CITY (analysis domain) — smaller than BBOX_FETCH when they differ.
osm_bbox <- c(BBOX_CITY["xmin"], BBOX_CITY["ymin"],
              BBOX_CITY["xmax"], BBOX_CITY["ymax"])

if (!use_osm_cache(RAW_OSM_GREEN, 1L, "OSM green spaces")) {
  overpass_pause_before_query()
  osm_green <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "leisure",
                      value = c("park", "nature_reserve", "garden")) |>
      osmdata_sf()
  }, "OSM green spaces")

  green_polygons <- if (!is.null(combine_osm_polygons(osm_green))) {
    combine_osm_polygons(osm_green) |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM green space polygons returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(green_polygons, RAW_OSM_GREEN, delete_dsn = TRUE)
  cat(sprintf("  → %d green space polygons written\n", nrow(green_polygons)))
}

if (!use_osm_cache(RAW_OSM_GROUND_VEG, 0L, "OSM ground vegetation")) {
  overpass_pause_before_query()
  osm_ground_veg <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "natural", value = c("grassland", "scrub")) |>
      osmdata_sf()
  }, "OSM ground vegetation")

  ground_veg_polygons <- if (!is.null(combine_osm_polygons(osm_ground_veg))) {
    combine_osm_polygons(osm_ground_veg) |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM ground vegetation polygons returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(ground_veg_polygons, RAW_OSM_GROUND_VEG, delete_dsn = TRUE)
  cat(sprintf("  → %d ground vegetation polygons written\n", nrow(ground_veg_polygons)))

  overpass_pause_before_query()
  osm_ground_veg2 <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "landuse", value = c("grass", "meadow", "allotments")) |>
      osmdata_sf()
  }, "OSM ground vegetation (landuse)")

  ground_veg_polygons2 <- if (!is.null(combine_osm_polygons(osm_ground_veg2))) {
    combine_osm_polygons(osm_ground_veg2) |> st_transform(CRS_LOCAL)
  } else {
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  ground_veg_polygons_all <- bind_rows(ground_veg_polygons, ground_veg_polygons2)
  st_write(ground_veg_polygons_all, RAW_OSM_GROUND_VEG, delete_dsn = TRUE)
  cat(sprintf("  → %d ground vegetation polygons written (combined)\n", nrow(ground_veg_polygons_all)))
}

if (!use_osm_cache(RAW_OSM_PATHS, 0L, "OSM paths")) {
  overpass_pause_before_query()
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

if (!use_osm_cache(RAW_OSM_ROADS, 0L, "OSM roads")) {
  overpass_pause_before_query()
  osm_roads <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "highway",
                      value = c("motorway", "trunk", "primary", "secondary",
                                "tertiary", "residential", "service",
                                "unclassified", "living_street")) |>
      osmdata_sf()
  }, "OSM roads")

  road_lines <- if (!is.null(osm_roads$osm_lines)) {
    osm_roads$osm_lines |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM road lines returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(road_lines, RAW_OSM_ROADS, delete_dsn = TRUE)
  cat(sprintf("  → %d road lines written\n", nrow(road_lines)))
}

if (!use_osm_cache(RAW_OSM_RAIL, 0L, "OSM rail")) {
  overpass_pause_before_query()
  osm_rail <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "railway",
                      value = c("rail", "light_rail", "subway", "tram")) |>
      osmdata_sf()
  }, "OSM rail")

  rail_lines <- if (!is.null(osm_rail$osm_lines)) {
    osm_rail$osm_lines |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM rail lines returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(rail_lines, RAW_OSM_RAIL, delete_dsn = TRUE)
  cat(sprintf("  → %d rail lines written\n", nrow(rail_lines)))
}

if (!use_osm_cache(RAW_OSM_LAMPS, 0L, "OSM street lamps")) {
  overpass_pause_before_query()
  osm_lamps <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "highway", value = "street_lamp") |>
      osmdata_sf()
  }, "OSM street lamps")

  lamp_points <- if (!is.null(osm_lamps$osm_points)) {
    osm_lamps$osm_points |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM street lamps returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(lamp_points, RAW_OSM_LAMPS, delete_dsn = TRUE)
  cat(sprintf("  → %d street lamp points written\n", nrow(lamp_points)))
}

if (!use_osm_cache(RAW_OSM_LIT_ROADS, 0L, "OSM lit roads")) {
  overpass_pause_before_query()
  osm_lit_roads <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "lit", value = "yes") |>
      osmdata_sf()
  }, "OSM lit roads")

  lit_lines <- if (!is.null(osm_lit_roads$osm_lines)) {
    osm_lit_roads$osm_lines |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM lit road lines returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(lit_lines, RAW_OSM_LIT_ROADS, delete_dsn = TRUE)
  cat(sprintf("  → %d lit road lines written\n", nrow(lit_lines)))
}

if (!use_osm_cache(RAW_OSM_AMENITIES, 0L, "OSM amenities")) {
  overpass_pause_before_query()
  osm_amenities <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "amenity") |>
      osmdata_sf()
  }, "OSM amenities")

  amenity_points <- bind_rows(
    if (!is.null(osm_amenities$osm_points)) osm_amenities$osm_points else NULL,
    if (!is.null(combine_osm_polygons(osm_amenities))) st_centroid(combine_osm_polygons(osm_amenities)) else NULL
  )
  amenity_points <- if (!is.null(amenity_points) && nrow(amenity_points) > 0L) {
    amenity_points |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM amenities returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(amenity_points, RAW_OSM_AMENITIES, delete_dsn = TRUE)
  cat(sprintf("  → %d amenity points written\n", nrow(amenity_points)))
}

if (!use_osm_cache(RAW_OSM_WATER_POLY, 0L, "OSM water bodies")) {
  overpass_pause_before_query()
  osm_water_bodies <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "natural", value = "water") |>
      osmdata_sf()
  }, "OSM water bodies")

  water_polygons <- if (!is.null(combine_osm_polygons(osm_water_bodies))) {
    combine_osm_polygons(osm_water_bodies) |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM water polygons returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(water_polygons, RAW_OSM_WATER_POLY, delete_dsn = TRUE)
  cat(sprintf("  → %d water polygons written\n", nrow(water_polygons)))
}

if (!use_osm_cache(RAW_OSM_WATER, 0L, "OSM waterways")) {
  overpass_pause_before_query()
  osm_waterways <- fetch_osm_sf(function() {
    opq(bbox = osm_bbox, timeout = 180) |>
      add_osm_feature(key = "waterway",
                      value = c("river", "stream", "ditch", "drain", "canal")) |>
      osmdata_sf()
  }, "OSM waterways")

  water_lines <- if (!is.null(osm_waterways$osm_lines)) {
    osm_waterways$osm_lines |> st_transform(CRS_LOCAL)
  } else {
    warning("No OSM waterway lines returned — writing empty layer")
    st_sf(geometry = st_sfc(crs = CRS_LOCAL))
  }
  st_write(water_lines, RAW_OSM_WATER, delete_dsn = TRUE)
  cat(sprintf("  → %d waterway lines written\n", nrow(water_lines)))
}

# ── 4. ESA WorldCover 10m landcover classification ───────────────────────────
#
# Source: WC_FILE, prepared by download_worldcover.R
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
    "WorldCover not found: %s\n  Run download_worldcover.R or enable AUTO_DOWNLOAD_RASTER_INPUTS.",
    wc_path
  ))
}

# ── 5. EMC-BUILT impervious surface fraction ──────────────────────────────────
#
# Source: EMC_FILE, manually downloaded as EMC_CITY_ID.tif
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
    "EMC-BUILT not found: %s\n  Download manually and save as EMC_%s.tif.",
    emc_path,
    CITY_ID
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
    "Skipping NDVI - run download_sentinel2.R, set S2_NDVI_FILE, or add a .SAFE product under S2_SAFE_DIR."
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
  # LST_DIR is shared across every city processed on this machine, and
  # LST_BAND_PATTERN matches any lst_*.tif with no city filtering — without
  # this check, a stale lst_<other_city>.tif left over from a previous run
  # gets silently picked up for the wrong city. Exclude any city-tagged file
  # that isn't this city's own; untagged raw scenes (e.g. manually-placed
  # *_ST_B10.TIF) are unaffected, since those were never city-tagged anyway.
  wrong_city_lst <- grepl("^lst_.*\\.tif$", basename(matches), ignore.case = TRUE) &
    !grepl(paste0("^lst_", CITY_ID, "\\.tif$"), basename(matches), ignore.case = TRUE)
  matches <- matches[!wrong_city_lst]
  if (length(matches) > 0L) lst_source <- matches[1]
}

if (!is.na(lst_source)) {
  cat(sprintf("Processing Landsat LST: %s\n", lst_source))
  lst_raw <- rast(lst_source)
  if (grepl("ST_B10\\.TIF$", basename(lst_source), ignore.case = TRUE)) {
    lst_raw <- lst_raw * LST_DN_SCALE + LST_DN_OFFSET - 273.15
  }
  names(lst_raw) <- "lst_celsius"
  lst_crop <- crop_to_city(lst_raw)
  writeRaster(lst_crop, RAW_LST, overwrite = TRUE, datatype = "FLT4S")
  lst_written <- TRUE
  cat("  → LST raster written (°C)\n")
} else {
  message("Skipping LST - run download_landsat_temp.R, set LST_FILE, or add LST_*.tif/ST_B10 under LST_DIR.")
}

cat("\nIngestion complete. Check data/raw/ for outputs.\n")
