# NatureGap — Export approved Supabase observations for R
#
# Reads public.pipeline_observations_export and writes a city-local GeoPackage
# consumed by 03_observations/observation_layer.R.

library(sf)
library(tidyverse)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

run_supabase_observations_export <- function() {
db_url <- database_url()
required <- identical(Sys.getenv("SUPABASE_OBSERVATIONS_REQUIRED", unset = "0"), "1")
enabled <- required || identical(Sys.getenv("SUPABASE_OBSERVATIONS_ENABLED", unset = "0"), "1")

write_empty_supabase_observations <- function() {
  if (file.exists(RAW_SUPABASE_OBS)) return(invisible(NULL))
  empty <- st_sf(
    observation_id = character(),
    observation_source = character(),
    taxon_name = character(),
    iconic_taxon_name = character(),
    common_label = character(),
    observed_on = as.Date(character()),
    observation_weight = numeric(),
    observer_id = character(),
    gps_accuracy_m = numeric(),
    cell_id = character(),
    survey_id = character(),
    survey_duration_seconds = integer(),
    habitat_indicators = character(),
    geometry = st_sfc(crs = 4326)
  )
  st_write(empty, RAW_SUPABASE_OBS, delete_dsn = TRUE, quiet = TRUE)
  invisible(NULL)
}

skip_supabase_observations <- function(msg) {
  if (required) stop(msg, call. = FALSE)
  message(msg)
  write_empty_supabase_observations()
  return(invisible(NULL))
}

if (!enabled) {
  skip_supabase_observations(
    "Supabase observation export is disabled; continuing with existing or empty local observations."
  )
  return(invisible(NULL))
}

if (!nzchar(db_url)) {
  skip_supabase_observations(
    "DATABASE_URL is not set in this R session; skipping Supabase observation export."
  )
  return(invisible(NULL))
}

message(sprintf("Using DATABASE_URL for Supabase observation export: %s", describe_database_url(db_url)))

for (pkg in c("DBI", "RPostgres")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    skip_supabase_observations(sprintf(
      "Package '%s' is required to export Supabase observations. Install it or unset SUPABASE_OBSERVATIONS_REQUIRED.",
      pkg
    ))
    return(invisible(NULL))
  }
}

con <- tryCatch(
  connect_database(db_url),
  error = function(err) {
    skip_supabase_observations(sprintf(
      "Could not connect to PostgreSQL for Supabase observation export; continuing without Supabase observations. Error: %s",
      conditionMessage(err)
    ))
    NULL
  }
)
if (is.null(con)) return(invisible(NULL))
on.exit(DBI::dbDisconnect(con), add = TRUE)

query <- "
select
  observation_id,
  observation_source,
  taxon_name,
  iconic_taxon_name,
  common_label,
  observed_on,
  observation_weight,
  observer_id,
  gps_accuracy_m,
  cell_id,
  survey_id,
  survey_duration_seconds,
  habitat_indicators::text as habitat_indicators,
  lng,
  lat
from public.pipeline_observations_export
where city_id = $1
order by observation_source, observed_on, observation_id
"

rows <- tryCatch(
  DBI::dbGetQuery(con, query, params = list(CITY_ID)),
  error = function(err) {
    skip_supabase_observations(sprintf(
      "Could not query public.pipeline_observations_export; continuing without Supabase observations. Error: %s",
      conditionMessage(err)
    ))
    NULL
  }
)
if (is.null(rows)) return(invisible(NULL))

if (nrow(rows) == 0L) {
  observations <- st_sf(
    rows |> select(-lng, -lat),
    geometry = st_sfc(crs = 4326)
  )
} else {
  invalid <- rows |>
    filter(is.na(observation_id) | !nzchar(observation_id) | is.na(taxon_name) | !nzchar(taxon_name) | is.na(lng) | is.na(lat))
  if (nrow(invalid) > 0L) {
    stop(sprintf(
      "Supabase observation export contains %d invalid rows with missing IDs, taxa, or coordinates.",
      nrow(invalid)
    ), call. = FALSE)
  }

  observations <- rows |>
    mutate(
      observed_on = as.Date(observed_on),
      observation_weight = as.numeric(observation_weight),
      gps_accuracy_m = as.numeric(gps_accuracy_m)
    ) |>
    st_as_sf(coords = c("lng", "lat"), crs = 4326, remove = TRUE)
}

st_write(observations, RAW_SUPABASE_OBS, delete_dsn = TRUE, quiet = TRUE)
cat(sprintf(
  "Written: %s (%d approved Supabase observations for %s)\n",
  RAW_SUPABASE_OBS,
  nrow(observations),
  CITY_ID
))
}

run_supabase_observations_export()
