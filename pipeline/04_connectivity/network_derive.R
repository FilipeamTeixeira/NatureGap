# Derived ecological network: habitat-core nodes + least-cost corridors between
# them, over the full habitat-resistance cell graph.
#
# The 20 m cells stay the analytical surface. This builds the *simplified*
# representation drawn on top of them at overview and transition zoom.
#
# Order matters, and it is the opposite of the obvious one:
#
#   nodes first (habitat cores)  ->  route between neighbouring nodes over the
#   WHOLE resistance surface  ->  score each route as a whole  ->  prune
#
# The previous version did `induced_subgraph(importance >= threshold)` ->
# skeletonise -> emit every branch. Cutting the graph at the threshold *before*
# deriving topology is the root defect: no route can then cross a degraded
# block, so every high-importance blob becomes its own island and the output is
# a field of short fragments (Porto: 130 components, 420 segments, median 84 m)
# rather than a network. Refining the skeleton cannot fix that — the
# connectivity was discarded upstream of it.
#
# Not done here, deliberately:
#   - no node per cell, no node per skeleton junction, no node per park
#   - no straight lines between green-space polygons
#   - no all-pairs routing (Delaunay candidates only)
# Every corridor is a least-cost path through the resistance surface, so where
# one follows a canal or a park edge that is emergent, not imposed.

# ── candidate connections ────────────────────────────────────────────────────

# Delaunay neighbours. bOnlyEdges gives the edges directly, and the
# triangulation reuses the input vertices exactly, so matching coordinates back
# to node indices is safe at millimetre rounding.
delaunay_pairs <- function(xy) {
  if (nrow(xy) < 3L) return(NULL)
  tri <- tryCatch(
    sf::st_triangulate(sf::st_sfc(sf::st_multipoint(xy)), bOnlyEdges = TRUE),
    error = function(e) NULL
  )
  if (is.null(tri) || length(tri) == 0L) return(NULL)
  co <- sf::st_coordinates(tri)
  if (is.null(co) || nrow(co) < 2L) return(NULL)

  key <- sprintf("%.3f_%.3f", xy[, 1L], xy[, 2L])
  idx <- match(sprintf("%.3f_%.3f", co[, "X"], co[, "Y"]), key)

  # One group per emitted linestring. L1 is the linestring within a
  # multilinestring, L2 the feature; both may be absent for simpler geometries.
  lab <- if (all(c("L1", "L2") %in% colnames(co))) {
    paste(co[, "L2"], co[, "L1"])
  } else if ("L1" %in% colnames(co)) {
    as.character(co[, "L1"])
  } else {
    rep("1", nrow(co))
  }

  out <- list()
  for (g in unique(lab)) {
    ii <- idx[lab == g]
    ii <- ii[!is.na(ii)]
    if (length(ii) < 2L) next
    out[[length(out) + 1L]] <- cbind(utils::head(ii, -1L), utils::tail(ii, -1L))
  }
  if (length(out) == 0L) return(NULL)
  do.call(rbind, out)
}

knn_pairs <- function(xy, k) {
  n <- nrow(xy)
  if (n < 2L) return(NULL)
  d <- as.matrix(stats::dist(xy))
  diag(d) <- Inf
  kk <- min(k, n - 1L)
  do.call(rbind, lapply(seq_len(n), function(i) cbind(i, order(d[i, ])[seq_len(kk)])))
}

normalise_pairs <- function(pairs) {
  if (is.null(pairs) || length(pairs) == 0L) return(NULL)
  pairs <- pairs[pairs[, 1L] != pairs[, 2L], , drop = FALSE]
  if (nrow(pairs) == 0L) return(NULL)
  pairs <- cbind(pmin(pairs[, 1L], pairs[, 2L]), pmax(pairs[, 1L], pairs[, 2L]))
  unique(pairs)
}

candidate_pairs <- function(xy, k, max_link_m) {
  pairs <- normalise_pairs(delaunay_pairs(xy))
  if (is.null(pairs)) pairs <- normalise_pairs(knn_pairs(xy, k))
  if (is.null(pairs)) return(NULL)
  sep <- sqrt(
    (xy[pairs[, 1L], 1L] - xy[pairs[, 2L], 1L])^2 +
      (xy[pairs[, 1L], 2L] - xy[pairs[, 2L], 2L])^2
  )
  pairs <- pairs[sep <= max_link_m, , drop = FALSE]
  if (nrow(pairs) == 0L) return(NULL)
  pairs
}

