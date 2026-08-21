# Digitaal Vlaanderen "Orthofotomozaïek, middenschalig, zomeropnamen" WCS
# (Flanders regional infrared orthophoto) -> false-colour infrared composite
# -> DN-based NDVI.
#
# Source:   https://geo.api.vlaanderen.be/OMZ/wcs
# Coverage: OMZNIR21VL (summer 2021 NIR mosaic, Flanders), pinned by year.
#           The service also carries OMZNIR18/15/12/09VL; 2021 is the most
#           recent NIR mosaic it offers. Pinning the year rather than tracking
#           a "current" alias keeps reruns reproducible.
# Native:   0.4 m GSD, EPSG:31370 (Belge Lambert 72), 3 bands, image/tiff.
#
# Band order: 1=Near-Infrared, 2=Red, 3=Green — verified, not assumed. Bands 2
# and 3 of OMZNIR21VL are pixel-for-pixel the Red and Green bands of the
# companion OMZRGB21VL coverage over the same bbox (r = 0.998 / 0.997, identical
# band means), while band 1 correlates with none of them (r <= 0.46). Rendering
# band 1 as red over Gentbrugse Meersen gives a textbook false-colour infrared
# image: canopy bright red, pavement and roofs cyan, water near-black.
#
# WCS, not WMS — unlike the Dutch and Portuguese CIR sources this one serves
# lossless image/tiff with real georeferencing, so there is no JPEG artefact
# caveat and no world file to write (contrast download_nl_cir_ndvi.R).
#
# WCS version 1.0.0 deliberately. The service also advertises 2.0.1, but that
# returns multipart/related (a GML part plus the TIFF part) which would have to
# be MIME-split before terra could read it. 1.0.0 returns the bare GeoTIFF and
# takes width/height directly, which is how the target GSD is set here.
#
# IMPORTANT — this is DN-based NDVI, not reflectance-based. The coverage is an
# 8-bit visual product (0-255 per band), not calibrated surface reflectance.
# Absolute values are NOT directly comparable to the Sentinel-2 or PlanetScope
# NDVI used elsewhere in this pipeline. Keep this as a separate field; do not
# overwrite RAW_NDVI with it.
#
# FLANDERS ONLY. Belgium has no national orthophoto service — Flanders
# (Digitaal Vlaanderen) and Wallonia (SPW) are separate agencies with separate
# endpoints, and the Brussels-Capital Region is a hole in the Flemish mosaic
# even though it sits inside the coverage envelope. config.R keys
# CIR_DOWNLOADER_BY_COUNTRY on country, so a Walloon or Brussels city would be
# routed here by default and would fetch nodata; be_flanders_assert_coverage()
# below refuses the envelope case, and the near-empty-NDVI check at the end of
# the run catches the Brussels case.
#
# Country-specific, NOT part of RASTER_INPUT_DOWNLOADERS by default. Invoke by
# sourcing this file with CITY set to a Flemish city (CRS_LOCAL EPSG:31370).

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(httr2)
library(terra)
library(sf)

BE_FLANDERS_CIR_NDVI_FILE <- file.path(
  DATA_IMPORT, "nir",
  paste0("ndvi_", CITY_ID, ".tif")
)

