# Shared AOI helpers — sourced by city config files (config_porto.R, etc.)

ring_to_geojson_coords <- function(ring) {
  lapply(seq_len(nrow(ring)), function(i) as.numeric(ring[i, ]))
}

nominatim_geojson_to_sf <- function(geojson_df) {
  coords <- geojson_df$coordinates[[1L]]
  if (geojson_df$type[[1L]] == "Polygon") {
    ring <- coords[1L, , , drop = TRUE]
    geometry <- list(type = "Polygon", coordinates = list(ring_to_geojson_coords(ring)))
  } else if (geojson_df$type[[1L]] == "MultiPolygon") {
    polys <- lapply(seq_len(dim(coords)[1L]), function(i) {
      list(ring_to_geojson_coords(coords[i, , , drop = TRUE]))
    })
    geometry <- list(type = "MultiPolygon", coordinates = polys)
  } else {
    stop("Unsupported Nominatim geometry type: ", geojson_df$type[[1L]], call. = FALSE)
  }

  fc <- list(
    type = "FeatureCollection",
    features = list(list(type = "Feature", properties = list(), geometry = geometry))
  )
  sf::st_read(jsonlite::toJSON(fc, auto_unbox = TRUE), quiet = TRUE)
}

fetch_relation_boundary <- function(relation_id, cache_path, city) {
  if (file.exists(cache_path)) {
    message("[config] Using cached boundary: ", cache_path)
    return(sf::st_read(cache_path, quiet = TRUE))
  }

  url <- sprintf(
    "https://nominatim.openstreetmap.org/lookup?osm_ids=R%s&polygon_geojson=1&format=json",
    relation_id
  )
  message("[config] Fetching boundary from Nominatim (relation ", relation_id, ")")
  resp <- tryCatch(
    jsonlite::fromJSON(url),
    error = function(err) {
      stop("Nominatim lookup failed for relation ", relation_id, ": ", conditionMessage(err), call. = FALSE)
    }
  )

  if (length(resp) == 0L || !"geojson" %in% names(resp)) {
    stop("Nominatim returned no polygon for relation ", relation_id, call. = FALSE)
  }

  aoi_sf <- nominatim_geojson_to_sf(resp$geojson)
  aoi_sf$city <- city
  sf::st_write(aoi_sf, cache_path, delete_dsn = TRUE, quiet = TRUE)
  message("[config] Cached boundary: ", cache_path)
  sf::st_read(cache_path, quiet = TRUE)
}

bbox_to_aoi <- function(bbox, city) {
  sf::st_as_sfc(
    sf::st_bbox(
      c(
        xmin = unname(bbox["xmin"]),
        ymin = unname(bbox["ymin"]),
        xmax = unname(bbox["xmax"]),
        ymax = unname(bbox["ymax"])
      ),
      crs = 4326
    )
  ) |>
    sf::st_sf(city = city)
}

load_city_aoi <- function(city, aoi_mode, boundaries_dir, relation_id = NULL, bbox = NULL) {
  mode <- match.arg(aoi_mode, c("relation", "bbox"))
  cache_path <- file.path(boundaries_dir, paste0(city, ".geojson"))

  if (mode == "relation") {
    if (is.null(relation_id)) {
      stop("relation_id must be set when aoi_mode == 'relation'", call. = FALSE)
    }
    fetch_relation_boundary(relation_id, cache_path, city)
  } else {
    if (is.null(bbox)) {
      stop("bbox must be set when aoi_mode == 'bbox'", call. = FALSE)
    }
    bbox_to_aoi(bbox, city)
  }
}

CONFIG_AOI_HELPERS_LOADED <- TRUE
