# NatureGap — Step 05: Patch Aggregation
# Aggregates 20 m hex metrics to green-space patches.

library(sf)
library(tidyverse)
library(jsonlite)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

HABITAT_THRESHOLD <- 0.40

required_files <- c(PROC_GREEN_SPACES, PROC_GRID_HABITAT, PROC_GRID_OBS, PROC_GRID_CONN)
missing_files <- required_files[!file.exists(required_files)]
if (length(missing_files) > 0L) {
  stop(sprintf("Patch aggregation inputs missing: %s", paste(missing_files, collapse = ", ")), call. = FALSE)
}

green_spaces <- st_read(PROC_GREEN_SPACES, quiet = TRUE) |>
  st_transform(CRS_LOCAL)

hab <- st_read(PROC_GRID_HABITAT, quiet = TRUE) |>
  st_transform(CRS_LOCAL)

obs <- st_read(PROC_GRID_OBS, quiet = TRUE) |>
  st_drop_geometry()

conn <- st_read(PROC_GRID_CONN, quiet = TRUE) |>
  st_drop_geometry()

if (!"green_space_id" %in% names(green_spaces)) {
  stop("green_spaces.gpkg must contain green_space_id.", call. = FALSE)
}
if (!"green_space_id" %in% names(hab)) {
  stop("grid_habitat.gpkg must contain green_space_id from the spatial base.", call. = FALSE)
}
if (!"betweenness_centrality" %in% names(conn)) {
  stop("grid_connectivity.gpkg must contain betweenness_centrality.", call. = FALSE)
}
if (!"raw_species_count" %in% names(obs)) {
  stop("grid_observations.gpkg must contain raw_species_count.", call. = FALSE)
}

hex <- hab |>
  select(-any_of("path_km")) |>
  left_join(
    obs |>
      select(
        cell_id, raw_species_count, path_km, n_obs,
        any_of(c("observed_dates_json", "observer_ids_json"))
      ),
    by = "cell_id"
  ) |>
  left_join(
    conn |> select(cell_id, betweenness_centrality),
    by = "cell_id"
  ) |>
  filter(!is.na(green_space_id))

if (!"observed_dates_json" %in% names(hex)) hex$observed_dates_json <- "[]"
if (!"observer_ids_json" %in% names(hex)) hex$observer_ids_json <- "[]"

if (nrow(hex) == 0L) {
  stop("No hex cells are linked to green_space_id; cannot aggregate patches.", call. = FALSE)
}

hex_sampled <- hex |>
  mutate(
    path_km = replace_na(path_km, 0),
    corrected_richness_i = if_else(
      path_km > 0,
      raw_species_count / log(1 + path_km),
      NA_real_
    )
  )

parse_json_values <- function(values) {
  values <- values[!is.na(values) & nzchar(values)]
  if (length(values) == 0L) return(character())
  unique(unlist(lapply(values, function(value) {
    parsed <- tryCatch(jsonlite::fromJSON(value), error = function(e) character())
    as.character(parsed)
  }), use.names = FALSE))
}

patch_base <- hex_sampled |>
  st_drop_geometry() |>
  group_by(green_space_id) |>
  summarise(
    mean_hex_habitat_quality = mean(habitat_quality, na.rm = TRUE),
    corrected_richness = sum(corrected_richness_i, na.rm = TRUE),
    sampled_cell_count = sum(!is.na(corrected_richness_i)),
    n_visits = sum(n_obs, na.rm = TRUE),
    n_dates = length(parse_json_values(observed_dates_json)),
    n_observers = length(parse_json_values(observer_ids_json)),
    patch_corridor_importance = max(betweenness_centrality, na.rm = TRUE),
    .groups = "drop"
  ) |>
  mutate(
    corrected_richness = if_else(sampled_cell_count == 0L, NA_real_, corrected_richness),
    patch_corridor_importance = if_else(
      is.infinite(patch_corridor_importance),
      NA_real_,
      patch_corridor_importance
    ),
    patch_effort = if_else(
      n_visits > 0 & n_observers == 0L,
      NA_real_,
      log(1 + n_visits * n_dates * sqrt(n_observers))
    ),
    accessibility = patch_effort
  )

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
    fragmentation = suppressWarnings(fragmentation_edges(patch_hex, hab))
  )
}) |>
  bind_rows()

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
    patch_habitat_quality = mean_hex_habitat_quality * log10(patch_area_m2 / 400),
    max_expected_richness = 80 * (patch_area_m2 / 400)^0.25,
    expected_richness = max_expected_richness * (
      0.65 * patch_habitat_quality +
        0.20 * patch_corridor_importance +
        0.15 * accessibility
    ),
    ecological_residual = expected_richness - corrected_richness
  )

green_spaces_out <- green_spaces |>
  select(-any_of(names(patch_metrics)[names(patch_metrics) != "green_space_id"])) |>
  left_join(patch_metrics, by = "green_space_id")

st_write(green_spaces_out, PROC_GREEN_SPACES_AGG, delete_dsn = TRUE)

cat(sprintf("Written: %s (%d green spaces)\n", PROC_GREEN_SPACES_AGG, nrow(green_spaces_out)))
