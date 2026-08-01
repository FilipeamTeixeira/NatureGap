# DGT "Ortos2025" WMS (Portugal national orthophoto, Direção-Geral do Território)
# -> false-colour infrared composite -> NDVI, for Porto only.
#
# Source: https://cartografia.dgterritorio.gov.pt/wms/ortos2025
# Layer used: Ortos2025-IRG (Infrared-Red-Green false-colour composite).
# Band order: 1=Near-Infrared, 2=Red, 3=Green. This matches DGT's documented
# convention across their other products (OrtoSat, Sentinel-2 mosaics all use
# "IRG" = Infravermelho/Red/Green in that band order) — I could not reach the
# Ortos2025-IRG layer's own metadata page directly, so treat this as
# high-confidence but VERIFY visually on first run (see check at the bottom).
#
# IMPORTANT — this is DN-based NDVI, not reflectance-based. The WMS returns an
# 8-bit visual product (0-255 per band), not calibrated surface reflectance.
# NDVI computed this way is a valid, standard greenness signal for relative
# comparison *within* this raster, but its absolute values are NOT directly
# comparable to the Sentinel-2 or PlanetScope NDVI already used elsewhere in
# this pipeline — those are reflectance-based. Keep this as a separate field,
# don't blend it numerically with the other NDVI sources without accounting
# for that difference.
#
# Country-specific, NOT part of RASTER_INPUT_DOWNLOADERS by default — this is
# a Porto-only supplementary source (per config_porto.R's CRS_LOCAL), unlike
# WorldCover/Sentinel-2/etc which work the same way for every city. Add other
# cities' equivalents to their own config as you get them.

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(httr2)
library(terra)
library(sf)

PT_ORTHO_NDVI_FILE <- file.path(
  DATA_IMPORT, "nir",
  paste0("ndvi_", CITY_ID, ".tif")
)

WMS_BASE_URL   <- "https://cartografia.dgterritorio.gov.pt/wms/ortos2025"
WMS_LAYER      <- "Ortos2025-IRG"
WMS_CRS        <- "EPSG:3763"   # matches config_porto.R's CRS_LOCAL exactly — no reprojection needed
WMS_MAX_PIXELS <- 3500L         # safety margin under the server's stated MaxWidth/MaxHeight of 4096
TARGET_GSD_M   <- 0.5           # metres/pixel — matches native DGT ortho resolution; raise if tiles are too large/slow

pt_ortho_tile_bboxes <- function(bbox_3763, max_pixels = WMS_MAX_PIXELS, gsd = TARGET_GSD_M) {
  width_m  <- bbox_3763["xmax"] - bbox_3763["xmin"]
  height_m <- bbox_3763["ymax"] - bbox_3763["ymin"]

  tile_span_m <- max_pixels * gsd
  n_cols <- max(1L, ceiling(width_m / tile_span_m))
  n_rows <- max(1L, ceiling(height_m / tile_span_m))

  x_breaks <- seq(bbox_3763["xmin"], bbox_3763["xmax"], length.out = n_cols + 1L)
  y_breaks <- seq(bbox_3763["ymin"], bbox_3763["ymax"], length.out = n_rows + 1L)

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

pt_ortho_fetch_tile <- function(tile_bbox, gsd = TARGET_GSD_M) {
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
      FORMAT = "image/tiff",
      TRANSPARENT = "FALSE"
    )

  tmp_tif <- tempfile(fileext = ".tif")
  resp <- req_perform(req, path = tmp_tif)

  if (resp_content_type(resp) != "image/tiff") {
    # WMS servers return an XML ServiceException with a 200 status on bad
    # requests — check for this explicitly rather than let a bogus "image"
    # fail silently or confusingly later in terra::rast().
    stop(
      "DGT WMS did not return a TIFF (got ", resp_content_type(resp), "). ",
      "Response body: ", paste(readLines(tmp_tif, warn = FALSE), collapse = " ")
    )
  }

  r <- rast(tmp_tif)
  # Assign georeferencing explicitly from the exact bbox we requested, rather
  # than trust the server to embed it correctly in the TIFF.
  ext(r) <- ext(tile_bbox["xmin"], tile_bbox["xmax"], tile_bbox["ymin"], tile_bbox["ymax"])
  crs(r) <- WMS_CRS
  r
}

download_pt_ortho_ndvi <- function(bbox = BBOX_CITY, out_file = PT_ORTHO_NDVI_FILE) {
  if (file.exists(out_file)) {
    message("Portugal ortho NDVI already exists: ", out_file)
    return(invisible(out_file))
  }
  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

  bbox_3763 <- st_bbox(bbox, crs = 4326) |> st_as_sfc() |> st_transform(WMS_CRS) |> st_bbox()

  tiles <- pt_ortho_tile_bboxes(bbox_3763)
  tile_rasters <- vector("list", length(tiles))

  for (i in seq_along(tiles)) {
    message(sprintf("Fetching tile %d/%d...", i, length(tiles)))
    tile_rasters[[i]] <- pt_ortho_fetch_tile(tiles[[i]])
  }

  mosaic <- if (length(tile_rasters) == 1L) {
    tile_rasters[[1]]
  } else {
    terra::mosaic(terra::sprc(tile_rasters), fun = "first")
  }

  ndvi <- (mosaic[[1]] - mosaic[[2]]) / (mosaic[[1]] + mosaic[[2]])
  names(ndvi) <- "pt_ortho_ndvi_dn"

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
    "vegetated areas (parks, gardens) show clearly higher values than roads/roofs. ",
    "If the pattern looks inverted or flat, the IRG band order assumption ",
    "(NIR, Red, Green) may not hold for this specific layer and needs rechecking."
  )
  invisible(out_file)
}

download_pt_ortho_ndvi()
