# NatureGap — Import versioned pipeline products to PostgreSQL
#
# Deterministic import contract:
#   manifest.json + cell_attributes.geojson (or chunked parts + manifest)
#   + optional parks.geojson -> public.import_pipeline_dataset(...)
#
# Replace semantics (migration 20260723190000_pipeline_import_replace.sql):
#   each import purges prior rows for the target dataset_id, then promotes the
#   new snapshot as the active city projection. Re-importing current.json is safe.

library(jsonlite)
library(sf)
library(tidyverse)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

run_postgres_import <- function() {
db_url <- database_url()
required <- identical(Sys.getenv("POSTGRES_IMPORT_REQUIRED", unset = "0"), "1")
enabled <- required || identical(Sys.getenv("POSTGRES_IMPORT_ENABLED", unset = "0"), "1")
import_cell_attributes <- identical(Sys.getenv("POSTGRES_IMPORT_CELL_ATTRIBUTES", unset = "0"), "1")

skip_postgres_import <- function(msg) {
  if (required) stop(msg, call. = FALSE)
  message(msg)
  invisible(NULL)
}

if (!enabled) {
  skip_postgres_import(
    "PostgreSQL pipeline import is disabled; generated export files remain available for manual upload/import."
  )
  return(invisible(NULL))
}

if (!nzchar(db_url)) {
  skip_postgres_import("DATABASE_URL is not set in this R session; skipping PostgreSQL pipeline import.")
  return(invisible(NULL))
}

message(sprintf("Using DATABASE_URL for PostgreSQL pipeline import: %s", describe_database_url(db_url)))

for (pkg in c("DBI", "RPostgres")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    skip_postgres_import(sprintf(
      "Package '%s' is required to import pipeline products. Install it or unset POSTGRES_IMPORT_REQUIRED.",
      pkg
    ))
    return(invisible(NULL))
  }
}

repo_root <- if (basename(PIPELINE_ROOT) == "pipeline") dirname(PIPELINE_ROOT) else PIPELINE_ROOT
export_root <- file.path(repo_root, "pipeline-export", CITY_ID)

resolve_data_version <- function() {
  env_version <- Sys.getenv("NATUREGAP_DATA_VERSION", unset = "")
  if (nzchar(env_version)) return(env_version)

  version_has_manifest <- function(version) {
    file.exists(file.path(export_root, version, "manifest.json"))
  }

  current_path <- file.path(export_root, "current.json")
  if (file.exists(current_path)) {
    current <- jsonlite::read_json(current_path, simplifyVector = FALSE)
    current_version <- as.character(current$datasetId %||% current$dataVersion %||% "")
    if (nzchar(current_version)) {
      return(current_version)
    }
  }

  if (exists("DATA_VERSION", envir = .GlobalEnv) && nzchar(DATA_VERSION)) {
    if (version_has_manifest(DATA_VERSION)) {
      return(DATA_VERSION)
    }
    message(sprintf(
      "Ignoring stale session DATA_VERSION=%s (export folder missing); using current.json instead.",
      DATA_VERSION
    ))
  }

  stop(sprintf("Cannot resolve DATA_VERSION; missing %s", current_path), call. = FALSE)
}

# `%||%` <- function(a, b) if (is.null(a) || !length(a) || !nzchar(as.character(a))) b else a

