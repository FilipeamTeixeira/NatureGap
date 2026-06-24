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

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

HAB_THRESHOLD    <- 0.40  # cells above this are "habitat" patches
CONN_RASTER_RES  <- max(CELL_SIZE * 5, 250)  # connectivity raster: coarser than grid

# ── 1. Load habitat grid ─────────────────────────────────────────────────────

grid <- st_read(PROC_GRID_HABITAT, quiet = TRUE) |>
  mutate(is_habitat = habitat_quality >= HAB_THRESHOLD)

cat(sprintf("Habitat cells: %d / %d\n", sum(grid$is_habitat), nrow(grid)))

# ── 2. Rasterize habitat class ───────────────────────────────────────────────

hab_rast <- rasterize(
  vect(grid),
  rast(ext(vect(grid)), res = CONN_RASTER_RES, crs = CRS_LOCAL),
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
# Nodes = habitat cells; edges = queen/diagonal neighbours within one cell step.
# Use CELL_SIZE (grid resolution), not CONN_RASTER_RES (patch-analysis raster).

hab_sf <- grid |> filter(is_habitat)
hab_pts <- st_centroid(hab_sf)
cell_ids <- hab_sf$cell_id
qualities <- hab_sf$habitat_quality

adj_threshold <- sqrt(2) * CELL_SIZE * 1.05  # diagonal neighbour + tolerance

within <- st_is_within_distance(hab_pts, hab_pts, dist = adj_threshold, sparse = TRUE)

edges_list <- lapply(seq_along(within), function(i) {
  neighbors <- within[[i]]
  neighbors <- neighbors[neighbors > i]
  if (length(neighbors) == 0) return(NULL)
  data.frame(
    from = cell_ids[i],
    to = cell_ids[neighbors],
    from_idx = i,
    to_idx = neighbors
  )
})
edges_df <- bind_rows(edges_list)

edge_resistance <- (
  (1 - qualities[edges_df$from_idx]) + (1 - qualities[edges_df$to_idx])
) / 2

edges_df$weight <- edge_resistance

g <- graph_from_data_frame(
  edges_df |> select(from, to, weight),
  directed = FALSE,
  vertices = data.frame(name = cell_ids)
)

cat(sprintf("Graph: %d nodes, %d edges\n", vcount(g), ecount(g)))

if (ecount(g) > vcount(g) * 12L) {
  warning(sprintf(
    "Graph has %d edges (expected ~6–8 per habitat cell). Check CELL_SIZE.",
    ecount(g)
  ), call. = FALSE)
}

# ── 5. Betweenness centrality → corridor importance ──────────────────────────
# Normalised betweenness: 0 = unimportant node, 1 = key corridor bottleneck
edge_resistance_clean <- edge_resistance

eps <- min(edge_resistance_clean[edge_resistance_clean > 0], na.rm = TRUE) * 0.001

edge_resistance_clean[edge_resistance_clean <= 0] <- eps
E(g)$weight <- edge_resistance_clean

cat("Computing betweenness centrality...\n")
bc <- betweenness(g, weights = E(g)$weight, normalized = TRUE)

bc_df <- tibble(
  cell_id              = as.integer(V(g)$name),
  corridor_importance  = as.numeric(bc)
)

# ── 6. Fragmentation index ───────────────────────────────────────────────────
# Simple proxy: proportion of 8-neighbours that are NOT habitat (0 = all habitat, 1 = isolated)

# For each habitat cell, count non-habitat neighbours
nb_counts <- get.adjacency(g, sparse = FALSE) |> rowSums()
max_possible <- if (CELL_SIZE <= 15) 6L else 8L  # hex ≈ 6 neighbours; square queen = 8

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

st_write(grid_conn, PROC_GRID_CONN, delete_dsn = TRUE)
cat("Written: grid_connectivity.gpkg\n")
