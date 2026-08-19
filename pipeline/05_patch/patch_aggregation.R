# NatureGap — Step 05: Patch Aggregation
# Aggregates 20 m hex metrics to green-space patches.

library(sf)
library(tidyverse)
library(jsonlite)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))
source(here::here("05_residuals", "expected_model.R"), local = FALSE)
source(here::here("score_scaling.R"), local = FALSE)
source(here::here("cell_taxa.R"), local = FALSE)

HABITAT_THRESHOLD <- 0.40

# ── Patch-level expected richness (fitted species-area model) ─────────────────
# expected_richness is fitted per city from
#
#   effort_corrected_richness ~ patch_area_m2^SPECIES_AREA_Z + quality_modifier
#
# so it lands in the units it is subtracted from and the patch residual is a
# real residual (see 05_residuals/expected_model.R).
#
# SPECIES_AREA_Z stays a documented ASSUMPTION for the exponent — the area term's
# shape — and is defined in config.R. SPECIES_AREA_C is no longer used: the
# coefficient on the area term is fitted rather than asserted, which removes a
# tuning constant that previously set the whole scale. Unlike the hex scale,
# patch area genuinely varies, so an area term is meaningful here.
# See docs/methodology.md §6.2.

required_files <- c(PROC_GREEN_SPACES, PROC_GRID_RESID)
missing_files <- required_files[!file.exists(required_files)]
if (length(missing_files) > 0L) {
  stop(sprintf("Patch aggregation inputs missing: %s", paste(missing_files, collapse = ", ")), call. = FALSE)
}

green_spaces <- st_read(PROC_GREEN_SPACES, quiet = TRUE) |>
  st_transform(CRS_LOCAL)

hex <- st_read(PROC_GRID_RESID, quiet = TRUE) |>
  st_transform(CRS_LOCAL)

if (!"green_space_id" %in% names(green_spaces)) {
  stop("green_spaces.gpkg must contain green_space_id.", call. = FALSE)
}
if (!"green_space_id" %in% names(hex)) {
  overlap <- suppressWarnings(st_intersection(
    hex |> select(cell_id),
    green_spaces |> select(green_space_id)
  ))
  if (nrow(overlap) == 0L) {
    stop("grid_residuals.gpkg must contain green_space_id from the spatial base.", call. = FALSE)
  }
  overlap <- suppressWarnings(st_collection_extract(overlap, "POLYGON", warn = FALSE))
  overlap_rank <- overlap |>
    mutate(overlap_area_m2 = as.numeric(st_area(overlap))) |>
    st_drop_geometry() |>
    arrange(cell_id, desc(overlap_area_m2), green_space_id) |>
    group_by(cell_id) |>
    slice_head(n = 1L) |>
    ungroup() |>
    select(cell_id, green_space_id)
  hex <- hex |> left_join(overlap_rank, by = "cell_id")
}

for (col in c(
  "habitat_quality", "expected_richness", "species_richness",
  "observed_richness", "effort_corrected_richness", "survey_effort_units",
  "ecological_residual", "ecological_residual_normalized",
  "ecological_residual_mean", "ecological_residual_std", "corridor_importance",
  "betweenness_centrality", "tree_fraction", "veg_fraction", "ndvi_texture", "canopy_height_idx", "nature_gap_score", "fragmentation_index",
  "impact_score", "intervention_rank", "intervention_score", "path_km", "path_local_m", "n_obs",
  "accessibility_component"
)) {
  if (!col %in% names(hex)) hex[[col]] <- NA_real_
}

hex <- hex |>
  mutate(
    effort_corrected_richness = coalesce(effort_corrected_richness, observed_richness),
    observed_richness = coalesce(observed_richness, effort_corrected_richness),
    survey_effort_units = if_else(
      replace_na(path_local_m, 0) < MIN_PATH_M,
      NA_real_,
      coalesce(survey_effort_units, log1p(path_local_m))
    )
  )

if (!"is_unsampled" %in% names(hex)) {
  hex$is_unsampled <- replace_na(hex$path_local_m, 0) < MIN_PATH_M
}

hex <- hex |>
  filter(!is.na(green_space_id))

if (!"observed_dates_json" %in% names(hex)) hex$observed_dates_json <- "[]"
if (!"observer_ids_json" %in% names(hex)) hex$observer_ids_json <- "[]"

