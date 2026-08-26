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

# Corridors are a function of habitat_quality and the graph tuning constants,
# not of the path network — so the freshness key is the habitat grid plus those
# constants. Keying on paths (as this did while corridors ran on the path graph)
# would now let a habitat change slip through the cache unnoticed, and would
# equally fail to invalidate when CONN_DISPERSAL_M or the resistance ceiling is
# retuned.
habitat_fingerprint <- function(grid_sf) {
  if (nrow(grid_sf) == 0L) return("empty")
  # Quiet: the fingerprint is computed on every freshness check, and the
  # vegetation-source message belongs to the actual build, not to cache probes.
  perm <- tryCatch(
    cell_permeability(grid_sf, verbose = FALSE),
    error = function(e) rep(NA_real_, nrow(grid_sf))
  )
  digest::digest(
    paste0(
      paste(grid_sf$cell_id, collapse = ","),
      "|",
      paste(round(as.numeric(perm), 6), collapse = ",")
    ),
    algo = "xxhash64"
  )
}

# The derived network has its own tuning, independent of the graph's. Keeping it
# in the fingerprint means retuning NET_* invalidates the network without
# claiming the betweenness behind it also changed.
network_tuning_hash <- function() {
  digest::digest(
    list(
      NET_CORE_IMPORTANCE, NET_CORE_MIN_AREA_HA, NET_MAJOR_AREA_HA,
      NET_SECONDARY_AREA_HA, NET_NODES_PER_KM2, NET_NODES_MIN, NET_NODES_MAX,
      NET_CANDIDATE_K, NET_MAX_LINK_M, NET_MAX_ROUTE_RESISTANCE,
      NET_MAX_ROUTE_COST_M, NET_REDUNDANCY_RATIO, NET_MAX_ROUTE_OVERLAP,
      NET_STRENGTH_BREAKS, NET_BOTTLENECK_PERMEABILITY, NET_BOTTLENECK_MIN_M,
      NET_SMOOTH_PASSES, NET_SIMPLIFY_M
    ),
    algo = "xxhash64"
  )
}

connectivity_source_fingerprint <- function(grid_sf,
                                            max_resistance = CONN_MAX_RESISTANCE,
                                            min_permeability = CONN_MIN_PERMEABILITY,
                                            dispersal_m = CONN_DISPERSAL_M) {
  list(
    habitat_hash = habitat_fingerprint(grid_sf),
    cell_count = nrow(grid_sf),
    max_resistance = max_resistance,
    min_permeability = min_permeability,
    dispersal_m = dispersal_m,
    graph_kind = "habitat-resistance-hex-adjacency",
    network_kind = "core-nodes-least-cost-routes",
    network_tuning = network_tuning_hash(),
    computed_at = as.character(Sys.time())
  )
}

# Freshness in two steps, because the two halves of this job have different
# costs. The betweenness graph is expensive and depends only on the habitat grid
# and the CONN_* constants; the derived network is cheap and additionally depends
# on the NET_* constants. Retuning the network must not force a betweenness
# recompute, so callers check the graph and the network separately.
connectivity_graph_up_to_date <- function(data_proc = DATA_PROC, grid_sf = NULL) {
  paths_info <- connectivity_paths(data_proc)
  required <- c(paths_info$meta, paths_info$nodes, paths_info$edges)
  if (exists("PROC_CONNECTIVITY_GRAPH")) required <- c(required, PROC_CONNECTIVITY_GRAPH)
  if (!all(file.exists(required))) return(FALSE)
  meta <- jsonlite::read_json(paths_info$meta, simplifyVector = TRUE)

  if (is.null(grid_sf)) {
    if (!file.exists(PROC_GRID_HABITAT)) return(FALSE)
    grid_sf <- sf::st_read(PROC_GRID_HABITAT, quiet = TRUE)
  }

  current <- connectivity_source_fingerprint(grid_sf)
  isTRUE(identical(meta$habitat_hash %||% NA_character_, current$habitat_hash)) &&
    isTRUE(identical(meta$graph_kind %||% NA_character_, current$graph_kind)) &&
    isTRUE(isTRUE(all.equal(meta$max_resistance %||% NA_real_, current$max_resistance))) &&
    isTRUE(isTRUE(all.equal(meta$min_permeability %||% NA_real_, current$min_permeability))) &&
    isTRUE(isTRUE(all.equal(meta$dispersal_m %||% NA_real_, current$dispersal_m)))
}

