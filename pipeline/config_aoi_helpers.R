# Shared AOI helpers — sourced by config.R once a city file has been loaded.

ring_to_geojson_coords <- function(ring) {
  lapply(seq_len(nrow(ring)), function(i) as.numeric(ring[i, ]))
}

nominatim_geojson_to_sf <- function(geojson_df) {
  # geojson_df may contain one row (single relation) or several (multiple
  # relations looked up in one request) — convert every row, not just the
  # first, and return them all as separate features. The caller unions them
  # into a single AOI polygon.
  features <- lapply(seq_len(nrow(geojson_df)), function(i) {
    coords <- geojson_df$coordinates[[i]]
    geom_type <- geojson_df$type[[i]]
    if (geom_type == "Polygon") {
      ring <- coords[1L, , , drop = TRUE]
      geometry <- list(type = "Polygon", coordinates = list(ring_to_geojson_coords(ring)))
    } else if (geom_type == "MultiPolygon") {
      polys <- lapply(seq_len(dim(coords)[1L]), function(j) {
        list(ring_to_geojson_coords(coords[j, , , drop = TRUE]))
      })
      geometry <- list(type = "MultiPolygon", coordinates = polys)
    } else {
      stop("Unsupported Nominatim geometry type: ", geom_type, call. = FALSE)
    }
    list(type = "Feature", properties = list(), geometry = geometry)
  })

  fc <- list(type = "FeatureCollection", features = features)
  sf::st_read(jsonlite::toJSON(fc, auto_unbox = TRUE), quiet = TRUE)
}

fetch_relation_boundary_local <- function(relation_id, regional_pbf) {
  if (!nzchar(Sys.which("osmium"))) return(NULL)
  if (is.null(regional_pbf) || !file.exists(regional_pbf)) return(NULL)

  extract_pbf <- tempfile(fileext = ".osm.pbf")
  export_geojson <- tempfile(fileext = ".geojson")
  on.exit(unlink(c(extract_pbf, export_geojson)), add = TRUE)

  ids <- paste0("r", relation_id)
  status_extract <- suppressWarnings(system2(
    "osmium",
    c("getid", "-r", shQuote(regional_pbf), ids, "-o", shQuote(extract_pbf)),
    stdout = TRUE, stderr = TRUE
  ))
  if (!is.null(attr(status_extract, "status")) && attr(status_extract, "status") != 0L) {
    message("[config] osmium getid failed, falling back to Nominatim: ",
            paste(status_extract, collapse = " "))
    return(NULL)
  }
  if (!file.exists(extract_pbf) || file.info(extract_pbf)$size == 0L) return(NULL)

  status_export <- suppressWarnings(system2(
    "osmium",
    c("export", shQuote(extract_pbf), "-o", shQuote(export_geojson),
      "-f", "geojson", "--geometry-types=polygon"),
    stdout = TRUE, stderr = TRUE
  ))
  if (!is.null(attr(status_export, "status")) && attr(status_export, "status") != 0L) {
    message("[config] osmium export failed, falling back to Nominatim: ",
            paste(status_export, collapse = " "))
    return(NULL)
  }
  if (!file.exists(export_geojson) || file.info(export_geojson)$size == 0L) return(NULL)

  boundary <- tryCatch(sf::st_read(export_geojson, quiet = TRUE), error = function(e) NULL)
  if (is.null(boundary) || nrow(boundary) == 0L) return(NULL)

  boundary <- boundary[sf::st_geometry_type(boundary) %in% c("POLYGON", "MULTIPOLYGON"), ]
  if (nrow(boundary) == 0L) return(NULL)

  boundary
}

fetch_relation_boundary <- function(relation_id, cache_path, city, regional_pbf = NULL) {
  if (file.exists(cache_path)) {
    message("[config] Using cached boundary: ", cache_path)
    return(sf::st_read(cache_path, quiet = TRUE))
  }

  message(sprintf(
    "[config] Looking up boundary for relation%s %s...",
    if (length(relation_id) > 1L) "s" else "", paste(relation_id, collapse = ", ")
  ))

  local_result <- fetch_relation_boundary_local(relation_id, regional_pbf)
  if (!is.null(local_result)) {
    message("[config] Boundary extracted locally from ", regional_pbf, " via osmium — no network request made.")
    geom <- sf::st_union(sf::st_make_valid(sf::st_geometry(local_result)))
    aoi_sf <- sf::st_sf(city = city, geometry = geom)
    sf::st_write(aoi_sf, cache_path, delete_dsn = TRUE, quiet = TRUE)
    message("[config] Cached boundary: ", cache_path)
    return(sf::st_read(cache_path, quiet = TRUE))
  }

  message("[config] Local extraction unavailable or found nothing usable — falling back to Nominatim.")

  # relation_id may be a single ID or a vector of several adjacent relations
  # to combine into one AOI. sprintf() is vectorized, so building the URL
  # directly from a multi-element relation_id previously produced one URL
  # per relation instead of one request for all of them — Nominatim's
  # lookup endpoint natively supports a comma-separated osm_ids list
  # (up to 50 at once), so join them into a single request instead.
  osm_ids <- paste0("R", relation_id, collapse = ",")
  url <- sprintf(
    "https://nominatim.openstreetmap.org/lookup?osm_ids=%s&polygon_geojson=1&format=json",
    osm_ids
  )
  message(sprintf(
    "[config] Fetching boundary from Nominatim (relation%s %s)",
    if (length(relation_id) > 1L) "s" else "",
    paste(relation_id, collapse = ", ")
  ))
  resp <- tryCatch(
    jsonlite::fromJSON(url),
    error = function(err) {
      stop("Nominatim lookup failed for relation(s) ", paste(relation_id, collapse = ", "),
           ": ", conditionMessage(err), call. = FALSE)
    }
  )

  if (length(resp) == 0L || !"geojson" %in% names(resp)) {
    stop("Nominatim returned no polygon for relation(s) ", paste(relation_id, collapse = ", "), call. = FALSE)
  }
  if (nrow(resp) < length(relation_id)) {
    warning(sprintf(
      "[config] Requested %d relation(s) but Nominatim only returned %d — some IDs may be invalid or not found. Continuing with what was returned.",
      length(relation_id), nrow(resp)
    ), call. = FALSE)
  }

  aoi_sf <- nominatim_geojson_to_sf(resp$geojson)
  # Multiple relations come back as separate rows — union into one AOI so
  # the rest of the pipeline (which expects a single combined study area)
  # sees one geometry, not several disconnected ones.
  if (nrow(aoi_sf) > 1L) {
    aoi_sf <- sf::st_sf(
      city = city,
      geometry = sf::st_union(sf::st_make_valid(sf::st_geometry(aoi_sf)))
    )
  } else {
    aoi_sf$city <- city
  }
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
