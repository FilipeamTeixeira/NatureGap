library(rstac)
library(terra)

download_worldcover <- function(bbox,
                                outdir = tempdir()) {

  dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

  items <-
    stac("https://planetarycomputer.microsoft.com/api/stac/v1") |>
    stac_search(
      collections = "esa-worldcover",
      bbox = unname(bbox)
    ) |>
    post_request() |>
    items_fetch() |>
    items_sign_planetary_computer()

  if (length(items$features) == 0)
    stop("No WorldCover tiles found.")

  files <- character()

  for (i in seq_along(items$features)) {

    href <- items$features[[i]]$assets$map$href

    outfile <- file.path(
      outdir,
      basename(sub("\\?.*$", "", href))
    )

    if (!file.exists(outfile)) {
      download.file(href, outfile, mode = "wb")
    }

    files <- c(files, outfile)
  }

  r <- if (length(files) == 1) {
    rast(files)
  } else {
    mosaic(sprc(lapply(files, rast)))
  }

  crop(r, ext(
    bbox["xmin"],
    bbox["xmax"],
    bbox["ymin"],
    bbox["ymax"]
  ))
}

wc <- download_worldcover(BBOX_CITY)

dir.create("data/raw/worldcover", recursive = TRUE, showWarnings = FALSE)

writeRaster(
  wc,
  "data/raw/worldcover/worldcover.tif",
  overwrite = TRUE
)