# ── geometry helpers ─────────────────────────────────────────────────────────

step_lengths <- function(xy) {
  if (nrow(xy) < 2L) return(numeric(0))
  sqrt(diff(xy[, 1L])^2 + diff(xy[, 2L])^2)
}

# Corner-cutting smoother. A centreline through hex centroids zigzags at 60
# degrees; averaging interior vertices relaxes that into a curve without pulling
# the line off the cells it came from. Endpoints are pinned, and the vertex
# count is preserved — which is what lets bottleneck sections be cut by index
# after smoothing rather than before it.
smooth_coords <- function(xy, passes) {
  if (nrow(xy) < 3L || passes < 1L) return(xy)
  for (i in seq_len(passes)) {
    inner <- (xy[-c(1L, nrow(xy)), , drop = FALSE] * 2 +
                xy[-c(nrow(xy) - 1L, nrow(xy)), , drop = FALSE] +
                xy[-c(1L, 2L), , drop = FALSE]) / 4
    xy <- rbind(xy[1L, , drop = FALSE], inner, xy[nrow(xy), , drop = FALSE])
  }
  xy
}

simplify_line <- function(xy, tol, crs_local) {
  ls <- sf::st_linestring(xy)
  if (tol <= 0 || nrow(xy) < 3L) return(ls)
  out <- tryCatch(
    sf::st_simplify(sf::st_sfc(ls, crs = crs_local), dTolerance = tol),
    error = function(e) NULL
  )
  if (is.null(out) || sf::st_is_empty(out)[1L]) return(ls)
  geom <- sf::st_geometry(out)[[1L]]
  if (!inherits(geom, "LINESTRING") || nrow(sf::st_coordinates(geom)) < 2L) return(ls)
  geom
}

# ── scoring ──────────────────────────────────────────────────────────────────

# Mean resistance along the route, not mean corridor_importance: the route now
# crosses cells that carry no betweenness at all, where importance is 0 by
# definition, and averaging those collapses every score to the floor.
corridor_class <- function(mean_resistance, breaks = NET_STRENGTH_BREAKS) {
  as.character(cut(
    mean_resistance,
    breaks = c(-Inf, breaks, Inf),
    labels = c("strongest", "strong", "moderate", "weak"),
    right = FALSE
  ))
}

# 1 for a route through ideal habitat, 0 at the rejection ceiling. Carries
# corridor width on the map, so it must stay on a 0-1 scale.
corridor_quality <- function(mean_resistance, ceiling = NET_MAX_ROUTE_RESISTANCE) {
  q <- (ceiling - mean_resistance) / max(ceiling - 1, 1e-9)
  pmin(1, pmax(0, q))
}

# Hierarchy for zoom gating. Derived from the tiers a corridor actually connects,
# so "primary" means "between two significant habitat cores" rather than
# "happens to be long".
corridor_rank <- function(tier_a, tier_b) {
  score <- function(t) switch(t, major = 3L, secondary = 2L, 1L)
  s <- score(tier_a) + score(tier_b)
  if (s >= 5L) "primary" else if (s >= 3L) "secondary" else "minor"
}

# Contiguous runs of hostile cells inside a route. A run counts only if the
# stretch it covers is long enough to be a real interruption — a single low
# permeability cell is noise, a 100 m crossing is a barrier. The extent measured
# includes the segments entering and leaving the run, which is the ground the
# hostile stretch actually occupies.
bottleneck_flags <- function(perm_vals, seg_len, perm_floor, min_m,
                             min_section_m = NET_MIN_SECTION_M) {
  bad <- is.finite(perm_vals) & perm_vals < perm_floor
  n <- length(bad)
  if (n < 2L || !any(bad)) return(rep(FALSE, n))
  r <- rle(bad)
  ends <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1L
  for (k in seq_along(r$values)) {
    if (!r$values[k]) next
    s <- starts[k]
    e <- ends[k]
    span <- sum(seg_len[max(1L, s - 1L):min(n - 1L, e)])
    if (!is.finite(span) || span < min_m) bad[s:e] <- FALSE
  }
  absorb_stub_runs(bad, seg_len, min_section_m)
}

