# NatureGap — Patch connectivity: dPC and its intra / flux / connector fractions
#
# How much each habitat patch contributes to the city's habitat availability
# (probability of connectivity, PC: Saura & Pascual-Hortal 2007), split as in
# Saura & Rubio (2010):
#   intra      the patch's own habitat
#   flux       connections that start or end at the patch
#   connector  connectivity between *other* patches that runs through it — its
#              role as a stepping stone
# Settings and reasons: the PATCH_* block in config.R. docs/methodology.md §9b.
#
# Method:
#   1. Patches: connected cells with permeability >= PATCH_MIN_VEGETATION, kept
#      at PATCH_MIN_AREA_HA or more. Habitat amount a = sum of cell area x
#      vegetation share.
#   2. Distances: least-cost, edge to edge, over the corridors' resistance
#      surface. A directed copy of the surface gets one source vertex per patch
#      (arcs out to its cells) and one sink (arcs in from its cells), so only
#      the two end patches are free to cross and no path can pass through a
#      source or sink. Symmetric by construction; the smaller direction is kept.
#   3. Links: p = exp(-theta d), theta set so p = PATCH_P_AT_DISPERSAL at
#      CONN_DISPERSAL_M; links beyond PATCH_MAX_LINK_M dropped. p* (the most
#      probable path) is exp(-theta x the shortest path over those links).
#   4. PC numerator = sum_ij a_i a_j p*_ij. intra and flux follow directly.
#      connector_k needs p* recomputed without k; only pairs within
#      PATCH_MAX_LINK_M of k can route through it with any weight (a path via k
#      longer than 2 x PATCH_MAX_LINK_M has p* < 6e-6), so it is recomputed on
#      k's neighbourhood alone.
#
# Outputs (no-op when inputs and settings are unchanged):
#   PROC_PATCH_CONN   per patch: patch_id, cells, area_ha, habitat_ha, links,
#                     dpc, dpc_intra, dpc_flux, dpc_connector, connector_pct
#   PROC_PATCH_CELLS  cell_id -> patch_id (cells outside patches are absent)
#   PROC_PATCH_META   settings, fingerprint, summary

patch_connectivity_fingerprint <- function(grid_sf) {
  list(
    habitat_hash = habitat_fingerprint(grid_sf),
    cell_count = nrow(grid_sf),
    max_resistance = CONN_MAX_RESISTANCE,
    resistance_shape = CONN_RESISTANCE_SHAPE,
    dispersal_m = CONN_DISPERSAL_M,
    min_vegetation = PATCH_MIN_VEGETATION,
    min_area_ha = PATCH_MIN_AREA_HA,
    p_at_dispersal = PATCH_P_AT_DISPERSAL,
    max_link_m = PATCH_MAX_LINK_M
  )
}

patch_connectivity_up_to_date <- function(grid_sf) {
  if (!all(file.exists(c(PROC_PATCH_CONN, PROC_PATCH_CELLS, PROC_PATCH_META)))) return(FALSE)
  meta <- jsonlite::read_json(PROC_PATCH_META, simplifyVector = TRUE)
  current <- patch_connectivity_fingerprint(grid_sf)
  all(vapply(names(current), function(k) isTRUE(all.equal(meta$fingerprint[[k]], current[[k]])), logical(1)))
}

