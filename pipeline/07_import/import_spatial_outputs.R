# NatureGap — Import spatial pipeline outputs to PostgreSQL
#
# Persists:
#   processed/green_spaces.gpkg -> public.green_spaces
#   processed/hex_cells.gpkg    -> public.hex_cells
#   processed/connectivity_graph.rds -> public.corridor_links

library(DBI)
library(sf)
library(tidyverse)
library(igraph)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

run_spatial_outputs_import <- function() {
  db_url <- database_url()
  required <- identical(Sys.getenv("SPATIAL_IMPORT_REQUIRED", unset = "0"), "1")
  enabled <- required || identical(Sys.getenv("SPATIAL_IMPORT_ENABLED", unset = "0"), "1")

  skip_spatial_import <- function(msg) {
    if (required) stop(msg, call. = FALSE)
    message(msg)
    invisible(NULL)
  }

  if (!enabled) {
    skip_spatial_import("Spatial PostgreSQL import is disabled; generated spatial files remain local.")
    return(invisible(NULL))
  }

  if (!nzchar(db_url)) {
    skip_spatial_import("DATABASE_URL is not set in this R session; skipping spatial PostgreSQL import.")
    return(invisible(NULL))
  }

  for (path in c(PROC_GREEN_SPACES, PROC_HEX_CELLS, PROC_CONNECTIVITY_GRAPH)) {
    if (!file.exists(path)) {
      stop(sprintf("Required spatial import product is missing: %s", path), call. = FALSE)
    }
  }

  data_version <- Sys.getenv("NATUREGAP_DATA_VERSION", unset = "")
  if (!nzchar(data_version) && exists("DATA_VERSION")) data_version <- DATA_VERSION
  if (!nzchar(data_version)) {
    data_version <- format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y%m%dT%H%M%SZ")
  }

  generated_at <- as.POSIXct(Sys.time(), tz = "UTC")
  con <- tryCatch(
    connect_database(db_url),
    error = function(err) {
      skip_spatial_import(sprintf(
        "Could not connect to PostgreSQL for spatial import. Error: %s",
        conditionMessage(err)
      ))
      NULL
    }
  )
  if (is.null(con)) return(invisible(NULL))
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  green_spaces <- st_read(PROC_GREEN_SPACES, quiet = TRUE) |>
    st_transform(4326)

  hex_cells <- st_read(PROC_HEX_CELLS, quiet = TRUE) |>
    st_transform(4326)

  # ── Per-city normalisation helpers ───────────────────────────────────────

  # norm_sequential: rescales x to [0, 1] using p5/p95 as floor/ceiling.
  # Values outside the range are clamped. If p5 == p95, returns 0.5.
  norm_sequential <- function(x) {
    finite_vals <- x[is.finite(x)]
    if (length(finite_vals) == 0L) return(rep(NA_real_, length(x)))
    p5  <- quantile(finite_vals, 0.05, names = FALSE)
    p95 <- quantile(finite_vals, 0.95, names = FALSE)
    if (!is.finite(p5) || !is.finite(p95) || p5 == p95) {
      return(rep(0.5, length(x)))
    }
    pmin(1, pmax(0, (x - p5) / (p95 - p5)))
  }

  # norm_diverging: rescales x to [-1, 1], keeping 0 anchored at 0.
  # Uses max(|p10|, |p90|) as symmetric bound. If bound == 0 or NA, returns 0.
  norm_diverging <- function(x) {
    finite_vals <- x[is.finite(x)]
    if (length(finite_vals) == 0L) return(rep(NA_real_, length(x)))
    p10 <- quantile(finite_vals, 0.10, names = FALSE)
    p90 <- quantile(finite_vals, 0.90, names = FALSE)
    bound <- max(abs(p10), abs(p90), na.rm = TRUE)
    if (!is.finite(bound) || bound == 0) return(rep(0, length(x)))
    pmin(1, pmax(-1, x / bound))
  }

  # norm_rank: maps intervention_rank to [0, 1] where rank 1 => 1.0.
  norm_rank <- function(x) {
    finite_vals <- x[is.finite(x)]
    if (length(finite_vals) == 0L) return(rep(NA_real_, length(x)))
    max_rank <- max(finite_vals)
    min_rank <- min(finite_vals)
    if (max_rank == min_rank) return(rep(1.0, length(x)))
    1 - ((x - min_rank) / (max_rank - min_rank))
  }

  # Helper: compute percentile stats for a numeric vector.
  metric_stats <- function(vals, diverging = FALSE) {
    finite_vals <- vals[is.finite(vals)]
    if (length(finite_vals) == 0L) {
      return(list(
        min_val = NA_real_, max_val = NA_real_,
        p05 = NA_real_, p10 = NA_real_, p25 = NA_real_,
        p50 = NA_real_, p75 = NA_real_, p90 = NA_real_, p95 = NA_real_,
        bound = NA_real_
      ))
    }
    p10 <- quantile(finite_vals, 0.10, names = FALSE)
    p90 <- quantile(finite_vals, 0.90, names = FALSE)
    list(
      min_val = min(finite_vals),
      max_val = max(finite_vals),
      p05     = quantile(finite_vals, 0.05, names = FALSE),
      p10     = p10,
      p25     = quantile(finite_vals, 0.25, names = FALSE),
      p50     = quantile(finite_vals, 0.50, names = FALSE),
      p75     = quantile(finite_vals, 0.75, names = FALSE),
      p90     = p90,
      p95     = quantile(finite_vals, 0.95, names = FALSE),
      bound   = if (diverging) max(abs(p10), abs(p90), na.rm = TRUE) else NA_real_
    )
  }

  # ── Green-space _norm columns ─────────────────────────────────────────────

  for (col in c(
    "habitat_quality_index", "effort_corrected_richness", "expected_richness",
    "corridor_importance", "mean_canopy", "mean_lst",
    "ecological_residual", "nature_gap_score", "intervention_rank"
  )) {
    if (!col %in% names(green_spaces)) green_spaces[[col]] <- NA_real_
  }

  green_spaces <- green_spaces |>
    mutate(
      habitat_quality_norm           = norm_sequential(habitat_quality_index),
      effort_corrected_richness_norm = norm_sequential(effort_corrected_richness),
      expected_richness_norm         = norm_sequential(expected_richness),
      corridor_importance_norm       = norm_sequential(corridor_importance),
      mean_canopy_norm               = norm_sequential(mean_canopy),
      mean_lst_norm                  = norm_sequential(mean_lst),
      ecological_residual_norm       = norm_diverging(ecological_residual),
      nature_gap_score_norm          = norm_diverging(nature_gap_score),
      intervention_rank_norm         = norm_rank(intervention_rank)
    )

  # ── Hex-cell _norm columns ────────────────────────────────────────────────

  for (col in c(
    "ndvi_idx", "canopy_height_idx", "lst_idx",
    "disturbance_idx", "betweenness_centrality", "ecological_residual", "nature_gap_score"
  )) {
    if (!col %in% names(hex_cells)) hex_cells[[col]] <- NA_real_
  }

  hex_cells <- hex_cells |>
    mutate(
      ndvi_norm             = norm_sequential(ndvi_idx),
      canopy_norm           = norm_sequential(canopy_height_idx),
      lst_norm              = norm_sequential(lst_idx),
      disturbance_norm      = norm_sequential(disturbance_idx),
      betweenness_norm      = norm_sequential(betweenness_centrality),
      residual_norm         = norm_diverging(ecological_residual),
      nature_gap_score_norm = norm_diverging(nature_gap_score)
    )

  # ── Compute city_layer_stats rows ─────────────────────────────────────────

  gs_df <- st_drop_geometry(green_spaces)

  patch_metric_specs <- list(
    list(metric = "habitat_quality_index",           diverging = FALSE),
    list(metric = "effort_corrected_richness",        diverging = FALSE),
    list(metric = "expected_richness",               diverging = FALSE),
    list(metric = "corridor_importance",             diverging = FALSE),
    list(metric = "mean_canopy",                     diverging = FALSE),
    list(metric = "mean_lst",                        diverging = FALSE),
    list(metric = "ecological_residual",             diverging = TRUE),
    list(metric = "nature_gap_score",                diverging = TRUE),
    list(metric = "intervention_rank",               diverging = FALSE)
  )

  hex_df <- st_drop_geometry(hex_cells)

  hex_metric_specs <- list(
    list(metric = "ndvi_idx",              diverging = FALSE),
    list(metric = "canopy_height_idx",     diverging = FALSE),
    list(metric = "lst_idx",              diverging = FALSE),
    list(metric = "disturbance_idx",       diverging = FALSE),
    list(metric = "betweenness_centrality",diverging = FALSE),
    list(metric = "ecological_residual",   diverging = TRUE),
    list(metric = "nature_gap_score",      diverging = TRUE)
  )

  stats_rows <- bind_rows(
    lapply(patch_metric_specs, function(spec) {
      vals <- as.numeric(gs_df[[spec$metric]])
      s <- metric_stats(vals, diverging = spec$diverging)
      tibble(
        city_id  = CITY_ID,
        metric   = spec$metric,
        min_val  = s$min_val,
        max_val  = s$max_val,
        p05      = s$p05,
        p10      = s$p10,
        p25      = s$p25,
        p50      = s$p50,
        p75      = s$p75,
        p90      = s$p90,
        p95      = s$p95,
        bound    = s$bound
      )
    }),
    lapply(hex_metric_specs, function(spec) {
      metric_key <- paste0("hex:", spec$metric)
      vals <- as.numeric(hex_df[[spec$metric]])
      s <- metric_stats(vals, diverging = spec$diverging)
      tibble(
        city_id  = CITY_ID,
        metric   = metric_key,
        min_val  = s$min_val,
        max_val  = s$max_val,
        p05      = s$p05,
        p10      = s$p10,
        p25      = s$p25,
        p50      = s$p50,
        p75      = s$p75,
        p90      = s$p90,
        p95      = s$p95,
        bound    = s$bound
      )
    })
  )

  graph <- readRDS(PROC_CONNECTIVITY_GRAPH)

  if (!inherits(graph, "igraph")) {
    stop("connectivity_graph.rds must contain an igraph object.", call. = FALSE)
  }
  if (!"cell_id" %in% names(hex_cells)) {
    stop("hex_cells.gpkg must contain cell_id.", call. = FALSE)
  }
  if (!"green_space_id" %in% names(hex_cells)) {
    hex_cells$green_space_id <- NA_character_
  }
  if (!"green_space_id" %in% names(green_spaces)) {
    stop("green_spaces.gpkg must contain green_space_id.", call. = FALSE)
  }

  metric_cols <- c(
    "habitat_quality", "ndvi_idx", "canopy_height_idx", "lst_idx",
    "disturbance_idx", "betweenness_centrality", "intervention_rank",
    "ecological_residual", "nature_gap_score"
  )
  for (col in metric_cols) {
    if (!col %in% names(hex_cells)) hex_cells[[col]] <- NA
  }
  for (col in c("tree_fraction", "shrub_fraction", "grass_fraction", "water_fraction", "built_fraction_wc", "bare_fraction")) {
    if (!col %in% names(hex_cells)) hex_cells[[col]] <- NA_real_
  }
  land_use_class <- function(tree, shrub, grass, water = NA_real_, built = NA_real_, bare = NA_real_) {
    tree_v <- replace_na(tree, -Inf)
    shrub_v <- replace_na(shrub, -Inf)
    grass_v <- replace_na(grass, -Inf)
    water_v <- replace_na(water, -Inf)
    built_v <- replace_na(built, -Inf)
    bare_v <- replace_na(bare, -Inf)
    max_v <- pmax(tree_v, shrub_v, grass_v, water_v, built_v, bare_v)
    case_when(
      !is.finite(max_v) ~ "unknown",
      max_v <= 0 ~ "unknown",
      tree_v == max_v ~ "tree",
      shrub_v == max_v ~ "shrub",
      grass_v == max_v ~ "grass",
      water_v == max_v ~ "water",
      built_v == max_v ~ "built",
      bare_v == max_v ~ "bare",
      TRUE ~ "mixed"
    )
  }

  vertices <- igraph::as_data_frame(graph, what = "vertices")
  edges <- igraph::as_data_frame(graph, what = "edges") |>
    mutate(
      from_cell_id = as.character(from),
      to_cell_id = as.character(to),
      weight = as.numeric(weight)
    )

  hex_centroids <- hex_cells |>
    select(cell_id) |>
    mutate(cell_id = as.character(cell_id)) |>
    st_centroid()

  centroid_lookup <- setNames(st_geometry(hex_centroids), hex_centroids$cell_id)

  link_geometries <- lapply(seq_len(nrow(edges)), function(i) {
    from_geom <- centroid_lookup[[edges$from_cell_id[[i]]]]
    to_geom <- centroid_lookup[[edges$to_cell_id[[i]]]]
    if (is.null(from_geom) || is.null(to_geom)) {
      return(st_linestring(matrix(numeric(), ncol = 2)))
    }
    from_xy <- st_coordinates(from_geom)
    to_xy <- st_coordinates(to_geom)
    st_linestring(rbind(from_xy[, c("X", "Y")], to_xy[, c("X", "Y")]))
  })

  corridor_links <- st_sf(
    city_id = CITY_ID,
    dataset_id = data_version,
    link_id = paste(edges$from_cell_id, edges$to_cell_id, sep = "--"),
    resistance = edges$weight,
    importance = if_else(is.finite(edges$weight), 1 / (1 + edges$weight), NA_real_),
    geometry = st_sfc(link_geometries, crs = 4326)
  ) |>
    filter(!st_is_empty(geometry))

  for (col in c(
    "habitat_quality_index", "effort_corrected_richness", "expected_richness",
    "ecological_residual", "nature_gap_score", "corridor_importance", "intervention_rank",
    "habitat_quality_norm", "effort_corrected_richness_norm", "expected_richness_norm",
    "corridor_importance_norm", "mean_canopy_norm", "mean_lst_norm",
    "ecological_residual_norm", "nature_gap_score_norm", "intervention_rank_norm"
  )) {
    if (!col %in% names(green_spaces)) green_spaces[[col]] <- NA_real_
  }

  green_import <- green_spaces |>
    mutate(
      city_id = CITY_ID,
      dataset_id = data_version,
      generated_at = generated_at,
      name = if ("name" %in% names(green_spaces)) as.character(name) else NA_character_,
      name_ja = if ("nameJa" %in% names(green_spaces)) as.character(nameJa) else NA_character_,
      ward_id = if ("wardId" %in% names(green_spaces)) as.character(wardId) else NA_character_
    ) |>
    select(
      city_id, dataset_id, green_space_id, generated_at, name, name_ja, ward_id,
      habitat_quality_index, effort_corrected_richness, expected_richness,
      ecological_residual, nature_gap_score, corridor_importance, intervention_rank,
      habitat_quality_norm, effort_corrected_richness_norm, expected_richness_norm,
      corridor_importance_norm, mean_canopy_norm, mean_lst_norm,
      ecological_residual_norm, nature_gap_score_norm, intervention_rank_norm
    )

  hex_import <- hex_cells |>
    mutate(
      city_id = CITY_ID,
      dataset_id = data_version,
      cell_id = as.character(cell_id),
      green_space_id = as.character(green_space_id),
      land_use_class = land_use_class(
        tree_fraction, shrub_fraction, grass_fraction,
        water_fraction, built_fraction_wc, bare_fraction
      )
    ) |>
    select(
      city_id, dataset_id, cell_id, green_space_id,
      habitat_quality, ndvi_idx, canopy_height_idx, lst_idx,
      disturbance_idx, land_use_class, betweenness_centrality,
      intervention_rank, ecological_residual, nature_gap_score,
      ndvi_norm, canopy_norm, lst_norm, disturbance_norm, betweenness_norm, residual_norm, nature_gap_score_norm
    )

  temp_suffix <- paste0("_", as.integer(runif(1, 1e6, 9e6)))
  temp_green <- paste0("tmp_green_spaces", temp_suffix)
  temp_hex <- paste0("tmp_hex_cells", temp_suffix)
  temp_links <- paste0("tmp_corridor_links", temp_suffix)

  DBI::dbWithTransaction(con, {
    st_write(green_import, con, DBI::Id(schema = "public", table = temp_green), quiet = TRUE, delete_layer = TRUE)
    st_write(hex_import, con, DBI::Id(schema = "public", table = temp_hex), quiet = TRUE, delete_layer = TRUE)
    st_write(corridor_links, con, DBI::Id(schema = "public", table = temp_links), quiet = TRUE, delete_layer = TRUE)

    q_green <- as.character(DBI::dbQuoteIdentifier(con, DBI::Id(schema = "public", table = temp_green)))
    q_hex <- as.character(DBI::dbQuoteIdentifier(con, DBI::Id(schema = "public", table = temp_hex)))
    q_links <- as.character(DBI::dbQuoteIdentifier(con, DBI::Id(schema = "public", table = temp_links)))

    on.exit({
      DBI::dbExecute(con, sprintf("drop table if exists %s", q_green))
      DBI::dbExecute(con, sprintf("drop table if exists %s", q_hex))
      DBI::dbExecute(con, sprintf("drop table if exists %s", q_links))
    }, add = TRUE)

    DBI::dbExecute(con, sprintf(
      "
      insert into public.green_spaces (
        city_id, dataset_id, green_space_id, generated_at, name, name_ja,
        ward_id, geometry, habitat_quality_index, effort_corrected_richness,
        expected_richness, ecological_residual, nature_gap_score, corridor_importance,
        intervention_rank, is_active,
        habitat_quality_norm, effort_corrected_richness_norm, expected_richness_norm,
        corridor_importance_norm, mean_canopy_norm, mean_lst_norm,
        ecological_residual_norm, nature_gap_score_norm, intervention_rank_norm
      )
      select city_id, dataset_id, green_space_id, generated_at, name, name_ja,
             ward_id, extensions.st_multi(geom)::geometry(MultiPolygon, 4326),
             habitat_quality_index, effort_corrected_richness, expected_richness,
             ecological_residual, nature_gap_score, corridor_importance, intervention_rank, true,
             habitat_quality_norm, effort_corrected_richness_norm, expected_richness_norm,
             corridor_importance_norm, mean_canopy_norm, mean_lst_norm,
             ecological_residual_norm, nature_gap_score_norm, intervention_rank_norm
      from %s
      on conflict (city_id, green_space_id) do update set
        dataset_id = excluded.dataset_id,
        generated_at = excluded.generated_at,
        name = excluded.name,
        name_ja = excluded.name_ja,
        ward_id = excluded.ward_id,
        geometry = excluded.geometry,
        habitat_quality_index = excluded.habitat_quality_index,
        effort_corrected_richness = excluded.effort_corrected_richness,
        expected_richness = excluded.expected_richness,
        ecological_residual = excluded.ecological_residual,
        nature_gap_score = excluded.nature_gap_score,
        corridor_importance = excluded.corridor_importance,
        intervention_rank = excluded.intervention_rank,
        is_active = true,
        habitat_quality_norm = excluded.habitat_quality_norm,
        effort_corrected_richness_norm = excluded.effort_corrected_richness_norm,
        expected_richness_norm = excluded.expected_richness_norm,
        corridor_importance_norm = excluded.corridor_importance_norm,
        mean_canopy_norm = excluded.mean_canopy_norm,
        mean_lst_norm = excluded.mean_lst_norm,
        ecological_residual_norm = excluded.ecological_residual_norm,
        nature_gap_score_norm = excluded.nature_gap_score_norm,
        intervention_rank_norm = excluded.intervention_rank_norm
      ",
      q_green
    ))

    DBI::dbExecute(con, sprintf(
      "
      insert into public.hex_cells (
        city_id, dataset_id, cell_id, green_space_id, geometry,
        habitat_quality, ndvi_idx, canopy_height_idx, lst_idx,
        disturbance_idx, land_use_class, betweenness_centrality,
        intervention_rank, ecological_residual, nature_gap_score,
        ndvi_norm, canopy_norm, lst_norm, disturbance_norm, betweenness_norm, residual_norm, nature_gap_score_norm
      )
      select city_id, dataset_id, cell_id, nullif(green_space_id, ''),
             geom::geometry(Polygon, 4326),
             habitat_quality, ndvi_idx, canopy_height_idx, lst_idx,
             disturbance_idx, land_use_class, betweenness_centrality,
             intervention_rank, ecological_residual, nature_gap_score,
             ndvi_norm, canopy_norm, lst_norm, disturbance_norm, betweenness_norm, residual_norm, nature_gap_score_norm
      from %s
      on conflict (city_id, dataset_id, cell_id) do update set
        green_space_id = excluded.green_space_id,
        geometry = excluded.geometry,
        habitat_quality = excluded.habitat_quality,
        ndvi_idx = excluded.ndvi_idx,
        canopy_height_idx = excluded.canopy_height_idx,
        lst_idx = excluded.lst_idx,
        disturbance_idx = excluded.disturbance_idx,
        land_use_class = excluded.land_use_class,
        betweenness_centrality = excluded.betweenness_centrality,
        intervention_rank = excluded.intervention_rank,
        ecological_residual = excluded.ecological_residual,
        nature_gap_score = excluded.nature_gap_score,
        ndvi_norm = excluded.ndvi_norm,
        canopy_norm = excluded.canopy_norm,
        lst_norm = excluded.lst_norm,
        disturbance_norm = excluded.disturbance_norm,
        betweenness_norm = excluded.betweenness_norm,
        residual_norm = excluded.residual_norm,
        nature_gap_score_norm = excluded.nature_gap_score_norm
      ",
      q_hex
    ))

    DBI::dbExecute(con, sprintf(
      "
      insert into public.corridor_links (
        city_id, dataset_id, link_id, geometry, resistance, importance
      )
      select city_id, dataset_id, link_id,
             geom::geometry(LineString, 4326), resistance, importance
      from %s
      on conflict (city_id, dataset_id, link_id) do update set
        geometry = excluded.geometry,
        resistance = excluded.resistance,
        importance = excluded.importance
      ",
      q_links
    ))
  })

  # ── Write city_layer_stats (upsert, outside main transaction) ────────────

  if (nrow(stats_rows) > 0L) {
    tmp_stats <- paste0("tmp_city_layer_stats", temp_suffix)
    DBI::dbWriteTable(con, DBI::Id(schema = "public", table = tmp_stats), stats_rows, overwrite = TRUE)
    on.exit(DBI::dbExecute(con, sprintf("drop table if exists public.%s",
      DBI::dbQuoteIdentifier(con, tmp_stats))), add = TRUE)

    DBI::dbExecute(con, sprintf(
      "
      insert into public.city_layer_stats
        (city_id, metric, min_val, max_val, p05, p10, p25, p50, p75, p90, p95, bound)
      select city_id, metric, min_val, max_val, p05, p10, p25, p50, p75, p90, p95, bound
      from public.%s
      on conflict (city_id, metric) do update set
        min_val = excluded.min_val,
        max_val = excluded.max_val,
        p05     = excluded.p05,
        p10     = excluded.p10,
        p25     = excluded.p25,
        p50     = excluded.p50,
        p75     = excluded.p75,
        p90     = excluded.p90,
        p95     = excluded.p95,
        bound   = excluded.bound
      ",
      DBI::dbQuoteIdentifier(con, tmp_stats)
    ))
    cat(sprintf("Written city_layer_stats: %d metric rows for city %s\n",
                nrow(stats_rows), CITY_ID))
  }

  cat(sprintf(
    "Spatial PostgreSQL import complete: %d green spaces, %d hex cells, %d corridor links\n",
    nrow(green_import),
    nrow(hex_import),
    nrow(corridor_links)
  ))
}

run_spatial_outputs_import()
