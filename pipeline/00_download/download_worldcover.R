if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(rstac)
library(terra)

# ESA WorldCover tiles are 3x3 degrees (~123 MB each). Reading the AOI window
# straight out of the Cloud-Optimised GeoTIFF over /vsicurl keeps the transfer
# proportional to the AOI; pulling whole tiles with download.file() reliably
# blows past its timeout on a city-sized run.
wc_gdal_config <- function() {
  setGDALconfig("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  setGDALconfig("VSI_CACHE", "TRUE")
  setGDALconfig("VSI_CACHE_SIZE", "67108864")
  setGDALconfig("GDAL_HTTP_MAX_RETRY", "5")
  setGDALconfig("GDAL_HTTP_RETRY_DELAY", "3")
  setGDALconfig("GDAL_HTTP_TIMEOUT", "120")
}

wc_extents_overlap <- function(a, b) {
  a <- as.vector(a)
  b <- as.vector(b)
  a[1] < b[2] && a[2] > b[1] && a[3] < b[4] && a[4] > b[3]
}

# Windowed read of one tile straight from the signed COG href.
wc_read_window <- function(href, aoi_ext) {
  crop(rast(paste0("/vsicurl/", href)), aoi_ext)
}

# Whole-tile fallback. Downloads to a .part file so an interrupted transfer is
# never left behind to be picked up as a valid cache entry on the next run.
wc_download_tile <- function(href, outfile) {
  part <- paste0(outfile, ".part")
  unlink(part)
  old_timeout <- options(timeout = max(getOption("timeout"), 3600L))
  on.exit({
    options(old_timeout)
    unlink(part)
  }, add = TRUE)

  download.file(href, part, mode = "wb")
  if (!file.rename(part, outfile)) {
    stop("Could not move downloaded tile into place: ", outfile, call. = FALSE)
  }
  outfile
}

# Fallback window, from a cached or freshly downloaded whole tile. A cached tile
# left truncated by an earlier failed run is discarded and fetched again.
wc_window_from_tile <- function(href, tile_name, outdir, aoi_ext) {
  outfile <- file.path(outdir, tile_name)

  for (attempt in 1:2) {
    if (!file.exists(outfile)) {
      message("Downloading: ", tile_name)
      wc_download_tile(href, outfile)
    }
    win <- tryCatch(
      crop(rast(outfile), aoi_ext),
      error = function(e) {
        message("Cached tile ", tile_name, " is unusable (", conditionMessage(e),
                "); re-downloading.")
        unlink(outfile)
        NULL
      }
    )
    if (!is.null(win)) return(win)
  }

  stop("Could not read WorldCover tile: ", tile_name, call. = FALSE)
}

download_worldcover <- function(bbox = BBOX_CITY,
                                out_file = WC_FILE) {
  if (file.exists(out_file)) {
    message("WorldCover already exists: ", out_file)
    return(invisible(out_file))
  }

  outdir <- dirname(out_file)
  dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

  items <- stac("https://planetarycomputer.microsoft.com/api/stac/v1") |>
    stac_search(
      collections = "esa-worldcover",
      bbox = unname(bbox)
    ) |>
    post_request() |>
    items_fetch() |>
    items_sign_planetary_computer()

  if (length(items$features) == 0L) {
    stop("No WorldCover tiles found.")
  }

  aoi_ext <- ext(
    unname(bbox["xmin"]),
    unname(bbox["xmax"]),
    unname(bbox["ymin"]),
    unname(bbox["ymax"])
  )

  wc_gdal_config()

  parts <- list()
  for (i in seq_along(items$features)) {
    feature <- items$features[[i]]
    href <- feature$assets$map$href
    tile_name <- basename(sub("\\?.*$", "", href))

    tile_bbox <- unlist(feature$bbox)
    if (length(tile_bbox) == 4L &&
        !wc_extents_overlap(ext(tile_bbox[c(1, 3, 2, 4)]), aoi_ext)) {
      next
    }

    win <- tryCatch(
      wc_read_window(href, aoi_ext),
      error = function(e) {
        message("Windowed read failed for ", tile_name, " (", conditionMessage(e),
                "); falling back to a full tile download.")
        NULL
      }
    )

    if (is.null(win)) win <- wc_window_from_tile(href, tile_name, outdir, aoi_ext)

    parts[[length(parts) + 1L]] <- win
  }

  if (length(parts) == 0L) {
    stop("No WorldCover tiles overlap the AOI.", call. = FALSE)
  }

  wc <- if (length(parts) == 1L) parts[[1L]] else mosaic(sprc(parts))
  wc <- crop(wc, aoi_ext)

  writeRaster(
    wc, out_file, overwrite = TRUE,
    gdal = c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256", "COMPRESS=DEFLATE")
  )
  message("Written: ", out_file)
  invisible(out_file)
}

download_worldcover()
