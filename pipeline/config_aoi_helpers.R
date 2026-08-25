# Shared AOI helpers — sourced by config.R once a city file has been loaded.

# The set of relation IDs an AOI was built from, normalised so that reordering
# or duplicating IDs in a city file does not read as a different AOI. Stored in
# the cached boundary so a stale cache is detected instead of silently reused.
relation_ids_key <- function(relation_id) {
  ids <- suppressWarnings(as.integer(relation_id))
  ids <- sort(unique(ids[!is.na(ids)]))
  paste(ids, collapse = ",")
}

log_aoi_source <- function(aoi_sf, source_desc) {
  area_km2 <- tryCatch(
    sum(as.numeric(sf::st_area(sf::st_geometry(aoi_sf)))) / 1e6,
    error = function(e) NA_real_
  )
  bb <- sf::st_bbox(sf::st_transform(aoi_sf, 4326))
  message(sprintf(
    "[config] AOI from %s | area %.1f km2 | bbox %.4f %.4f %.4f %.4f",
    source_desc, area_km2,
    bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]]
  ))
  invisible(aoi_sf)
}

log_aoi_extent <- function(aoi_sf, relation_id) {
  log_aoi_source(aoi_sf, sprintf(
    "%d relation(s) [%s]",
    length(unique(relation_id)), paste(relation_id, collapse = ", ")
  ))
}

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
      "-f", "geojson", "--geometry-types=polygon", "--add-unique-id=type_id"),
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

  # "osmium getid -r" also pulls in the relations' members, so the export can
  # contain tagged member polygons that are not part of the boundary. Keep only
  # the requested relations: osmium's unique id is the libosmium *area* id,
  # which for an area built from a relation is 2 * relation_id + 1 (ways use
  # 2 * way_id), prefixed with the object type.
  id_col <- intersect(c("id", "@id", "unique_id"), names(boundary))
  if (length(id_col) >= 1L) {
    # as.numeric() and %.0f, not 2L * id: integer overflow would silently NA
    # out relation IDs above ~1.07e9, and format() would use scientific notation.
    area_ids <- sprintf("a%.0f", 2 * as.numeric(relation_id) + 1)
    wanted <- c(sprintf("r%.0f", as.numeric(relation_id)), area_ids)
    keep <- as.character(boundary[[id_col[1L]]]) %in% wanted
    if (any(keep)) {
      if (!all(keep)) {
        message(sprintf(
          "[config] osmium export returned %d polygon(s); keeping the %d belonging to the requested relation(s).",
          nrow(boundary), sum(keep)
        ))
      }
      boundary <- boundary[keep, ]
    } else {
      warning("[config] Could not match any exported polygon to the requested relation IDs -- using every exported polygon, which may widen the AOI.", call. = FALSE)
    }
  }
  if (nrow(boundary) == 0L) return(NULL)

  if (nrow(boundary) < length(unique(relation_id))) {
    warning(sprintf(
      "[config] Requested %d relation(s) but the local extract yielded %d polygon(s) -- the regional PBF may predate some relations.",
      length(unique(relation_id)), nrow(boundary)
    ), call. = FALSE)
  }

  boundary
}

