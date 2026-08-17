# PDOK "Luchtfoto CIR" WMS (Netherlands national infrared orthophoto)
# -> false-colour infrared composite -> DN-based NDVI.
#
# Source: https://service.pdok.nl/hwh/luchtfotocir/wms/v1_0
# Layer used: 2025_ortho25IR (Luchtfoto 2025 Ortho 25cm Infrarood), pinned by
# year rather than Actueel_ortho25IR so reruns stay reproducible when PDOK
# rolls the "current" mosaic forward.
# Band order: 1=Near-Infrared, 2=Red, 3=Green. Confirmed visually on a
# Vondelpark probe (vegetation high, water/roofs low) before this script
# was written.
#
# PDOK serves this layer as JPEG only (WMS/WMTS; no lossless WCS). JPEG is
# lossy, so individual pixels are not trustworthy; values averaged into a
# 20 m hex still carry a usable greenness signal. JPEG also carries no
# georeferencing — ext()/crs() assignment from the requested bbox is
# load-bearing, not optional.
#
# IMPORTANT — this is DN-based NDVI, not reflectance-based. The WMS returns
# an 8-bit visual product (0-255 per band), not calibrated surface
# reflectance. Absolute values are NOT directly comparable to the Sentinel-2
# or PlanetScope NDVI used elsewhere in this pipeline. Keep this as a
# separate field; do not overwrite RAW_NDVI with it.
#
# Country-specific, NOT part of RASTER_INPUT_DOWNLOADERS by default. Invoke
# by sourcing this file with CITY set to a Dutch city (CRS_LOCAL EPSG:28992).

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(httr2)
library(terra)
library(sf)

NL_CIR_NDVI_FILE <- file.path(
  DATA_IMPORT, "nir",
  paste0("ndvi_", CITY_ID, ".tif")
)

WMS_BASE_URL   <- "https://service.pdok.nl/hwh/luchtfotocir/wms/v1_0"
WMS_LAYER      <- "2025_ortho25IR"
WMS_CRS        <- "EPSG:28992"  # matches amsterdam-schimmelstraat.R's CRS_LOCAL
WMS_MAX_PIXELS <- 2400L         # safety margin under PDOK's stated MaxWidth/MaxHeight of 2500
WMS_FORMAT     <- "image/jpeg"  # PDOK offers no lossless GetMap format
TARGET_GSD_M   <- 0.5           # metres/pixel — coarser than native 25 cm; raise native if needed
MAX_TILES      <- 200L          # refuse unexpectedly large AOIs before hitting the WMS

nl_cir_tile_bboxes <- function(bbox_28992, max_pixels = WMS_MAX_PIXELS, gsd = TARGET_GSD_M) {
  width_m  <- bbox_28992["xmax"] - bbox_28992["xmin"]
  height_m <- bbox_28992["ymax"] - bbox_28992["ymin"]

  tile_span_m <- max_pixels * gsd
  n_cols <- max(1L, ceiling(width_m / tile_span_m))
  n_rows <- max(1L, ceiling(height_m / tile_span_m))

  x_breaks <- seq(bbox_28992["xmin"], bbox_28992["xmax"], length.out = n_cols + 1L)
  y_breaks <- seq(bbox_28992["ymin"], bbox_28992["ymax"], length.out = n_rows + 1L)

  tiles <- list()
  k <- 1L
  for (i in seq_len(n_cols)) {
    for (j in seq_len(n_rows)) {
      tiles[[k]] <- c(
        xmin = unname(x_breaks[i]), xmax = unname(x_breaks[i + 1L]),
        ymin = unname(y_breaks[j]), ymax = unname(y_breaks[j + 1L])
      )
      k <- k + 1L
    }
  }
  message(sprintf(
    "Split into %d tile(s) (%d x %d) at %.2f m/px, each <= %d px",
    length(tiles), n_cols, n_rows, gsd, max_pixels
  ))
  tiles
}

