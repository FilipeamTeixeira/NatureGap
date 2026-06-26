# NatureGap — Step 05: Mismatch and Intervention Layer
# Computes the ecological residual and ranks cells for intervention.
#
# Ecological residual = expected richness − effort-corrected richness
# Positive residual → high habitat pressure
# Negative residual → potential refuge
#
# Intervention ranking:
#   intervention_score = (ecological_residual * 0.5) * (corridor_importance * 0.5)
#   Top-ranked cells get counterfactual connectivity estimates.
#
# Outputs:
#   data/processed/grid_residuals.gpkg  — full grid with all computed fields
#   data/processed/top_interventions.csv — top-ranked cells with estimates

library(sf)
library(tidyverse)
library(igraph)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

TOP_N         <- 20    # number of cells for counterfactual connectivity

# ── 1. Load and join layers ──────────────────────────────────────────────────

hab  <- st_read(PROC_GRID_HABITAT,     quiet = TRUE)
obs  <- st_read(PROC_GRID_OBS,quiet = TRUE) |>
  st_drop_geometry() |>
  select(cell_id, species_richness, richness_corrected,
         effort_corrected_richness, is_unsampled, n_obs, species_shannon,
         n_survey_dates, weighted_observation_effort, has_structured_survey,
         weekend_only, temporal_bias_flag,
         plant, bird, insect, mammal, fungi)

conn <- st_read(PROC_GRID_CONN,quiet = TRUE) |>
  st_drop_geometry() |>
  select(cell_id, corridor_importance, connectivity_score, node_importance,
         fragmentation_index, neighbor_fragmentation, edge_density,
         patch_isolation, patch_size_distribution, patch_area_ha)

grid <- hab |>
  left_join(obs,  by = "cell_id") |>
  left_join(conn, by = "cell_id")

# ── 2. Expected richness model ────────────────────────────────────────────────
# Uses existing habitat proxies, connectivity metrics, and path accessibility.
# Unsampled cells still receive an expected richness estimate, but their
# observed/corrected richness and residual stay NA and are excluded from ranking.

if (!exists("MAX_EXPECTED_RICHNESS")) MAX_EXPECTED_RICHNESS <- 350L

grid <- grid |>
  mutate(
    effort_corrected_richness = coalesce(effort_corrected_richness, richness_corrected),
    is_unsampled = if_else(
      is.na(is_unsampled),
      replace_na(path_km, 0) <= 0,
      is_unsampled
    ),
    max_path_km = max(path_km, na.rm = TRUE),
    habitat_component = replace_na(habitat_quality, 0),
    connectivity_component = pmin(1, pmax(0, replace_na(corridor_importance, 0))),
    accessibility_component = if_else(
      replace_na(path_km, 0) <= 0 | !is.finite(max_path_km) | max_path_km <= 0,
      0,
      pmin(1, log1p(path_km) / log1p(max_path_km))
    ),
    expected_richness = MAX_EXPECTED_RICHNESS * (
      0.65 * habitat_component +
      0.20 * connectivity_component +
      0.15 * accessibility_component
    ),
    ecological_residual = if_else(
      is_unsampled,
      NA_real_,
      expected_richness - effort_corrected_richness
    ),
    underperformance = pmax(0, ecological_residual)
  ) |>
  select(-max_path_km)

max_abs_residual <- max(abs(grid$ecological_residual), na.rm = TRUE)
# grid <- grid |>
#   mutate(
#     impact_score = if_else(
#       max_abs_residual == 0,
#       0,
#       round(ecological_residual / max_abs_residual * 50)
#     )
#   )

m <- if (is.finite(max_abs_residual)) max_abs_residual else NA_real_

if (is.na(m) || m == 0) {
  grid <- grid |>
    mutate(impact_score = 0)
} else {
  grid <- grid |>
    mutate(impact_score = if_else(
      is.na(ecological_residual),
      NA_real_,
      round(-ecological_residual / m * 50)
    ))
}

# ── 3. Intervention score and ranking ────────────────────────────────────────

grid <- grid |>
  mutate(
    intervention_score = (
      replace_na(ecological_residual, 0) * 0.5
    ) * (
      replace_na(corridor_importance, 0) * 0.5
    ),
    composite = intervention_score,
    intervention_rank = rank(-intervention_score, ties.method = "first", na.last = "keep")
  )