WCS_BASE_URL   <- "https://geo.api.vlaanderen.be/OMZ/wcs"
WCS_COVERAGE   <- "OMZNIR21VL"
WCS_VERSION    <- "1.0.0"
WCS_CRS        <- "EPSG:31370"  # matches gent.R's CRS_LOCAL — no reprojection needed
WCS_FORMAT     <- "GEOTIFF"
# The service is ArcGIS Server behind the WCS facade and publishes no
# MaxWidth/MaxHeight in its capabilities. Probed: 2500 and 3000 px square
# return 200, 3500 and above return an ArcGIS "Error occurred while processing
# request" HTML page with status 400. 2500 keeps a real margin under that.
WCS_MAX_PIXELS <- 2500L
# metres/pixel. Native is 0.4 m; 0.5 matches the Dutch and Portuguese CIR
# downloaders, which is what CIR_VEG_NDVI_THRESHOLD and CIR_VEG_RENDER_THRESHOLD
# in config.R were set against. Cross-city comparability of veg_fraction is the
# reason to hold this at 0.5 even though Gent's AOI is large.
#
# KNOW WHAT THIS COSTS on a whole-municipality AOI. Gent's relation is
# ~19 x 24 km (Kanaalzone and rural deelgemeenten included), so its bbox at
# 0.5 m is 38188 x 46911 px = 304 tiles and a 7.2 GB uncompressed mosaic. The
# AOI mask below drops the 128 tiles that touch neither the municipality nor its
# halo, leaving 176 to fetch (~3.3 GB of requests) — the dropped area still sits
# in the mosaic's extent, but as constant-NA blocks that DEFLATE flattens.
# The tile directory is only unlinked *after* the final writeRaster, so tiles
# and output coexist; expect ~4 GB peak. The per-tile loop resumes after an
# interruption, but a disk-full during the final write does not.
#
# If it still needs to come down, raising TARGET_GSD_M to 1.0 quarters
# everything and still leaves ~400 CIR pixels per 20 m hex — but Gent's
# veg_fraction would then be measured on 1 m pixels against Porto's and
# Amsterdam's 0.5 m, which biases it at vegetation edges. Note it anywhere the
# cities are compared. That does not help process_tile() either, which crops by
# halo extent and so does 4x the CIR work at 0.5 m as at 1.0 m regardless of
# how the raster was built.
TARGET_GSD_M   <- 0.5
# Refuse unexpectedly large AOIs before hitting the WCS. Counted after the AOI
# mask, so Gent's full municipality needs 176 rather than 304; 320 leaves room
# for a city whose bbox fills better than Gent's without blocking the intended
# run. Still a guard — a bad-AOI tripwire, not a claim that 320 tiles is cheap.
MAX_TILES      <- 320L

# Envelope of OMZNIR21VL, from its DescribeCoverage gml:boundedBy (EPSG:31370).
# This is a bounding box, not the true coverage footprint — it circumscribes
# Flanders and therefore also encloses Brussels, which the mosaic excludes.
FLANDERS_ENVELOPE <- c(xmin = 17000, ymin = 148000, xmax = 264000, ymax = 250000)

be_flanders_assert_coverage <- function(bbox_31370) {
  outside <- bbox_31370["xmin"] < FLANDERS_ENVELOPE["xmin"] ||
    bbox_31370["ymin"] < FLANDERS_ENVELOPE["ymin"] ||
    bbox_31370["xmax"] > FLANDERS_ENVELOPE["xmax"] ||
    bbox_31370["ymax"] > FLANDERS_ENVELOPE["ymax"]
  if (outside) {
    stop(sprintf(
      paste0(
        "AOI [%s] falls outside the OMZNIR21VL coverage envelope [%s]. ",
        "This coverage is Flanders only — Wallonia is served by SPW, not by ",
        "Digitaal Vlaanderen, and needs its own downloader. Drop this city's ",
        "country from CIR_DOWNLOADER_BY_COUNTRY in config.R, or restrict ",
        "BBOX_CITY to the Flemish part of the AOI."
      ),
      paste(round(unname(bbox_31370)), collapse = ", "),
      paste(unname(FLANDERS_ENVELOPE), collapse = ", ")
    ), call. = FALSE)
  }
  invisible(TRUE)
}

# Geometry a tile must touch to be worth fetching, or NULL to fetch the whole
# bbox. Gent's bbox is 442 km2 around a 158 km2 municipality (36% fill, because
# the relation sprawls diagonally out to the Kanaalzone), so over half the tiles
# in the grid hold nothing the pipeline ever reads.
#
# Buffered by halo_m, not taken raw: process_tile() crops CIR to each core
# tile's halo (config.R default 750 m) before extracting, so data is needed for
# a margin around the AOI, not just inside it. Dropping tiles that only the
# halo reaches would put NA into that margin instead of real NDVI.
#
# Returns NULL rather than erroring when `aoi` is missing, so sourcing this file
# without config.R loaded still fetches the full bbox as it always did.
be_flanders_aoi_mask <- function(margin_m = if (exists("halo_m")) halo_m else 750) {
  if (!exists("aoi")) return(NULL)
  geom <- tryCatch(
    st_union(st_transform(st_geometry(aoi), WCS_CRS)),
    error = function(e) NULL
  )
  if (is.null(geom) || length(geom) == 0L) return(NULL)
  st_buffer(geom, margin_m)
}