# Every artefact this job is responsible for, not just the meta file. A run that
# produced nodes but no edges, or nodes but no derived network, is not up to date
# — and nothing downstream would notice except by silently exporting less than it
# should. Porto hit exactly this: its meta already matched the current tuning, so
# the job would have skipped and never written the network.
connectivity_up_to_date <- function(data_proc = DATA_PROC, grid_sf = NULL) {
  paths_info <- connectivity_paths(data_proc)
  required <- character(0)
  if (exists("PROC_NETWORK_NODES")) required <- c(required, PROC_NETWORK_NODES)
  if (exists("PROC_NETWORK_EDGES")) required <- c(required, PROC_NETWORK_EDGES)
  if (length(required) > 0L && !all(file.exists(required))) return(FALSE)
  if (!connectivity_graph_up_to_date(data_proc, grid_sf)) return(FALSE)

  meta <- jsonlite::read_json(paths_info$meta, simplifyVector = TRUE)
  isTRUE(identical(meta$network_kind %||% NA_character_, "core-nodes-least-cost-routes")) &&
    isTRUE(identical(meta$network_tuning %||% NA_character_, network_tuning_hash()))
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

clamp01 <- function(x) {
  x <- as.numeric(x)
  x[!is.finite(x)] <- 0
  pmin(1, pmax(0, x))
}

# Vegetation cover per cell. veg_fraction is the preferred (NIR/NDVI-led,
# smooth) measure, but it only exists where NIR imagery is available — currently
# the Netherlands and Portugal. Elsewhere the column may be absent *or present
# and entirely NA*, so fall back through the WorldCover equivalents. Those
# correlate 0.78 with veg_fraction on Amsterdam and are close to binary, which
# makes corridors blockier where they are used.
#
# Usability, not presence, decides. Testing `"veg_fraction" %in% names()` alone
# sent Yokohama down the preferred branch onto an all-NA column, zeroing
# permeability for all 258,767 cells and emptying the graph.
usable_measure <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  any(is.finite(x) & x > 0)
}

cell_vegetation <- function(grid_sf, verbose = TRUE) {
  say <- function(src) {
    if (verbose) message("[connectivity] Vegetation source: ", src)
    invisible(NULL)
  }

  if ("veg_fraction" %in% names(grid_sf) && usable_measure(grid_sf$veg_fraction)) {
    say("veg_fraction")
    return(clamp01(grid_sf$veg_fraction))
  }

  parts <- c("tree_fraction", "shrub_fraction", "grass_fraction")
  if (all(parts %in% names(grid_sf)) && any(vapply(parts, function(p) usable_measure(grid_sf[[p]]), logical(1)))) {
    say("tree + shrub + grass fractions (no usable veg_fraction — expected without NIR coverage)")
    return(clamp01(
      clamp01(grid_sf$tree_fraction) +
        clamp01(grid_sf$shrub_fraction) +
        clamp01(grid_sf$grass_fraction)
    ))
  }

  if ("green_fraction_wc" %in% names(grid_sf) && usable_measure(grid_sf$green_fraction_wc)) {
    say("green_fraction_wc")
    return(clamp01(grid_sf$green_fraction_wc))
  }

  stop(
    "No usable vegetation measure in the grid. veg_fraction, the tree/shrub/grass ",
    "fractions and green_fraction_wc are all absent or entirely empty, so corridor ",
    "resistance cannot be weighted.",
    call. = FALSE
  )
}

# Permeability to wildlife movement: vegetation discounted by built cover. Both
# inputs use their full 0-1 range, which is the contrast that habitat_quality
# lacks. See the CONN_* block in config.R for why the documented
# 1 - habitat_quality formula was replaced.
cell_permeability <- function(grid_sf, verbose = TRUE) {
  built <- if ("built_fraction_wc" %in% names(grid_sf)) {
    clamp01(grid_sf$built_fraction_wc)
  } else {
    rep(0, nrow(grid_sf))
  }
  cell_vegetation(grid_sf, verbose = verbose) * (1 - built)
}

# Resistance to movement. Floored at 1 so ideal habitat costs its true length:
# a zero floor gives zero-cost edges, which makes shortest paths degenerate
# (unbounded free movement through the best cells).
habitat_resistance <- function(permeability, max_resistance = CONN_MAX_RESISTANCE) {
  1 + (max_resistance - 1) * (1 - clamp01(permeability))
}

# Hex-adjacency graph weighted by habitat resistance: nodes are 20 m cell
# centroids, edges join cells that share a boundary, and edge cost is the
# centroid distance scaled by the mean resistance of the two cells it links.
hex_resistance_graph <- function(cells, max_resistance) {
  centroids <- suppressWarnings(sf::st_centroid(sf::st_geometry(cells)))
  coords <- sf::st_coordinates(centroids)

  # st_touches is exact for a hex tessellation (neighbours share an edge) and
  # avoids hard-coding a centroid spacing that depends on st_make_grid's
  # cellsize convention.
  nb <- sf::st_touches(cells)
  from_idx <- rep(seq_along(nb), lengths(nb))
  to_idx <- unlist(nb, use.names = FALSE)
  keep <- from_idx < to_idx
  from_idx <- from_idx[keep]
  to_idx <- to_idx[keep]

  if (length(from_idx) == 0L) {
    stop("No adjacent cells — the resistance graph would have no edges.", call. = FALSE)
  }

  res <- habitat_resistance(cells$permeability, max_resistance)
  seg_len <- sqrt(
    (coords[from_idx, 1L] - coords[to_idx, 1L])^2 +
      (coords[from_idx, 2L] - coords[to_idx, 2L])^2
  )

  nodes_df <- tibble::tibble(
    node_id = as.character(cells$cell_id),
    x = coords[, 1L],
    y = coords[, 2L],
    permeability = as.numeric(cells$permeability),
    resistance = res
  )

  edges_df <- tibble::tibble(
    from_node = nodes_df$node_id[from_idx],
    to_node = nodes_df$node_id[to_idx],
    x_from = coords[from_idx, 1L],
    y_from = coords[from_idx, 2L],
    x_to = coords[to_idx, 1L],
    y_to = coords[to_idx, 2L],
    weight = pmax(seg_len * (res[from_idx] + res[to_idx]) / 2, 1e-6)
  ) |>
    dplyr::mutate(edge_id = paste0(from_node, "__", to_node))

  g <- igraph::graph_from_data_frame(
    edges_df |> dplyr::transmute(from = from_node, to = to_node, weight, edge_id),
    directed = FALSE,
    vertices = nodes_df |> dplyr::rename(name = node_id)
  )

  list(graph = g, nodes = nodes_df, edges = edges_df)
}