nl_cir_fetch_tile <- function(tile_bbox, gsd = TARGET_GSD_M) {
  width_px  <- max(1L, round((tile_bbox["xmax"] - tile_bbox["xmin"]) / gsd))
  height_px <- max(1L, round((tile_bbox["ymax"] - tile_bbox["ymin"]) / gsd))

  req <- request(WMS_BASE_URL) |>
    req_url_query(
      SERVICE = "WMS",
      VERSION = "1.3.0",
      REQUEST = "GetMap",
      LAYERS = WMS_LAYER,
      STYLES = "",
      CRS = WMS_CRS,
      BBOX = paste(
        tile_bbox["xmin"], tile_bbox["ymin"],
        tile_bbox["xmax"], tile_bbox["ymax"],
        sep = ","
      ),
      WIDTH = width_px,
      HEIGHT = height_px,
      FORMAT = WMS_FORMAT,
      TRANSPARENT = "FALSE"
    )

  tmp_jpg <- tempfile(fileext = ".jpg")
  resp <- req_perform(req, path = tmp_jpg)

  ctype <- resp_content_type(resp)
  if (!grepl("jpeg|jpg", ctype, ignore.case = TRUE)) {
    # WMS servers return an XML ServiceException with a 200 status on bad
    # requests — check for this explicitly rather than let a bogus "image"
    # fail silently or confusingly later in terra::rast().
    stop(
      "PDOK CIR WMS did not return a JPEG (got ", ctype, "). ",
      "Response body: ", paste(readLines(tmp_jpg, warn = FALSE), collapse = " ")
    )
  }

  r <- rast(tmp_jpg)
  if (nlyr(r) < 2L) {
    stop(
      "PDOK CIR WMS returned ", nlyr(r), " band(s); need at least NIR and Red."
    )
  }
  # JPEG has no georeferencing. Assign from the exact bbox we requested.
  ext(r) <- ext(tile_bbox["xmin"], tile_bbox["xmax"], tile_bbox["ymin"], tile_bbox["ymax"])
  crs(r) <- WMS_CRS
  r
}

download_nl_cir_ndvi <- function(bbox = BBOX_CITY, out_file = NL_CIR_NDVI_FILE) {
  if (exists("CRS_LOCAL") && !identical(CRS_LOCAL, WMS_CRS)) {
    stop(
      "download_nl_cir_ndvi.R is for Dutch cities (CRS_LOCAL ", WMS_CRS, "). ",
      "Current city uses ", CRS_LOCAL, ".",
      call. = FALSE
    )
  }
  if (file.exists(out_file)) {
    message("Netherlands CIR NDVI already exists: ", out_file)
    return(invisible(out_file))
  }
  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

  bbox_28992 <- st_bbox(bbox, crs = 4326) |> st_as_sfc() |> st_transform(WMS_CRS) |> st_bbox()

  tiles <- nl_cir_tile_bboxes(bbox_28992)
  if (length(tiles) > MAX_TILES) {
    stop(
      sprintf(
        "AOI would require %d tiles (cap %d) at %.2f m/px. ",
        length(tiles), MAX_TILES, TARGET_GSD_M
      ),
      "Shrink BBOX_CITY or raise TARGET_GSD_M / MAX_TILES.",
      call. = FALSE
    )
  }

  tile_rasters <- vector("list", length(tiles))
  for (i in seq_along(tiles)) {
    message(sprintf("Fetching tile %d/%d...", i, length(tiles)))
    tile_rasters[[i]] <- nl_cir_fetch_tile(tiles[[i]])
  }

  mosaic <- if (length(tile_rasters) == 1L) {
    tile_rasters[[1]]
  } else {
    terra::mosaic(terra::sprc(tile_rasters), fun = "first")
  }

  ndvi <- (mosaic[[1]] - mosaic[[2]]) / (mosaic[[1]] + mosaic[[2]])
  names(ndvi) <- "nl_cir_ndvi_dn"

  writeRaster(
    ndvi, out_file, overwrite = TRUE, datatype = "FLT4S",
    gdal = c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256", "COMPRESS=DEFLATE")
  )

  message(sprintf(
    "Written: %s (%d x %d px at %.2fm, CRS %s)",
    out_file, ncol(ndvi), nrow(ndvi), TARGET_GSD_M, WMS_CRS
  ))
  message(
    "SANITY CHECK before trusting this: plot(rast('", out_file, "')) and confirm ",
    "vegetated areas (Vondelpark, Amstelpark) show clearly higher values than ",
    "canal water and Zuidas rooftops."
  )
  invisible(out_file)
}

download_nl_cir_ndvi()
