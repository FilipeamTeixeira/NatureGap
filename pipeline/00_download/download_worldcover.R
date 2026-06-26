if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(rstac)
library(terra)

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

  files <- character()
  for (i in seq_along(items$features)) {
    href <- items$features[[i]]$assets$map$href
    outfile <- file.path(outdir, basename(sub("\\?.*$", "", href)))

    if (!file.exists(outfile)) {
      download.file(href, outfile, mode = "wb")
    }

    files <- c(files, outfile)
  }

  r <- if (length(files) == 1L) {
    rast(files)
  } else {
    mosaic(sprc(lapply(files, rast)))
  }

  wc <- crop(r, ext(
    bbox["xmin"],
    bbox["xmax"],
    bbox["ymin"],
    bbox["ymax"]
  ))

  writeRaster(wc, out_file, overwrite = TRUE)
  message("Written: ", out_file)
  invisible(out_file)
}

download_worldcover()