if (nrow(hex) == 0L) {
  stop("No hex cells are linked to green_space_id; cannot aggregate patches.", call. = FALSE)
}

finite_weighted_mean <- function(value, weight) {
  ok <- is.finite(value) & is.finite(weight) & weight > 0
  if (!any(ok)) return(NA_real_)
  stats::weighted.mean(value[ok], weight[ok])
}

finite_sum_or_na <- function(value) {
  ok <- is.finite(value)
  if (!any(ok)) return(NA_real_)
  sum(value[ok])
}

finite_weighted_sum <- function(value, weight) {
  ok <- is.finite(value) & is.finite(weight) & weight > 0
  if (!any(ok)) return(NA_real_)
  sum(value[ok] * weight[ok])
}

finite_median <- function(value) {
  value <- value[is.finite(value)]
  if (length(value) == 0L) return(NA_real_)
  stats::median(value)
}

finite_min <- function(value) {
  value <- value[is.finite(value)]
  if (length(value) == 0L) return(NA_real_)
  min(value)
}

finite_max <- function(value) {
  value <- value[is.finite(value)]
  if (length(value) == 0L) return(NA_real_)
  max(value)
}

fragmentation_edges <- function(patch_hex, all_hex) {
  if (nrow(patch_hex) == 0L) return(NA_real_)
  non_habitat <- all_hex |>
    filter(is.na(habitat_quality) | habitat_quality < HABITAT_THRESHOLD)
  if (nrow(non_habitat) == 0L) return(0)
  exposed <- st_intersection(
    st_boundary(st_union(st_geometry(patch_hex))),
    st_boundary(st_union(st_geometry(non_habitat)))
  )
  sum(as.numeric(st_length(exposed)), na.rm = TRUE)
}

patch_fragmentation <- lapply(green_spaces$green_space_id, function(pid) {
  patch_hex <- hex |> filter(green_space_id == pid)
  tibble(
    green_space_id = pid,
    fragmentation = suppressWarnings(fragmentation_edges(patch_hex, hex))
  )
}) |>
  bind_rows()

hex_overlap <- suppressWarnings(st_intersection(
  hex |> select(cell_id, green_space_id),
  green_spaces |> select(green_space_id)
))
hex_overlap$overlap_area_m2 <- as.numeric(st_area(hex_overlap))
hex_overlap <- hex_overlap |>
  filter(green_space_id == green_space_id.1) |>
  st_drop_geometry() |>
  select(cell_id, green_space_id, overlap_area_m2)

hex$full_cell_area_m2 <- as.numeric(st_area(hex))
hex_weighted <- hex |>
  left_join(hex_overlap, by = c("cell_id", "green_space_id")) |>
  mutate(
    overlap_area_m2 = coalesce(overlap_area_m2, full_cell_area_m2),
    overlap_fraction = if_else(full_cell_area_m2 > 0, overlap_area_m2 / full_cell_area_m2, 0),
    sampled_for_residual = !replace_na(is_unsampled, TRUE) & is.finite(ecological_residual)
  )

# ── Pooled patch observation totals ──────────────────────────────────────────
# A park's observed richness is a *ratio of pooled sums*, not a mean of per-cell
# ratios. Averaging 300 cells that each read "0 species / 4.8 effort units" is
# not an estimate of what the park holds: on the 2026-08-19 Porto export that
# average had median 0 and a maximum of 2.1 across 1,058 scored parks, while the
# largest park demonstrably holds 637 distinct taxa.
#
# Membership is exclusive — overlap_rank above assigns each cell to at most one
# green space — so both sides use whole-cell membership: a species cannot be
# prorated across a boundary, so neither is the effort that found it.
#
# Only sampled cells count, on both sides. An unsampled cell's effort is below
# threshold by definition, so including its taxa but not its effort would
# overstate richness per unit effort.
cell_taxa_lookup <- read_cell_taxa()

patch_pooled <- hex_weighted |>
  st_drop_geometry() |>
  filter(sampled_for_residual, !is.na(green_space_id)) |>
  group_by(green_space_id) |>
  summarise(
    pooled_species_richness = count_cell_taxa(cell_id, cell_taxa_lookup),
    pooled_effort_units = sum(survey_effort_units, na.rm = TRUE),
    pooled_sampled_cells = dplyr::n(),
    .groups = "drop"
  )

