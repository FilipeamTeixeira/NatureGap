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
# separate from raw ecological_residual. Each term is centred on this city's
# median and scaled by a percentile spread (score_scaling.R), so the score is
# signed around a typical cell for this city rather than biased positive by two
# non-negative deficit terms.
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
source(here::here("score_scaling.R"), local = FALSE)

TOP_N         <- 20    # number of cells for counterfactual connectivity

# ── 1. Load and join layers ──────────────────────────────────────────────────

grid <- if (file.exists(PROC_GRID_OBS)) {
  st_read(PROC_GRID_OBS, quiet = TRUE)
} else {
  st_read(PROC_GRID_HABITAT, quiet = TRUE)
}

# traffic_exposure arrives via grid_observations (step 03 writes the cached
# combined grid wholesale). A dataset built before the field existed will not
# have it, and the cell_attributes transmute below is explicit, so default it.
if (!"traffic_exposure" %in% names(grid)) grid$traffic_exposure <- NA_real_

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
  response    = "species_richness",
  terms       = EXPECTED_MODEL_TERMS,
  min_rows    = EXPECTED_MODEL_MIN_CELLS,
  scale_label = "hex",
  offset_col  = "survey_effort_units"
)

record_expected_model("hex", expected_model$record, reset = TRUE)

grid$expected_richness <- expected_model$predict(st_drop_geometry(grid))

grid <- grid |>
  mutate(
    ecological_residual = if_else(
      is_unsampled,
      NA_real_,
      expected_richness - effort_corrected_richness
    )
  )

# Underperformance is floored at the sampled median, not at zero. A log-link fit
# minimises deviance rather than squared error, so the raw gap is not centred on
# the response scale: it is positive in ~90% of sampled cells on Porto. A zero
# floor would therefore exclude almost nothing and the intervention ranking would
# lose the filter it depends on (docs/methodology.md §10).
residual_median <- stats::median(
  grid$ecological_residual[is.finite(grid$ecological_residual)]
)
if (!is.finite(residual_median)) residual_median <- 0

