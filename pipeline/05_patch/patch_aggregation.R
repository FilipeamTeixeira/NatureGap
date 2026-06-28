# NatureGap — Step 05: Patch Aggregation
# Aggregates 20 m hex metrics to green-space patches.

library(sf)
library(tidyverse)
library(jsonlite)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

HABITAT_THRESHOLD <- 0.40

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
  stop("grid_residuals.gpkg must contain green_space_id from the spatial base.", call. = FALSE)
}

for (col in c(
  "habitat_quality", "expected_richness", "species_richness",
  "observed_richness", "effort_corrected_richness", "survey_effort_units",
  "ecological_residual", "ecological_residual_normalized",
  "ecological_residual_mean", "ecological_residual_std", "corridor_importance",
  "betweenness_centrality", "nature_gap_score", "fragmentation_index", "impact_score", "intervention_rank",
  "intervention_score", "path_km", "n_obs"
)) {
  if (!col %in% names(hex)) hex[[col]] <- NA_real_
}

hex <- hex |>
  mutate(
    effort_corrected_richness = coalesce(effort_corrected_richness, observed_richness),
    observed_richness = coalesce(observed_richness, effort_corrected_richness),
    survey_effort_units = if_else(
      replace_na(path_km, 0) <= 0,
      NA_real_,
      coalesce(survey_effort_units, log1p(path_km))
    )
  )

if (!"is_unsampled" %in% names(hex)) hex$is_unsampled <- replace_na(hex$path_km, 0) <= 0

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

patch_base <- hex_weighted |>
  st_drop_geometry() |>
  group_by(green_space_id) |>
  summarise(
    habitat_quality_index = finite_weighted_mean(habitat_quality, overlap_area_m2),
    expected_richness = finite_weighted_mean(expected_richness, overlap_area_m2),
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
    ecological_residual = finite_weighted_mean(
      ecological_residual[sampled_for_residual],
      overlap_area_m2[sampled_for_residual]
    ),
    ecological_residual_normalized = finite_weighted_mean(
      ecological_residual_normalized[sampled_for_residual],
      overlap_area_m2[sampled_for_residual]
    ),
    ecological_residual_mean = finite_weighted_mean(ecological_residual_mean, overlap_area_m2),
    ecological_residual_std = finite_weighted_mean(ecological_residual_std, overlap_area_m2),
    corridor_importance = finite_weighted_mean(corridor_importance, overlap_area_m2),
    betweenness_centrality = finite_weighted_mean(betweenness_centrality, overlap_area_m2),
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
  mutate(
    effort_corrected_richness = if_else(sampled_cell_count == 0L, NA_real_, effort_corrected_richness),
    observed_richness = if_else(sampled_cell_count == 0L, NA_real_, observed_richness),
    survey_effort_units = if_else(sampled_cell_count == 0L, NA_real_, survey_effort_units),
    species_richness_raw = if_else(sampled_cell_count == 0L, NA_real_, species_richness_raw),
    ecological_residual = if_else(sampled_cell_count == 0L, NA_real_, ecological_residual),
    ecological_residual_normalized = if_else(sampled_cell_count == 0L, NA_real_, ecological_residual_normalized),
    data_availability_ratio = if_else(linked_area_m2 > 0, sampled_area_m2 / linked_area_m2, NA_real_),
    fragmentation = coalesce(fragmentation_index, fragmentation)
  )

patch_metrics <- patch_metrics |>
  mutate(
    bio_residual_norm = if_else(
      is.na(ecological_residual_normalized),
      NA_real_,
      pmax(-1, pmin(1, ecological_residual_normalized / 2))
    ),
    habitat_quality_deficit = 1 - pmin(1, pmax(0, replace_na(habitat_quality_index, 0))),
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