# Sections below a usable length carry no information — a 20 m stub at the end of
# a corridor is a dot, not a stretch of anything. Absorb the shortest offender
# into whichever neighbour is longer and repeat; each pass merges at least two
# runs, so this terminates.
absorb_stub_runs <- function(bad, seg_len, min_section_m) {
  n <- length(bad)
  if (n < 2L) return(bad)
  repeat {
    r <- rle(bad)
    if (length(r$lengths) < 2L) break
    ends <- cumsum(r$lengths)
    starts <- ends - r$lengths + 1L
    # Measured over exactly the segments the section will be emitted with —
    # section k>1 starts one vertex early so consecutive sections join, and
    # measuring one segment wider than that left 20 m slivers in place.
    span <- vapply(seq_along(r$lengths), function(k) {
      lo <- if (k == 1L) 1L else starts[k] - 1L
      hi <- ends[k] - 1L
      if (hi >= lo) sum(seg_len[lo:hi]) else 0
    }, numeric(1L))
    short <- which(span < min_section_m)
    if (length(short) == 0L) break
    k <- short[which.min(span[short])]
    nb <- if (k == 1L) {
      2L
    } else if (k == length(r$lengths)) {
      k - 1L
    } else if (span[k - 1L] >= span[k + 1L]) {
      k - 1L
    } else {
      k + 1L
    }
    bad[starts[k]:ends[k]] <- r$values[nb]
  }
  bad
}

# Vertex ranges for the sections a route splits into. Each section after the
# first starts one vertex early, so consecutive sections share a vertex and the
# rendered line stays continuous.
section_ranges <- function(bad) {
  r <- rle(bad)
  ends <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1L
  out <- list()
  for (k in seq_along(r$values)) {
    s <- if (k == 1L) starts[k] else starts[k] - 1L
    e <- ends[k]
    if (e - s < 1L) next
    out[[length(out) + 1L]] <- list(from = s, to = e, bottleneck = isTRUE(r$values[k]))
  }
  out
}

# ── nodes ────────────────────────────────────────────────────────────────────

# One node per habitat core, placed at the core's centre rather than at its most
# important cell: corridor_importance peaks at bottlenecks, so maximising it
# pulls the node off the patch and onto the pinch point leading out of it.
# Restricting to the core's more permeable cells keeps the node on habitat.
core_node_cell <- function(cell_names, xy, perm) {
  p <- perm[cell_names]
  cut_p <- stats::quantile(p, 0.75, na.rm = TRUE)
  cand <- cell_names[is.finite(p) & p >= cut_p]
  if (length(cand) == 0L) cand <- cell_names
  cx <- mean(xy[cell_names, 1L])
  cy <- mean(xy[cell_names, 2L])
  d <- (xy[cand, 1L] - cx)^2 + (xy[cand, 2L] - cy)^2
  cand[which.min(d)]
}