fetch_relation_boundary <- function(relation_id, cache_path, city, regional_pbf = NULL) {
  wanted_key <- relation_ids_key(relation_id)

  # The cache is keyed on <city>.geojson, which says nothing about which
  # relations produced it -- editing relation_id in a city file used to leave a
  # stale boundary in place and be silently ignored. Record the relation IDs in
  # the cached file and refetch whenever they no longer match. A cache written
  # before this field existed has no recorded IDs and is therefore refetched.
  if (file.exists(cache_path)) {
    cached <- tryCatch(sf::st_read(cache_path, quiet = TRUE), error = function(e) NULL)
    cached_key <- if (!is.null(cached) && "relation_ids" %in% names(cached) &&
                      nrow(cached) > 0L && !is.na(cached$relation_ids[[1L]])) {
      relation_ids_key(strsplit(as.character(cached$relation_ids[[1L]]), ",")[[1L]])
    } else {
      NA_character_
    }

    if (!is.null(cached) && identical(cached_key, wanted_key)) {
      message("[config] Using cached boundary: ", cache_path, " (relations ", wanted_key, ")")
      return(cached)
    }

    message(sprintf(
      "[config] Cached boundary %s was built from %s but relations %s are requested -- refetching.",
      cache_path,
      if (is.na(cached_key)) "an unrecorded set of relations" else paste0("relations ", cached_key),
      wanted_key
    ))
  }

  message(sprintf(
    "[config] Looking up boundary for relation%s %s...",
    if (length(relation_id) > 1L) "s" else "", paste(relation_id, collapse = ", ")
  ))

  local_result <- fetch_relation_boundary_local(relation_id, regional_pbf)
  if (!is.null(local_result)) {
    message("[config] Boundary extracted locally from ", regional_pbf, " via osmium — no network request made.")
    geom <- sf::st_union(sf::st_make_valid(sf::st_geometry(local_result)))
    aoi_sf <- sf::st_sf(city = city, relation_ids = wanted_key, geometry = geom)
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
      relation_ids = wanted_key,
      geometry = sf::st_union(sf::st_make_valid(sf::st_geometry(aoi_sf)))
    )
  } else {
    aoi_sf$city <- city
    aoi_sf$relation_ids <- wanted_key
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

# AOI read from a file the user supplies — a shapefile, GeoPackage, GeoJSON, or
# anything else GDAL can open. Use this when the OSM relation is a poor study
# area (Gent's municipality reaches far out into the Kanaalzone and the rural
# deelgemeenten) and a bbox is too crude. Nothing is cached: the file on disk is
# the source of truth, so editing it and rerunning picks the new shape up.
file_to_aoi <- function(aoi_file, city, layer = NULL, pipeline_root = NULL) {
  path <- path.expand(aoi_file)
  if (!is.null(pipeline_root) && !startsWith(path, "/")) {
    path <- file.path(pipeline_root, aoi_file)
  }
  if (!file.exists(path)) {
    stop(sprintf("aoi_file not found: %s", path), call. = FALSE)
  }
  # A .shp alone is not readable — the sidecars carry the attributes, the index
  # and, critically, the CRS. Say which one is missing rather than letting GDAL
  # fail with a less obvious message.
  if (grepl("\\.shp$", path, ignore.case = TRUE)) {
    sidecars <- paste0(sub("\\.shp$", "", path, ignore.case = TRUE), c(".dbf", ".shx"))
    missing <- sidecars[!file.exists(sidecars)]
    if (length(missing)) {
      stop(sprintf("Shapefile %s is missing its sidecar file(s): %s",
                   path, paste(basename(missing), collapse = ", ")), call. = FALSE)
    }
  }

  shape <- if (is.null(layer)) {
    sf::st_read(path, quiet = TRUE)
  } else {
    sf::st_read(path, layer = layer, quiet = TRUE)
  }
  if (nrow(shape) == 0L) {
    stop("aoi_file contains no features: ", path, call. = FALSE)
  }

  polygons <- shape[sf::st_geometry_type(shape) %in% c("POLYGON", "MULTIPOLYGON"), ]
  if (nrow(polygons) == 0L) {
    stop(sprintf("aoi_file holds no polygons (found %s): %s",
                 paste(unique(as.character(sf::st_geometry_type(shape))), collapse = ", "),
                 path), call. = FALSE)
  }
  if (nrow(polygons) < nrow(shape)) {
    message(sprintf("[config] aoi_file: ignoring %d non-polygon feature(s).",
                    nrow(shape) - nrow(polygons)))
  }

  if (is.na(sf::st_crs(polygons))) {
    stop(sprintf(paste0("aoi_file has no CRS: %s\n",
                        "  Give the file a .prj (or write it out from GIS with a CRS set) -- ",
                        "coordinates cannot be reprojected without one."), path),
         call. = FALSE)
  }

  # Several features are unioned into the single study-area polygon the rest of
  # the pipeline expects, exactly as multiple relations are.
  geom <- sf::st_union(sf::st_make_valid(sf::st_geometry(polygons)))
  aoi_sf <- sf::st_sf(city = city, geometry = sf::st_transform(geom, 4326))

  # A file carrying a CRS that is only nominally defined (GDAL substitutes an
  # engineering CRS for some formats) reprojects without complaint but lands
  # nowhere real. Catch that here rather than three pipeline steps later.
  bb <- sf::st_bbox(aoi_sf)
  if (bb[["xmin"]] < -180 || bb[["xmax"]] > 180 || bb[["ymin"]] < -90 || bb[["ymax"]] > 90) {
    stop(sprintf(paste0("aoi_file reprojects to coordinates outside the valid lon/lat range: %s\n",
                        "  Its CRS (%s) is probably wrong -- reproject the file in GIS and try again."),
                 path, sf::st_crs(polygons)$input), call. = FALSE)
  }

  log_aoi_source(aoi_sf, sprintf("file %s (%d polygon(s)%s)",
                                 basename(path), nrow(polygons),
                                 if (is.null(layer)) "" else paste0(", layer ", layer)))
}

load_city_aoi <- function(city, aoi_mode, boundaries_dir, relation_id = NULL, bbox = NULL,
                          aoi_file = NULL, aoi_layer = NULL, regional_pbf = NULL,
                          pipeline_root = NULL) {
  mode <- match.arg(aoi_mode, c("relation", "bbox", "file"))
  cache_path <- file.path(boundaries_dir, paste0(city, ".geojson"))

  if (mode == "relation") {
    if (is.null(relation_id)) {
      stop("relation_id must be set when aoi_mode == 'relation'", call. = FALSE)
    }
    log_aoi_extent(
      fetch_relation_boundary(relation_id, cache_path, city, regional_pbf = regional_pbf),
      relation_id
    )
  } else if (mode == "file") {
    if (is.null(aoi_file)) {
      stop("aoi_file must be set when aoi_mode == 'file'", call. = FALSE)
    }
    file_to_aoi(aoi_file, city, layer = aoi_layer, pipeline_root = pipeline_root)
  } else {
    if (is.null(bbox)) {
      stop("bbox must be set when aoi_mode == 'bbox'", call. = FALSE)
    }
    bbox_to_aoi(bbox, city)
  }
}

CONFIG_AOI_HELPERS_LOADED <- TRUE