be_flanders_tile_bboxes <- function(bbox_31370, max_pixels = WCS_MAX_PIXELS, gsd = TARGET_GSD_M,
                                    keep_within = NULL) {
  # Snap the AOI outward onto the gsd grid, then cut it into tiles of exactly
  # `max_pixels` pixels (the last column/row may be shorter). Every tile then
  # has exactly `gsd` resolution and sits on one shared pixel grid, which is
  # what the VRT stitch below needs. Splitting the AOI into tiles of equal
  # *metric* width instead leaves them on an off-grid resolution derived from
  # the AOI width, where rounding to whole pixels can open sub-pixel seams.
  x_min <- floor(unname(bbox_31370["xmin"]) / gsd) * gsd
  y_min <- floor(unname(bbox_31370["ymin"]) / gsd) * gsd
  n_px_x <- as.integer(ceiling((unname(bbox_31370["xmax"]) - x_min) / gsd))
  n_px_y <- as.integer(ceiling((unname(bbox_31370["ymax"]) - y_min) / gsd))

  x_offsets <- seq(0L, n_px_x - 1L, by = max_pixels)
  y_offsets <- seq(0L, n_px_y - 1L, by = max_pixels)

  tiles <- list()
  ids <- character(0)
  k <- 1L
  for (ci in seq_along(x_offsets)) {
    for (ri in seq_along(y_offsets)) {
      ox <- x_offsets[ci]
      oy <- y_offsets[ri]
      w <- min(max_pixels, n_px_x - ox)
      h <- min(max_pixels, n_px_y - oy)
      tiles[[k]] <- c(
        xmin = x_min + ox * gsd, xmax = x_min + (ox + w) * gsd,
        ymin = y_min + oy * gsd, ymax = y_min + (oy + h) * gsd
      )
      # Named by grid position, not by fetch order, so the scratch file for a
      # given patch of ground keeps its name whatever else the selection below
      # drops. A sequential index would silently re-point resumed tiles at
      # different ground if the AOI or halo_m changed.
      ids[k] <- sprintf("c%02d_r%02d", ci, ri)
      k <- k + 1L
    }
  }
  names(tiles) <- ids
  message(sprintf(
    "Split into %d tile(s) (%d x %d) at %.2f m/px, each <= %d px",
    length(tiles), length(x_offsets), length(y_offsets), gsd, max_pixels
  ))

  if (!is.null(keep_within)) {
    tile_polys <- st_sfc(
      lapply(tiles, function(t) st_polygon(list(unname(cbind(
        c(t["xmin"], t["xmax"], t["xmax"], t["xmin"], t["xmin"]),
        c(t["ymin"], t["ymin"], t["ymax"], t["ymax"], t["ymin"])
      ))))),
      crs = WCS_CRS
    )
    keep <- lengths(st_intersects(tile_polys, keep_within)) > 0L
    if (!any(keep)) {
      stop(
        "No tile in the grid intersects the AOI. This should be impossible — ",
        "the grid is built from the AOI's own bbox — so treat it as a CRS or ",
        "geometry problem rather than raising MAX_TILES.",
        call. = FALSE
      )
    }
    message(sprintf(
      "  %d tile(s) do not touch the AOI (+halo) and are skipped; fetching %d.",
      sum(!keep), sum(keep)
    ))
    tiles <- tiles[keep]
  }
  tiles
}