grid <- grid |>
  mutate(underperformance = pmax(0, ecological_residual - residual_median))

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
      # Defined even here: intervention export and top_interventions.csv read
      # these columns unconditionally.
      habitat_quality_deficit = 1 - pmin(1, pmax(0, replace_na(habitat_quality, 0))),
      connectivity_deficit = 1 - pmin(1, pmax(0, replace_na(corridor_importance, 0))),
      habitat_deficit_norm = NA_real_,
      connectivity_deficit_norm = NA_real_,
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
      habitat_quality_deficit = 1 - pmin(1, pmax(0, replace_na(habitat_quality, 0))),
      connectivity_deficit = 1 - pmin(1, pmax(0, replace_na(corridor_importance, 0)))
    )

  # Centring parameters come from the scored cells only, so an unsampled cell
  # cannot move the median that scored cells are measured against.
  scored <- !is.na(grid$ecological_residual)
  score_params <- list(
    biodiversity        = robust_centre_params(grid$ecological_residual[scored]),
    habitatDeficit      = robust_centre_params(grid$habitat_quality_deficit[scored]),
    connectivityDeficit = robust_centre_params(grid$connectivity_deficit[scored])
  )
  record_score_scaling("hex", score_params, reset = TRUE)

  grid <- grid |>
    mutate(
      bio_residual_norm = apply_robust_centre(ecological_residual, score_params$biodiversity),
      habitat_deficit_norm = apply_robust_centre(habitat_quality_deficit, score_params$habitatDeficit),
      connectivity_deficit_norm = apply_robust_centre(connectivity_deficit, score_params$connectivityDeficit),
      impact_score = if_else(
        is.na(bio_residual_norm),
        NA_real_,
        round(bio_residual_norm * 50)
      ),
      nature_gap_score = if_else(
        is.na(bio_residual_norm),
        NA_real_,
        (
          0.50 * bio_residual_norm +
            0.30 * replace_na(habitat_deficit_norm, 0) +
            0.20 * replace_na(connectivity_deficit_norm, 0)
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

# ── 3b. Rank stability across CONN_MAX_RESISTANCE ────────────────────────────
# intervention_rank above is computed at the single baseline R and is left
# exactly as it was. This adds, alongside it, a measure of how much that rank
# depends on the assumption — see docs/sensitivity-analysis.md section 1, where
# only 5% of Amsterdam's baseline top-20 survives R = 100.
#
# rank_stability is the share of R values placing the cell in the top
# RANK_STABILITY_TOP_FRAC of scored cells. 1.0 means the cell ranks highly
# whether wildlife disperses easily or barely at all; a low value means the
# cell's position is an artefact of the chosen R, not a finding.

ens_cols <- grep("^corridor_importance_r[0-9]+$", names(grid), value = TRUE)

if (length(ens_cols) == 0L) {
  # Datasets built before the ensemble existed. NA, not 0: "not measured" and
  # "measured as unstable" must not look alike to a consumer.
  grid$rank_stability <- NA_real_
  grid$intervention_rank_ensemble <- NA_real_
  warning(
    "No corridor_importance_r* columns — rank stability unavailable. Re-run ",
    "04_connectivity/connectivity.R with FORCE_CONNECTIVITY=1.",
    call. = FALSE
  )
} else {
  # The whole chain must be re-run per R, not just the final multiplier.
  # corridor_importance is one of EXPECTED_MODEL_TERMS via connectivity_component
  # (05_residuals/expected_model.R:27), so R propagates through the refitted
  # expected-richness model into the residual and underperformance as well.
  # Varying only the multiplier understated the sensitivity: it reported 0.70
  # top-20 retention for Porto at R = 100 where the published sweep reports 0.45.
  #
  # This mirrors sensitivity/sweep_connectivity.R, and carries the same guard it
  # does: reproduce the pipeline's own baseline exactly first, or the numbers
  # below measure reconstruction error rather than sensitivity.
  ens_chain <- function(ci) {
    d <- grid
    d$connectivity_component <- pmin(1, pmax(0, replace_na(ci, 0)))
    d$habitat_component <- replace_na(d$habitat_quality, 0)
    m <- suppressWarnings(fit_expected_model(
      train = d |> st_drop_geometry() |>
        filter(!replace_na(is_unsampled, TRUE), is.finite(effort_corrected_richness)),
      response = "species_richness", terms = EXPECTED_MODEL_TERMS,
      min_rows = EXPECTED_MODEL_MIN_CELLS, scale_label = "ensemble",
      offset_col = "survey_effort_units"
    ))
    exp_r <- m$predict(st_drop_geometry(d))
    resid <- ifelse(replace_na(d$is_unsampled, TRUE), NA_real_,
                    exp_r - d$effort_corrected_richness)
    med <- stats::median(resid[is.finite(resid)])
    if (!is.finite(med)) med <- 0
    up <- pmax(0, resid - med)
    (replace_na(up, 0) * 0.5) * (replace_na(ci, 0) * 0.5)
  }

  base_col <- paste0("corridor_importance_r", CONN_MAX_RESISTANCE)
  if (base_col %in% ens_cols) {
    check <- max(abs(ens_chain(grid[[base_col]]) - grid$intervention_score), na.rm = TRUE)
    cat(sprintf("Ensemble baseline reproduction: max|diff| = %.3e\n", check))
    if (!is.finite(check) || check > 1e-8) {
      stop(sprintf(
        "Ensemble chain does not reproduce the pipeline baseline (max|diff| = %.3e). ",
        check), "Stability numbers would measure reconstruction error.", call. = FALSE)
    }
  }

  ens_scores <- vapply(ens_cols, function(cn) ens_chain(grid[[cn]]),
                       numeric(nrow(grid)))

  top_flag <- vapply(seq_len(ncol(ens_scores)), function(j) {
    v <- ens_scores[, j]
    scored <- is.finite(v) & v > 0
    out <- rep(FALSE, length(v))
    if (!any(scored)) return(out)
    keep <- head(order(-v), min(RANK_STABILITY_TOP_N, sum(scored)))
    out[keep] <- scored[keep]
    out
  }, logical(nrow(grid)))

  # Per-R overlap with the baseline top-N, directly comparable to the table in
  # docs/sensitivity-analysis.md section 1. Divergence there means the ensemble
  # and the published sweep disagree, and one of them is wrong.
  base_topn <- head(order(-grid$intervention_score), RANK_STABILITY_TOP_N)
  cat("Baseline top-", RANK_STABILITY_TOP_N, " retention by R:\n", sep = "")
  for (j in seq_along(ens_cols)) {
    cat(sprintf("  R=%-4s %.2f\n", sub("^corridor_importance_r", "", ens_cols[j]),
                mean(top_flag[base_topn, j])))
  }

  grid$rank_stability <- rowMeans(top_flag)
  med_score <- apply(ens_scores, 1, stats::median, na.rm = TRUE)
  grid$intervention_rank_ensemble <- rank(-med_score, ties.method = "first",
                                          na.last = "keep")

  cat(sprintf(
    "Rank stability over R = {%s}: %d cells stable in every run, %d in none\n",
    paste(sub("^corridor_importance_r", "", ens_cols), collapse = ", "),
    sum(grid$rank_stability == 1, na.rm = TRUE),
    sum(grid$rank_stability == 0, na.rm = TRUE)
  ))

  base_top <- head(order(-grid$intervention_score), TOP_N)
  cat(sprintf(
    "Baseline top-%d: %d of %d hold up across every R (mean stability %.2f)\n",
    TOP_N, sum(grid$rank_stability[base_top] == 1, na.rm = TRUE), TOP_N,
    mean(grid$rank_stability[base_top], na.rm = TRUE)
  ))
}

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

      # pmax(), not coalesce(): process_tile.R replace_na()s tree_fraction and
      # green_fraction_wc to 0 together, so tree_fraction is never NA when
      # green_fraction_wc is populated and coalesce() always returned the tree
      # term alone. A cell that is pure grassland with no trees was told to
      # "increase canopy and green cover" it already has. The impervious test
      # below keeps coalesce() on purpose — impervious_fraction is NA for the
      # whole grid when its raster is absent, so falling back to the WorldCover
      # built fraction is the intended behaviour there.
      coalesce(pmax(tree_fraction, green_fraction_wc, na.rm = TRUE), 0) < 0.10 ~
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
    rank_stability,
    intervention_rank_ensemble,
    traffic_exposure,
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
