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
  # Snap the AOI outward onto the gsd grid, then cut it into tiles of exactly
  # `max_pixels` pixels (the last column/row may be shorter). Every tile then
  # has exactly `gsd` resolution and sits on one shared pixel grid, which is
  # what the VRT stitch below needs. Splitting the AOI into tiles of equal
  # *metric* width instead leaves them on an off-grid resolution derived from
  # the AOI width, where rounding to whole pixels can open sub-pixel seams.
  x_min <- floor(unname(bbox_3763["xmin"]) / gsd) * gsd
  y_min <- floor(unname(bbox_3763["ymin"]) / gsd) * gsd
  n_px_x <- as.integer(ceiling((unname(bbox_3763["xmax"]) - x_min) / gsd))
  n_px_y <- as.integer(ceiling((unname(bbox_3763["ymax"]) - y_min) / gsd))

  x_offsets <- seq(0L, n_px_x - 1L, by = max_pixels)
  y_offsets <- seq(0L, n_px_y - 1L, by = max_pixels)

  tiles <- list()
  k <- 1L
  for (ox in x_offsets) {
    for (oy in y_offsets) {
      w <- min(max_pixels, n_px_x - ox)
      h <- min(max_pixels, n_px_y - oy)
      tiles[[k]] <- c(
        xmin = x_min + ox * gsd, xmax = x_min + (ox + w) * gsd,
        ymin = y_min + oy * gsd, ymax = y_min + (oy + h) * gsd
      )
      k <- k + 1L
    }
  }
  message(sprintf(
    "Split into %d tile(s) (%d x %d) at %.2f m/px, each <= %d px",
    length(tiles), length(x_offsets), length(y_offsets), gsd, max_pixels
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

  # NDVI is reduced to one band per tile *before* anything is stitched. The
  # obvious alternative — mosaic the 3-band IRG tiles, then compute NDVI on the
  # mosaic — materialises a ~3.8 GB FLT4S intermediate for a city the size of
  # Porto, which overruns the 4 GB ceiling of the plain GeoTIFF terra writes
  # its temp files as ("cannot write values (err: 3)") and needs disk this
  # machine does not reliably have. One band and a VRT stitch keeps peak use to
  # a single tile in memory and ~1.3 GB on disk.
  tile_dir <- paste0(tools::file_path_sans_ext(out_file), "_tiles")
  grid_stamp <- paste(
    c(round(unname(bbox_3763), 3), TARGET_GSD_M, WMS_MAX_PIXELS, WMS_LAYER),
    collapse = "|"
  )
  stamp_file <- file.path(tile_dir, "grid.txt")
  if (dir.exists(tile_dir) &&
      !identical(tryCatch(readLines(stamp_file, warn = FALSE)[1], error = function(e) NA_character_),
                 grid_stamp)) {
    # Scratch tiles left by an interrupted run for a *different* grid must not
    # be reused — they would stitch into a silently wrong raster.
    unlink(tile_dir, recursive = TRUE)
  }
  dir.create(tile_dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(grid_stamp, stamp_file)

  tile_files <- file.path(tile_dir, sprintf("ndvi_tile_%03d.tif", seq_along(tiles)))
  for (i in seq_along(tiles)) {
    if (file.exists(tile_files[i])) {
      message(sprintf("Tile %d/%d already fetched.", i, length(tiles)))
      next
    }
    message(sprintf("Fetching tile %d/%d...", i, length(tiles)))
    irg <- pt_ortho_fetch_tile(tiles[[i]])
    ndvi_tile <- (irg[[1]] - irg[[2]]) / (irg[[1]] + irg[[2]])

    # Write to a scratch name and rename, so an interrupted write cannot leave
    # a truncated tile that the resume path above would happily reuse. The
    # scratch name has to keep the .tif extension — terra guesses the driver
    # from it and refuses anything it cannot recognise.
    partial <- sub("\\.tif$", "_part.tif", tile_files[i])
    writeRaster(
      ndvi_tile, partial, overwrite = TRUE, datatype = "FLT4S",
      gdal = c("TILED=YES", "COMPRESS=DEFLATE")
    )
    file.rename(partial, tile_files[i])
  }

  ndvi <- if (length(tile_files) == 1L) rast(tile_files) else terra::vrt(tile_files, overwrite = TRUE)
  names(ndvi) <- "pt_ortho_ndvi_dn"

  writeRaster(
    ndvi, out_file, overwrite = TRUE, datatype = "FLT4S",
    gdal = c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256",
             "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")
  )
  unlink(tile_dir, recursive = TRUE)

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