identify_habitat_cores <- function(graph, imp, perm, xy, cell_area_m2,
                                   core_importance, min_area_ha,
                                   major_area_ha, secondary_area_ha,
                                   nodes_per_km2, nodes_min, nodes_max) {
  core_names <- names(imp)[is.finite(imp) & imp >= core_importance]
  if (length(core_names) == 0L) {
    stop("No cells at or above NET_CORE_IMPORTANCE — the network would be empty.", call. = FALSE)
  }

  sub <- igraph::induced_subgraph(graph, vids = which(igraph::V(graph)$name %in% core_names))
  comp <- igraph::components(sub)
  sub_names <- igraph::V(sub)$name

  area_ha <- as.numeric(comp$csize) * cell_area_m2 / 1e4
  keep <- which(area_ha >= min_area_ha)
  if (length(keep) == 0L) {
    stop(
      "No habitat core reaches NET_CORE_MIN_AREA_HA (", min_area_ha,
      " ha) — lower it or lower NET_CORE_IMPORTANCE.",
      call. = FALSE
    )
  }

  # AOI extent from the graph's own footprint. Node budget scales with the area
  # being mapped, so a denser city gets a denser map only where that density is
  # ecologically real, not simply because it has more permeable cells.
  aoi_km2 <- (diff(range(xy[, 1L])) * diff(range(xy[, 2L]))) / 1e6
  budget <- max(nodes_min, min(nodes_max, round(nodes_per_km2 * aoi_km2)))

  keep <- keep[order(area_ha[keep], decreasing = TRUE)]
  keep <- utils::head(keep, budget)

  cells <- lapply(keep, function(ci) sub_names[comp$membership == ci])
  # Tier computed before the tibble is built: inside tibble(), `area_ha[keep]`
  # would resolve to the column just defined and index it by component id.
  kept_area <- area_ha[keep]
  tier <- ifelse(
    kept_area >= major_area_ha, "major",
    ifelse(kept_area >= secondary_area_ha, "secondary", "stepping-stone")
  )
  tibble::tibble(
    cell_id = vapply(cells, core_node_cell, character(1L), xy = xy, perm = perm),
    core_cells = as.integer(comp$csize[keep]),
    area_ha = round(kept_area, 3),
    tier = tier
  ) |>
    dplyr::distinct(cell_id, .keep_all = TRUE)
}

# ── routing ──────────────────────────────────────────────────────────────────

# Least-cost route per candidate pair, one Dijkstra per source vertex rather
# than one per pair. Routes run over the full graph, so a corridor may cross
# weak ground; the ceilings are what keep it from crossing the whole city.
route_candidates <- function(graph, weights, vnames, pairs, node_cells, xy,
                             max_resistance, max_cost_m) {
  vid <- stats::setNames(seq_along(vnames), vnames)
  from_v <- vid[node_cells[pairs[, 1L]]]
  to_v <- vid[node_cells[pairs[, 2L]]]
  ok <- is.finite(from_v) & is.finite(to_v)
  pairs <- pairs[ok, , drop = FALSE]
  from_v <- from_v[ok]
  to_v <- to_v[ok]
  if (nrow(pairs) == 0L) return(list())

  routes <- vector("list", nrow(pairs))
  for (src in unique(from_v)) {
    sel <- which(from_v == src)
    # An AOI with detached parts (islands, a river-split relation) leaves the
    # routing surface in more than one component, so some targets are genuinely
    # unreachable. That is a rejection, not a problem worth warning about.
    sp <- suppressWarnings(igraph::shortest_paths(
      graph, from = src, to = to_v[sel], weights = weights, output = "both"
    ))
    for (j in seq_along(sel)) {
      vp <- as.integer(sp$vpath[[j]])
      ep <- as.integer(sp$epath[[j]])
      if (length(vp) < 2L) next
      cost <- sum(weights[ep])
      cells <- vnames[vp]
      len <- sum(step_lengths(xy[cells, , drop = FALSE]))
      if (!is.finite(cost) || !is.finite(len) || len <= 0) next
      mean_res <- cost / len
      if (mean_res > max_resistance || cost > max_cost_m) next
      routes[[sel[j]]] <- list(
        a = pairs[sel[j], 1L],
        b = pairs[sel[j], 2L],
        cells = cells,
        cost = cost,
        length_m = len,
        mean_resistance = mean_res
      )
    }
  }
  Filter(Negate(is.null), routes)
}