# Betweenness graph: permeable cells only. Impermeable cells are dropped rather
# than carried at high cost — nothing disperses through a building, and
# excluding them keeps the betweenness computation small enough to run.
build_habitat_graph <- function(grid_sf,
                                min_permeability = CONN_MIN_PERMEABILITY,
                                max_resistance = CONN_MAX_RESISTANCE) {
  perm_all <- cell_permeability(grid_sf)

  cells <- grid_sf[, "cell_id"]
  cells$permeability <- perm_all
  permeable <- perm_all > min_permeability
  if (!any(permeable)) {
    stop(
      "No cells above CONN_MIN_PERMEABILITY (", min_permeability,
      ") — the habitat graph would be empty.",
      call. = FALSE
    )
  }

  hex_resistance_graph(cells[permeable, , drop = FALSE], max_resistance)
}

# Routing surface: *every* cell, walls included at maximum resistance.
#
# The betweenness graph cannot serve as the routing surface. Dropping walls
# leaves it in 520-1375 disconnected components (its largest holds 8-20% of
# cells), so a least-cost route between two habitat cores is unreachable four
# times out of five — which is why corridors used to be confined inside single
# high-importance blobs. A corridor may legitimately cross degraded ground; the
# NET_MAX_ROUTE_* ceilings, not a missing edge, are what decide whether it does.
build_routing_graph <- function(grid_sf, max_resistance = CONN_MAX_RESISTANCE) {
  cells <- grid_sf[, "cell_id"]
  cells$permeability <- cell_permeability(grid_sf, verbose = FALSE)
  hex_resistance_graph(cells, max_resistance)
}

# Percentile rank among cells that actually carry routes. Cells with zero
# betweenness stay 0 rather than being ranked up into the lower percentiles —
# no route passes through them, so they are not weak corridors, they are not
# corridors. Raw betweenness under a dispersal cutoff is a tiny, highly skewed
# number (Amsterdam's path-graph maximum was 0.0187), which left every absolute
# threshold downstream permanently unreachable; ranking restores a 0-1 scale
# those thresholds can actually express.
corridor_percentile <- function(x) {
  out <- rep(NA_real_, length(x))
  finite <- is.finite(x)
  out[finite] <- 0
  pos <- finite & x > 0
  if (any(pos)) {
    out[pos] <- rank(x[pos], ties.method = "average") / sum(pos)
  }
  out
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
  if (!"corridor_importance" %in% names(nodes)) {
    stop(
      "Connectivity lookup predates the habitat-resistance graph — re-run ",
      "04_connectivity/connectivity.R with FORCE_CONNECTIVITY=1.",
      call. = FALSE
    )
  }

  # Cells are graph nodes now, so this is a direct key match rather than a
  # nearest-feature snap. match() (not a join) keeps grid order and sidesteps
  # cell_id type coercion between the grid and the parquet.
  idx <- match(as.character(grid_sf$cell_id), as.character(nodes$node_id))

  betweenness <- as.numeric(nodes$betweenness_centrality)[idx]
  corridor <- as.numeric(nodes$corridor_importance)[idx]

  # Ensemble columns (corridor_importance_r<R>) ride along when present, so
  # residuals.R can derive rank stability. Absent for datasets built before the
  # ensemble existed, which is why residuals.R treats them as optional.
  ens_cols <- grep("^corridor_importance_r[0-9]+$", names(nodes), value = TRUE)
  ens <- lapply(ens_cols, function(cn) as.numeric(nodes[[cn]])[idx])
  names(ens) <- ens_cols

  tibble::tibble(
    !!!ens,
    cell_id = grid_sf$cell_id,
    # Non-NA marks a cell that is in the corridor graph; NA marks a wall
    # excluded by CONN_MIN_PERMEABILITY.
    path_node_id = as.character(nodes$node_id)[idx],
    betweenness_centrality = betweenness,
    corridor_importance = corridor,
    connectivity_score = corridor,
    node_importance = betweenness,
    fragmentation_index = NA_real_,
    neighbor_fragmentation = NA_real_,
    edge_density = NA_real_,
    patch_isolation = NA_real_,
    patch_size_distribution = NA_real_,
    patch_area_ha = NA_real_
  )
}
