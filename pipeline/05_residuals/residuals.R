# NatureGap — Step 05: Mismatch and Intervention Layer
# Computes the ecological residual and ranks cells for intervention.
#
# Ecological residual = expected richness − effort-corrected richness
# Positive residual → fewer species recorded than habitat suggests
# Negative residual → more species recorded than habitat suggests
#
# expected_richness is the fitted conditional expectation of effort-corrected
# richness (05_residuals/expected_model.R), so both sides of that subtraction
# are the same quantity in the same units and the residual is centred on zero.
#
# Nature Gap score = composite headline (0.50 biodiversity + 0.30 habitat + 0.20 connectivity),
# scaled to [-100, 100] and separate from raw ecological_residual.
#
# Intervention ranking:
#   intervention_score = underperformance * corridor_importance weighting
#   Top-ranked cells get counterfactual connectivity estimates.
#
# Outputs:
#   data/processed/grid_residuals.gpkg  — full grid with all computed fields
#   data/processed/top_interventions.csv — top-ranked cells with estimates

library(sf)
library(tidyverse)
library(igraph)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

source(here::here("04_connectivity", "connectivity_load.R"), local = FALSE)
source(here::here("05_residuals", "expected_model.R"), local = FALSE)

TOP_N         <- 20    # number of cells for counterfactual connectivity

# ── 1. Load and join layers ──────────────────────────────────────────────────

grid <- if (file.exists(PROC_GRID_OBS)) {
  st_read(PROC_GRID_OBS, quiet = TRUE)
} else {
  st_read(PROC_GRID_HABITAT, quiet = TRUE)
}

grid <- grid |>
  select(-any_of(c(
    "is_unsampled", "corridor_importance", "connectivity_score",
    "betweenness_centrality", "path_node_id", "node_importance",
    "fragmentation_index", "neighbor_fragmentation", "edge_density",
    "patch_isolation", "patch_size_distribution", "patch_area_ha"
  )))

if ("is_unsampled" %in% names(grid)) {
  grid <- grid |> rename(obs_is_unsampled = is_unsampled)
} else {
  grid$obs_is_unsampled <- NA
}

conn <- join_connectivity_to_cells(grid)

grid <- grid |>
  left_join(conn, by = "cell_id")

if (!"betweenness_centrality" %in% names(grid)) {
  grid$betweenness_centrality <- grid$corridor_importance
}

# ── 2. Expected richness model ────────────────────────────────────────────────
# Habitat proxies, connectivity, and path accessibility are the predictors; the
# response is effort-corrected richness itself, fitted on this city's sampled
# cells. expected_richness is therefore in the units it is subtracted from
# (species per effort unit), and the residual is what the predictors could not
# account for.
#
# The previous formulation multiplied a [0,1] quality blend by
# SPECIES_AREA_C * (CELL_SIZE^2)^SPECIES_AREA_Z — a constant ≈ 53.7 at 20 m,
# identical for every hex, so it contributed scale and nothing else. It put
# expected richness near 20 while observed richness sits near 0.05, which made
# the "gap" an artefact of the scale clash rather than a measurement: on the
# 2026-08-19 exports ecological_residual correlated with expected_richness at
# 0.999 in all three cities and was positive in 99.99% of sampled cells. The
# species-area law now applies only where area actually varies (patch scale).
#
# Unsampled cells still receive an expected richness estimate, but their
# observed/corrected richness and residual stay NA and are excluded from ranking
# and from the fit.

if (!"path_local_m" %in% names(grid)) {
  stop(
    "path_local_m missing from the observation grid — re-run 02_habitat/03_observations ",
    "so neighbourhood path length is available before residuals.",
    call. = FALSE
  )
}

grid <- grid |>
  mutate(
    effort_corrected_richness = coalesce(effort_corrected_richness, richness_corrected),
    survey_effort_units = if_else(
      replace_na(path_local_m, 0) < MIN_PATH_M,
      NA_real_,
      coalesce(survey_effort_units, log1p(path_local_m))
    ),
    observed_richness = coalesce(observed_richness, effort_corrected_richness),
    is_unsampled = if_else(
      is.na(obs_is_unsampled),
      replace_na(path_local_m, 0) < MIN_PATH_M,
      obs_is_unsampled
    ),
    max_path_local_m = max(path_local_m, na.rm = TRUE),
    habitat_component = replace_na(habitat_quality, 0),
    connectivity_component = pmin(1, pmax(0, replace_na(corridor_importance, 0))),
    accessibility_component = if_else(
      replace_na(path_local_m, 0) < MIN_PATH_M | !is.finite(max_path_local_m) | max_path_local_m <= 0,
      0,
      pmin(1, log1p(path_local_m) / log1p(max_path_local_m))
    )
  ) |>
  select(-max_path_local_m, -obs_is_unsampled)

# Fit on sampled cells only: an unsampled cell has no observation to explain,
# and including its NA response would either drop it or bias the intercept.
expected_model <- fit_expected_model(
  train = grid |>
    st_drop_geometry() |>
    filter(!replace_na(is_unsampled, TRUE)),
  response    = "effort_corrected_richness",
  terms       = EXPECTED_MODEL_TERMS,
  min_rows    = EXPECTED_MODEL_MIN_CELLS,
  scale_label = "hex"
)

record_expected_model("hex", expected_model$record, reset = TRUE)