be_flanders_fetch_tile <- function(tile_bbox, gsd = TARGET_GSD_M) {
  width_px  <- max(1L, round((tile_bbox["xmax"] - tile_bbox["xmin"]) / gsd))
  height_px <- max(1L, round((tile_bbox["ymax"] - tile_bbox["ymin"]) / gsd))

  req <- request(WCS_BASE_URL) |>
    req_url_query(
      SERVICE = "WCS",
      VERSION = WCS_VERSION,
      REQUEST = "GetCoverage",
      COVERAGE = WCS_COVERAGE,
      CRS = WCS_CRS,
      BBOX = paste(
        tile_bbox["xmin"], tile_bbox["ymin"],
        tile_bbox["xmax"], tile_bbox["ymax"],
        sep = ","
      ),
      WIDTH = width_px,
      HEIGHT = height_px,
      FORMAT = WCS_FORMAT
    ) |>
    # An oversized or malformed request comes back as a 400 with an HTML body,
    # which req_perform() would raise as an httr2 error before the
    # content-type check below could report what the server actually said.
    req_error(is_error = function(resp) FALSE)

  tmp_tif <- tempfile(fileext = ".tif")
  resp <- req_perform(req, path = tmp_tif)

  if (!grepl("^image/tiff", resp_content_type(resp))) {
    # ArcGIS Server answers bad requests with an HTML error page — check for
    # this explicitly rather than let a bogus "image" fail confusingly later
    # in terra::rast().
    stop(
      "Vlaanderen OMZ WCS did not return a TIFF (HTTP ", resp_status(resp),
      ", content type ", resp_content_type(resp), "). Response body: ",
      substr(paste(readLines(tmp_tif, warn = FALSE), collapse = " "), 1, 500),
      call. = FALSE
    )
  }

  r <- rast(tmp_tif)
  if (nlyr(r) < 2L) {
    stop(
      "Vlaanderen OMZ WCS returned ", nlyr(r),
      " band(s); need at least NIR and Red.",
      call. = FALSE
    )
  }
  # The WCS does embed a correct geotransform, but assign it explicitly from
  # the bbox we asked for anyway, so every tile lands on exactly the grid
  # be_flanders_tile_bboxes() computed and the VRT stitch has nothing to
  # reconcile.
  ext(r) <- ext(tile_bbox["xmin"], tile_bbox["xmax"], tile_bbox["ymin"], tile_bbox["ymax"])
  crs(r) <- WCS_CRS
  r
}

