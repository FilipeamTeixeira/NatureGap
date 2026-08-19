# Derived ecological network: nodes + corridor centrelines from the
# habitat-resistance cell graph.
#
# The 20 m cells stay the analytical surface. This builds the *simplified*
# representation on top of them: connected areas of high-corridor-importance
# cells, reduced to a skeleton of least-cost centrelines with nodes at
# junctions, endpoints and stepping stones.
#
# Not done here, deliberately:
#   - no line per cell adjacency (that was corridor-links, the dense mesh)
#   - no node per cell, and no node per park
#   - no straight lines between green-space polygons
# Every centreline is a least-cost path through the connectivity surface, so
# where a corridor follows a canal or a park edge that is emergent, not imposed.

# Skeleton by farthest-point growth. Betweenness thresholding was the obvious
# alternative and gives blobby, disconnected fragments; growing a tree from the
# two most remote cells and repeatedly attaching the most remote unattached cell
# yields a connected tree with clean topology, which is what the contraction
# step below needs.
#
# Path *geometry* uses resistance weights, so centrelines run through good
# habitat. Branch *pruning* counts cells, which is scale-free — a threshold in
# effective metres is meaningless here, since one 20 m step costs ~20 effective
# m through ideal habitat but ~256 through median urban habitat.
grow_skeleton <- function(sg, min_branch_cells) {
  n <- igraph::vcount(sg)
  if (n < 2L) return(NULL)
  w <- igraph::E(sg)$weight

  far_from <- function(v) {
    d <- igraph::distances(sg, v = v, weights = w)[1L, ]
    d[!is.finite(d)] <- -Inf
    which.max(d)
  }
  a <- far_from(1L)
  b <- far_from(a)
  if (a == b) return(NULL)

  trunk <- as.integer(igraph::shortest_paths(
    sg, from = a, to = b, weights = w, output = "vpath"
  )$vpath[[1L]])
  if (length(trunk) < 2L) return(NULL)

  pairs <- list(cbind(utils::head(trunk, -1L), utils::tail(trunk, -1L)))
  skel <- unique(trunk)

  repeat {
    # Distance from the whole skeleton at once, via a zero-weight super-node.
    # Cheaper and simpler than an |skel| x |V| distance matrix, which grows as
    # the skeleton does.
    sg2 <- igraph::add_vertices(sg, 1L)
    super <- igraph::vcount(sg2)
    sg2 <- igraph::add_edges(
      sg2,
      as.vector(rbind(rep(super, length(skel)), skel)),
      attr = list(weight = rep(1e-9, length(skel)))
    )
    d <- igraph::distances(sg2, v = super, weights = igraph::E(sg2)$weight)[1L, ]
    d <- d[seq_len(n)]
    d[skel] <- -Inf
    d[!is.finite(d)] <- -Inf
    f <- which.max(d)
    if (!is.finite(d[f]) || d[f] <= 0) break

    path <- as.integer(igraph::shortest_paths(
      sg2, from = f, to = super, weights = igraph::E(sg2)$weight, output = "vpath"
    )$vpath[[1L]])
    path <- path[path != super]
    if (length(path) < min_branch_cells) break

    pairs[[length(pairs) + 1L]] <- cbind(utils::head(path, -1L), utils::tail(path, -1L))
    skel <- unique(c(skel, path))
  }

  pr <- do.call(rbind, pairs)
  pr <- unique(t(apply(pr, 1L, sort)))
  # Character vertex names, so the graph carries the subgraph vertex indices
  # explicitly. A numeric edge list would instead create vertices 1..max with no
  # name attribute, losing the mapping back to cell ids.
  tree <- igraph::graph_from_edgelist(matrix(as.character(pr), ncol = 2L), directed = FALSE)
  # Growth can re-touch the skeleton mid-path and close a loop; a spanning tree
  # guarantees the contraction below terminates and emits each chain once.
  if (!igraph::is_connected(tree)) {
    keep <- igraph::components(tree)
    tree <- igraph::induced_subgraph(tree, which(keep$membership == which.max(keep$csize)))
  }
  igraph::mst(tree)
}

