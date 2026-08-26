# Reference air-quality surface via OGC WCS, for LUR calibration only.
#
# Gent      -> ATMO-Street (IRCELINE/VMM/VITO), 10 m, EPSG:31370, CC BY 4.0
# Amsterdam -> RIVM NSL (Atlas Leefomgeving), 25 m, EPSG:28992
#
# Both are open services: no account, no request, no key. Configure per city
# with AIR_QUALITY_WCS in pipeline/cities/<city>.R; cities without it are
# skipped, which is the normal case.
#
# This raster is NOT a pipeline input. It is the dependent variable that
# calibration/fit_lur.R regresses the OSM traffic predictors against. It stays
# under data/<city>/raw/ (gitignored) and is never exported. Anything published
# that derives from it must carry the attribution recorded in the city file.
#
# Usage:
#   NATUREGAP_CITY=gent Rscript --vanilla -e 'source("config.R"); source("00_download/download_air_quality.R")'

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(httr2)
library(terra)

if (!exists("AIR_QUALITY_WCS") || is.null(AIR_QUALITY_WCS)) {
  message("[airquality] No AIR_QUALITY_WCS for ", CITY_ID, " — skipping.")
} else if (file.exists(RAW_AIR_QUALITY) && OSM_SKIP_IF_EXISTS) {
  message("[airquality] Cached raster present — skipping download.")
} else {

  cfg <- AIR_QUALITY_WCS

  # Request in the coverage's own CRS. Reprojecting server-side is supported by
  # some WCS implementations and not others; asking for the native grid and
  # reprojecting locally with terra is the portable route, and it avoids
  # resampling the reference surface before it is even sampled.
  aoi_native <- st_transform(aoi, cfg$crs)
  bb <- st_bbox(aoi_native)

  # Snap outward so the request covers whole source pixels, and pad by a hex
  # ring so centroid sampling near the AOI edge is not extrapolating.
  pad <- 100
  x <- c(floor(bb[["xmin"]]) - pad, ceiling(bb[["xmax"]]) + pad)
  y <- c(floor(bb[["ymin"]]) - pad, ceiling(bb[["ymax"]]) + pad)

  url <- paste0(cfg$endpoint,
                "?service=WCS&version=2.0.1&request=GetCoverage",
                "&coverageid=", cfg$coverage,
                "&format=image/tiff",
                sprintf("&subset=X(%.0f,%.0f)&subset=Y(%.0f,%.0f)", x[1], x[2], y[1], y[2]))

  cat(sprintf("[airquality] %s  %s %d (%s)\n", CITY_ID, toupper(cfg$pollutant), cfg$year, cfg$model))
  cat(sprintf("[airquality] subset X(%.0f,%.0f) Y(%.0f,%.0f) in %s\n", x[1], x[2], y[1], y[2], cfg$crs))

  resp <- request(url) |>
    req_timeout(600) |>
    req_retry(max_tries = 3L, backoff = \(i) 10 * i) |>
    req_perform()

  ct <- resp_content_type(resp)
  if (!grepl("tiff", ct, fixed = TRUE)) {
    stop(
      "WCS did not return a GeoTIFF (content-type '", ct, "'). ",
      "The body usually carries an OWS ExceptionReport explaining why:\n",
      substr(resp_body_string(resp), 1, 500),
      call. = FALSE
    )
  }

  bytes <- resp_body_raw(resp)
  if (!is.null(cfg$max_bytes) && length(bytes) >= cfg$max_bytes * 0.98) {
    warning(
      "Response is at the documented WCS size cap (", length(bytes), " bytes). ",
      "It may be silently truncated — request the AOI in tiles.",
      call. = FALSE
    )
  }

  dir.create(dirname(RAW_AIR_QUALITY), recursive = TRUE, showWarnings = FALSE)
  writeBin(bytes, RAW_AIR_QUALITY)

  r <- rast(RAW_AIR_QUALITY)
  vals <- values(r, mat = FALSE)
  finite <- vals[is.finite(vals)]
  if (length(finite) == 0L) stop("Downloaded raster has no finite values.", call. = FALSE)

  cat(sprintf(
    "Written: %s\n  %d x %d px, res %.1f m, %s\n  %s: min %.1f, median %.1f, max %.1f %s\n",
    RAW_AIR_QUALITY, ncol(r), nrow(r), res(r)[1], crs(r, describe = TRUE)$code,
    toupper(cfg$pollutant), min(finite), median(finite), max(finite), cfg$unit
  ))
}
