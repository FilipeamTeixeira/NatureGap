# Shared connectivity lookup helpers (path-network node/edge betweenness)

PATH_HIGHWAY_VALUES <- c("path", "footway", "pedestrian", "steps", "track")

connectivity_paths <- function(data_proc = DATA_PROC) {
  list(
    nodes = file.path(data_proc, "connectivity_nodes.parquet"),
    edges = file.path(data_proc, "connectivity_edges.parquet"),
    meta = file.path(data_proc, "connectivity_meta.json"),
    paths_cache = file.path(data_proc, "path_network_aoi.gpkg")
  )
}

osm_tag_from_other <- function(other_tags, key) {
  if (is.na(other_tags) || !nzchar(other_tags)) return(NA_character_)
  pattern <- paste0("\"", key, "\"=>\"([^\"]*)\"")
  match <- regexpr(pattern, other_tags, perl = TRUE)
  if (match[1L] == -1L) return(NA_character_)
  substr(other_tags, match[1L] + nchar(key) + 4L, match[1L] + attr(match, "match.length") - 2L)
}

read_osm_path_lines <- function(pbf_path, wkt_filter) {
  layers <- c("lines", "multilinestrings")
  out <- lapply(layers, function(layer) {
    tryCatch(
      sf::st_read(pbf_path, layer = layer, wkt_filter = wkt_filter, quiet = TRUE, int64_as_string = TRUE),
      error = function(e) NULL
    )
  })
  out <- Filter(Negate(is.null), out)
  if (length(out) == 0L) {
    return(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
  }
  out <- dplyr::bind_rows(out)
  if ("other_tags" %in% names(out) && !"highway" %in% names(out)) out$highway <- NA_character_
  if ("other_tags" %in% names(out)) {
    missing <- is.na(out$highway) | !nzchar(out$highway)
    if (any(missing)) {
      out$highway[missing] <- vapply(out$other_tags[missing], osm_tag_from_other, character(1L), key = "highway")
    }
  }
  out
}

load_paths_aoi <- function(aoi_wgs84 = aoi, crs_local = CRS_LOCAL, city_slug = city,
                         pipeline_root = PIPELINE_ROOT, raw_paths = RAW_OSM_PATHS) {
  aoi_local <- sf::st_transform(aoi_wgs84, crs_local)
  wkt_filter <- sf::st_as_text(sf::st_as_sfc(sf::st_bbox(sf::st_transform(aoi_local, 4326))), trim = TRUE)

  tiles_dir <- file.path(pipeline_root, "data", "tiles", city_slug)
  pbfs <- sort(list.files(tiles_dir, pattern = "\\.osm\\.pbf$", full.names = TRUE))

  if (length(pbfs) > 0L) {
    paths <- dplyr::bind_rows(lapply(pbfs, read_osm_path_lines, wkt_filter = wkt_filter))
    if (nrow(paths) > 0L) {
      paths <- paths |>
        dplyr::filter(.data$highway %in% PATH_HIGHWAY_VALUES) |>
        sf::st_transform(crs_local) |>
        sf::st_make_valid()
      inside <- sf::st_intersects(paths, aoi_local, sparse = FALSE)[, 1L]
      return(paths[inside, , drop = FALSE])
    }
  }

  if (file.exists(raw_paths)) {
    paths <- sf::st_read(raw_paths, quiet = TRUE) |> sf::st_transform(crs_local)
    inside <- sf::st_intersects(paths, aoi_local, sparse = FALSE)[, 1L]
    return(paths[inside, , drop = FALSE])
  }

  stop("No path network source found (tile PBFs or RAW_OSM_PATHS).", call. = FALSE)
}

path_network_fingerprint <- function(paths) {
  if (nrow(paths) == 0L) return("empty")
  geom <- suppressWarnings(sf::st_union(sf::st_geometry(paths)))
  digest::digest(sf::st_as_text(geom), algo = "xxhash64")
}

connectivity_source_fingerprint <- function(paths, regional_pbf_path = NULL) {
  if (is.null(regional_pbf_path) && exists("regional_pbf", inherits = TRUE)) {
    regional_pbf_path <- get("regional_pbf", inherits = TRUE)
  }
  list(
    path_hash = path_network_fingerprint(paths),
    regional_pbf_mtime = if (!is.null(regional_pbf_path) && file.exists(regional_pbf_path)) {
      as.character(file.info(regional_pbf_path)$mtime)
    } else {
      NA_character_
    },
    path_feature_count = nrow(paths),
    computed_at = as.character(Sys.time())
  )
}

connectivity_up_to_date <- function(data_proc = DATA_PROC, paths = NULL,
                                    regional_pbf_path = NULL) {
  if (is.null(regional_pbf_path) && exists("regional_pbf", inherits = TRUE)) {
    regional_pbf_path <- get("regional_pbf", inherits = TRUE)
  }
  paths_info <- connectivity_paths(data_proc)
  if (!file.exists(paths_info$meta) || !file.exists(paths_info$nodes)) {
    return(FALSE)
  }
  meta <- jsonlite::read_json(paths_info$meta, simplifyVector = TRUE)

  if (is.null(paths)) {
    if (!file.exists(paths_info$paths_cache)) {
      return(FALSE)
    }
    paths <- sf::st_read(paths_info$paths_cache, quiet = TRUE)
  }

  current <- connectivity_source_fingerprint(paths, regional_pbf_path)
  isTRUE(identical(meta$path_hash, current$path_hash)) &&
    isTRUE(identical(meta$regional_pbf_mtime %||% NA_character_, current$regional_pbf_mtime %||% NA_character_))
}

`%||%` <- function(x, y) if (is.null(x)) y else x

node_id_from_xy <- function(x, y) {
  sprintf("n_%d_%d", as.integer(round(x * 10)), as.integer(round(y * 10)))
}

build_path_network_graph <- function(paths) {
  paths <- suppressWarnings(sf::st_cast(paths, "LINESTRING", warn = FALSE))
  paths <- paths[!sf::st_is_empty(paths), , drop = FALSE]
  if (nrow(paths) == 0L) {
    stop("Path network is empty for this AOI.", call. = FALSE)
  }

  edges_list <- vector("list", nrow(paths))
  edge_count <- 0L
  for (i in seq_len(nrow(paths))) {
    coords <- sf::st_coordinates(paths[i, ])
    if (nrow(coords) < 2L) next
    for (j in seq_len(nrow(coords) - 1L)) {
      x1 <- coords[j, "X"]
      y1 <- coords[j, "Y"]
      x2 <- coords[j + 1L, "X"]
      y2 <- coords[j + 1L, "Y"]
      from_node <- node_id_from_xy(x1, y1)
      to_node <- node_id_from_xy(x2, y2)
      if (identical(from_node, to_node)) next
      edge_count <- edge_count + 1L
      len <- sqrt((x2 - x1)^2 + (y2 - y1)^2)
      edges_list[[edge_count]] <- tibble::tibble(
        from_node = from_node,
        to_node = to_node,
        x_from = x1,
        y_from = y1,
        x_to = x2,
        y_to = y2,
        weight = pmax(len, 1e-6)
      )
    }
  }

  edges_df <- dplyr::bind_rows(edges_list) |>
    dplyr::mutate(
      edge_id = paste0(from_node, "__", to_node),
      weight = pmax(weight, 1e-6)
    ) |>
    dplyr::group_by(edge_id) |>
    dplyr::slice(1L) |>
    dplyr::ungroup()

  nodes_df <- dplyr::bind_rows(
    edges_df |> dplyr::transmute(node_id = from_node, x = x_from, y = y_from),
    edges_df |> dplyr::transmute(node_id = to_node, x = x_to, y = y_to)
  ) |>
    dplyr::distinct(node_id, .keep_all = TRUE)

  g <- igraph::graph_from_data_frame(
    edges_df |> dplyr::transmute(from = from_node, to = to_node, weight, edge_id),
    directed = FALSE,
    vertices = nodes_df |> dplyr::rename(name = node_id)
  )

  list(graph = g, nodes = nodes_df, edges = edges_df)
}

join_connectivity_to_cells <- function(grid_sf, nodes_parquet = connectivity_paths()$nodes,
                                       crs_local = CRS_LOCAL) {
  if (!file.exists(nodes_parquet)) {
    stop(
      "Connectivity lookup not found: ", nodes_parquet,
      " — run 04_connectivity/connectivity.R first.",
      call. = FALSE
    )
  }

  nodes <- arrow::read_parquet(nodes_parquet)
  nodes_sf <- sf::st_as_sf(nodes, coords = c("x", "y"), crs = crs_local, remove = FALSE)
  centroids <- suppressWarnings(sf::st_centroid(grid_sf))
  idx <- sf::st_nearest_feature(centroids, nodes_sf)

  tibble::tibble(
    cell_id = grid_sf$cell_id,
    path_node_id = nodes_sf$node_id[idx],
    betweenness_centrality = nodes$betweenness_centrality[idx],
    corridor_importance = nodes$betweenness_centrality[idx],
    connectivity_score = nodes$betweenness_centrality[idx],
    node_importance = nodes$betweenness_centrality[idx],
    fragmentation_index = NA_real_,
    neighbor_fragmentation = NA_real_,
    edge_density = NA_real_,
    patch_isolation = NA_real_,
    patch_size_distribution = NA_real_,
    patch_area_ha = NA_real_
  )
}