# Contract degree-2 runs into polylines. Each emitted chain starts and ends at a
# terminal (junction or endpoint), so the result is one line per corridor
# segment rather than one per cell step.
contract_chains <- function(tree) {
  deg <- igraph::degree(tree)
  # Names, not indices: by this point they are cell ids, which are not
  # necessarily integers and must not be coerced.
  ids <- igraph::V(tree)$name
  terminals <- which(deg != 2L)
  if (length(terminals) == 0L) terminals <- 1L

  seen <- new.env(parent = emptyenv())
  key <- function(u, v) paste0(min(u, v), "_", max(u, v))
  chains <- list()

  for (t in terminals) {
    for (nb in as.integer(igraph::neighbors(tree, t))) {
      if (!is.null(seen[[key(t, nb)]])) next
      chain <- c(t, nb)
      assign(key(t, nb), TRUE, envir = seen)
      prev <- t
      cur <- nb
      while (deg[cur] == 2L) {
        nxt <- setdiff(as.integer(igraph::neighbors(tree, cur)), prev)
        if (length(nxt) != 1L) break
        if (!is.null(seen[[key(cur, nxt)]])) break
        assign(key(cur, nxt), TRUE, envir = seen)
        chain <- c(chain, nxt)
        prev <- cur
        cur <- nxt
      }
      chains[[length(chains) + 1L]] <- ids[chain]
    }
  }
  chains
}

# Corner-cutting smoother. A centreline through hex centroids zigzags at 60
# degrees; averaging interior vertices relaxes that into a curve without pulling
# the line off the cells it came from. Endpoints are pinned so segments still
# meet exactly at their shared nodes.
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

corridor_class <- function(importance) {
  cut(
    importance,
    breaks = c(-Inf, 0.35, 0.55, 0.75, 0.9, Inf),
    labels = c("fragmented", "weak", "moderate", "strong", "strongest"),
    right = FALSE
  )
}

