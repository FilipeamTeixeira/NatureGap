if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(rstac)
library(terra)

# Landsat Collection 2 Level-2 QA_PIXEL, bits 0-5: Fill, Dilated Cloud,
# Cirrus, Cloud, Cloud Shadow, Snow. A pixel is unusable for LST if ANY of
# these bits are set. Bits 0:5 sum to 63 (1+2+4+8+16+32); since 64 = 2^6,
# `qa %% 64 != 0` is an exact, vectorized equivalent of bitwAnd(qa, 63) != 0
# that terra evaluates directly as raster algebra (no per-pixel R calls).
LANDSAT_QA_BAD_MOD <- 64L

# Wall-clock budget for one scene's windowed read, in seconds.
LST_SCENE_TIME_LIMIT <- 120

# Landsat C2 L2 assets are ~80 MB tiled COGs with overviews. Reading the AOI
# window over /vsicurl keeps the transfer proportional to the AOI (a few
# seconds per scene); rast() on a bare https:// href does NOT read a window --
# terra pulls the whole file and reliably hits GDAL_HTTP_TIMEOUT. Note that
# setGDALconfig() is process-wide, so these are set here rather than relying on
# whatever an earlier downloader in the same R session happened to leave behind.
lst_gdal_config <- function() {
  setGDALconfig("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  setGDALconfig("VSI_CACHE", "TRUE")
  setGDALconfig("VSI_CACHE_SIZE", "67108864")
  setGDALconfig("GDAL_HTTP_MAX_RETRY", "5")
  setGDALconfig("GDAL_HTTP_RETRY_DELAY", "3")
  setGDALconfig("GDAL_HTTP_TIMEOUT", "120")
}

lst_vsicurl <- function(href) {
  if (startsWith(href, "/vsicurl/")) href else paste0("/vsicurl/", href)
}

# Signed hrefs carry a long SAS query string; drop it for log messages.
lst_asset_name <- function(href) basename(sub("\\?.*$", "", href))

# One scene's spatial anomaly, or NULL when no usable pixel survives the QA
# mask. Runs in its own frame so the transient time limit is cleared by
# on.exit() during unwinding -- i.e. before the caller's error handler runs.
# Resetting it in a tryCatch(finally = ) instead lets the pending limit re-fire
# inside the handler and propagate out of the scene loop.
lst_scene_anomaly <- function(lst_url, qa_url, aoi_wgs84) {
  setTimeLimit(elapsed = LST_SCENE_TIME_LIMIT, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf, transient = FALSE), add = TRUE)

  lst_r <- rast(lst_vsicurl(lst_url))
  qa_r  <- rast(lst_vsicurl(qa_url))

  # Crop to the study bbox first -- these are full ~185 km Landsat scenes;
  # nothing beyond the bbox is read from the remote COG.
  aoi <- project(aoi_wgs84, crs(lst_r))
  lst_r <- crop(lst_r, aoi)
  qa_r  <- resample(crop(qa_r, aoi), lst_r, method = "near")

  bad <- (qa_r %% LANDSAT_QA_BAD_MOD) != 0
  lst_r[bad] <- NA

  lst_c <- lst_r * LST_DN_SCALE + LST_DN_OFFSET - 273.15
  n_valid <- global(!is.na(lst_c), "sum", na.rm = TRUE)[1, 1]
  if (is.na(n_valid) || n_valid == 0) return(NULL)

  # Per-scene spatial anomaly relative to this scene's own valid study-area
  # pixels, so date-to-date weather differences cancel out rather than
  # dominating the composite.
  scene_mean <- global(lst_c, "mean", na.rm = TRUE)[1, 1]
  anomaly <- lst_c - scene_mean
  names(anomaly) <- "lst_anomaly_c"
  anomaly
}

download_landsat_temp <- function(bbox = BBOX_CITY,
                                  out_file = LST_FILE,
                                  date_windows = LST_SEASON_WINDOWS) {
  if (file.exists(out_file)) {
    message("Landsat LST already exists: ", out_file)
    return(invisible(out_file))
  }

  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

  bbox_unnamed <- unname(bbox)

  # stac_search() only accepts one datetime range per call — query each
  # season window separately and pool the resulting features.
  features <- list()
  last_items <- NULL
  for (window in date_windows) {
    items <- stac("https://planetarycomputer.microsoft.com/api/stac/v1") |>
      stac_search(
        collections = "landsat-c2-l2",
        bbox = bbox_unnamed,
        datetime = window
      ) |>
      ext_filter(
        `eo:cloud_cover` <= 10 &&
          platform %in% c("landsat-8", "landsat-9")
      ) |>
      post_request() |>
      items_fetch()
    features <- c(features, items$features)
    last_items <- items
  }

  n_found <- length(features)
  message(sprintf(
    "[LST] %d candidate Landsat 8/9 scene(s) found across %d date window(s).",
    n_found, length(date_windows)
  ))
  if (n_found == 0L) {
    stop("No Landsat C2 L2 scenes found across configured date windows.")
  }

  items_all <- last_items
  items_all$features <- features
  items_all <- items_sign(items_all, sign_planetary_computer())

  lst_urls <- assets_url(items_all, asset_names = "lwir11")
  qa_urls  <- assets_url(items_all, asset_names = "qa_pixel")

  aoi_wgs84 <- vect(
    ext(bbox[["xmin"]], bbox[["xmax"]], bbox[["ymin"]], bbox[["ymax"]]),
    crs = "EPSG:4326"
  )

  lst_gdal_config()

  anomalies <- list()
  ref_template <- NULL
  n_ok <- 0L

  for (i in seq_along(lst_urls)) {
    if (is.na(lst_urls[i]) || is.na(qa_urls[i])) next

    message(sprintf("[LST] Processing scene %d/%d...", i, length(lst_urls)))

    scene_result <- tryCatch(
      lst_scene_anomaly(lst_urls[i], qa_urls[i], aoi_wgs84),
      error = function(err) {
        message(sprintf(
          "[LST] Skipping scene %d/%d (%s): %s",
          i, length(lst_urls), lst_asset_name(lst_urls[i]), conditionMessage(err)
        ))
        NULL
      }
    )

    if (!is.null(scene_result)) {
      # All per-scene anomalies are aligned to the first usable scene's grid so
      # rast() can stack them for the median composite.
      if (is.null(ref_template)) {
        ref_template <- rast(scene_result)
      } else {
        scene_result <- resample(scene_result, ref_template, method = "bilinear")
      }
      n_ok <- n_ok + 1L
      anomalies[[n_ok]] <- scene_result
    }
  }

  message(sprintf("[LST] %d / %d candidate scene(s) processed successfully.", n_ok, n_found))
  if (n_ok == 0L) {
    stop("No Landsat scenes could be processed into a valid LST anomaly.")
  }

  # Pixel-wise median across per-scene anomalies — the persistent spatial
  # thermal pattern (e.g. canopy/corridor cooling), not any single date's
  # weather.
  composite <- app(rast(anomalies), fun = median, na.rm = TRUE)
  names(composite) <- "lst_celsius"

  writeRaster(
    composite, out_file, overwrite = TRUE,
    gdal = tiled_gdal_opts(composite)
  )
  message(sprintf(
    "[LST] Written: %s (median of %d per-scene spatial anomalies)",
    out_file, n_ok
  ))
  invisible(out_file)
}

download_landsat_temp()
