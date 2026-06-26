if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(openeo)

download_sentinel2_ndvi <- function(bbox = BBOX_CITY,
                                    out_file = S2_NDVI_FILE) {
  if (file.exists(out_file)) {
    message("Sentinel-2 NDVI already exists: ", out_file)
    return(invisible(out_file))
  }

  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

  con <- connect("https://openeo.dataspace.copernicus.eu")
  login()

  p <- processes()

  cube <- p$load_collection(
    id = "SENTINEL2_L2A",
    spatial_extent = list(
      west = unname(bbox["xmin"]),
      south = unname(bbox["ymin"]),
      east = unname(bbox["xmax"]),
      north = unname(bbox["ymax"])
    ),
    temporal_extent = list("2023-04-01", "2023-09-30"),
    bands = list("B04", "B08", "SCL")
  )

  cloud_mask <- p$reduce_dimension(
    data = cube,
    reducer = function(data, context) {
      scl <- p$array_element(data, label = "SCL")
      p$or(
        p$lte(scl, 3L),
        p$gte(scl, 7L)
      )
    },
    dimension = "bands"
  )

  cube_b <- p$filter_bands(cube, bands = list("B04", "B08"))
  cube_masked <- p$mask(cube_b, mask = cloud_mask)

  ndvi <- p$reduce_dimension(
    data = cube_masked,
    reducer = function(data, context) {
      b08 <- p$array_element(data, label = "B08")
      b04 <- p$array_element(data, label = "B04")
      p$normalized_difference(x = b08, y = b04)
    },
    dimension = "bands"
  )

  ndvi_composite <- p$reduce_dimension(
    ndvi,
    reducer = function(x, ctx) p$median(x),
    dimension = "t"
  )

  compute_result(
    ndvi_composite,
    format = "GTiff",
    output_file = out_file
  )

  message("Written: ", out_file)
  invisible(out_file)
}

download_sentinel2_ndvi()