grid$expected_richness <- expected_model$predict(st_drop_geometry(grid))

grid <- grid |>
  mutate(
    ecological_residual = if_else(
      is_unsampled,
      NA_real_,
      expected_richness - effort_corrected_richness
    ),
    underperformance = pmax(0, ecological_residual)
  )

finite_residuals <- grid$ecological_residual[is.finite(grid$ecological_residual)]
city_residual_max <- if (length(finite_residuals) > 0L) max(abs(finite_residuals)) else NA_real_
city_residual_mean <- if (length(finite_residuals) > 0L) mean(finite_residuals) else NA_real_
city_residual_sd <- if (length(finite_residuals) > 1L) stats::sd(finite_residuals) else NA_real_

if (!is.finite(city_residual_max) || city_residual_max <= 0) {
  grid <- grid |>
    mutate(
      impact_score = 0,
      ecological_residual_mean = city_residual_mean,
      ecological_residual_std = city_residual_sd,
      ecological_residual_normalized = NA_real_,
      bio_residual_norm = NA_real_,
      nature_gap_score = NA_real_
    )
} else {
  grid <- grid |>
    mutate(
      ecological_residual_mean = city_residual_mean,
      ecological_residual_std = city_residual_sd,
      ecological_residual_normalized = if_else(
        is.na(ecological_residual) | !is.finite(city_residual_sd) | city_residual_sd <= 0,
        NA_real_,
        (ecological_residual - city_residual_mean) / city_residual_sd
      ),
      bio_residual_norm = if_else(
        is.na(ecological_residual),
        NA_real_,
        pmax(-1, pmin(1, ecological_residual / city_residual_max))
      ),
      impact_score = if_else(
        is.na(bio_residual_norm),
        NA_real_,
        round(bio_residual_norm * 50)
      ),
      habitat_quality_deficit = 1 - pmin(1, pmax(0, replace_na(habitat_quality, 0))),
      connectivity_deficit = 1 - pmin(1, pmax(0, replace_na(corridor_importance, 0))),
      nature_gap_score = if_else(
        is.na(bio_residual_norm),
        NA_real_,
        (
          0.50 * bio_residual_norm +
            0.30 * habitat_quality_deficit +
            0.20 * connectivity_deficit
        ) * 100
      )
    )
}

# ── 3. Intervention score and ranking ────────────────────────────────────────

grid <- grid |>
  mutate(
    intervention_score = (
      replace_na(underperformance, 0) * 0.5
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

  local_idx <- lengths(st_is_within_distance(
    suppressWarnings(st_centroid(grid_sf)),
    suppressWarnings(st_centroid(target)),
    dist = radius_m
  )) > 0
  local_grid <- grid_sf[local_idx, ]
  if (nrow(local_grid) < 3L) return(NA_real_)

  build_local_score <- function(local_grid, upgraded = FALSE) {
    qualities <- pmin(1, pmax(0, replace_na(local_grid$habitat_quality, 0)))
    if (upgraded) {
      qualities[local_grid$cell_id == target_cell_id] <- 1
    }
    pts <- suppressWarnings(st_centroid(local_grid))
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

# ── 6. Carry green_space_id from spatial base ────────────────────────────────
# Habitat/observation tiles rebuild cell_id locally and do not preserve the
# linkage written by 02_spatial/spatial_base.R. Re-attach by overlap area.

if (!"green_space_id" %in% names(grid) && file.exists(PROC_GREEN_SPACES)) {
  green_spaces_link <- st_read(PROC_GREEN_SPACES, quiet = TRUE) |>
    st_transform(st_crs(grid)) |>
    st_make_valid()
  overlap <- suppressWarnings(st_intersection(
    grid |> select(cell_id),
    green_spaces_link |> select(green_space_id)
  ))
  if (nrow(overlap) > 0L) {
    overlap <- suppressWarnings(st_collection_extract(overlap, "POLYGON", warn = FALSE))
    overlap_rank <- overlap |>
      mutate(overlap_area_m2 = as.numeric(st_area(overlap))) |>
      st_drop_geometry() |>
      arrange(cell_id, desc(overlap_area_m2), green_space_id) |>
      group_by(cell_id) |>
      slice_head(n = 1L) |>
      ungroup() |>
      select(cell_id, green_space_id)
    grid <- grid |> left_join(overlap_rank, by = "cell_id")
  } else {
    grid$green_space_id <- NA_character_
  }
}

# ── 7. Write outputs ─────────────────────────────────────────────────────────

st_write(grid, PROC_GRID_RESID, delete_dsn = TRUE)
write_csv(top_cells, PROC_TOP_INTER)

cell_attributes <- grid |>
  transmute(
    cell_id = paste0(CITY_ID, "-", cell_id),
    observed_richness,
    expected_richness,
    effort_corrected_richness,
    survey_effort_units,
    ecological_residual,
    ecological_residual_normalized,
    ecological_residual_mean,
    ecological_residual_std,
    nature_gap_score,
    corridor_importance,
    betweenness_centrality,
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
    path_local_m,
    is_unsampled,
    temporal_bias_flag,
    last_updated = Sys.time()
  )

st_write(cell_attributes, PROC_CELL_ATTR, delete_dsn = TRUE)

cat("Written: grid_residuals.gpkg\n")
cat("Written: cell_attributes.gpkg\n")
cat("Written: top_interventions.csv\n")