top_cells <- grid |>
  st_drop_geometry() |>
  filter(!is.na(intervention_rank), intervention_score > 0) |>
  arrange(intervention_rank) |>
  slice_head(n = TOP_N)

cat(sprintf("Top %d intervention cells identified\n", nrow(top_cells)))

# ── 4. Counterfactual connectivity for top cells ─────────────────────────────

counterfactual_gain <- function(grid_sf, target_cell_id, radius_m = CELL_SIZE * 4) {
  target <- grid_sf |> filter(cell_id == target_cell_id)
  if (nrow(target) != 1L) return(NA_real_)

  local_idx <- lengths(st_is_within_distance(st_centroid(grid_sf), st_centroid(target), dist = radius_m)) > 0
  local_grid <- grid_sf[local_idx, ]
  if (nrow(local_grid) < 3L) return(NA_real_)

  build_local_score <- function(local_grid, upgraded = FALSE) {
    qualities <- pmin(1, pmax(0, replace_na(local_grid$habitat_quality, 0)))
    if (upgraded) {
      qualities[local_grid$cell_id == target_cell_id] <- 1
    }
    pts <- st_centroid(local_grid)
    within <- st_is_within_distance(pts, pts, dist = CELL_SIZE * 1.15, sparse = TRUE)
    edges <- bind_rows(lapply(seq_along(within), function(i) {
      neighbors <- within[[i]]
      neighbors <- neighbors[neighbors > i]
      if (length(neighbors) == 0L) return(NULL)
      tibble(from = local_grid$cell_id[i], to = local_grid$cell_id[neighbors],
             from_idx = i, to_idx = neighbors)
    }))
    if (nrow(edges) == 0L) return(0)
    weights <- ((1 - qualities[edges$from_idx]) + (1 - qualities[edges$to_idx])) / 2
    eps <- min(weights[weights > 0], na.rm = TRUE) * 0.001
    if (!is.finite(eps) || eps <= 0) eps <- 1e-6
    g <- graph_from_data_frame(
      edges |> mutate(weight = pmax(weights, eps)) |> select(from, to, weight),
      directed = FALSE,
      vertices = tibble(name = local_grid$cell_id)
    )
    mean(betweenness(g, weights = E(g)$weight, normalized = TRUE), na.rm = TRUE)
  }

  baseline <- build_local_score(local_grid, upgraded = FALSE)
  upgraded <- build_local_score(local_grid, upgraded = TRUE)
  if (!is.finite(baseline) || baseline <= 0) return(NA_real_)
  (upgraded - baseline) / baseline * 100
}

top_cells <- top_cells |>
  mutate(
    connectivity_gain_pct = vapply(
      cell_id,
      \(cid) counterfactual_gain(grid, cid),
      numeric(1)
    ),
    counterfactual_note = "Local 20m-hex connectivity graph rerun with candidate cell upgraded to habitat quality 1.0"
  )

# ── 5. Assign intervention categories ────────────────────────────────────────

top_cells <- top_cells |>
  mutate(
    primary_action = case_when(
      corridor_importance > 0.7 ~ "Create or restore habitat corridor",
      fragmentation_index > 0.8 ~ "Reduce isolation — connect to nearest patch",

      coalesce(tree_fraction, green_fraction_wc, 0) < 0.10 ~
        "Increase canopy and green cover",

      coalesce(impervious_fraction, built_fraction_wc, 0) > 0.70 ~
        "Add shade trees to reduce heat",

      TRUE ~ "Increase native plant diversity"
    )
  )

# ── 6. Write outputs ─────────────────────────────────────────────────────────

st_write(grid, PROC_GRID_RESID, delete_dsn = TRUE)
write_csv(top_cells, PROC_TOP_INTER)

cell_attributes <- grid |>
  transmute(
    cell_id = paste0(CITY_ID, "-", cell_id),
    expected_richness,
    effort_corrected_richness,
    ecological_residual,
    corridor_importance,
    intervention_rank,
    intervention_score,
    heat_exposure,
    noise,
    light_pollution,
    disturbance_index,
    fragmentation = fragmentation_index,
    fragmentation_index,
    water_proximity,
    connectivity_score,
    node_importance,
    path_km,
    is_unsampled,
    temporal_bias_flag,
    last_updated = Sys.time()
  )

st_write(cell_attributes, PROC_CELL_ATTR, delete_dsn = TRUE)

cat("Written: grid_residuals.gpkg\n")
cat("Written: cell_attributes.gpkg\n")
cat("Written: top_interventions.csv\n")
