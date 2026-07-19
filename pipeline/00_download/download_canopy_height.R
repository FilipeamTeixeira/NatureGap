# Meta / WRI 1 m Global Canopy Height Maps (2009–2020, mostly 2018–2020)
# Dataset: https://gee-community-catalog.org/projects/meta_trees/
# Retrieved via forestdata::fd_canopy_height(model = "meta"); requires aws.s3 for S3 tiles.

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(sf)
library(terra)
library(forestdata)

city_bbox_sf <- function(bbox) {
  st_as_sfc(
    st_bbox(
      c(
        xmin = unname(bbox["xmin"]),
        ymin = unname(bbox["ymin"]),
        xmax = unname(bbox["xmax"]),
        ymax = unname(bbox["ymax"])
      ),
      crs = 4326
    )
  ) |>
    st_sf()
}

download_canopy_height <- function(bbox = BBOX_CITY,
                                   out_file = CANOPY_HEIGHT_FILE) {
  if (file.exists(out_file)) {
    message("Canopy height already exists: ", out_file)
    return(invisible(out_file))
  }

  if (!requireNamespace("aws.s3", quietly = TRUE)) {
    stop(
      "Package 'aws.s3' is required for Meta canopy height tiles. ",
      "Install with install.packages('aws.s3').",
      call. = FALSE
    )
  }

  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

  aoi <- city_bbox_sf(bbox)

  message("Downloading Meta/WRI 1 m canopy height via forestdata...")
  chm <- fd_canopy_height(
    x = aoi,
    model = "meta",
    crop = TRUE,
    mask = FALSE,
    merge = TRUE,
    quiet = FALSE
  )

  if (inherits(chm, "SpatRasterCollection")) {
    chm <- mosaic(sprc(chm))
  }

  if (is.null(chm) || nlyr(chm) < 1L) {
    stop(
      "No Meta/WRI canopy height tiles intersect BBOX_CITY. ",
      "Check the city extent in config.R.",
      call. = FALSE
    )
  }

  chm <- project(chm, "EPSG:4326", method = "bilinear")
  chm <- crop(chm, ext(
    unname(bbox["xmin"]),
    unname(bbox["xmax"]),
    unname(bbox["ymin"]),
    unname(bbox["ymax"])
  ))
  names(chm) <- "canopy_height_m"

  writeRaster(chm, out_file, overwrite = TRUE, datatype = "FLT4S")

  message(sprintf(
    "Written: %s (%d × %d pixels at %.2fm)",
    out_file, nrow(chm), ncol(chm), mean(res(chm))
  ))
  invisible(out_file)
}

download_canopy_height()