# routing: build_routing_graph() output. Returns per-patch and per-cell tables.
compute_patch_dpc <- function(routing, cell_area_m2,
                              min_vegetation = PATCH_MIN_VEGETATION,
                              min_area_ha = PATCH_MIN_AREA_HA,
                              dispersal_m = CONN_DISPERSAL_M,
                              p_at_dispersal = PATCH_P_AT_DISPERSAL,
                              max_link_m = PATCH_MAX_LINK_M,
                              chunk = 100L, verbose = TRUE) {
  say <- function(...) if (verbose) message(sprintf(...))
  g <- routing$graph
  perm <- routing$nodes$permeability
  n_v <- igraph::vcount(g)

  # 1. Patches
  eligible <- which(perm >= min_vegetation)
  comp <- igraph::components(igraph::induced_subgraph(g, eligible))
  area_ha <- as.numeric(comp$csize) * cell_area_m2 / 1e4
  kept <- which(area_ha >= min_area_ha)
  if (length(kept) < 2L) stop("fewer than two habitat patches at PATCH_MIN_VEGETATION / PATCH_MIN_AREA_HA")
  patch_of_cell <- match(comp$membership, kept)            # NA for dropped components
  cell_v <- eligible[!is.na(patch_of_cell)]
  cell_p <- patch_of_cell[!is.na(patch_of_cell)]
  n_p <- length(kept)
  habitat_ha <- as.numeric(tapply(perm[cell_v], factor(cell_p, seq_len(n_p)), sum)) * cell_area_m2 / 1e4
  say("[patches] %d patches (%.1f ha of habitat in %d cells)", n_p, sum(habitat_ha), length(cell_v))

  # 2. Edge-to-edge least-cost distances on a directed copy with per-patch
  #    source (n_v + p) and sink (n_v + n_p + p) vertices.
  el <- igraph::as_edgelist(g, names = FALSE)
  w <- igraph::E(g)$weight
  src <- n_v + cell_p; snk <- n_v + n_p + cell_p
  arcs <- rbind(el, el[, 2:1], cbind(src, cell_v), cbind(cell_v, snk))
  G <- igraph::make_graph(as.vector(t(arcs)), n = n_v + 2L * n_p, directed = TRUE)
  aw <- c(w, w, numeric(2L * length(cell_v)))
  rm(el, arcs); invisible(gc())
  D <- matrix(Inf, n_p, n_p)
  for (s in split(seq_len(n_p), ceiling(seq_len(n_p) / chunk))) {
    D[s, ] <- igraph::distances(G, v = n_v + s, to = n_v + n_p + seq_len(n_p),
                                mode = "out", weights = aw, algorithm = "dijkstra")
    say("[patches]   distances %d / %d", max(s), n_p)
  }
  rm(G, aw); invisible(gc())
  D <- pmin(D, t(D)); diag(D) <- 0

  # 3. Links and the most probable paths
  theta <- -log(p_at_dispersal) / dispersal_m
  ij <- which(upper.tri(D) & D <= max_link_m, arr.ind = TRUE)
  PG <- igraph::make_graph(as.vector(t(ij)), n = n_p, directed = FALSE)
  igraph::E(PG)$weight <- pmax(D[ij], 1e-6)
  Dp <- igraph::distances(PG, weights = igraph::E(PG)$weight)
  links <- igraph::degree(PG)
  say("[patches] %d links within %g effective m", nrow(ij), max_link_m)

  # 4. PC fractions
  a <- habitat_ha
  Ps <- exp(-theta * Dp)                                   # Inf -> 0, diagonal 1
  pc_num <- sum(a * (Ps %*% a))
  intra <- 100 * a^2 / pc_num
  flux <- 100 * 2 * a * (as.vector(Ps %*% a) - a) / pc_num
  connector <- numeric(n_p)
  for (k in which(links >= 2L)) {
    nb <- setdiff(which(Dp[k, ] <= max_link_m), k)
    if (length(nb) < 2L) next
    region <- setdiff(which(Dp[k, ] <= 2 * max_link_m), k)
    sub <- igraph::induced_subgraph(PG, region)
    at <- match(nb, region)
    Dk <- igraph::distances(sub, v = at, to = at, weights = igraph::E(sub)$weight)
    loss <- exp(-theta * Dp[nb, nb, drop = FALSE]) - exp(-theta * Dk)
    diag(loss) <- 0
    connector[k] <- 100 * sum(a[nb] * (loss %*% a[nb])) / pc_num
  }
  connector <- pmax(connector, 0)                          # rounding noise only

  patches <- tibble::tibble(
    patch_id = seq_len(n_p),
    cells = as.integer(comp$csize[kept]),
    area_ha = round(area_ha[kept], 4),
    habitat_ha = round(habitat_ha, 4),
    links = as.integer(links),
    dpc = intra + flux + connector,
    dpc_intra = intra,
    dpc_flux = flux,
    dpc_connector = connector,
    connector_pct = corridor_percentile(connector)
  )
  cells <- tibble::tibble(cell_id = routing$nodes$node_id[cell_v], patch_id = cell_p)
  list(patches = patches, cells = cells,
       summary = list(patches = n_p, cells = length(cell_v), links = nrow(ij),
                      habitatHa = sum(habitat_ha), theta = theta,
                      connectorPatches = sum(connector > 0),
                      connectorShareOfDpc = sum(connector) / sum(intra + flux + connector)))
}

run_patch_connectivity <- function(grid_sf, force = FALSE) {
  if (!force && patch_connectivity_up_to_date(grid_sf)) {
    message("[patches] Habitat grid and settings unchanged — skipping")
    return(invisible(NULL))
  }
  t0 <- Sys.time()
  routing <- build_routing_graph(grid_sf)
  cell_area_m2 <- as.numeric(stats::median(sf::st_area(grid_sf)))
  res <- compute_patch_dpc(routing, cell_area_m2)
  arrow::write_parquet(res$patches, PROC_PATCH_CONN)
  arrow::write_parquet(res$cells, PROC_PATCH_CELLS)
  jsonlite::write_json(
    list(fingerprint = patch_connectivity_fingerprint(grid_sf),
         method = "docs/methodology.md §9b",
         computedAt = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
         runtimeMin = round(as.numeric(Sys.time() - t0, units = "mins"), 2),
         summary = res$summary),
    PROC_PATCH_META, auto_unbox = TRUE, pretty = TRUE, digits = NA
  )
  message(sprintf("[patches] %d patches, %d stepping stones (connector > 0); connector %.0f%% of all dPC (%.1f min)",
                  res$summary$patches, res$summary$connectorPatches,
                  100 * res$summary$connectorShareOfDpc,
                  as.numeric(Sys.time() - t0, units = "mins")))
  message("[patches] Wrote ", PROC_PATCH_CONN, ", ", basename(PROC_PATCH_CELLS), ", ", basename(PROC_PATCH_META))
  invisible(res)
}
