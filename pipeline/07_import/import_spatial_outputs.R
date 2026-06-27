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
    "habitat_quality", "path_km", "is_unsampled", "betweenness_centrality"
  )
  for (col in metric_cols) {
    if (!col %in% names(hex_cells)) hex_cells[[col]] <- NA
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
    from_cell_id = edges$from_cell_id,
    to_cell_id = edges$to_cell_id,
    weight = edges$weight,
    properties = "{}",
    geometry = st_sfc(link_geometries, crs = 4326)
  ) |>
    filter(!st_is_empty(geometry))

  green_import <- green_spaces |>
    mutate(
      city_id = CITY_ID,
      dataset_id = data_version,
      generated_at = generated_at,
      name = if ("name" %in% names(green_spaces)) as.character(name) else NA_character_,
      name_ja = if ("nameJa" %in% names(green_spaces)) as.character(nameJa) else NA_character_,
      ward_id = if ("wardId" %in% names(green_spaces)) as.character(wardId) else NA_character_,
      properties = "{}"
    ) |>
    select(city_id, dataset_id, green_space_id, generated_at, name, name_ja, ward_id, properties)

  hex_import <- hex_cells |>
    mutate(
      city_id = CITY_ID,
      dataset_id = data_version,
      cell_id = as.character(cell_id),
      green_space_id = as.character(green_space_id),
      properties = "{}"
    ) |>
    select(
      city_id, dataset_id, cell_id, green_space_id,
      habitat_quality, path_km, is_unsampled, betweenness_centrality,
      properties
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
        ward_id, geometry, properties, is_active
      )
      select city_id, dataset_id, green_space_id, generated_at, name, name_ja,
             ward_id, extensions.st_multi(geom)::geometry(MultiPolygon, 4326),
             properties::jsonb, true
      from %s
      on conflict (city_id, green_space_id) do update set
        dataset_id = excluded.dataset_id,
        generated_at = excluded.generated_at,
        name = excluded.name,
        name_ja = excluded.name_ja,
        ward_id = excluded.ward_id,
        geometry = excluded.geometry,
        properties = excluded.properties,
        is_active = true
      ",
      q_green
    ))

    DBI::dbExecute(con, sprintf(
      "
      insert into public.hex_cells (
        city_id, dataset_id, cell_id, green_space_id, geometry,
        habitat_quality, path_km, is_unsampled, betweenness_centrality,
        properties
      )
      select city_id, dataset_id, cell_id, nullif(green_space_id, ''),
             geom::geometry(Polygon, 4326),
             habitat_quality, path_km, is_unsampled, betweenness_centrality,
             properties::jsonb
      from %s
      on conflict (city_id, dataset_id, cell_id) do update set
        green_space_id = excluded.green_space_id,
        geometry = excluded.geometry,
        habitat_quality = excluded.habitat_quality,
        path_km = excluded.path_km,
        is_unsampled = excluded.is_unsampled,
        betweenness_centrality = excluded.betweenness_centrality,
        properties = excluded.properties
      ",
      q_hex
    ))

    DBI::dbExecute(con, sprintf(
      "
      insert into public.corridor_links (
        city_id, dataset_id, from_cell_id, to_cell_id, weight, geometry, properties
      )
      select city_id, dataset_id, from_cell_id, to_cell_id, weight,
             geom::geometry(LineString, 4326), properties::jsonb
      from %s
      on conflict (city_id, dataset_id, from_cell_id, to_cell_id) do update set
        weight = excluded.weight,
        geometry = excluded.geometry,
        properties = excluded.properties
      ",
      q_links
    ))
  })

  cat(sprintf(
    "Spatial PostgreSQL import complete: %d green spaces, %d hex cells, %d corridor links\n",
    nrow(green_import),
    nrow(hex_import),
    nrow(corridor_links)
  ))
}

run_spatial_outputs_import()