# Backbone plus worthwhile redundancy. A minimum spanning tree over route cost
# gives the connected skeleton; an extra link earns its place only by being much
# cheaper than the detour the tree forces, and by not retracing cells a kept
# route already covers. This is what replaces "render every branch".
prune_routes <- function(routes, node_cells, redundancy_ratio, max_overlap) {
  if (length(routes) == 0L) return(integer(0))
  from <- node_cells[vapply(routes, function(r) r$a, integer(1L))]
  to <- node_cells[vapply(routes, function(r) r$b, integer(1L))]
  cost <- vapply(routes, function(r) r$cost, numeric(1L))

  ng <- igraph::graph_from_data_frame(
    data.frame(from = from, to = to, weight = cost, ridx = seq_along(routes)),
    directed = FALSE,
    vertices = data.frame(name = unique(c(from, to)))
  )
  tree <- igraph::mst(ng, weights = igraph::E(ng)$weight)
  keep <- as.integer(igraph::E(tree)$ridx)

  used <- unique(unlist(lapply(routes[keep], function(r) r$cells), use.names = FALSE))
  tree_d <- igraph::distances(tree, weights = igraph::E(tree)$weight)

  extra <- setdiff(seq_along(routes), keep)
  extra <- extra[order(cost[extra])]
  for (i in extra) {
    detour <- tree_d[from[i], to[i]]
    if (!is.finite(detour) || cost[i] >= redundancy_ratio * detour) next
    overlap <- mean(routes[[i]]$cells %in% used)
    if (overlap > max_overlap) next
    keep <- c(keep, i)
    used <- unique(c(used, routes[[i]]$cells))
  }
  keep
}

# ── assembly ─────────────────────────────────────────────────────────────────

