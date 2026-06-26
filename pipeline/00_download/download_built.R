if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(sf)
library(terra)

download_emc_built <- function(bbox = BBOX_CITY,
                               res = 100,
                               out_file = EMC_FILE,
                               as_fraction = TRUE) {
  if (file.exists(out_file)) {
    message("EMC-BUILT already exists: ", out_file)
    return(invisible(out_file))
  }

  outdir <- dirname(out_file)
  dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

  dataset_dir <- sprintf("EMC_BUILT_S_E2022_GLOBE_R2025A_54009_%d", res)
  dataset_root <- paste0(
    "https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/",
    "EMC_BUILT_GLOBE_R2025A/", dataset_dir, "/V1-0/"
  )

  bbox_sf <- st_as_sfc(
    st_bbox(setNames(bbox, c("xmin", "ymin", "xmax", "ymax")), crs = 4326)
  )
  bbox_mol <- st_bbox(st_transform(bbox_sf, "ESRI:54009"))

  if (res == 1000) {
    zip_name <- sprintf("%s_V1_0.zip", dataset_dir)
    zip_path <- file.path(outdir, zip_name)
    if (!file.exists(zip_path)) {
      download.file(paste0(dataset_root, zip_name), zip_path, mode = "wb")
      unzip(zip_path, exdir = outdir)
    }
    tif <- list.files(outdir, pattern = paste0(dataset_dir, ".*\\.tif$"),
                      full.names = TRUE)[1]
  } else {
    x_origin  <- -18040096
    y_origin  <- 9020048
    tile_size <- 1000000

    col_min <- floor((bbox_mol["xmin"] - x_origin) / tile_size) + 1L
    col_max <- floor((bbox_mol["xmax"] - x_origin) / tile_size) + 1L
    row_min <- floor((y_origin - bbox_mol["ymax"]) / tile_size) + 1L
    row_max <- floor((y_origin - bbox_mol["ymin"]) / tile_size) + 1L

    tiles <- expand.grid(row = seq(row_min, row_max),
                         col = seq(col_min, col_max))
    message(nrow(tiles), " tile(s) - rows ", row_min, "-", row_max,
            ", cols ", col_min, "-", col_max)

    raster_files <- character()
    for (i in seq_len(nrow(tiles))) {
      tile_name <- sprintf("%s_V1_0_R%d_C%d",
                           dataset_dir, tiles$row[i], tiles$col[i])
      zip_path <- file.path(outdir, paste0(tile_name, ".zip"))
      tif_path <- file.path(outdir, paste0(tile_name, ".tif"))

      if (!file.exists(tif_path)) {
        url <- paste0(dataset_root, "tiles/", tile_name, ".zip")
        message("Downloading: ", basename(url))
        tryCatch(
          download.file(url, zip_path, mode = "wb"),
          error = function(e) message("Tile not found: ", basename(url))
        )
        if (file.exists(zip_path)) {
          unzip(zip_path, exdir = outdir)
          file.remove(zip_path)
        }
      }
      if (file.exists(tif_path)) raster_files <- c(raster_files, tif_path)
    }
    tif <- raster_files
  }

  if (length(tif) == 0L || anyNA(tif)) {
    stop("No EMC-BUILT raster tiles were downloaded.")
  }

  r <- if (length(tif) > 1L) mosaic(sprc(lapply(tif, rast))) else rast(tif)
  r_crop <- crop(r, ext(bbox_mol[c("xmin", "xmax", "ymin", "ymax")]))

  if (as_fraction) {
    cell_area_m2 <- res^2
    r_crop <- r_crop / cell_area_m2
    r_crop[r_crop > 1] <- NA
    names(r_crop) <- "imperv_fraction"
  }

  writeRaster(r_crop, out_file, overwrite = TRUE)
  message("Written: ", out_file)
  invisible(out_file)
}

download_emc_built()
