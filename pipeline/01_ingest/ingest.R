# NatureGap — Step 01: Data Ingestion
# Pulls raw data from open sources and writes to data/raw/
#
# Sources:
#   - iNaturalist  (REST API — research + needs_id / “Verifiable”)
#   - GBIF         (rgbif — occ_download when credentialed, else occ_search)
#   - OpenStreetMap (local tile PBFs via GDAL; osmdata/Overpass as fallback)
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

# The AOI a cached OSM fetch was actually made for, recorded beside the .gpkg.
#
# Feature count alone cannot detect a cache fetched for a *smaller* BBOX_CITY:
# the cache is complete for the box it was fetched for, so it looks healthy.
# On Amsterdam the green-space and ground-vegetation caches survived the AOI
# widening east and stopped at X=124,482 / 124,371 RD against an AOI reaching
# X=131,290 — IJburg ended up with zero named green spaces and the eastern
# third of the city fell back to the raster presence bars alone. Same class of
# staleness canopy_cache_stale_reason() guards against in 02_habitat.
#
# A cache with no sidecar is treated as stale. It predates this stamp, so its
# fetch AOI is unknowable and one refetch is the only safe answer.
osm_cache_aoi_path <- function(path) paste0(path, ".aoi.json")

write_osm_cache <- function(value, path) {
  st_write(value, path, delete_dsn = TRUE)
  write_json(
    list(
      xmin = unname(BBOX_CITY[["xmin"]]), ymin = unname(BBOX_CITY[["ymin"]]),
      xmax = unname(BBOX_CITY[["xmax"]]), ymax = unname(BBOX_CITY[["ymax"]])
    ),
    osm_cache_aoi_path(path),
    auto_unbox = TRUE, digits = 10
  )
  invisible(path)
}

