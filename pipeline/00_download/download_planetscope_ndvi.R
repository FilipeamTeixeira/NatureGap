# PlanetScope 8-band Surface Reflectance -> NDVI, via Planet's Data + Orders API.
# Requires an active Education & Research (E&R) account and API key.
# Docs: https://docs.planet.com/develop/apis/data/item-search/
#       https://docs.planet.com/develop/apis/orders/tools/
#
# NOTE — this consumes your E&R quota. Unlike the other 00_download/ scripts,
# this one is NOT wired into RASTER_INPUT_DOWNLOADERS by default. Add it to a
# city's RASTER_INPUT_DOWNLOADERS list yourself once you're ready to spend quota
# on that city.
#
# Setup:
#   1. Add PLANET_API_KEY=your_key_here to pipeline/.env.local (or repo root .env.local)
#   2. Get your key from https://account.planet.com -> Settings -> API Key

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(httr2)
library(terra)

PLANET_API_BASE   <- "https://api.planet.com"
PLANET_ITEM_TYPE  <- "PSScene"
PLANET_BUNDLE     <- "analytic_8b_sr_udm2"  # 8-band surface reflectance; needed for NIR + Red-Edge
PLANET_MAX_ITEMS  <- 4L                     # cap order size / quota use per city
PLANET_CLOUD_MAX  <- 0.10                   # max cloud_cover fraction (0-1)

planet_api_key <- function() {
  key <- Sys.getenv("PLANET_API_KEY", unset = "")
  if (!nzchar(key)) {
    stop(
      "PLANET_API_KEY is not set. Add it to your .env.local ",
      "(repo root or pipeline/ both work — see config.R's env_file search order), e.g.\n",
      "  PLANET_API_KEY=your_key_here",
      call. = FALSE
    )
  }
  key
}

bbox_geojson_polygon <- function(bbox) {
  xmin <- unname(bbox["xmin"]); xmax <- unname(bbox["xmax"])
  ymin <- unname(bbox["ymin"]); ymax <- unname(bbox["ymax"])
  list(
    type = "Polygon",
    coordinates = list(list(
      c(xmin, ymin), c(xmax, ymin), c(xmax, ymax), c(xmin, ymax), c(xmin, ymin)
    ))
  )
}

