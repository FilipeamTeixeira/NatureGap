
library(rstac)
library(terra)

# Planetary Computer STAC endpoint
stac_src <- stac("https://planetarycomputer.microsoft.com/api/stac/v1")

# Search Landsat C2 L2 scenes
items <- stac_src |>
  stac_search(
    collections = "landsat-c2-l2",
    bbox        = BBOX_CITY,
    datetime    = "2023-06-01/2023-09-30"
  ) |>
  ext_filter(
    `eo:cloud_cover` <= 10 &&
      platform %in% c("landsat-8", "landsat-9")
  ) |>
  post_request() |>
  items_fetch()

# Sign assets (required for Planetary Computer)
items <- items_sign(items, sign_planetary_computer())

# Get the surface temperature band URL (lwir11 = ST_B10, in DN)
st_urls <- assets_url(items, asset_names = "lwir11")

# Download and convert to Kelvin
# Scale factor: DN * 0.00341802 + 149.0
r <- rast(st_urls[1])
st_kelvin <- r * 0.00341802 + 149.0
st_celsius <- st_kelvin - 273.15

writeRaster(st_celsius, paste0("data/to_import/landsat/LST_",CITY_ID,".tif"), overwrite = TRUE)
