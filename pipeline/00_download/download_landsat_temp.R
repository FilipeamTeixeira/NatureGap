if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(rstac)
library(terra)

download_landsat_temp <- function(bbox = BBOX_CITY,
                                  out_file = LST_FILE) {
  if (file.exists(out_file)) {
    message("Landsat LST already exists: ", out_file)
    return(invisible(out_file))
  }

  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

  items <- stac("https://planetarycomputer.microsoft.com/api/stac/v1") |>
    stac_search(
      collections = "landsat-c2-l2",
      bbox = unname(bbox),
      datetime = "2023-06-01/2023-09-30"
    ) |>
    ext_filter(
      `eo:cloud_cover` <= 10 &&
        platform %in% c("landsat-8", "landsat-9")
    ) |>
    post_request() |>
    items_fetch()

  if (length(items$features) == 0L) {
    stop("No Landsat C2 L2 scenes found.")
  }

  items <- items_sign(items, sign_planetary_computer())
  st_urls <- assets_url(items, asset_names = "lwir11")

  if (length(st_urls) == 0L || is.na(st_urls[1])) {
    stop("No Landsat lwir11/ST_B10 asset found.")
  }

  r <- rast(st_urls[1])
  st_kelvin <- r * LST_DN_SCALE + LST_DN_OFFSET
  st_celsius <- st_kelvin - 273.15
  names(st_celsius) <- "lst_celsius"

  writeRaster(st_celsius, out_file, overwrite = TRUE)
  message("Written: ", out_file)
  invisible(out_file)
}

download_landsat_temp()
