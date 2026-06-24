# NatureGap — Step 05: Mismatch and Intervention Layer
# Computes the ecological residual and ranks cells for intervention.
#
# Ecological residual = observed richness (effort-corrected) − expected richness
# Negative residual → nature under pressure relative to habitat quality
# Positive residual → biodiversity surplus, potential unrecognised refuge
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

DATA_PROC <- here::here("data/processed")

W_RESIDUAL    <- 0.55  # weight on underperformance in composite score
W_CORRIDOR    <- 0.45  # weight on corridor importance
TOP_N         <- 20    # number of cells for counterfactual connectivity

# ── 1. Load and join layers ──────────────────────────────────────────────────

hab  <- st_read(file.path(DATA_PROC, "grid_habitat.gpkg"),     quiet = TRUE)
obs  <- st_read(file.path(DATA_PROC, "grid_observations.gpkg"),quiet = TRUE) |>
  st_drop_geometry() |>
  select(cell_id, richness_corrected, n_obs, species_shannon)

conn <- st_read(file.path(DATA_PROC, "grid_connectivity.gpkg"),quiet = TRUE) |>
  st_drop_geometry() |>
  select(cell_id, corridor_importance, fragmentation_index, patch_area_ha)

grid <- hab |>
  left_join(obs,  by = "cell_id") |>
  left_join(conn, by = "cell_id")

# ── 2. Expected richness from habitat quality ─────────────────────────────────
# Simple linear scaling: a cell at habitat_quality = 1.0 is expected to support
# MAX_EXPECTED species. This is deliberately simple and documented as an index,
# not a calibrated prediction.
#
# In future work, this should be replaced with a species distribution model
# trained on independent validation data.

MAX_EXPECTED <- 350  # rough upper bound for Yokohama urban biodiversity

grid <- grid |>
  mutate(
    expected_richness = habitat_quality * MAX_EXPECTED,
    richness_corrected = replace_na(richness_corrected, 0),
    ecological_residual = richness_corrected - expected_richness,
    underperformance = pmax(0, -ecological_residual)
  )

max_abs_residual <- max(abs(grid$ecological_residual), na.rm = TRUE)
# grid <- grid |>
#   mutate(
#     impact_score = if_else(
#       max_abs_residual == 0,
#       0,
#       round(ecological_residual / max_abs_residual * 50)
#     )
#   )

m <- max_abs_residual

if (m == 0) {
  grid <- grid |>
    mutate(impact_score = 0)
} else {
  grid <- grid |>
    mutate(impact_score = round(ecological_residual / m * 50))
}

# ── 3. Normalise components for composite score ───────────────────────────────

grid <- grid |>
  mutate(
    resid_range   = max(underperformance, na.rm = TRUE) - min(underperformance, na.rm = TRUE),
    resid_norm    = if_else(
      resid_range == 0,
      0,
      (underperformance - min(underperformance, na.rm = TRUE)) / resid_range
    ),
    corr_norm     = replace_na(corridor_importance, 0),
    composite     = W_RESIDUAL * resid_norm + W_CORRIDOR * corr_norm
  ) |>
  select(-resid_range)

# ── 4. Rank cells by composite score ─────────────────────────────────────────

grid <- grid |>
  mutate(intervention_rank = rank(-composite, ties.method = "first", na.last = "keep"))

top_cells <- grid |>
  st_drop_geometry() |>
  filter(!is.na(intervention_rank)) |>
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

st_write(grid, file.path(DATA_PROC, "grid_residuals.gpkg"), delete_dsn = TRUE)
write_csv(top_cells, file.path(DATA_PROC, "top_interventions.csv"))

cat("Written: grid_residuals.gpkg\n")
cat("Written: top_interventions.csv\n")
