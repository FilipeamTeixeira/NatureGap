# NatureGap — Step 04: Ecological Function Layer
# Computes landscape connectivity on the canonical 20 m hex grid.
#
# Method:
#   1. Use the configured 20 m hex cells directly; no regridding.
#   2. Include every cell in the graph (urban + green + water + built-up).
#   3. Encode resistance per cell from habitat quality.
#   4. Compute betweenness centrality → corridor importance score.
#   5. Compute fragmentation from neighbouring 20 m hex context.
#
# Outputs:
#   data/processed/grid_connectivity.gpkg

library(sf)
library(terra)
library(tidyverse)
library(igraph)
library(landscapemetrics)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

HAB_THRESHOLD <- 0.40
HAS_GDISTANCE <- requireNamespace("gdistance", quietly = TRUE)

# ── 1. Load canonical 20 m habitat grid ──────────────────────────────────────

grid <- st_read(PROC_GRID_HABITAT, quiet = TRUE) |>
  mutate(is_habitat = habitat_quality >= HAB_THRESHOLD)

cat(sprintf("Habitat cells: %d / %d\n", sum(grid$is_habitat), nrow(grid)))

# ── 2. 20 m hex adjacency graph ──────────────────────────────────────────────

cell_pts <- st_centroid(grid)
cell_ids <- grid$cell_id
qualities <- pmin(1, pmax(0, replace_na(grid$habitat_quality, 0)))

adj_threshold <- CELL_SIZE * 1.15
within <- st_is_within_distance(cell_pts, cell_pts, dist = adj_threshold, sparse = TRUE)

