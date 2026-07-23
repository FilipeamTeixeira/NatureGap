# NatureGap — Connectivity job (standalone)
#
# Builds path-network betweenness over the full AOI (not per tile).
# Run on an independent schedule:
#   source("pipeline/config_porto.R")
#   source("pipeline/04_connectivity/connectivity.R")
#
# Skips automatically when the path network fingerprint is unchanged.
# Set FORCE_CONNECTIVITY=1 to override.

library(sf)
library(tidyverse)
library(igraph)
library(arrow)
library(jsonlite)
library(here)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

source(here::here("04_connectivity", "connectivity_load.R"), local = FALSE)

dir.create(DATA_PROC, recursive = TRUE, showWarnings = FALSE)

paths_info <- connectivity_paths()
force_run <- isTRUE(as.logical(Sys.getenv("FORCE_CONNECTIVITY", unset = "FALSE")))

if (!force_run && connectivity_up_to_date()) {
  message("[connectivity] Path network unchanged — skipping (set FORCE_CONNECTIVITY=1 to override)")
} else {
  paths_aoi <- load_paths_aoi()
  fingerprint <- connectivity_source_fingerprint(paths_aoi)
  message(sprintf("[connectivity] Building path network from %d path features…", nrow(paths_aoi)))
  sf::st_write(paths_aoi, paths_info$paths_cache, delete_dsn = TRUE, quiet = TRUE)

  net <- build_path_network_graph(paths_aoi)
  g <- net$graph
  nodes_df <- net$nodes
  edges_df <- net$edges

  message(sprintf(
    "[connectivity] Graph: %d nodes, %d edges",
    igraph::vcount(g),
    igraph::ecount(g)
  ))

  cat("Computing path-network betweenness…\n")
  node_bc <- igraph::betweenness(g, weights = igraph::E(g)$weight, normalized = TRUE)
  edge_bc_raw <- igraph::edge_betweenness(g, weights = igraph::E(g)$weight)
  edge_bc <- if (length(edge_bc_raw) > 1L) {
    edge_bc_raw / max(edge_bc_raw)
  } else {
    edge_bc_raw
  }

  nodes_df$betweenness_centrality <- as.numeric(node_bc[as.character(nodes_df$node_id)])
  edges_df$betweenness_centrality <- as.numeric(edge_bc)

  arrow::write_parquet(nodes_df, paths_info$nodes)
  arrow::write_parquet(edges_df, paths_info$edges)
  jsonlite::write_json(fingerprint, paths_info$meta, auto_unbox = TRUE, pretty = TRUE)

  saveRDS(g, PROC_CONNECTIVITY_GRAPH)

  grid_stub <- if (file.exists(PROC_GRID_HABITAT)) {
    sf::st_read(PROC_GRID_HABITAT, quiet = TRUE) |>
      dplyr::select(dplyr::any_of(c("cell_id", "green_space_id"))) |>
      dplyr::left_join(join_connectivity_to_cells(sf::st_read(PROC_GRID_HABITAT, quiet = TRUE)), by = "cell_id")
  } else {
    NULL
  }

  if (!is.null(grid_stub)) {
    sf::st_write(grid_stub, PROC_GRID_CONN, delete_dsn = TRUE, quiet = TRUE)
    message("[connectivity] Wrote grid_connectivity.gpkg (cell ↔ node lookup)")
  }

  message("[connectivity] Wrote ", paths_info$nodes)
  message("[connectivity] Wrote ", paths_info$edges)
  message("[connectivity] Wrote ", paths_info$meta)
  message("[connectivity] Wrote ", PROC_CONNECTIVITY_GRAPH)
}