`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0L) return(b)
  if (is.character(a) && length(a) == 1L && !nzchar(a)) return(b)
  a
}

data_version <- resolve_data_version()
if (is.null(data_version) || !grepl("^[0-9]{8}T[0-9]{6}Z$", data_version)) {
  stop(sprintf("Invalid DATA_VERSION: %s", data_version %||% "<null>"), call. = FALSE)
}

# Idempotency guard: export.R now triggers this import inline right after
# writing current.json, and run_pipeline.R's own 07_import step may also
# source this file immediately afterwards. Both may legitimately fire in the
# same R session — only run the DB promotion once per city/dataset per session.
import_done_key <- paste0(".naturegap_postgres_import_done__", CITY_ID)
if (identical(mget(import_done_key, envir = .GlobalEnv, ifnotfound = list(NULL))[[1]], data_version)) {
  message(sprintf(
    "PostgreSQL import already completed for %s / %s in this session; skipping duplicate run.",
    CITY_ID, data_version
  ))
  return(invisible(NULL))
}

version_dir <- file.path(export_root, data_version)
manifest_path <- file.path(version_dir, "manifest.json")
parks_path <- file.path(version_dir, "parks.geojson.gz")
if (!file.exists(parks_path)) {
  parks_path <- file.path(version_dir, "parks.geojson")
}

if (!file.exists(manifest_path)) {
  stop(sprintf(
    paste0(
      "Required import product is missing: %s\n",
      "  Resolved dataset: %s\n",
      "  current.json points to: %s\n",
      "  Restart R or set NATUREGAP_DATA_VERSION to an existing export folder."
    ),
    manifest_path,
    data_version,
    if (file.exists(file.path(export_root, "current.json"))) {
      as.character(jsonlite::read_json(file.path(export_root, "current.json"), simplifyVector = FALSE)$datasetId %||% "<unknown>")
    } else {
      "<missing>"
    }
  ), call. = FALSE)
}

manifest <- jsonlite::read_json(manifest_path, simplifyVector = FALSE)
if (!identical(manifest$cityId, CITY_ID)) {
  stop(sprintf("Manifest cityId %s does not match configured CITY_ID %s.", manifest$cityId, CITY_ID), call. = FALSE)
}
if (!identical(manifest$datasetId %||% manifest$dataVersion, data_version)) {
  stop("Manifest datasetId/dataVersion does not match selected DATA_VERSION.", call. = FALSE)
}

# Upsert legend/render percentile bounds. Cheap (one row per metric) and always
# runs — independent of POSTGRES_IMPORT_CELL_ATTRIBUTES. Conflict target matches
# primary key (city_id, metric) from 20260628120000_per_city_normalisation.sql.
upsert_city_layer_stats <- function(stats_df, con) {
  for (i in seq_len(nrow(stats_df))) {
    row <- stats_df[i, ]
    DBI::dbExecute(con, "
      insert into public.city_layer_stats
        (city_id, metric, min_val, max_val, p05, p10, p25, p50, p75, p90, p95, bound)
      values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
      on conflict (city_id, metric) do update set
        min_val = excluded.min_val, max_val = excluded.max_val,
        p05 = excluded.p05, p10 = excluded.p10, p25 = excluded.p25,
        p50 = excluded.p50, p75 = excluded.p75, p90 = excluded.p90,
        p95 = excluded.p95, bound = excluded.bound
    ", params = unname(as.list(row)))
  }
}

register_storage_dataset <- function(con, storage_prefix, manifest_storage_path, source_layer) {
  DBI::dbWithTransaction(con, {
    DBI::dbExecute(
      con,
      "
      update public.pipeline_datasets
      set is_active = false
      where city_id = $1
        and dataset_id <> $2
      ",
      params = list(CITY_ID, data_version)
    )

    DBI::dbExecute(
      con,
      "
      insert into public.pipeline_datasets (
        city_id, dataset_id, generated_at, storage_prefix, manifest_path, source_layer, is_active
      )
      values ($1, $2, $3::timestamptz, $4, $5, $6, true)
      on conflict (city_id, dataset_id) do update
      set generated_at = excluded.generated_at,
          storage_prefix = excluded.storage_prefix,
          manifest_path = excluded.manifest_path,
          source_layer = excluded.source_layer,
          is_active = true,
          updated_at = now()
      ",
      params = list(
        CITY_ID,
        data_version,
        manifest$generatedAt,
        storage_prefix,
        manifest_storage_path,
        source_layer
      )
    )
  })

  list(
    status = "registered_storage_dataset",
    cityId = CITY_ID,
    datasetId = data_version,
    storagePrefix = storage_prefix,
    manifestPath = manifest_storage_path,
    importedCellAttributes = FALSE
  )
}

list_cell_attribute_sources <- function(version_dir) {
  # Prefer the compressed product, falling back to the plain name so datasets
  # exported before compression still import.
  single_path <- file.path(version_dir, "cell_attributes.geojson.gz")
  if (!file.exists(single_path)) {
    single_path <- file.path(version_dir, "cell_attributes.geojson")
  }
  if (file.exists(single_path)) {
    return(list(single_path))
  }

  chunk_manifest_path <- file.path(version_dir, "cell_attributes.manifest.json")
  if (!file.exists(chunk_manifest_path)) {
    stop(sprintf(
      "Required import product is missing: %s (and no cell_attributes.manifest.json)",
      single_path
    ), call. = FALSE)
  }

  chunk_manifest <- jsonlite::read_json(chunk_manifest_path, simplifyVector = FALSE)
  chunk_names <- chunk_manifest$chunks %||% list()
  if (length(chunk_names) == 0L) {
    stop("cell_attributes.manifest.json contains no chunks.", call. = FALSE)
  }

  paths <- file.path(version_dir, chunk_names)
  missing <- paths[!file.exists(paths)]
  if (length(missing) > 0L) {
    stop(sprintf("Chunk file missing: %s", missing[[1L]]), call. = FALSE)
  }
  as.list(paths)
}

# The batch-import threshold is about how much GeoJSON *text* is handed to
# Postgres in one statement, so it must be measured on uncompressed bytes — a
# 21 MB .gz is ~450 MB of GeoJSON and would otherwise slip under the limit and
# be sent as a single statement. RFC 1952 records the uncompressed length
# modulo 2^32 in the trailing 4 bytes; these products are single-member gzip
# streams well under 4 GiB, so that value is exact.
uncompressed_size <- function(path) {
  if (!endsWith(path, ".gz")) return(unname(file.info(path)$size))
  con <- file(path, "rb")
  on.exit(close(con), add = TRUE)
  seek(con, where = -4L, origin = "end")
  sum(as.numeric(readBin(con, "raw", 4L)) * 256^(0:3))
}

use_batch_import <- function(sources) {
  length(sources) > 1L || (
    length(sources) == 1L &&
      uncompressed_size(sources[[1]]) > 40 * 1024^2
  )
}

batch_import_available <- function(con) {
  out <- DBI::dbGetQuery(
    con,
    "select to_regprocedure('public.import_pipeline_dataset_prepare(text,text,timestamptz,text,text,text)') is not null as ok"
  )
  isTRUE(out$ok[[1]])
}

replace_import_available <- function(con) {
  out <- DBI::dbGetQuery(
    con,
    "select to_regprocedure('public.purge_pipeline_dataset_snapshot(text,text)') is not null as ok"
  )
  isTRUE(out$ok[[1]])
}

# Export products are gzipped (see write_geojson in 06_export/export.R).
# gzfile() reads plain files transparently too, so both spellings work and
# datasets exported before compression still import unchanged.
open_geojson <- function(path) {
  if (endsWith(path, ".gz")) gzfile(path, "rb") else file(path, "rb")
}

read_geojson_text <- function(path) {
  con <- open_geojson(path)
  on.exit(close(con), add = TRUE)
  # The uncompressed size is not knowable up front for a gzip stream, so read
  # to exhaustion and join once rather than growing a buffer per block.
  chunks <- list()
  repeat {
    chunk <- readBin(con, "raw", 8L * 1024L^2)
    if (length(chunk) == 0L) break
    chunks[[length(chunks) + 1L]] <- chunk
  }
  if (length(chunks) == 0L) return("")
  text <- rawToChar(do.call(c, chunks))
  Encoding(text) <- "UTF-8"
  text
}

count_geojson_features <- function(path) {
  data <- jsonlite::fromJSON(read_geojson_text(path), simplifyVector = FALSE)
  length(data$features %||% list())
}

validate_geojson_features <- function(data, id_field, label, source = label) {
  if (!identical(data$type, "FeatureCollection")) {
    stop(sprintf("%s must be a GeoJSON FeatureCollection: %s", label, source), call. = FALSE)
  }
  features <- data$features %||% list()
  if (length(features) == 0L && identical(label, "cell_attributes")) {
    stop("cell_attributes.geojson contains no features.", call. = FALSE)
  }

  ids <- vapply(features, function(feature) {
    props <- feature$properties %||% list()
    value <- props[[id_field]] %||% props$cellId %||% props$id
    as.character(value %||% "")
  }, character(1))

  if (any(!nzchar(ids))) {
    stop(sprintf("%s contains missing IDs.", source), call. = FALSE)
  }
  duplicates <- unique(ids[duplicated(ids)])
  if (length(duplicates) > 0L) {
    stop(sprintf(
      "%s contains duplicate IDs: %s",
      source,
      paste(head(duplicates, 20), collapse = ", ")
    ), call. = FALSE)
  }

  missing_geometry <- vapply(features, function(feature) {
    is.null(feature$geometry) || identical(feature$geometry$type, NULL)
  }, logical(1))
  if (any(missing_geometry)) {
    stop(sprintf("%s contains %d features with missing geometry.", source, sum(missing_geometry)), call. = FALSE)
  }

  data
}

if (import_cell_attributes) {
  cell_sources <- list_cell_attribute_sources(version_dir)
  expected_cell_count <- sum(vapply(cell_sources, count_geojson_features, integer(1L)))
  message(sprintf(
    "Found %d cell_attributes source file(s) (%d features total)",
    length(cell_sources),
    expected_cell_count
  ))

  green_geojson <- if (file.exists(parks_path)) {
    validate_geojson_features(
      jsonlite::fromJSON(read_geojson_text(parks_path), simplifyVector = FALSE),
      "id",
      "parks",
      parks_path
    )
  } else {
    NULL
  }
  green_geojson_text <- if (is.null(green_geojson)) {
    NA_character_
  } else {
    jsonlite::toJSON(green_geojson, auto_unbox = TRUE, null = "null")
  }
} else {
  cell_sources <- list()
  expected_cell_count <- as.integer(manifest$counts$cells %||% manifest$counts$renderCells %||% 0L)
  green_geojson_text <- NA_character_
  message(
    paste0(
      "POSTGRES_IMPORT_CELL_ATTRIBUTES is not enabled; ",
      "registering the active Storage/PMTiles dataset without importing cell_attributes rows."
    )
  )
}

message("Connecting to PostgreSQL…")
con <- tryCatch(
  connect_database(db_url),
  error = function(err) {
    skip_postgres_import(sprintf(
      "Could not connect to PostgreSQL for pipeline import; generated export files remain available for manual upload/import. Error: %s",
      conditionMessage(err)
    ))
    NULL
  }
)
if (is.null(con)) return(invisible(NULL))
on.exit(DBI::dbDisconnect(con), add = TRUE)

#New stuff — privilege is enforced inside can_manage_pipeline_datasets(); no
# session JWT spoofing needed for direct postgres DATABASE_URL connections.
tryCatch({
  DBI::dbExecute(con, "SET role = 'postgres';")
}, error = function(e) {
  message("Warning: Could not set postgres role; import may fail if privileges are insufficient.")
})

tryCatch({
  DBI::dbExecute(con, "SET statement_timeout = '10min'")
}, error = function(e) {
  message("Warning: Could not disable statement_timeout.")
})

if (!replace_import_available(con)) {
  message(
    paste0(
      "Warning: purge_pipeline_dataset_snapshot is not installed; ",
      "re-importing an existing dataset_id may leave orphan rows or fail promotion. ",
      "Apply migration supabase/migrations/20260723190000_pipeline_import_replace.sql."
    )
  )
}

storage_prefix <- paste0("pipeline-export/", CITY_ID, "/", data_version, "/")
manifest_storage_path <- paste0(storage_prefix, "manifest.json")
source_layer <- manifest$sourceLayer %||% "hexgrid"

# city_layer_stats: always upsert when the file exists. Not gated by
# POSTGRES_IMPORT_CELL_ATTRIBUTES — one row per metric, not per hex.
city_layer_stats_path <- file.path(version_dir, "city_layer_stats.json")
if (file.exists(city_layer_stats_path)) {
  stats_df <- jsonlite::read_json(city_layer_stats_path, simplifyVector = TRUE)
  if (is.data.frame(stats_df) && nrow(stats_df) > 0L) {
    # Ensure column order matches the $1..$12 insert list.
    stats_df <- stats_df[, c(
      "city_id", "metric", "min_val", "max_val",
      "p05", "p10", "p25", "p50", "p75", "p90", "p95", "bound"
    )]
    message(sprintf("Upserting %d city_layer_stats row(s) for %s…", nrow(stats_df), CITY_ID))
    upsert_city_layer_stats(stats_df, con)
    message(sprintf("Upserted city_layer_stats (%d metrics)", nrow(stats_df)))
  } else {
    message(sprintf("city_layer_stats.json is empty; skipping stats upsert (%s)", city_layer_stats_path))
  }
} else {
  message(sprintf(
    "city_layer_stats.json not found at %s; skipping stats upsert (re-run export.R to generate it).",
    city_layer_stats_path
  ))
}

if (!import_cell_attributes) {
  result <- register_storage_dataset(con, storage_prefix, manifest_storage_path, source_layer)
  cat("PostgreSQL import complete:\n")
  cat(as.character(jsonlite::toJSON(result, auto_unbox = TRUE, pretty = TRUE)), "\n")
  assign(import_done_key, data_version, envir = .GlobalEnv)

  prune_script <- here::here("07_import", "prune_stale_storage.R")
  if (file.exists(prune_script)) {
    source(prune_script, local = FALSE)
    run_storage_prune_after_promotion(CITY_ID, con)
  } else {
    message("07_import/prune_stale_storage.R not found; stale Storage objects were not pruned.")
  }
  return(invisible(result))
}

if (use_batch_import(cell_sources)) {
  if (!batch_import_available(con)) {
    stop(
      paste0(
        "Large cell_attributes export requires batched import functions.\n",
        "Apply migration supabase/migrations/20260723180000_pipeline_import_batch.sql ",
        "then retry."
      ),
      call. = FALSE
    )
  }

  message("Preparing batched PostgreSQL import…")
  DBI::dbGetQuery(
    con,
    "select public.import_pipeline_dataset_prepare($1::text, $2::text, $3::timestamptz, $4::text, $5::text, $6::text)",
    params = list(
      CITY_ID,
      data_version,
      manifest$generatedAt,
      storage_prefix,
      manifest_storage_path,
      source_layer
    )
  )

  imported_cells <- 0L
  for (i in seq_along(cell_sources)) {
    source_path <- cell_sources[[i]]
    source_size_mb <- unname(file.info(source_path)$size) / 1024^2
    message(sprintf(
      "Importing cell batch %d/%d (%s, %.1f MB)…",
      i, length(cell_sources), basename(source_path), source_size_mb
    ))
    batch_count <- DBI::dbGetQuery(
      con,
      "select public.import_pipeline_dataset_cells_batch($1::text, $2::text, $3::timestamptz, $4::jsonb) as batch_count",
      params = list(
        CITY_ID,
        data_version,
        manifest$generatedAt,
        read_geojson_text(source_path)
      )
    )$batch_count[[1]]
    imported_cells <- imported_cells + as.integer(batch_count)
    message(sprintf("  → batch %d/%d imported (%d cells, %d total so far)", i, length(cell_sources), batch_count, imported_cells))
  }

  message("Finalizing import (green spaces + dataset promotion)…")
  result <- tryCatch(
    DBI::dbGetQuery(
      con,
      "select public.import_pipeline_dataset_finalize($1::text, $2::text, $3::timestamptz, $4::integer, $5::jsonb, $6::boolean) as result",
      params = list(
        CITY_ID,
        data_version,
        manifest$generatedAt,
        expected_cell_count,
        green_geojson_text,
        TRUE
      )
    ),
    error = function(err) {
      skip_postgres_import(sprintf(
        "Could not finalize batched pipeline import. Error: %s",
        conditionMessage(err)
      ))
      NULL
    }
  )
} else {
  cell_geojson_text <- read_geojson_text(cell_sources[[1]])
  message(sprintf(
    "Running import_pipeline_dataset (%.1f MB, %d cells)…",
    nchar(cell_geojson_text) / 1024^2,
    expected_cell_count
  ))
  result <- tryCatch(
    DBI::dbGetQuery(
      con,
      "
      select public.import_pipeline_dataset(
        $1::text,
        $2::text,
        $3::timestamptz,
        $4::text,
        $5::text,
        $6::text,
        $7::jsonb,
        $8::jsonb,
        $9::boolean
      ) as result
      ",
      params = list(
        CITY_ID,
        data_version,
        manifest$generatedAt,
        storage_prefix,
        manifest_storage_path,
        source_layer,
        cell_geojson_text,
        green_geojson_text,
        TRUE
      )
    ),
    error = function(err) {
      skip_postgres_import(sprintf(
        "Could not run public.import_pipeline_dataset; generated export files remain available for manual upload/import. Error: %s",
        conditionMessage(err)
      ))
      NULL
    }
  )
}
if (is.null(result)) return(invisible(NULL))

cat("PostgreSQL import complete:\n")
cat(as.character(result$result[[1]]), "\n")
assign(import_done_key, data_version, envir = .GlobalEnv)

prune_script <- here::here("07_import", "prune_stale_storage.R")
if (file.exists(prune_script)) {
  source(prune_script, local = FALSE)
  run_storage_prune_after_promotion(CITY_ID, con)
} else {
  message("07_import/prune_stale_storage.R not found; stale Storage objects were not pruned.")
}
}

run_postgres_import()