patch_base <- hex_weighted |>
  st_drop_geometry() |>
  group_by(green_space_id) |>
  summarise(
    habitat_quality_index = finite_weighted_mean(habitat_quality, overlap_area_m2),
    accessibility = finite_weighted_mean(accessibility_component, overlap_area_m2),
    observed_richness = finite_weighted_mean(
      observed_richness[sampled_for_residual],
      overlap_area_m2[sampled_for_residual]
    ),
    effort_corrected_richness = finite_weighted_mean(
      effort_corrected_richness[sampled_for_residual],
      overlap_area_m2[sampled_for_residual]
    ),
    survey_effort_units = finite_weighted_mean(
      survey_effort_units[sampled_for_residual],
      overlap_area_m2[sampled_for_residual]
    ),
    species_richness_raw = finite_weighted_mean(
      species_richness[sampled_for_residual],
      overlap_area_m2[sampled_for_residual]
    ),
    ecological_residual_mean = finite_weighted_mean(ecological_residual_mean, overlap_area_m2),
    ecological_residual_std = finite_weighted_mean(ecological_residual_std, overlap_area_m2),
    corridor_importance = finite_weighted_mean(corridor_importance, overlap_area_m2),
    betweenness_centrality = finite_weighted_mean(betweenness_centrality, overlap_area_m2),
    tree_fraction = finite_weighted_mean(tree_fraction, overlap_area_m2),
    veg_fraction = finite_weighted_mean(veg_fraction, overlap_area_m2),
    ndvi_texture = finite_weighted_mean(ndvi_texture, overlap_area_m2),
    canopy_height_idx = finite_weighted_mean(canopy_height_idx, overlap_area_m2),
    fragmentation_index = finite_weighted_mean(fragmentation_index, overlap_area_m2),
    impact_score = finite_median(impact_score),
    patch_intervention_score = finite_weighted_mean(intervention_score, overlap_area_m2),
    n_visits = sum(replace_na(n_obs, 0), na.rm = TRUE),
    sampled_area_m2 = sum(overlap_area_m2[sampled_for_residual], na.rm = TRUE),
    linked_area_m2 = sum(overlap_area_m2, na.rm = TRUE),
    sampled_cell_count = sum(sampled_for_residual, na.rm = TRUE),
    linked_cell_count = n(),
    .groups = "drop"
  ) |>
  mutate(
    intervention_rank = if_else(
      is.finite(patch_intervention_score),
      rank(-patch_intervention_score, ties.method = "first", na.last = "keep"),
      NA_real_
    )
  )

patch_area <- green_spaces |>
  transmute(
    green_space_id,
    patch_area_m2 = as.numeric(st_area(green_spaces))
  ) |>
  st_drop_geometry()

patch_metrics <- patch_base |>
  left_join(patch_fragmentation, by = "green_space_id") |>
  left_join(patch_area, by = "green_space_id") |>
  left_join(patch_pooled, by = "green_space_id") |>
  mutate(
    # quality_modifier: area-weighted mean of the patch's intensive quality
    # metrics (habitat quality, corridor importance, accessibility), clamped to
    # [0, 1]. Averaging IS appropriate here — these are intensive properties, not
    # counts — unlike richness, which must scale with total patch area below.
    quality_modifier = pmin(1, pmax(0, replace_na(
      rowMeans(
        cbind(habitat_quality_index, corridor_importance, accessibility),
        na.rm = TRUE
      ),
      0
    ))),
    # Area term of the species-area relationship. Its coefficient is fitted
    # below; only the exponent stays an assumption.
    area_term = patch_area_m2 ^ SPECIES_AREA_Z,
    # Ratio of pooled sums, replacing the area-weighted mean of per-cell ratios
    # that patch_base still computes for the intensive metrics. Falls back to
    # that mean only when no taxa file was available, so a missing
    # cell_taxa.json degrades rather than blanking the layer.
    pooled_effort_units = replace_na(pooled_effort_units, 0),
    effort_corrected_richness = case_when(
      sampled_cell_count == 0L ~ NA_real_,
      is.na(pooled_species_richness) ~ effort_corrected_richness,
      pooled_effort_units > 0 ~ pooled_species_richness / pooled_effort_units,
      TRUE ~ NA_real_
    ),
    observed_richness = effort_corrected_richness,
    survey_effort_units = if_else(
      sampled_cell_count == 0L | pooled_effort_units <= 0,
      NA_real_,
      pooled_effort_units
    ),
    # Distinct taxa pooled across the patch, not a mean or a sum of per-cell
    # counts. See cell_taxa.R on why a sum over cells is not a richness.
    species_richness_raw = if_else(
      sampled_cell_count == 0L,
      NA_real_,
      as.numeric(coalesce(as.numeric(pooled_species_richness), species_richness_raw))
    ),
    data_availability_ratio = if_else(linked_area_m2 > 0, sampled_area_m2 / linked_area_m2, NA_real_),
    fragmentation = coalesce(fragmentation_index, fragmentation)
  )