derive_connectivity_network <- function(routing, nodes_df, cell_area_m2,
                                        core_importance = NET_CORE_IMPORTANCE,
                                        min_area_ha = NET_CORE_MIN_AREA_HA,
                                        major_area_ha = NET_MAJOR_AREA_HA,
                                        secondary_area_ha = NET_SECONDARY_AREA_HA,
                                        nodes_per_km2 = NET_NODES_PER_KM2,
                                        nodes_min = NET_NODES_MIN,
                                        nodes_max = NET_NODES_MAX,
                                        candidate_k = NET_CANDIDATE_K,
                                        max_link_m = NET_MAX_LINK_M,
                                        max_resistance = NET_MAX_ROUTE_RESISTANCE,
                                        max_cost_m = NET_MAX_ROUTE_COST_M,
                                        redundancy_ratio = NET_REDUNDANCY_RATIO,
                                        max_overlap = NET_MAX_ROUTE_OVERLAP,
                                        bottleneck_perm = NET_BOTTLENECK_PERMEABILITY,
                                        bottleneck_min_m = NET_BOTTLENECK_MIN_M,
                                        min_section_m = NET_MIN_SECTION_M,
                                        smooth_passes = NET_SMOOTH_PASSES,
                                        simplify_m = NET_SIMPLIFY_M,
                                        crs_local = CRS_LOCAL) {
  graph <- routing$graph
  # Geometry and permeability come from the routing surface, which covers every
  # cell; corridor_importance comes from the betweenness graph, which covers
  # only the permeable ones. A cell absent from the latter cannot be a habitat
  # core, which is correct — it is a wall.
  perm <- stats::setNames(routing$nodes$permeability, routing$nodes$node_id)
  xy <- as.matrix(routing$nodes[, c("x", "y")])
  rownames(xy) <- routing$nodes$node_id
  imp <- stats::setNames(
    nodes_df$corridor_importance[match(routing$nodes$node_id, nodes_df$node_id)],
    routing$nodes$node_id
  )

  cores <- identify_habitat_cores(
    graph, imp, perm, xy, cell_area_m2,
    core_importance, min_area_ha, major_area_ha, secondary_area_ha,
    nodes_per_km2, nodes_min, nodes_max
  )
  node_cells <- cores$cell_id
  node_xy <- xy[node_cells, , drop = FALSE]

  pairs <- candidate_pairs(node_xy, candidate_k, max_link_m)
  routes <- if (is.null(pairs)) {
    list()
  } else {
    route_candidates(
      graph, igraph::E(graph)$weight, igraph::V(graph)$name,
      pairs, node_cells, xy, max_resistance, max_cost_m
    )
  }
  keep <- prune_routes(routes, node_cells, redundancy_ratio, max_overlap)
  routes <- routes[keep]

  # Degree from the pruned network, then a modest promotion: a small core that
  # ends up carrying several corridors is a genuine junction hub, which is the
  # one place node significance is topological rather than areal.
  cores$degree <- 0L
  for (r in routes) {
    cores$degree[r$a] <- cores$degree[r$a] + 1L
    cores$degree[r$b] <- cores$degree[r$b] + 1L
  }
  cores$tier[cores$tier == "stepping-stone" & cores$degree >= 3L] <- "secondary"
  cores$tier[cores$tier == "secondary" & cores$degree >= 4L] <- "major"
  # An unreachable core is not part of the network. Majors stay regardless —
  # a large isolated habitat area is a finding, not noise.
  tier_by_cell <- stats::setNames(cores$tier, cores$cell_id)
  cores <- cores[cores$degree > 0L | cores$tier %in% "major", , drop = FALSE]

  seg <- list()
  for (i in seq_along(routes)) {
    r <- routes[[i]]
    pts <- smooth_coords(xy[r$cells, , drop = FALSE], smooth_passes)
    steps <- step_lengths(pts)
    bad <- bottleneck_flags(
      perm[r$cells], steps, bottleneck_perm, bottleneck_min_m, min_section_m
    )
    strength <- corridor_class(r$mean_resistance)
    rank <- corridor_rank(tier_by_cell[[node_cells[r$a]]], tier_by_cell[[node_cells[r$b]]])
    sections <- section_ranges(bad)
    n_bottleneck <- sum(vapply(sections, function(s) isTRUE(s$bottleneck), logical(1L)))

    for (k in seq_along(sections)) {
      s <- sections[[k]]
      seg[[length(seg) + 1L]] <- list(
        geom = simplify_line(pts[s$from:s$to, , drop = FALSE], simplify_m, crs_local),
        corridor_id = sprintf("cor_%d", i),
        section = k,
        kind = if (s$bottleneck) "bottleneck" else "corridor",
        # Every section carries the corridor's one dominant class, bottlenecks
        # included, so the line does not flicker between colours along its
        # length. The break is expressed by `kind`, which the renderer paints as
        # an interruption over the dominant colour.
        strength = strength,
        rank = rank,
        from_node = node_cells[r$a],
        to_node = node_cells[r$b],
        length_m = r$length_m,
        mean_resistance = r$mean_resistance,
        bottlenecks = n_bottleneck
      )
    }
  }

  edges_sf <- if (length(seg) > 0L) {
    sf::st_sf(
      corridorId = vapply(seg, function(s) s$corridor_id, character(1L)),
      sectionIndex = vapply(seg, function(s) s$section, integer(1L)),
      kind = vapply(seg, function(s) s$kind, character(1L)),
      strength = vapply(seg, function(s) s$strength, character(1L)),
      rank = vapply(seg, function(s) s$rank, character(1L)),
      fromNode = vapply(seg, function(s) s$from_node, character(1L)),
      toNode = vapply(seg, function(s) s$to_node, character(1L)),
      lengthM = round(vapply(seg, function(s) s$length_m, numeric(1L))),
      meanResistance = round(vapply(seg, function(s) s$mean_resistance, numeric(1L)), 3),
      bottlenecks = vapply(seg, function(s) s$bottlenecks, integer(1L)),
      importance = round(corridor_quality(
        vapply(seg, function(s) s$mean_resistance, numeric(1L))
      ), 4),
      geometry = sf::st_sfc(lapply(seg, function(s) s$geom), crs = crs_local)
    )
  } else {
    sf::st_sf(
      corridorId = character(), sectionIndex = integer(), kind = character(),
      strength = character(), rank = character(), fromNode = character(),
      toNode = character(), lengthM = numeric(), meanResistance = numeric(),
      bottlenecks = integer(), importance = numeric(),
      geometry = sf::st_sfc(crs = crs_local)
    )
  }

  nodes_out <- sf::st_sf(
    cellId = cores$cell_id,
    tier = cores$tier,
    degree = as.integer(cores$degree),
    coreCells = as.integer(cores$core_cells),
    areaHa = as.numeric(cores$area_ha),
    importance = round(as.numeric(imp[cores$cell_id]), 4),
    geometry = sf::st_sfc(
      lapply(seq_len(nrow(cores)), function(i) {
        sf::st_point(xy[cores$cell_id[i], ])
      }),
      crs = crs_local
    )
  )

  list(
    nodes = nodes_out,
    edges = edges_sf,
    corridors = length(routes),
    candidates = if (is.null(pairs)) 0L else nrow(pairs)
  )
}
