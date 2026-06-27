# NatureGap — Step 04: Full Ecological Connectivity Graph
# Builds the full-urban-extent connectivity network on the canonical 20 m hex grid.
#
# Nodes:
#   all hexes, green and non-green
#
# Edges:
#   queen adjacency of hex cells
#
# Edge weight:
#   mean(1 - habitat_quality of both cells)
#
# Outputs:
#   data/processed/connectivity_graph.rds
#   data/processed/grid_connectivity.gpkg

library(sf)
library(tidyverse)
library(igraph)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

# ── 1. Load full 20 m hex grid ───────────────────────────────────────────────

grid <- st_read(PROC_GRID_HABITAT, quiet = TRUE) |>
  st_transform(CRS_LOCAL)

if (!"habitat_quality" %in% names(grid)) {
  stop("grid_habitat.gpkg must contain habitat_quality before connectivity.", call. = FALSE)
}

if (any(is.na(grid$habitat_quality))) {
  stop(
    "habitat_quality contains NA values; exact connectivity weights cannot be computed.",
    call. = FALSE
  )
}

cell_ids <- grid$cell_id
qualities <- grid$habitat_quality

cat(sprintf("Connectivity nodes: %d full-extent hex cells\n", nrow(grid)))

# ── 2. Queen adjacency on full graph ─────────────────────────────────────────

touches <- st_touches(grid, sparse = TRUE)

edges_df <- bind_rows(lapply(seq_along(touches), function(i) {
  neighbors <- touches[[i]]
  neighbors <- neighbors[neighbors > i]
  if (length(neighbors) == 0L) return(NULL)
  tibble(
    from = cell_ids[i],
    to = cell_ids[neighbors],
    from_idx = i,
    to_idx = neighbors
  )
}))

if (nrow(edges_df) == 0L) {
  stop("Connectivity graph has no queen-adjacent edges.", call. = FALSE)
}

edges_df <- edges_df |>
  mutate(
    weight = ((1 - qualities[from_idx]) + (1 - qualities[to_idx])) / 2
  )

centroids <- suppressWarnings(st_centroid(grid))
coords <- st_coordinates(centroids)

vertices_df <- tibble(
  name = as.character(cell_ids),
  cell_id = cell_ids,
  green_space_id = if ("green_space_id" %in% names(grid)) grid$green_space_id else NA_character_,
  x = coords[, "X"],
  y = coords[, "Y"]
)

g <- graph_from_data_frame(
  edges_df |> transmute(from = as.character(from), to = as.character(to), weight),
  directed = FALSE,
  vertices = vertices_df
)

cat(sprintf("Connectivity graph: %d nodes, %d queen-adjacent edges\n", vcount(g), ecount(g)))

# ── 3. Betweenness centrality on full graph only ─────────────────────────────

cat("Computing full-graph betweenness centrality...\n")
bc <- betweenness(g, weights = E(g)$weight, normalized = TRUE)

bc_df <- tibble(
  cell_id = cell_ids,
  betweenness_centrality = as.numeric(bc[as.character(cell_ids)])
)

# ── 4. Persist graph and per-hex metric ──────────────────────────────────────

grid_conn <- grid |>
  left_join(bc_df, by = "cell_id") |>
  mutate(
    corridor_importance = betweenness_centrality,
    connectivity_score = betweenness_centrality,
    node_importance = NA_real_,
    fragmentation_index = NA_real_,
    neighbor_fragmentation = NA_real_,
    edge_density = NA_real_,
    patch_isolation = NA_real_,
    patch_size_distribution = NA_real_,
    patch_area_ha = NA_real_
  )

hex_cells <- grid_conn |>
  select(-any_of(c(
    "corridor_importance",
    "connectivity_score",
    "node_importance",
    "fragmentation_index",
    "neighbor_fragmentation",
    "edge_density",
    "patch_isolation",
    "patch_size_distribution",
    "patch_area_ha"
  )))

saveRDS(g, PROC_CONNECTIVITY_GRAPH)
st_write(hex_cells, PROC_HEX_CELLS, delete_dsn = TRUE)
st_write(grid_conn, PROC_GRID_CONN, delete_dsn = TRUE)

cat(sprintf("Written: %s\n", PROC_CONNECTIVITY_GRAPH))
cat(sprintf("Written: %s\n", PROC_HEX_CELLS))
cat(sprintf("Written: %s\n", PROC_GRID_CONN))