download_be_flanders_cir_ndvi <- function(bbox = BBOX_CITY,
                                          out_file = BE_FLANDERS_CIR_NDVI_FILE) {
  if (exists("CRS_LOCAL") && !identical(CRS_LOCAL, WCS_CRS)) {
    stop(
      "download_be_flanders_cir_ndvi.R is for Flemish cities (CRS_LOCAL ",
      WCS_CRS, "). Current city uses ", CRS_LOCAL, ".",
      call. = FALSE
    )
  }
  if (file.exists(out_file)) {
    message("Flanders CIR NDVI already exists: ", out_file)
    return(invisible(out_file))
  }
  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

  bbox_31370 <- st_bbox(bbox, crs = 4326) |> st_as_sfc() |> st_transform(WCS_CRS) |> st_bbox()
  be_flanders_assert_coverage(bbox_31370)

  aoi_mask <- be_flanders_aoi_mask()
  if (is.null(aoi_mask)) {
    message("No `aoi` in scope — fetching the full bbox without AOI tile skipping.")
  }
  tiles <- be_flanders_tile_bboxes(bbox_31370, keep_within = aoi_mask)
  if (length(tiles) > MAX_TILES) {
    stop(
      sprintf(
        "AOI would require %d tiles (cap %d) at %.2f m/px, roughly %.1f GB of ",
        length(tiles), MAX_TILES, TARGET_GSD_M,
        length(tiles) * WCS_MAX_PIXELS^2 * 3 / 1e9
      ),
      "downloads. Set BBOX_CITY in the city file to the area you actually ",
      "analyse (Porto does this), or raise TARGET_GSD_M / MAX_TILES.",
      call. = FALSE
    )
  }

  # NDVI is reduced to one band per tile *before* anything is stitched. The
  # obvious alternative — mosaic the 3-band CIR tiles, then compute NDVI on the
  # mosaic — materialises a full-size 3-band FLT4S intermediate, and terra
  # writes its intermediates as uncompressed, non-BigTIFF GeoTIFFs, so at city
  # scale that hits the 4 GB ceiling of a classic GeoTIFF regardless of free
  # disk. One band per tile plus a VRT stitch keeps peak use to a single tile
  # in memory and the compressed per-tile files on disk. Band 3 (Green) is
  # dropped here because NDVI reads only NIR and Red.
  #
  # Pixels outside the mosaic come back as 0 in every band, so NDVI there is
  # 0/0 = NaN and lands in the output as NA rather than as a spurious 0.
  tile_dir <- paste0(tools::file_path_sans_ext(out_file), "_tiles")
  grid_stamp <- paste(
    c(round(unname(bbox_31370), 3), TARGET_GSD_M, WCS_MAX_PIXELS, WCS_COVERAGE,
      # Which tiles were selected is part of the grid: a rerun with a different
      # AOI or halo_m keeps the same bbox and gsd but wants a different set, and
      # stitching the old set under the new selection would go unnoticed.
      length(tiles), paste(names(tiles), collapse = ",")),
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

  tile_files <- file.path(tile_dir, sprintf("ndvi_tile_%s.tif", names(tiles)))
  for (i in seq_along(tiles)) {
    if (file.exists(tile_files[i])) {
      message(sprintf("Tile %d/%d already fetched.", i, length(tiles)))
      next
    }
    message(sprintf("Fetching tile %d/%d...", i, length(tiles)))
    cir <- be_flanders_fetch_tile(tiles[[i]])
    ndvi_tile <- (cir[[1]] - cir[[2]]) / (cir[[1]] + cir[[2]])

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
  names(ndvi) <- "be_flanders_cir_ndvi_dn"

  writeRaster(
    ndvi, out_file, overwrite = TRUE, datatype = "FLT4S",
    gdal = c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256",
             "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")
  )
  unlink(tile_dir, recursive = TRUE)

  written <- rast(out_file)
  veg_share <- global(written, function(x) mean(x >= CIR_VEG_NDVI_THRESHOLD, na.rm = TRUE))[1, 1]
  na_share  <- global(written, function(x) mean(is.na(x)))[1, 1]

  message(sprintf(
    "Written: %s (%d x %d px at %.2fm, CRS %s)",
    out_file, ncol(written), nrow(written), TARGET_GSD_M, WCS_CRS
  ))
  message(sprintf(
    "  %.1f%% of pixels above CIR_VEG_NDVI_THRESHOLD (%.2f); %.1f%% nodata.",
    100 * veg_share, CIR_VEG_NDVI_THRESHOLD, 100 * na_share
  ))
  # A Brussels-Capital AOI passes the envelope check but sits in a hole in the
  # Flemish mosaic, which returns as nodata rather than as an error.
  #
  # Tiles skipped by the AOI mask also read as nodata here, so this share is no
  # longer a clean coverage signal: Gent runs at roughly 40% nodata purely from
  # the 128 skipped tiles. Judge a suspicious figure against the skip count
  # reported above before blaming coverage.
  if (isTRUE(na_share > 0.5)) {
    warning(
      "More than half of this AOI came back as nodata. Some of that is the ",
      "tiles the AOI mask skipped; the rest would be missing coverage — ",
      "OMZNIR21VL is Flanders only, and the Brussels-Capital Region is ",
      "excluded from the mosaic even though it lies inside the coverage ",
      "envelope.",
      call. = FALSE
    )
  }
  message(
    "SANITY CHECK before trusting this: plot(rast('", out_file, "')) and confirm ",
    "vegetated areas (Citadelpark, Bourgoyen-Ossemeersen, Gentbrugse Meersen) ",
    "show clearly higher values than the Handelsdok water and port rooftops."
  )
  invisible(out_file)
}

download_be_flanders_cir_ndvi()