# NULL when the cache covers the current AOI, otherwise the reason it does not.
osm_cache_stale_reason <- function(resolved_path) {
  aoi_path <- osm_cache_aoi_path(resolved_path)
  if (!file.exists(aoi_path)) return("was fetched before the AOI was recorded")

  cached <- tryCatch(
    unlist(read_json(aoi_path, simplifyVector = TRUE)),
    error = function(e) NULL
  )
  if (!is.numeric(cached) || !all(c("xmin", "ymin", "xmax", "ymax") %in% names(cached))) {
    return("has an unreadable fetch AOI")
  }

  # Degrees. The tolerance only absorbs JSON round-tripping — the failure this
  # guards against is short by kilometres, not by a millionth of a degree.
  tol <- 1e-6
  if (cached[["xmin"]] > BBOX_CITY[["xmin"]] + tol ||
      cached[["ymin"]] > BBOX_CITY[["ymin"]] + tol ||
      cached[["xmax"]] < BBOX_CITY[["xmax"]] - tol ||
      cached[["ymax"]] < BBOX_CITY[["ymax"]] - tol) {
    return(sprintf(
      "covers %.4f,%.4f-%.4f,%.4f but the AOI is now %.4f,%.4f-%.4f,%.4f",
      cached[["xmin"]], cached[["ymin"]], cached[["xmax"]], cached[["ymax"]],
      BBOX_CITY[["xmin"]], BBOX_CITY[["ymin"]], BBOX_CITY[["xmax"]], BBOX_CITY[["ymax"]]
    ))
  }
  NULL
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

  resolved <- osm_cache_resolved_path(path)
  stale <- osm_cache_stale_reason(resolved)
  if (!is.null(stale)) {
    cat(sprintf("  → Refetching %s — cached copy %s\n", label, stale))
    return(FALSE)
  }

  cat(sprintf("  → Using cached %s (%s)\n", label, resolved))
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

  # The crop is what materialises a full copy of the raster, and terra writes
  # that copy as a classic (non-BigTIFF) GeoTIFF, which fails outright past
  # 4 GB however much disk is free — see the mosaic note in
  # 00_download/download_nl_cir_ndvi.R. Gent's 0.5 m CIR NDVI is 7.2 GB as
  # FLT4S, so it crosses that ceiling; Amsterdam (2.2 GB) and Porto (1.0 GB) do
  # not.
  #
  # Skip the crop when the city extent already covers the raster to within one
  # cell on every side. crop() snaps to cell boundaries, so in that case it can
  # shave at most a single row or column — nothing the hex extracts notice —
  # and the copy buys nothing. This is the normal case for the CIR rasters,
  # whose grid is snapped outward from BBOX_CITY by the downloaders. Rasters
  # that genuinely extend past the city (WorldCover, Sentinel-2, Landsat) are
  # unaffected and still crop.
  cell <- res(r)
  if (crop_ext["xmin"] <= raster_ext["xmin"] + cell[1] &&
      crop_ext["ymin"] <= raster_ext["ymin"] + cell[2] &&
      crop_ext["xmax"] >= raster_ext["xmax"] - cell[1] &&
      crop_ext["ymax"] >= raster_ext["ymax"] - cell[2]) {
    return(r)
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
  # Cursor pagination, not page numbers. The v1 API rejects any request where
  # page * per_page > 10000, so &page= silently caps a bbox at 10,000 records
  # however high INAT_MAX_RESULTS is set — Porto has 20,806 verifiable
  # observations and was ingesting exactly 10,000 of them, losing everything
  # after 2024-06-06. id_above walks the full set: ask for ids above the highest
  # one seen so far, with the ascending id sort this query already used.
  id_above <- 0L
  request <- 0L
  fetched <- 0L
  api_total <- NA_integer_

  repeat {
    request <- request + 1L
    url <- paste0(
      "https://api.inaturalist.org/v1/observations?",
      "swlat=", swlat,
      "&swlng=", swlng,
      "&nelat=", nelat,
      "&nelng=", nelng,
      "&quality_grade=", utils::URLencode(quality_param, reserved = TRUE),
      "&per_page=", per_page,
      "&id_above=", format(id_above, scientific = FALSE),
      "&order=asc",
      "&order_by=id"
    )
    cat(sprintf(
      "  → iNaturalist API (quality=%s, request=%d, per_page=%d, id_above=%s)…\n",
      quality_param, request, per_page, format(id_above, scientific = FALSE)
    ))

    resp <- tryCatch(
      jsonlite::fromJSON(url, flatten = TRUE),
      error = function(e) {
        warning(sprintf("iNat API request failed at id_above=%s: %s",
                        format(id_above, scientific = FALSE), conditionMessage(e)),
                call. = FALSE)
        NULL
      }
    )
    if (is.null(resp) || is.null(resp$results) || nrow(resp$results) == 0L) break

    # Captured on the first request only: with id_above set, total_results counts
    # what is left above the cursor, not the whole bbox.
    if (is.na(api_total)) api_total <- as.integer(resp$total_results)
    batch <- normalize_inat_results(resp$results)
    parts[[length(parts) + 1L]] <- batch
    fetched <- fetched + nrow(batch)

    next_cursor <- suppressWarnings(max(as.numeric(batch$id), na.rm = TRUE))
    if (!is.finite(next_cursor) || next_cursor <= id_above) {
      warning(sprintf(
        "iNat cursor failed to advance past id %s — stopping at %d records",
        format(id_above, scientific = FALSE), fetched
      ), call. = FALSE)
      break
    }
    id_above <- next_cursor

    if (nrow(batch) < per_page || fetched >= api_total || fetched >= max_total) break
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
  } else if (!is.na(api_total)) {
    cat(sprintf("  → iNaturalist: %d of %d verifiable observations in bbox\n",
                nrow(combined), api_total))
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

gbif_credentials_present <- function() {
  all(nzchar(Sys.getenv(c("GBIF_USER", "GBIF_PWD", "GBIF_EMAIL"))))
}

# Predicates shared by the download request and its cache key. Longitude and
# latitude ranges reproduce the occ_search bbox semantics exactly, without the
# WKT winding rules pred_within() imposes. There is no taxonRank predicate in
# the download API, so rank is filtered after import instead.
gbif_download_predicates <- function(bounds) {
  preds <- list(
    pred("hasCoordinate", TRUE),
    pred("hasGeospatialIssue", FALSE),
    pred("occurrenceStatus", "PRESENT"),
    pred_gte("decimalLatitude",  unname(bounds["ymin"])),
    pred_lte("decimalLatitude",  unname(bounds["ymax"])),
    pred_gte("decimalLongitude", unname(bounds["xmin"])),
    pred_lte("decimalLongitude", unname(bounds["xmax"]))
  )

  year_min <- if (exists("GBIF_YEAR_MIN")) GBIF_YEAR_MIN else NULL
  if (length(year_min) == 1L && !is.na(year_min)) {
    preds <- c(preds, list(pred_gte("year", as.integer(year_min))))
  }

  basis <- if (exists("GBIF_BASIS_OF_RECORD")) GBIF_BASIS_OF_RECORD else NULL
  if (length(basis) > 0L) {
    preds <- c(preds, list(pred_in("basisOfRecord", basis)))
  }

  preds
}

# Cache key over the predicate set, so changing the bbox or a scope filter
# requests a fresh archive while an unchanged re-run reuses the zip on disk.
gbif_predicate_hash <- function(preds) {
  # occ_predicate objects have no asJSON method, so hash the unclassed lists.
  substr(digest::digest(lapply(preds, unclass), algo = "xxhash64"), 1L, 12L)
}

# occ_download_wait() polls indefinitely; this honours GBIF_DOWNLOAD_TIMEOUT_MIN
# so a stuck job fails loudly instead of hanging ingest.
gbif_await_download <- function(dl_key, timeout_min) {
  deadline <- Sys.time() + as.difftime(timeout_min, units = "mins")
  repeat {
    meta <- tryCatch(occ_download_meta(dl_key), error = function(e) NULL)
    status <- if (is.null(meta)) NA_character_ else meta$status

    if (identical(status, "SUCCEEDED")) return(TRUE)
    if (status %in% c("KILLED", "CANCELLED", "FAILED")) {
      warning(sprintf("GBIF download %s ended with status %s", dl_key, status),
              call. = FALSE)
      return(FALSE)
    }
    if (Sys.time() > deadline) {
      warning(sprintf(
        "GBIF download %s still %s after %d min; giving up (the job keeps running — see https://www.gbif.org/occurrence/download/%s)",
        dl_key, status, timeout_min, dl_key
      ), call. = FALSE)
      return(FALSE)
    }

    cat(sprintf("    … %s, waiting\n", status))
    Sys.sleep(30)
  }
}

# Server-side download: one query, no offset ceiling, full bbox coverage.
# Returns NULL so the caller can fall back to occ_search paging.
fetch_gbif_via_download <- function(bounds) {
  if (!gbif_credentials_present()) {
    warning(paste0(
      "GBIF_USE_DOWNLOAD is TRUE but GBIF_USER / GBIF_PWD / GBIF_EMAIL are not set; ",
      "falling back to occ_search paging (slow, and capped at 100,000 records). ",
      "Add them to ~/.Renviron to use occ_download."
    ), call. = FALSE)
    return(NULL)
  }

  preds <- gbif_download_predicates(bounds)
  dir.create(GBIF_DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)
  cache_zip <- file.path(GBIF_DOWNLOAD_DIR, sprintf("gbif_%s.zip", gbif_predicate_hash(preds)))

  dl_key <- NA_character_
  dl_doi <- NA_character_

  if (file.exists(cache_zip)) {
    cat(sprintf("  → reusing cached GBIF download %s\n", basename(cache_zip)))
  } else {
    cat("  → requesting GBIF occ_download (server-side query)…\n")
    req <- tryCatch(
      do.call(occ_download, c(preds, list(format = "SIMPLE_CSV"))),
      error = function(e) {
        warning(sprintf("GBIF occ_download request failed: %s", conditionMessage(e)),
                call. = FALSE)
        NULL
      }
    )
    if (is.null(req)) return(NULL)

    dl_key <- as.character(req)
    dl_doi <- attr(req, "doi")
    cat(sprintf("  → download key %s — GBIF is preparing the archive\n", dl_key))

    timeout_min <- if (exists("GBIF_DOWNLOAD_TIMEOUT_MIN")) GBIF_DOWNLOAD_TIMEOUT_MIN else 90L
    if (!gbif_await_download(dl_key, timeout_min)) return(NULL)

    got <- tryCatch(
      occ_download_get(req, path = GBIF_DOWNLOAD_DIR, overwrite = TRUE),
      error = function(e) {
        warning(sprintf("Fetching GBIF download %s failed: %s", dl_key, conditionMessage(e)),
                call. = FALSE)
        NULL
      }
    )
    if (is.null(got)) return(NULL)
    file.rename(as.character(got), cache_zip)
  }

  out <- tryCatch(
    as_tibble(occ_download_import(rgbif::as.download(cache_zip))),
    error = function(e) {
      warning(sprintf("Reading GBIF archive %s failed: %s",
                      basename(cache_zip), conditionMessage(e)), call. = FALSE)
      NULL
    }
  )
  if (is.null(out) || nrow(out) == 0L) return(NULL)
  n_raw <- nrow(out)

  # SIMPLE_CSV names gbifID where occ_search names key; align so the shared
  # dedup and geometry code below needs no branch.
  if (!"key" %in% names(out) && "gbifID" %in% names(out)) {
    out$key <- as.character(out$gbifID)
  }

  # Rank filter, applied here because the download API has no taxonRank
  # predicate. Lossless: process_tile.R drops every record whose taxon_name
  # (GBIF `species`) is NA, so these rows were never used.
  ranks <- if (exists("GBIF_TAXON_RANKS")) GBIF_TAXON_RANKS else NULL
  if (length(ranks) > 0L && "taxonRank" %in% names(out)) {
    out <- out[toupper(out$taxonRank) %in% toupper(ranks), , drop = FALSE]
  }
  if ("species" %in% names(out)) {
    out <- out[!is.na(out$species) & nzchar(out$species), , drop = FALSE]
  }

  if (nrow(out) == 0L) {
    warning("GBIF download held no species-level records after filtering", call. = FALSE)
    return(NULL)
  }

  # SIMPLE_CSV carries ~50 columns; a large bbox would otherwise write a
  # multi-hundred-MB GeoPackage of fields nothing reads. Keep what
  # process_tile.R consumes plus provenance. Note SIMPLE_CSV has no
  # vernacularName — process_tile.R already defaults it to NA, so GBIF common
  # labels are simply absent on this path.
  keep <- c("key", "occurrenceID", "species", "class", "eventDate", "recordedBy",
            "taxonRank", "scientificName", "kingdom", "basisOfRecord", "year",
            "coordinateUncertaintyInMeters", "datasetKey", "license",
            "decimalLatitude", "decimalLongitude")
  out <- out[, intersect(keep, names(out)), drop = FALSE]

  # Record the provenance of what is about to be written to RAW_GBIF.
  if (exists("GBIF_DOWNLOAD_META")) {
    write_json(
      list(
        download_key = dl_key,
        doi          = if (is.null(dl_doi)) NA_character_ else dl_doi,
        archive      = basename(cache_zip),
        records_raw  = n_raw,
        records_kept = nrow(out),
        bbox         = as.list(bounds),
        taxon_ranks  = ranks,
        year_min     = if (exists("GBIF_YEAR_MIN")) GBIF_YEAR_MIN else NULL,
        basis        = if (exists("GBIF_BASIS_OF_RECORD")) GBIF_BASIS_OF_RECORD else NULL
      ),
      GBIF_DOWNLOAD_META, auto_unbox = TRUE, pretty = TRUE, na = "null"
    )
  }

  cat(sprintf("  → GBIF: %d of %d downloaded records kept (species-level)\n",
              nrow(out), n_raw))
  out
}

fetch_gbif_for_bbox <- function(bounds, max_total = 10000L) {
  page_size <- 300L
  offset <- 0L
  parts <- list()
  api_total <- NA_integer_

  # occ_search cannot page beyond offset 100,000; past that GBIF requires a
  # credentialed occ_download. Clamp to the real API ceiling so the cap is the
  # API's limit rather than an arbitrary number, and warn below when a bbox
  # holds more than was fetched.
  occ_search_max <- 100000L
  if (max_total > occ_search_max) {
    warning(sprintf(
      "GBIF_MAX_RESULTS=%d exceeds occ_search's %d-record ceiling; clamping. Use occ_download for more.",
      max_total, occ_search_max
    ), call. = FALSE)
    max_total <- occ_search_max
  }

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
    if (is.na(api_total) && !is.null(res$meta$count)) {
      api_total <- as.integer(res$meta$count)
    }
    parts[[length(parts) + 1L]] <- res$data
    offset <- offset + nrow(res$data)
    if (nrow(res$data) < batch) break
  }

  if (length(parts) == 0) return(NULL)
  out <- bind_rows(parts)
  out <- if ("key" %in% names(out)) {
    out |> distinct(key, .keep_all = TRUE)
  } else if ("occurrenceID" %in% names(out)) {
    out |> distinct(occurrenceID, .keep_all = TRUE)
  } else {
    out
  }

  if (!is.na(api_total) && api_total > nrow(out)) {
    warning(sprintf(
      "GBIF bbox has %d records but only %d were downloaded (GBIF_MAX_RESULTS=%d)",
      api_total, nrow(out), max_total
    ), call. = FALSE)
  } else if (!is.na(api_total)) {
    cat(sprintf("  → GBIF: %d of %d records in bbox\n", nrow(out), api_total))
  }

  out
}

cat("Fetching GBIF observations…\n")
gbif_raw <- if (!exists("GBIF_USE_DOWNLOAD") || isTRUE(GBIF_USE_DOWNLOAD)) {
  fetch_gbif_via_download(BBOX_FETCH)
} else {
  NULL
}
if (is.null(gbif_raw)) {
  gbif_max <- if (exists("GBIF_MAX_RESULTS")) GBIF_MAX_RESULTS else 10000L
  gbif_raw <- fetch_gbif_for_bbox(BBOX_FETCH, gbif_max)
}

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
#
# Read from the per-tile .osm.pbf extracts that 01_ingest/tile_registry.R cuts
# out of the regional PBF: GDAL's OSM driver serves the same ways and relations
# Overpass does, off local disk, with no rate limit, no 20 s inter-query pause
# and no five-retries-across-four-endpoints failure mode. Overpass survives only
# as the fallback for a city with no local extract, or whose tiles do not span
# BBOX_CITY — hence the osmdata helpers above are still here.
#
# Only two layers are written. RAW_OSM_GREEN is read by 02_spatial/spatial_base.R
# and 06_export/export.R; RAW_OSM_PATHS is the fallback path network for
# 04_connectivity, which prefers the tile PBFs itself. The layers this step used
# to fetch as well — roads, rail, street lamps, lit roads, amenities, ground
# vegetation, water bodies, waterways — were written and never read by anything:
# 02_habitat/process_tile.R derives all of those from the tile PBFs directly.

GREEN_LEISURE_VALUES <- c("park", "nature_reserve", "garden")
PATH_HIGHWAY_VALUES  <- c("path", "footway", "pedestrian", "steps", "track")

OSM_TILES_DIR <- file.path(PIPELINE_ROOT, "data", "tiles", city)

# GDAL's OSM driver promotes only the keys listed in its osmconf.ini to columns;
# everything else lands in the other_tags hstore. Same backfill as
# 02_habitat/process_tile.R and 04_connectivity/connectivity_load.R.
osm_tag_from_other <- function(other_tags, key) {
  if (is.na(other_tags) || !nzchar(other_tags)) return(NA_character_)
  pattern <- paste0("\"", key, "\"=>\"([^\"]*)\"")
  match <- regexpr(pattern, other_tags, perl = TRUE)
  if (match[1L] == -1L) return(NA_character_)
  substr(other_tags, match[1L] + nchar(key) + 4L, match[1L] + attr(match, "match.length") - 2L)
}

osm_tile_pbfs <- function(tiles_dir = OSM_TILES_DIR) {
  sort(list.files(tiles_dir, pattern = "\\.osm\\.pbf$", full.names = TRUE))
}

# Tiles are cut from the AOI plus its halo, so they span BBOX_CITY — unless a
# city file pins BBOX_CITY wider than its own AOI. Check rather than assume: a
# tile set that stops short would truncate the layer silently, which is exactly
# the failure osm_cache_stale_reason() exists to catch.
osm_tiles_cover_city <- function(tiles_dir = OSM_TILES_DIR) {
  core <- file.path(tiles_dir, "core_tiles.gpkg")
  if (!file.exists(core)) return(FALSE)
  bb <- tryCatch(
    st_bbox(st_transform(st_read(core, quiet = TRUE), 4326)),
    error = function(e) NULL
  )
  if (is.null(bb)) return(FALSE)
  tol <- 1e-6
  bb[["xmin"]] <= BBOX_CITY[["xmin"]] + tol &&
    bb[["ymin"]] <= BBOX_CITY[["ymin"]] + tol &&
    bb[["xmax"]] >= BBOX_CITY[["xmax"]] - tol &&
    bb[["ymax"]] >= BBOX_CITY[["ymax"]] - tol
}

# One feature straddling a tile boundary is present in every halo that covers
# it, so the same osm_id comes back several times. Keys are namespaced by
# origin: in the multipolygons layer a relation-built area carries osm_id and a
# way-built one carries osm_way_id, and the two ID spaces overlap.
osm_dedupe_key <- function(x) {
  id <- if ("osm_id" %in% names(x)) as.character(x$osm_id) else rep(NA_character_, nrow(x))
  way <- if ("osm_way_id" %in% names(x)) as.character(x$osm_way_id) else rep(NA_character_, nrow(x))
  has_id <- !is.na(id) & nzchar(id)
  ifelse(has_id, paste0("r", id), paste0("w", way))
}

read_local_osm <- function(layers, tag_cols, pbfs, wkt_filter) {
  parts <- unlist(
    lapply(pbfs, function(pbf) {
      lapply(layers, function(layer) {
        out <- tryCatch(
          st_read(pbf, layer = layer, wkt_filter = wkt_filter, quiet = TRUE,
                  int64_as_string = TRUE),
          error = function(e) NULL
        )
        if (is.null(out) || nrow(out) == 0L) NULL else out
      })
    }),
    recursive = FALSE
  )
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0L) return(st_sf(geometry = st_sfc(crs = 4326)))

  out <- bind_rows(parts)
  for (col in tag_cols) {
    if (!col %in% names(out)) out[[col]] <- NA_character_
    if ("other_tags" %in% names(out)) {
      missing <- is.na(out[[col]]) | !nzchar(out[[col]])
      if (any(missing)) {
        out[[col]][missing] <- vapply(out$other_tags[missing], osm_tag_from_other,
                                      character(1L), key = col)
      }
    }
  }
  out[!duplicated(osm_dedupe_key(out)), , drop = FALSE]
}

# NULL when the tiles yield nothing usable, so the caller can fall back to
# Overpass instead of writing an empty layer over a real one.
read_local_green_spaces <- function(pbfs, wkt_filter) {
  polys <- read_local_osm("multipolygons", "leisure", pbfs, wkt_filter)
  polys <- polys[!is.na(polys$leisure) & polys$leisure %in% GREEN_LEISURE_VALUES, , drop = FALSE]
  if (nrow(polys) == 0L) return(NULL)
  polys |>
    st_make_valid() |>
    st_cast("MULTIPOLYGON") |>
    st_transform(CRS_LOCAL)
}

read_local_paths <- function(pbfs, wkt_filter) {
  lines <- read_local_osm(c("lines", "multilinestrings"), "highway", pbfs, wkt_filter)
  lines <- lines[!is.na(lines$highway) & lines$highway %in% PATH_HIGHWAY_VALUES, , drop = FALSE]
  if (nrow(lines) == 0L) return(NULL)
  st_transform(lines, CRS_LOCAL)
}

cat("Loading OpenStreetMap features...\n")

# Use BBOX_CITY (analysis domain) — smaller than BBOX_FETCH when they differ.
osm_bbox <- c(BBOX_CITY["xmin"], BBOX_CITY["ymin"],
              BBOX_CITY["xmax"], BBOX_CITY["ymax"])
osm_wkt_filter <- st_as_text(
  st_as_sfc(st_bbox(c(xmin = unname(osm_bbox[[1L]]), ymin = unname(osm_bbox[[2L]]),
                      xmax = unname(osm_bbox[[3L]]), ymax = unname(osm_bbox[[4L]])),
                    crs = 4326)),
  trim = TRUE
)

osm_local_pbfs <- osm_tile_pbfs()
osm_use_local <- length(osm_local_pbfs) > 0L && osm_tiles_cover_city()

if (osm_use_local) {
  cat(sprintf("  → reading from %d local tile PBF(s) in %s — no Overpass\n",
              length(osm_local_pbfs), OSM_TILES_DIR))
} else if (length(osm_local_pbfs) > 0L) {
  cat(paste0("  → local tile PBFs stop short of BBOX_CITY (they were cut for an ",
             "earlier AOI) — using Overpass.\n",
             "    Re-run 01_ingest/tile_registry.R to rebuild them for the current ",
             "AOI and this step goes fully local.\n"))
} else {
  cat(sprintf("  → no tile PBFs in %s (run 01_ingest/tile_registry.R) — using Overpass\n",
              OSM_TILES_DIR))
}

if (!use_osm_cache(RAW_OSM_GREEN, 1L, "OSM green spaces")) {
  green_polygons <- if (osm_use_local) {
    read_local_green_spaces(osm_local_pbfs, osm_wkt_filter)
  } else {
    NULL
  }

  if (is.null(green_polygons)) {
    if (osm_use_local) {
      cat("  → no green space polygons in the tile PBFs — falling back to Overpass\n")
    }
    overpass_pause_before_query()
    osm_green <- fetch_osm_sf(function() {
      opq(bbox = osm_bbox, timeout = 180) |>
        add_osm_feature(key = "leisure", value = GREEN_LEISURE_VALUES) |>
        osmdata_sf()
    }, "OSM green spaces")

    green_polygons <- if (!is.null(combine_osm_polygons(osm_green))) {
      combine_osm_polygons(osm_green) |> st_transform(CRS_LOCAL)
    } else {
      warning("No OSM green space polygons returned — writing empty layer")
      st_sf(geometry = st_sfc(crs = CRS_LOCAL))
    }
  }

  write_osm_cache(green_polygons, RAW_OSM_GREEN)
  cat(sprintf("  → %d green space polygons written\n", nrow(green_polygons)))
}

if (!use_osm_cache(RAW_OSM_PATHS, 0L, "OSM paths")) {
  path_lines <- if (osm_use_local) {
    read_local_paths(osm_local_pbfs, osm_wkt_filter)
  } else {
    NULL
  }

  if (is.null(path_lines)) {
    if (osm_use_local) {
      cat("  → no path lines in the tile PBFs — falling back to Overpass\n")
    }
    overpass_pause_before_query()
    osm_paths <- fetch_osm_sf(function() {
      opq(bbox = osm_bbox, timeout = 180) |>
        add_osm_feature(key = "highway", value = PATH_HIGHWAY_VALUES) |>
        osmdata_sf()
    }, "OSM paths")

    path_lines <- if (!is.null(osm_paths$osm_lines)) {
      osm_paths$osm_lines |> st_transform(CRS_LOCAL)
    } else {
      warning("No OSM path lines returned — writing empty layer")
      st_sf(geometry = st_sfc(crs = CRS_LOCAL))
    }
  }

  write_osm_cache(path_lines, RAW_OSM_PATHS)
  cat(sprintf("  → %d path lines written\n", nrow(path_lines)))
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

# ── 6b. Country CIR orthophoto NDVI (optional) ──────────────────────────────
# DN-based vegetation mask + NDVI raster for veg_fraction / ndvi_texture.
# Does not overwrite RAW_NDVI.

if (config_path_exists(CIR_NDVI_FILE)) {
  cat(sprintf("Processing CIR orthophoto NDVI: %s\n", CIR_NDVI_FILE))
  cir <- crop_to_city(rast(CIR_NDVI_FILE))
  if (nlyr(cir) > 1L) cir <- cir[[1]]

  # Each of these goes straight to its output file instead of building an
  # unnamed intermediate first. `cir[!is.finite(cir)] <- NA` followed by
  # writeRaster() materialises the whole raster twice, once into terra's own
  # temp GeoTIFF — which is not BigTIFF and so cannot hold a raster over 4 GB
  # at all (Gent's 0.5 m CIR NDVI is 7.2 GB as FLT4S). ifel(filename=) writes
  # the result directly, block by block, with BIGTIFF=IF_SAFER on the output.
  #
  # Same values as before: is.finite() is FALSE for NA as well as NaN and Inf,
  # so those cells come out NA, and the veg mask below reads NA where the NDVI
  # is NA because the comparison is NA there.
  cir_gdal <- c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256",
                "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")
  ifel(
    is.finite(cir), cir, NA,
    filename = RAW_CIR_NDVI, overwrite = TRUE,
    wopt = list(names = "cir_ndvi_dn", datatype = "FLT4S", gdal = cir_gdal)
  )

  # Read back rather than reusing `cir`: the mask must be derived from the
  # NA-cleaned raster that was just written, and re-reading it costs one pass
  # instead of a second in-memory copy.
  cir <- rast(RAW_CIR_NDVI)
  ifel(
    cir >= CIR_VEG_NDVI_THRESHOLD, 1, 0,
    filename = RAW_VEG_FRACTION, overwrite = TRUE,
    wopt = list(names = "veg_fraction", datatype = "INT1U", gdal = cir_gdal)
  )
  cat(sprintf(
    "  → CIR NDVI written; veg mask threshold %.2f\n",
    CIR_VEG_NDVI_THRESHOLD
  ))
} else {
  message(
    "Skipping CIR NDVI - run download_pt_ortho_ndvi.R or download_nl_cir_ndvi.R ",
    "to write ", CIR_NDVI_FILE, "."
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
