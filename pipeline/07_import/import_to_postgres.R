# NatureGap — Import versioned pipeline products to PostgreSQL
#
# Deterministic import contract:
#   manifest.json + cell_attributes.geojson (or chunked parts + manifest)
#   + optional parks.geojson -> public.import_pipeline_dataset(...)

library(jsonlite)
library(sf)
library(tidyverse)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

run_postgres_import <- function() {
db_url <- database_url()
required <- identical(Sys.getenv("POSTGRES_IMPORT_REQUIRED", unset = "0"), "1")
enabled <- required || identical(Sys.getenv("POSTGRES_IMPORT_ENABLED", unset = "0"), "1")

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
parks_path <- file.path(version_dir, "parks.geojson")

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

# Build one JSON text payload for PostgreSQL without holding every feature in
# memory and re-serializing the full collection again after chunk merge.
read_cell_attributes_geojson_text <- function(version_dir) {
  single_path <- file.path(version_dir, "cell_attributes.geojson")
  if (file.exists(single_path)) {
    message("Reading cell_attributes.geojson…")
    return(readChar(single_path, file.info(single_path)$size))
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

  tmp <- tempfile(fileext = ".geojson")
  con <- file(tmp, open = "wt")
  on.exit(close(con), add = TRUE)
  write('{"type":"FeatureCollection","features":[', con)

  total_features <- 0L
  for (i in seq_along(chunk_names)) {
    chunk_name <- chunk_names[[i]]
    chunk_path <- file.path(version_dir, chunk_name)
    if (!file.exists(chunk_path)) {
      stop(sprintf("Chunk file missing: %s", chunk_path), call. = FALSE)
    }
    message(sprintf(
      "  merging chunk %d/%d (%s)…",
      i, length(chunk_names), chunk_name
    ))
    chunk_data <- jsonlite::read_json(chunk_path, simplifyVector = FALSE)
    feats <- chunk_data$features %||% list()
    if (length(feats) == 0L) next
    chunk_text <- jsonlite::toJSON(feats, auto_unbox = TRUE, null = "null")
    inner <- substr(chunk_text, 2L, nchar(chunk_text) - 1L)
    if (total_features > 0L) write(",", con)
    write(inner, con)
    total_features <- total_features + length(feats)
    rm(chunk_data, feats, chunk_text, inner)
    gc(verbose = FALSE)
  }
  write("]}", con)
  close(con)
  on.exit(NULL)

  merged_size_mb <- file.info(tmp)$size / 1024^2
  message(sprintf(
    "Merged cell_attributes.geojson (%d features, %.1f MB)",
    total_features,
    merged_size_mb
  ))
  readChar(tmp, file.info(tmp)$size)
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

cell_geojson_text <- read_cell_attributes_geojson_text(version_dir)
message(sprintf(
  "Prepared cell_attributes payload (%.1f MB); PostgreSQL validates server-side",
  nchar(cell_geojson_text) / 1024^2
))
green_geojson <- if (file.exists(parks_path)) {
  validate_geojson_features(
    jsonlite::read_json(parks_path, simplifyVector = FALSE),
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

message("Running import_pipeline_dataset on PostgreSQL (120k cells — may take 5–15 minutes)…")
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
      paste0("pipeline-export/", CITY_ID, "/", data_version, "/"),
      paste0("pipeline-export/", CITY_ID, "/", data_version, "/manifest.json"),
      manifest$sourceLayer %||% "hexgrid",
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
if (is.null(result)) return(invisible(NULL))

cat("PostgreSQL import complete:\n")
cat(as.character(result$result[[1]]), "\n")
assign(import_done_key, data_version, envir = .GlobalEnv)
}

run_postgres_import()