edges_df <- bind_rows(lapply(seq_along(within), function(i) {
  neighbors <- within[[i]]
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
  stop("Connectivity graph has no edges. Check CELL_SIZE and grid geometry.", call. = FALSE)
}

edge_resistance <- (
  (1 - qualities[edges_df$from_idx]) + (1 - qualities[edges_df$to_idx])
) / 2

eps <- min(edge_resistance[edge_resistance > 0], na.rm = TRUE) * 0.001
if (!is.finite(eps) || eps <= 0) eps <- 1e-6

edges_df$weight <- pmax(edge_resistance, eps)

g <- graph_from_data_frame(
  edges_df |> select(from, to, weight),
  directed = FALSE,
  vertices = tibble(name = cell_ids)
)

cat(sprintf("Graph: %d nodes, %d edges\n", vcount(g), ecount(g)))

if (ecount(g) > vcount(g) * 8L) {
  warning(sprintf(
    "Graph has %d edges (expected roughly 6 per 20 m hex cell). Check CELL_SIZE.",
    ecount(g)
  ), call. = FALSE)
}

# ── 3. Habitat patch context on the same 20 m graph ──────────────────────────

habitat_vertex_names <- as.character(grid$cell_id[grid$is_habitat])
patch_id <- rep(NA_integer_, nrow(grid))

if (length(habitat_vertex_names) > 0L) {
  habitat_subgraph <- induced_subgraph(g, vids = habitat_vertex_names)
  habitat_components <- components(habitat_subgraph)$membership
  patch_lookup <- tibble(
    cell_id = as.integer(names(habitat_components)),
    patch_id = as.integer(habitat_components)
  )
  patch_id <- left_join(
    tibble(cell_id = grid$cell_id),
    patch_lookup,
    by = "cell_id"
  )$patch_id
}

patch_area <- tibble(
  patch_id = patch_id,
  cell_area_m2 = as.numeric(st_area(grid))
) |>
  filter(!is.na(patch_id)) |>
  group_by(patch_id) |>
  summarise(patch_area_ha = sum(cell_area_m2) / 10000, .groups = "drop")

grid <- grid |>
  mutate(patch_id = patch_id) |>
  select(-any_of("patch_area_ha")) |>
  left_join(patch_area, by = "patch_id") |>
  mutate(patch_area_ha = replace_na(patch_area_ha, 0))

# ── 3b. landscapemetrics fragmentation components at 20 m ───────────────────

hab_rast <- rasterize(
  vect(grid),
  rast(ext(vect(grid)), res = CELL_SIZE, crs = CRS_LOCAL),
  field = "is_habitat"
)

edge_density <- tryCatch({
  calculate_lsm(hab_rast, what = "lsm_l_ed") |>
    filter(metric == "ed") |>
    summarise(value = mean(value, na.rm = TRUE)) |>
    pull(value)
}, error = function(e) NA_real_)

rescale01 <- function(x) {
  rng <- range(x, na.rm = TRUE)
  if (!all(is.finite(rng)) || diff(rng) == 0) return(rep(0, length(x)))
  pmin(1, pmax(0, (x - rng[1]) / diff(rng)))
}

habitat_patch_centroids <- grid |>
  filter(!is.na(patch_id)) |>
  group_by(patch_id) |>
  summarise(.groups = "drop") |>
  st_centroid()

patch_isolation <- rep(1, nrow(grid))
if (nrow(habitat_patch_centroids) > 1L) {
  d <- st_distance(st_centroid(grid), habitat_patch_centroids)
  patch_isolation <- apply(as.matrix(d), 1, function(row) {
    finite <- row[is.finite(row) & row > 0]
    if (length(finite) == 0L) return(0)
    min(finite)
  })
  patch_isolation <- rescale01(patch_isolation)
}

grid <- grid |>
  mutate(
    edge_density = replace_na(edge_density, 0),
    patch_isolation = patch_isolation,
    patch_size_distribution = if_else(
      patch_area_ha <= 0,
      1,
      1 - rescale01(patch_area_ha)
    ),
    edge_density_index = pmin(1, pmax(0, replace_na(edge_density, 0) / 100))
  )

# ── 4. Betweenness centrality → corridor importance ──────────────────────────

cat("Computing betweenness centrality...\n")
bc <- betweenness(g, weights = E(g)$weight, normalized = TRUE)

bc_df <- tibble(
  cell_id = as.integer(V(g)$name),
  corridor_importance = as.numeric(bc)
)

# ── 5. Fragmentation index ───────────────────────────────────────────────────

adj_matrix <- as_adjacency_matrix(g, sparse = TRUE)
neighbor_count <- rowSums(adj_matrix)
habitat_neighbor_count <- as.numeric(adj_matrix %*% as.integer(grid$is_habitat))

fragmentation_df <- tibble(
  cell_id = as.integer(V(g)$name),
  connected_nb_count = as.integer(neighbor_count),
  habitat_nb_count = as.integer(habitat_neighbor_count)
) |>
  mutate(fragmentation_index = if_else(
    connected_nb_count == 0L,
    1,
    1 - habitat_nb_count / connected_nb_count
  ))

# ── 6. Merge back to canonical grid ──────────────────────────────────────────

grid_conn <- grid |>
  left_join(bc_df, by = "cell_id") |>
  left_join(fragmentation_df, by = "cell_id") |>
  mutate(
    corridor_importance = replace_na(corridor_importance, 0),
    neighbor_fragmentation = replace_na(fragmentation_index, 1),
    fragmentation_index = pmin(1, pmax(0,
      0.35 * neighbor_fragmentation +
        0.25 * edge_density_index +
        0.20 * patch_isolation +
        0.20 * patch_size_distribution
    )),
    node_importance = pmin(1, pmax(0, habitat_quality * (1 - fragmentation_index))),
    connectivity_score = pmin(1, pmax(0,
      0.60 * corridor_importance +
        0.25 * node_importance +
        0.15 * (1 - fragmentation_index)
    ))
  )

st_write(grid_conn, PROC_GRID_CONN, delete_dsn = TRUE)
cat("Written: grid_connectivity.gpkg\n")