# ── 1. Search: find PSScene items covering the AOI ──────────────────────────
planet_search_items <- function(bbox = BBOX_CITY,
                                date_from = Sys.Date() - 180,
                                date_to   = Sys.Date(),
                                key = planet_api_key()) {
  geom <- bbox_geojson_polygon(bbox)

  body <- list(
    item_types = list(PLANET_ITEM_TYPE),
    geometry = geom,
    filter = list(
      type = "AndFilter",
      config = list(
        list(
          type = "DateRangeFilter",
          field_name = "acquired",
          config = list(
            gte = paste0(format(date_from, "%Y-%m-%d"), "T00:00:00Z"),
            lte = paste0(format(date_to,   "%Y-%m-%d"), "T23:59:59Z")
          )
        ),
        list(
          type = "RangeFilter",
          field_name = "cloud_cover",
          config = list(gte = 0, lte = PLANET_CLOUD_MAX)
        ),
        list(type = "AssetFilter", config = list("ortho_analytic_8b_sr")),
        list(type = "PermissionFilter", config = list("assets:download"))
      )
    )
  )

  resp <- request(paste0(PLANET_API_BASE, "/data/v1/quick-search")) |>
    req_auth_basic(key, "") |>
    req_body_json(body) |>
    req_perform()

  features <- resp_body_json(resp)$features
  if (length(features) == 0L) {
    stop(
      "No PlanetScope 8-band scenes found for this AOI/date range/cloud filter. ",
      "Try widening date_from or raising PLANET_CLOUD_MAX.",
      call. = FALSE
    )
  }

  ids <- vapply(features, function(f) f$id, character(1))
  clouds <- vapply(features, function(f) f$properties$cloud_cover %||% 1, double(1))

  # Take the least-cloudy scenes, capped to PLANET_MAX_ITEMS to limit quota use.
  ord <- order(clouds)
  ids[ord][seq_len(min(PLANET_MAX_ITEMS, length(ids)))]
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# ── 2. Order: clip + composite + harmonize via the Orders API ───────────────
planet_place_order <- function(item_ids, bbox = BBOX_CITY, key = planet_api_key()) {
  geom <- bbox_geojson_polygon(bbox)

  body <- list(
    name = paste0("naturegap_", CITY_ID, "_", format(Sys.Date(), "%Y%m%d")),
    products = list(list(
      item_ids = as.list(item_ids),
      item_type = PLANET_ITEM_TYPE,
      product_bundle = PLANET_BUNDLE
    )),
    # Tools are executed sequentially. Clip first to save compute!
    tools = list(
      list(clip = list(aoi = geom)),
      list(harmonize = list(target_sensor = "Sentinel-2")),
      # setNames forces {} instead of [] in JSON serialization
      list(composite = setNames(list(), character(0)))
    )
  )

  resp <- request(paste0(PLANET_API_BASE, "/compute/ops/orders/v2")) |>
    req_auth_basic(key, "") |>
    req_body_json(body) |>
    req_perform()

  resp_body_json(resp)$id
}

# ── 3. Poll until the order is ready, then return download URLs ─────────────
planet_wait_for_order <- function(order_id, key = planet_api_key(),
                                  poll_every = 15, timeout = 1800) {
  url <- paste0(PLANET_API_BASE, "/compute/ops/orders/v2/", order_id)
  waited <- 0

  repeat {
    resp <- request(url) |>
      req_headers(Authorization = paste("api-key", key)) |>
      req_perform()
    order <- resp_body_json(resp)
    state <- order$state

    if (state %in% c("success", "partial")) {
      if (state == "partial") {
        message("Order completed with state 'partial' — some items may be missing.")
      }
      results <- order$`_links`$results

      locations <- vapply(results, function(r) r$location, character(1))
      names(locations) <- vapply(results, function(r) r$name, character(1))
      return(locations)
    }
    if (state %in% c("failed", "cancelled")) {
      stop("Planet order ", order_id, " ended with state: ", state, call. = FALSE)
    }

    message(sprintf("Order %s: %s (waited %ds)...", order_id, state, waited))
    Sys.sleep(poll_every)
    waited <- waited + poll_every
    if (waited > timeout) {
      stop("Timed out waiting for Planet order ", order_id, call. = FALSE)
    }
  }
}

# ── 4. Download the clipped/composited tif, compute NDVI ────────────────────
download_planetscope_ndvi <- function(bbox = BBOX_CITY,
                                      out_file = PLANET_NDVI_FILE) {
  if (file.exists(out_file)) {
    message("PlanetScope NDVI already exists: ", out_file)
    return(invisible(out_file))
  }

  dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)
  key <- planet_api_key()

  message("Searching PlanetScope 8-band scenes...")
  item_ids <- planet_search_items(bbox = bbox, key = key)
  message(sprintf("Ordering %d scene(s): %s", length(item_ids), paste(item_ids, collapse = ", ")))

  order_id <- planet_place_order(item_ids, bbox = bbox, key = key)
  message("Order placed: ", order_id, " — polling for completion (this can take several minutes)...")

  urls <- planet_wait_for_order(order_id, key = key)

  # Pick the analytic image (skip udm2 / xml / metadata json sidecars)
  # tif_url <- urls[grepl("_SR_8b(_harmonized)?_clip\\.tif$|AnalyticMS_SR.*\\.tif$", urls)]
  # if (length(tif_url) == 0L) tif_url <- urls[grepl("\\.tif$", urls)]
  # tif_url <- tif_url[1]

  tif_url <- urls[grepl("\\.tif$", names(urls))]
  tif_url <- tif_url[1]

  tmp_tif <- tempfile(fileext = ".tif")
  message("Downloading: ", tif_url)
  request(tif_url) |> req_perform(path = tmp_tif)

  img <- rast(tmp_tif)
  # analytic_8b_sr band order: 1 CoastalBlue, 2 Blue, 3 GreenI, 4 Green,
  # 5 Yellow, 6 Red, 7 RedEdge, 8 NIR — verify against img metadata if in doubt.
  red <- img[[6]]
  nir <- img[[8]]

  ndvi <- (nir - red) / (nir + red)
  names(ndvi) <- "planet_ndvi"

  ndvi <- project(ndvi, "EPSG:4326", method = "bilinear")
  ndvi <- crop(ndvi, ext(
    unname(bbox["xmin"]), unname(bbox["xmax"]),
    unname(bbox["ymin"]), unname(bbox["ymax"])
  ))

  writeRaster(
    ndvi, out_file, overwrite = TRUE, datatype = "FLT4S",
    gdal = c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256", "COMPRESS=DEFLATE")
  )
  unlink(tmp_tif)

  message(sprintf(
    "Written: %s (%d x %d pixels at ~3m native)",
    out_file, nrow(ndvi), ncol(ndvi)
  ))
  invisible(out_file)
}

download_planetscope_ndvi()
