

library(openeo)

con <- connect("https://openeo.dataspace.copernicus.eu")
login()   # opens browser for OAuth2

p <- processes()

cube <- p$load_collection(
  id = "SENTINEL2_L2A",
  spatial_extent = list(west=BBOX_CITY[1], south=BBOX_CITY[2], east=BBOX_CITY[3], north=BBOX_CITY[4]),
  temporal_extent = list("2023-04-01", "2023-09-30"),
  bands = list("B04", "B08")
)

# 1. Include SCL in the initial load
cube <- p$load_collection(
  id = "SENTINEL2_L2A",
  spatial_extent = list(west = BBOX_CITY[1], south = BBOX_CITY[2],
                        east = BBOX_CITY[3], north = BBOX_CITY[4]),
  temporal_extent = list("2023-04-01", "2023-09-30"),
  bands = list("B04", "B08", "SCL")
)

# 2. Collapse the bands dimension to a single boolean mask layer
# Keep: 4 = vegetation, 5 = bare soil, 6 = water
# Mask: 0-3 (saturated/dark/shadow), 7-11 (unclassified/cloud/cirrus/snow)
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

# 3. Drop SCL from the spectral cube before masking
cube_b <- p$filter_bands(cube, bands = list("B04", "B08"))

# 4. Apply -- pixels where mask = TRUE become NA
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
# Reduce time → median composite
ndvi_composite <- p$reduce_dimension(
  ndvi,
  reducer = function(x, ctx) p$median(x),
  dimension = "t"
)

compute_result(
  ndvi_composite,
  format = "GTiff",
  output_file = "data/raw/sentinel2/ndvi_median.tif"
)