# Patches with no sampled cell have no observation to explain, so they are
# predicted but not fitted.
patch_expected_model <- fit_expected_model(
  train = patch_metrics |>
    st_drop_geometry() |>
    filter(replace_na(sampled_cell_count, 0L) > 0L),
  response    = "effort_corrected_richness",
  terms       = c("area_term", "quality_modifier"),
  min_rows    = EXPECTED_MODEL_MIN_PATCHES,
  scale_label = "patch"
)

record_expected_model("patch", patch_expected_model$record)

patch_metrics$expected_richness <- patch_expected_model$predict(
  st_drop_geometry(patch_metrics)
)

patch_metrics <- patch_metrics |>
  mutate(
    ecological_residual = if_else(
      sampled_cell_count == 0L,
      NA_real_,
      expected_richness - effort_corrected_richness
    )
  ) |>
  select(-area_term)

patch_finite_residuals <- patch_metrics$ecological_residual[is.finite(patch_metrics$ecological_residual)]
patch_residual_max <- if (length(patch_finite_residuals) > 0L) {
  max(abs(patch_finite_residuals))
} else {
  NA_real_
}
patch_residual_mean <- if (length(patch_finite_residuals) > 0L) {
  mean(patch_finite_residuals)
} else {
  NA_real_
}
patch_residual_sd <- if (length(patch_finite_residuals) > 1L) {
  stats::sd(patch_finite_residuals)
} else {
  NA_real_
}

patch_metrics <- patch_metrics |>
  mutate(
    ecological_residual_normalized = if_else(
      is.na(ecological_residual) | !is.finite(patch_residual_sd) | patch_residual_sd <= 0,
      NA_real_,
      (ecological_residual - patch_residual_mean) / patch_residual_sd
    ),
    habitat_quality_deficit = 1 - pmin(1, pmax(0, replace_na(habitat_quality_index, 0))),
    connectivity_deficit = 1 - pmin(1, pmax(0, replace_na(corridor_importance, 0)))
  )

# Same within-city centring as the hex score (score_scaling.R), with patch-level
# parameters: a park's score is relative to a typical scored park, not to a
# typical hex.
patch_scored <- !is.na(patch_metrics$ecological_residual)
patch_score_params <- list(
  biodiversity        = robust_centre_params(patch_metrics$ecological_residual[patch_scored]),
  habitatDeficit      = robust_centre_params(patch_metrics$habitat_quality_deficit[patch_scored]),
  connectivityDeficit = robust_centre_params(patch_metrics$connectivity_deficit[patch_scored])
)
record_score_scaling("patch", patch_score_params)

patch_metrics <- patch_metrics |>
  mutate(
    bio_residual_norm = apply_robust_centre(ecological_residual, patch_score_params$biodiversity),
    habitat_deficit_norm = apply_robust_centre(habitat_quality_deficit, patch_score_params$habitatDeficit),
    connectivity_deficit_norm = apply_robust_centre(connectivity_deficit, patch_score_params$connectivityDeficit),
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

stale_metric_cols <- c(
  "mean_hex_habitat_quality", "patch_habitat_quality", "corrected_richness",
  "observed_richness", "patch_corridor_importance", "n_dates", "n_observers",
  "patch_effort", "accessibility", "max_expected_richness", "nature_gap"
)

green_spaces_out <- green_spaces |>
  select(-any_of(c(names(patch_metrics)[names(patch_metrics) != "green_space_id"], stale_metric_cols))) |>
  left_join(patch_metrics, by = "green_space_id")

st_write(green_spaces_out, PROC_GREEN_SPACES_AGG, delete_dsn = TRUE)

cat(sprintf("Written: %s (%d green spaces)\n", PROC_GREEN_SPACES_AGG, nrow(green_spaces_out)))
