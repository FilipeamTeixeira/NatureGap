# NatureGap — Connectivity job (standalone)
#
# Builds dispersal-limited betweenness on a habitat-resistance hex graph over
# the full AOI (not per tile). Nodes are 20 m cell centroids, edges join
# adjacent cells, and cost is distance scaled by habitat resistance — so
# corridors follow habitat, not footpaths. The pedestrian path network is used
# only for observation-effort correction in 02_habitat; it models where
# observers walk, not where wildlife can move.
#
# Run on an independent schedule:
#   CITY <- "porto-center"; source("pipeline/config.R")
#   source("pipeline/04_connectivity/connectivity.R")
#
# Skips automatically when the habitat grid and the CONN_* tuning constants are
# unchanged. Set FORCE_CONNECTIVITY=1 to override.

library(sf)
library(tidyverse)
library(igraph)
library(arrow)
library(jsonlite)
library(here)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

source(here::here("04_connectivity", "connectivity_load.R"), local = FALSE)
source(here::here("04_connectivity", "network_derive.R"), local = FALSE)

dir.create(DATA_PROC, recursive = TRUE, showWarnings = FALSE)

paths_info <- connectivity_paths()
# as.logical("1") is NA, not TRUE, so the documented FORCE_CONNECTIVITY=1 was
# silently ignored — the flag only ever worked spelled "TRUE". Accept the forms
# a caller would reasonably reach for.
force_run <- toupper(trimws(Sys.getenv("FORCE_CONNECTIVITY", unset = ""))) %in%
  c("1", "TRUE", "T", "YES")

if (!file.exists(PROC_GRID_HABITAT)) {
  stop(
    "grid_habitat.gpkg not found — run 02_habitat before connectivity. Corridors ",
    "are weighted by habitat_quality, so the habitat grid is a hard input.",
    call. = FALSE
  )
}

# The dispersal cutoff is what makes this tractable at all; without it igraph
# falls back to all-pairs shortest paths over ~100k+ nodes.
if (!"cutoff" %in% names(formals(igraph::betweenness))) {
  stop(
    "igraph is too old: betweenness() has no cutoff argument. Dispersal-limited ",
    "betweenness needs igraph >= 1.3. Upgrade igraph before running connectivity.",
    call. = FALSE
  )
}

grid_habitat <- sf::st_read(PROC_GRID_HABITAT, quiet = TRUE)

# Cell area drives the habitat-core area thresholds, and it is a property of the
# grid rather than a constant — read it from the geometry instead of assuming a
# cellsize convention.
cell_area_m2 <- as.numeric(stats::median(sf::st_area(grid_habitat)))

# Corridors are routed over a resistance surface that includes walls, so this is
# built from the whole grid rather than from the betweenness graph. See
# build_routing_graph() for why the betweenness graph cannot serve.
write_derived_network <- function(nodes_df) {
  routing <- build_routing_graph(grid_habitat)
  message(sprintf(
    "[connectivity] Routing surface: %d cells, %d edges (walls carried at resistance %g)",
    igraph::vcount(routing$graph), igraph::ecount(routing$graph), CONN_MAX_RESISTANCE
  ))
  net <- derive_connectivity_network(routing, nodes_df, cell_area_m2 = cell_area_m2)
  sf::st_write(net$nodes, PROC_NETWORK_NODES, delete_dsn = TRUE, quiet = TRUE)
  sf::st_write(net$edges, PROC_NETWORK_EDGES, delete_dsn = TRUE, quiet = TRUE)
  message(sprintf(
    "[connectivity] Network: %d candidate links -> %d corridors (%d sections), %d nodes (%d major, %d secondary, %d stepping stones)",
    net$candidates, net$corridors, nrow(net$edges), nrow(net$nodes),
    sum(net$nodes$tier == "major"),
    sum(net$nodes$tier == "secondary"),
    sum(net$nodes$tier == "stepping-stone")
  ))
  invisible(net)
}

