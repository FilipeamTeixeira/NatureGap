# NatureGap — Import versioned pipeline products to PostgreSQL
#
# Deterministic import contract:
#   manifest.json + cell_attributes.geojson + optional parks.geojson
#   -> public.import_pipeline_dataset(...)

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
  if (exists("DATA_VERSION") && nzchar(DATA_VERSION)) return(DATA_VERSION)

  current_path <- file.path(export_root, "current.json")
  if (!file.exists(current_path)) {
    stop(sprintf("Cannot resolve DATA_VERSION; missing %s", current_path), call. = FALSE)
  }
  current <- jsonlite::read_json(current_path, simplifyVector = FALSE)
  current$datasetId %||% current$dataVersion
}

`%||%` <- function(a, b) if (is.null(a) || !length(a) || !nzchar(as.character(a))) b else a

data_version <- resolve_data_version()
if (is.null(data_version) || !grepl("^[0-9]{8}T[0-9]{6}Z$", data_version)) {
  stop(sprintf("Invalid DATA_VERSION: %s", data_version %||% "<null>"), call. = FALSE)
}

version_dir <- file.path(export_root, data_version)
manifest_path <- file.path(version_dir, "manifest.json")
cell_path <- file.path(version_dir, "cell_attributes.geojson")
parks_path <- file.path(version_dir, "parks.geojson")

for (path in c(manifest_path, cell_path)) {
  if (!file.exists(path)) stop(sprintf("Required import product is missing: %s", path), call. = FALSE)
}

manifest <- jsonlite::read_json(manifest_path, simplifyVector = FALSE)
if (!identical(manifest$cityId, CITY_ID)) {
  stop(sprintf("Manifest cityId %s does not match configured CITY_ID %s.", manifest$cityId, CITY_ID), call. = FALSE)
}
if (!identical(manifest$datasetId %||% manifest$dataVersion, data_version)) {
  stop("Manifest datasetId/dataVersion does not match selected DATA_VERSION.", call. = FALSE)
}

validate_geojson_features <- function(path, id_field, label) {
  data <- jsonlite::read_json(path, simplifyVector = FALSE)
  if (!identical(data$type, "FeatureCollection")) {
    stop(sprintf("%s must be a GeoJSON FeatureCollection: %s", label, path), call. = FALSE)
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
    stop(sprintf("%s contains missing IDs.", basename(path)), call. = FALSE)
  }
  duplicates <- unique(ids[duplicated(ids)])
  if (length(duplicates) > 0L) {
    stop(sprintf(
      "%s contains duplicate IDs: %s",
      basename(path),
      paste(head(duplicates, 20), collapse = ", ")
    ), call. = FALSE)
  }

  missing_geometry <- vapply(features, function(feature) {
    is.null(feature$geometry) || identical(feature$geometry$type, NULL)
  }, logical(1))
  if (any(missing_geometry)) {
    stop(sprintf("%s contains %d features with missing geometry.", basename(path), sum(missing_geometry)), call. = FALSE)
  }

  data
}

cell_geojson <- validate_geojson_features(cell_path, "cell_id", "cell_attributes")
green_geojson <- if (file.exists(parks_path)) {
  validate_geojson_features(parks_path, "id", "parks")
} else {
  NULL
}

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
      jsonlite::toJSON(cell_geojson, auto_unbox = TRUE, null = "null"),
      if (is.null(green_geojson)) NA_character_ else jsonlite::toJSON(green_geojson, auto_unbox = TRUE, null = "null"),
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
}

run_postgres_import()