# Build the whole derived network for one city.
derive_connectivity_network <- function(graph, nodes_df,
                                        min_importance = NET_MIN_IMPORTANCE,
                                        min_component_cells = NET_MIN_COMPONENT_CELLS,
                                        min_branch_cells = NET_MIN_BRANCH_CELLS,
                                        major_cells = NET_MAJOR_CELLS,
                                        secondary_cells = NET_SECONDARY_CELLS,
                                        smooth_passes = NET_SMOOTH_PASSES,
                                        crs_local = CRS_LOCAL) {
  imp <- nodes_df$corridor_importance
  names(imp) <- nodes_df$node_id
  keep_names <- nodes_df$node_id[is.finite(imp) & imp >= min_importance]
  if (length(keep_names) == 0L) {
    stop("No cells at or above NET_MIN_IMPORTANCE — the network would be empty.", call. = FALSE)
  }

  sub <- igraph::induced_subgraph(graph, vids = which(igraph::V(graph)$name %in% keep_names))
  comp <- igraph::components(sub)

  xy <- as.matrix(nodes_df[, c("x", "y")])
  rownames(xy) <- nodes_df$node_id

  seg_geom <- list(); seg_imp <- numeric(); seg_comp <- integer(); seg_cells <- integer()
  node_id <- character(); node_x <- numeric(); node_y <- numeric()
  node_kind <- character(); node_deg <- integer(); node_comp <- integer(); node_comp_cells <- integer()

  for (ci in seq_len(comp$no)) {
    members <- which(comp$membership == ci)
    csize <- length(members)
    sg <- igraph::induced_subgraph(sub, members)
    cell_names <- igraph::V(sg)$name

    # Too small to have a meaningful centreline: one stepping-stone node at the
    # component's most important cell. This is what keeps small habitat
    # fragments in the network without inventing a corridor through them.
    if (csize < min_component_cells) {
      best <- cell_names[which.max(imp[cell_names])]
      node_id <- c(node_id, best)
      node_x <- c(node_x, xy[best, 1L]); node_y <- c(node_y, xy[best, 2L])
      node_kind <- c(node_kind, "stepping-stone")
      node_deg <- c(node_deg, 0L); node_comp <- c(node_comp, ci)
      node_comp_cells <- c(node_comp_cells, csize)
      next
    }

    tree <- grow_skeleton(sg, min_branch_cells)
    if (is.null(tree) || igraph::vcount(tree) < 2L) {
      best <- cell_names[which.max(imp[cell_names])]
      node_id <- c(node_id, best)
      node_x <- c(node_x, xy[best, 1L]); node_y <- c(node_y, xy[best, 2L])
      node_kind <- c(node_kind, "stepping-stone")
      node_deg <- c(node_deg, 0L); node_comp <- c(node_comp, ci)
      node_comp_cells <- c(node_comp_cells, csize)
      next
    }
    # grow_skeleton works in sg's vertex indices; carry names through so the
    # chains come back as cell ids.
    igraph::V(tree)$name <- cell_names[as.integer(igraph::V(tree)$name)]

    for (chain in contract_chains(tree)) {
      chain <- as.character(chain)
      chain <- chain[chain %in% rownames(xy)]
      if (length(chain) < 2L) next
      pts <- smooth_coords(xy[chain, , drop = FALSE], smooth_passes)
      seg_geom[[length(seg_geom) + 1L]] <- sf::st_linestring(pts)
      seg_imp <- c(seg_imp, mean(imp[chain], na.rm = TRUE))
      seg_comp <- c(seg_comp, ci)
      seg_cells <- c(seg_cells, length(chain))
    }

    deg <- igraph::degree(tree)
    tree_names <- igraph::V(tree)$name

    add_node <- function(nm, kind, d) {
      if (!nm %in% rownames(xy)) return(invisible(NULL))
      node_id <<- c(node_id, nm)
      node_x <<- c(node_x, xy[nm, 1L]); node_y <<- c(node_y, xy[nm, 2L])
      node_kind <<- c(node_kind, kind)
      node_deg <<- c(node_deg, as.integer(d))
      node_comp <<- c(node_comp, ci)
      node_comp_cells <<- c(node_comp_cells, csize)
    }

    # One node stands for the connected area itself, tiered by its size. Giving
    # every terminal of a large area the area's own tier would scatter dozens of
    # major nodes across a single cluster.
    cluster_tier <- if (csize >= major_cells) {
      "major"
    } else if (csize >= secondary_cells) {
      "secondary"
    } else {
      "stepping-stone"
    }
    cluster_cell <- tree_names[which.max(imp[tree_names])]
    add_node(cluster_cell, cluster_tier, deg[match(cluster_cell, tree_names)])

    # Junctions are network features in their own right: a place where corridors
    # converge matters regardless of how large its area is.
    for (v in which(deg >= 3L)) {
      add_node(tree_names[v], if (deg[v] >= 4L) "major" else "secondary", deg[v])
    }
    # Corridor endpoints — where the connected network actually terminates.
    for (v in which(deg == 1L)) {
      add_node(tree_names[v], "stepping-stone", 1L)
    }
  }

  edges_sf <- if (length(seg_geom) > 0L) {
    sf::st_sf(
      segmentId = sprintf("seg_%d", seq_along(seg_geom)),
      componentId = seg_comp,
      cells = seg_cells,
      importance = round(seg_imp, 4),
      strength = as.character(corridor_class(seg_imp)),
      geometry = sf::st_sfc(seg_geom, crs = crs_local)
    )
  } else {
    sf::st_sf(
      segmentId = character(), componentId = integer(), cells = integer(),
      importance = numeric(), strength = character(),
      geometry = sf::st_sfc(crs = crs_local)
    )
  }

  nodes_out <- sf::st_sf(
    cellId = node_id,
    tier = node_kind,
    degree = node_deg,
    componentId = node_comp,
    componentCells = node_comp_cells,
    importance = round(as.numeric(imp[node_id]), 4),
    geometry = sf::st_sfc(
      lapply(seq_along(node_id), function(i) sf::st_point(c(node_x[i], node_y[i]))),
      crs = crs_local
    )
  )
  # A cell can qualify twice — as its area's representative and as a junction.
  # Order by tier so the stronger classification wins the dedupe rather than
  # whichever happened to be appended first.
  tier_rank <- c(major = 1L, secondary = 2L, `stepping-stone` = 3L)
  nodes_out <- nodes_out[order(tier_rank[nodes_out$tier], -nodes_out$degree), , drop = FALSE]
  nodes_out <- nodes_out[!duplicated(nodes_out$cellId), , drop = FALSE]

  list(nodes = nodes_out, edges = edges_sf, components = comp$no)
}