if (!force_run && connectivity_up_to_date(grid_sf = grid_habitat)) {
  message("[connectivity] Habitat grid and tuning unchanged — skipping (set FORCE_CONNECTIVITY=1 to override)")
} else if (!force_run && connectivity_graph_up_to_date(grid_sf = grid_habitat)) {
  # Only the NET_* tuning moved. Betweenness is the expensive half and is still
  # valid, so re-derive the network from the cached node table alone.
  message("[connectivity] Betweenness unchanged — rebuilding the derived network only")
  write_derived_network(arrow::read_parquet(paths_info$nodes))
  jsonlite::write_json(
    connectivity_source_fingerprint(grid_habitat), paths_info$meta,
    auto_unbox = TRUE, pretty = TRUE
  )
  message("[connectivity] Wrote ", PROC_NETWORK_NODES)
  message("[connectivity] Wrote ", PROC_NETWORK_EDGES)
} else {
  fingerprint <- connectivity_source_fingerprint(grid_habitat)

  message(sprintf(
    "[connectivity] Building habitat-resistance graph from %d cells (permeability > %.2f)…",
    nrow(grid_habitat), CONN_MIN_PERMEABILITY
  ))

  net <- build_habitat_graph(grid_habitat)
  g <- net$graph
  nodes_df <- net$nodes
  edges_df <- net$edges

  message(sprintf(
    "[connectivity] Graph: %d nodes, %d edges (%d cells dropped as impermeable)",
    igraph::vcount(g),
    igraph::ecount(g),
    nrow(grid_habitat) - igraph::vcount(g)
  ))

  cat(sprintf(
    "Computing dispersal-limited betweenness (cutoff %g effective m)…\n",
    CONN_DISPERSAL_M
  ))
  node_bc <- igraph::betweenness(
    g,
    weights = igraph::E(g)$weight,
    cutoff = CONN_DISPERSAL_M,
    normalized = TRUE
  )
  edge_bc_raw <- igraph::edge_betweenness(
    g,
    weights = igraph::E(g)$weight,
    cutoff = CONN_DISPERSAL_M
  )
  edge_bc <- if (length(edge_bc_raw) > 1L && max(edge_bc_raw) > 0) {
    edge_bc_raw / max(edge_bc_raw)
  } else {
    edge_bc_raw
  }

  nodes_df$betweenness_centrality <- as.numeric(node_bc[as.character(nodes_df$node_id)])
  nodes_df$corridor_importance <- corridor_percentile(nodes_df$betweenness_centrality)
  edges_df$betweenness_centrality <- as.numeric(edge_bc)
  edges_df$corridor_importance <- corridor_percentile(edges_df$betweenness_centrality)

  message(sprintf(
    "[connectivity] Corridor importance: %d of %d graph cells carry routes (%.1f%%)",
    sum(nodes_df$corridor_importance > 0, na.rm = TRUE),
    nrow(nodes_df),
    100 * mean(nodes_df$corridor_importance > 0, na.rm = TRUE)
  ))

  # ── Ensemble over CONN_MAX_RESISTANCE ──────────────────────────────────────
  # The published ranking is highly sensitive to this constant and it is
  # uncalibrated (docs/sensitivity-analysis.md section 1). Recompute corridor
  # importance across the plausible range so residuals.R can report which cells
  # rank highly regardless of it. The baseline column above is untouched: this
  # is additive, and intervention_rank still comes from CONN_MAX_RESISTANCE.
  #
  # Graph structure does not depend on R — R rescales edge weights, while
  # CONN_MIN_PERMEABILITY decides which cells are in the graph at all — but the
  # graph is rebuilt per R anyway rather than reweighted by hand, so this uses
  # exactly the same code path as the baseline and cannot drift from it.
  for (r_val in CONN_ENSEMBLE_R) {
    col <- paste0("corridor_importance_r", r_val)
    if (r_val == CONN_MAX_RESISTANCE) {
      nodes_df[[col]] <- nodes_df$corridor_importance
      next
    }
    net_r <- build_habitat_graph(grid_habitat, max_resistance = r_val)
    bc_r <- igraph::betweenness(
      net_r$graph,
      weights = igraph::E(net_r$graph)$weight,
      cutoff = CONN_DISPERSAL_M,
      normalized = TRUE
    )
    ci_r <- corridor_percentile(as.numeric(bc_r[as.character(net_r$nodes$node_id)]))
    nodes_df[[col]] <- ci_r[match(as.character(nodes_df$node_id),
                                  as.character(net_r$nodes$node_id))]
    message(sprintf("[connectivity]   ensemble R=%-3g  %d cells carry routes",
                    r_val, sum(nodes_df[[col]] > 0, na.rm = TRUE)))
  }

  # Edge-level corridor importance on the graph as well as in the parquet. Edge
  # order is preserved by graph_from_data_frame(), so this aligns with edges_df.
  igraph::E(g)$importance <- edges_df$corridor_importance

  arrow::write_parquet(nodes_df, paths_info$nodes)
  arrow::write_parquet(edges_df, paths_info$edges)
  jsonlite::write_json(fingerprint, paths_info$meta, auto_unbox = TRUE, pretty = TRUE)

  saveRDS(g, PROC_CONNECTIVITY_GRAPH)

  # Derived ecological network: the simplified node/corridor representation the
  # map draws at overview and transition zooms. The cells stay the analytical
  # surface and are revealed at close zoom instead.
  write_derived_network(nodes_df)

  grid_stub <- grid_habitat |>
    dplyr::select(dplyr::any_of(c("cell_id", "green_space_id"))) |>
    dplyr::left_join(join_connectivity_to_cells(grid_habitat), by = "cell_id")

  sf::st_write(grid_stub, PROC_GRID_CONN, delete_dsn = TRUE, quiet = TRUE)
  message("[connectivity] Wrote grid_connectivity.gpkg (cell ↔ corridor lookup)")

  message("[connectivity] Wrote ", paths_info$nodes)
  message("[connectivity] Wrote ", paths_info$edges)
  message("[connectivity] Wrote ", paths_info$meta)
  message("[connectivity] Wrote ", PROC_CONNECTIVITY_GRAPH)
}