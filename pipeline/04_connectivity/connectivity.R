# NatureGap — Step 04: Ecological Function Layer
# Computes landscape connectivity using the cell grid as a resistance surface.
#
# Method:
#   1. Classify cells into habitat patches (habitat_quality > threshold)
#   2. Compute patch-level metrics with landscapemetrics
#   3. Build adjacency graph with igraph; edge weights = resistance (1 - hab_quality)
#   4. Compute betweenness centrality → corridor importance score
#   5. Compute fragmentation index per cell
#
# Outputs:
#   data/processed/grid_connectivity.gpkg

library(sf)
library(terra)
library(tidyverse)
library(igraph)
library(landscapemetrics)

DATA_PROC <- here::here("data/processed")

HAB_THRESHOLD <- 0.40  # cells above this are "habitat" patches

# ── 1. Load habitat grid ─────────────────────────────────────────────────────

grid <- st_read(file.path(DATA_PROC, "grid_habitat.gpkg"), quiet = TRUE) |>
  mutate(is_habitat = habitat_quality >= HAB_THRESHOLD)

cat(sprintf("Habitat cells: %d / %d\n", sum(grid$is_habitat), nrow(grid)))

# ── 2. Rasterize habitat class ───────────────────────────────────────────────

CRS_LOCAL <- "EPSG:6674"
CELL_SIZE  <- 250

hab_rast <- rasterize(
  vect(grid),
  rast(ext(vect(grid)), res = CELL_SIZE, crs = CRS_LOCAL),
  field = "is_habitat"
)

# ── 3. Patch metrics with landscapemetrics ───────────────────────────────────

lsm_patch <- calculate_lsm(hab_rast, what = c("lsm_p_area", "lsm_p_shape", "lsm_p_enn"))
lsm_landscape <- calculate_lsm(hab_rast, what = c("lsm_l_shdi", "lsm_l_ai"))

# Map patch metrics back to cells using get_patches
patches <- get_patches(hab_rast, class = 1)[[1]][[1]]
patch_vals <- terra::extract(patches, vect(st_centroid(grid)), ID = TRUE)
grid$patch_id <- patch_vals[[2]]

patch_area <- lsm_patch |>
  filter(metric == "area", class == 1) |>
  select(id, patch_area_ha = value)

# grid <- grid |>
#   left_join(patch_area, by = c("patch_id" = "id")) |>
#   mutate(patch_area_ha = replace_na(patch_area_ha, 0))

grid <- grid |>
  select(-any_of("patch_area_ha")) |>          # safe to re-run
  left_join(patch_area, by = c("patch_id" = "id")) |>
  mutate(patch_area_ha = replace_na(patch_area_ha, 0))

# ── 4. Adjacency graph for connectivity ──────────────────────────────────────
# Nodes = habitat cells; edges = adjacency (queen's case)
# Edge weight = mean resistance of both cells = mean(1 - habitat_quality)

hab_cells <- grid |> filter(is_habitat) |> st_drop_geometry()

# Build adjacency from queen's neighbour rook + diagonal
grid_coords <- st_coordinates(st_centroid(grid |> filter(is_habitat)))

# Simple nearest-neighbour graph (within √2 × cell_size)
dist_mat <- as.matrix(dist(grid_coords))
adj_threshold <- sqrt(2) * CELL_SIZE * 1.05  # diagonal + 5% tolerance

edges <- which(dist_mat > 0 & dist_mat <= adj_threshold, arr.ind = TRUE)
edges <- edges[edges[, 1] < edges[, 2], ]  # upper triangle only

from_ids <- hab_cells$cell_id[edges[, 1]]
to_ids   <- hab_cells$cell_id[edges[, 2]]

resistance_from <- 1 - hab_cells$habitat_quality[edges[, 1]]
resistance_to   <- 1 - hab_cells$habitat_quality[edges[, 2]]
edge_resistance  <- (resistance_from + resistance_to) / 2

g <- graph_from_data_frame(
  data.frame(from = from_ids, to = to_ids, weight = edge_resistance),
  directed = FALSE,
  vertices = data.frame(name = hab_cells$cell_id)
)

cat(sprintf("Graph: %d nodes, %d edges\n", vcount(g), ecount(g)))

# ── 5. Betweenness centrality → corridor importance ──────────────────────────
# Normalised betweenness: 0 = unimportant node, 1 = key corridor bottleneck
edge_resistance_clean <- edge_resistance

eps <- min(edge_resistance_clean[edge_resistance_clean > 0], na.rm = TRUE) * 0.001

edge_resistance_clean[edge_resistance_clean <= 0] <- eps
E(g)$weight <- edge_resistance_clean
bc <- betweenness(g, weights = E(g)$weight, normalized = TRUE)

bc <- betweenness(g, weights = E(g)$weight, normalized = TRUE)

bc_df <- tibble(
  cell_id              = as.integer(V(g)$name),
  corridor_importance  = as.numeric(bc)
)

# ── 6. Fragmentation index ───────────────────────────────────────────────────
# Simple proxy: proportion of 8-neighbours that are NOT habitat (0 = all habitat, 1 = isolated)

# For each habitat cell, count non-habitat neighbours
nb_counts <- get.adjacency(g, sparse = FALSE) |> rowSums()
max_possible <- 8  # queen's case

fragmentation_df <- tibble(
  cell_id            = as.integer(V(g)$name),
  connected_nb_count = nb_counts
) |>
  mutate(fragmentation_index = 1 - connected_nb_count / max_possible)

# ── 7. Merge back to grid ─────────────────────────────────────────────────────

grid_conn <- grid |>
  left_join(bc_df, by = "cell_id") |>
  left_join(fragmentation_df, by = "cell_id") |>
  mutate(
    corridor_importance = replace_na(corridor_importance, 0),
    fragmentation_index = replace_na(fragmentation_index, 1)
  )

st_write(grid_conn, file.path(DATA_PROC, "grid_connectivity.gpkg"), delete_dsn = TRUE)
cat("Written: grid_connectivity.gpkg\n")
