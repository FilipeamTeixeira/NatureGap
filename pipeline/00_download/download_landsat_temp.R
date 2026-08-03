if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(rstac)
library(terra)

# Landsat Collection 2 Level-2 QA_PIXEL, bits 0-5: Fill, Dilated Cloud,
# Cirrus, Cloud, Cloud Shadow, Snow. A pixel is unusable for LST if ANY of
# these bits are set. Bits 0:5 sum to 63 (1+2+4+8+16+32); since 64 = 2^6,
# `qa %% 64 != 0` is an exact, vectorized equivalent of bitwAnd(qa, 63) != 0
# that terra evaluates directly as raster algebra (no per-pixel R calls).
LANDSAT_QA_BAD_MOD <- 64L

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

  anomalies <- list()
  ref_template <- NULL
  n_ok <- 0L

  for (i in seq_along(lst_urls)) {
    if (is.na(lst_urls[i]) || is.na(qa_urls[i])) next

    scene_result <- tryCatch({
      lst_r <- rast(lst_urls[i])
      qa_r  <- rast(qa_urls[i])

      # Crop to the study bbox first — these are full ~185 km Landsat
      # scenes; nothing beyond the bbox is read from the remote COG.
      aoi <- project(aoi_wgs84, crs(lst_r))
      lst_r <- crop(lst_r, aoi)
      qa_r  <- resample(crop(qa_r, aoi), lst_r, method = "near")

      bad <- (qa_r %% LANDSAT_QA_BAD_MOD) != 0
      lst_r[bad] <- NA

      lst_c <- lst_r * LST_DN_SCALE + LST_DN_OFFSET - 273.15

      n_valid <- global(!is.na(lst_c), "sum", na.rm = TRUE)[1, 1]
      if (is.na(n_valid) || n_valid == 0) return(NULL)

      # Per-scene spatial anomaly relative to this scene's own valid
      # study-area pixels, so date-to-date weather differences cancel out
      # rather than dominating the composite.
      scene_mean <- global(lst_c, "mean", na.rm = TRUE)[1, 1]
      anomaly <- lst_c - scene_mean
      names(anomaly) <- "lst_anomaly_c"

      if (is.null(ref_template)) {
        ref_template <- rast(anomaly)
      } else {
        anomaly <- resample(anomaly, ref_template, method = "bilinear")
      }
      anomaly
    }, error = function(err) {
      message(sprintf(
        "[LST] Skipping scene %d/%d (%s): %s",
        i, length(lst_urls), basename(lst_urls[i]), conditionMessage(err)
      ))
      NULL
    })

    if (!is.null(scene_result)) {
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
    gdal = c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256", "COMPRESS=DEFLATE")
  )
  message(sprintf(
    "[LST] Written: %s (median of %d per-scene spatial anomalies)",
    out_file, n_ok
  ))
  invisible(out_file)
}

download_landsat_temp()
