# NatureGap — Step 05: Mismatch and Intervention Layer
# Computes the ecological residual and ranks cells for intervention.
#
# Ecological residual = expected richness − effort-corrected richness
# Positive residual → high habitat pressure
# Negative residual → potential refuge
#
# Intervention ranking:
#   composite_score = w1 * normalised_underperformance + w2 * corridor_importance
#   Top-ranked cells get counterfactual connectivity estimates (re-run graph
#   with candidate cell reclassified as habitat, measure betweenness change).
#
# Outputs:
#   data/processed/grid_residuals.gpkg  — full grid with all computed fields
#   data/processed/top_interventions.csv — top-ranked cells with estimates

library(sf)
library(tidyverse)
library(igraph)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

W_RESIDUAL    <- 0.55  # weight on underperformance in composite score
W_CORRIDOR    <- 0.45  # weight on corridor importance
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
  select(cell_id, corridor_importance, fragmentation_index, patch_area_ha)

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

# ── 3. Normalise components for composite score ───────────────────────────────

grid <- grid |>
  mutate(
    resid_range   = max(underperformance, na.rm = TRUE) - min(underperformance, na.rm = TRUE),
    resid_norm    = if_else(
      is_unsampled | !is.finite(resid_range) | resid_range == 0,
      0,
      (underperformance - min(underperformance, na.rm = TRUE)) / resid_range
    ),
    corr_norm     = replace_na(corridor_importance, 0),
    composite     = W_RESIDUAL * resid_norm + W_CORRIDOR * corr_norm
  ) |>
  select(-resid_range)

# ── 4. Rank cells by composite score ─────────────────────────────────────────

grid <- grid |>
  mutate(
    intervention_rank = if_else(
      is_unsampled,
      NA_real_,
      rank(-composite, ties.method = "first", na.last = "keep")
    )
  )

top_cells <- grid |>
  st_drop_geometry() |>
  filter(!is.na(intervention_rank), !is_unsampled) |>
  arrange(intervention_rank) |>
  slice_head(n = TOP_N)

cat(sprintf("Top %d intervention cells identified\n", nrow(top_cells)))

# ── 5. Counterfactual connectivity for top cells ──────────────────────────────
# Re-run graph with each top cell reclassified as habitat (quality = 1.0)
# and measure change in mean betweenness of adjacent cells.
# NOTE: full re-run is slow for large grids; only TOP_N cells are evaluated.

# (Placeholder — requires connectivity graph from step 04 to be in memory.
#  In production, source("04_connectivity/connectivity.R") first or use targets.)

top_cells <- top_cells |>
  mutate(
    connectivity_gain_pct = NA_real_,  # populated by counterfactual loop
    counterfactual_note   = "Counterfactual not yet computed — run full pipeline"
  )

# ── 6. Assign intervention categories ────────────────────────────────────────

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

# ── 7. Write outputs ─────────────────────────────────────────────────────────

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
    heat_exposure = lst_rank,
    noise = NA_real_,
    light_pollution = NA_real_,
    fragmentation = fragmentation_index,
    water_proximity = NA_real_,
    connectivity_score = corridor_importance,
    path_km,
    is_unsampled,
    temporal_bias_flag,
    last_updated = Sys.time()
  )

st_write(cell_attributes, PROC_CELL_ATTR, delete_dsn = TRUE)

cat("Written: grid_residuals.gpkg\n")
cat("Written: cell_attributes.gpkg\n")
cat("Written: top_interventions.csv\n")
