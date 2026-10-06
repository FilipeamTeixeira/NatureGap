# NatureGap — Step 01: introduced-species sources
#
# Fetches what introduced_species.R combines, so that 05_opportunity can leave
# introduced species out of the opportunity gap without making requests:
#   - every configured GRIIS register (GBIF checklist datasets), shared by all
#     cities under GRIIS_CACHE_DIR, plus the city's island registers;
#   - the species iNaturalist flags as introduced inside BBOX_FETCH, per city
#     (RAW_INAT_INTRODUCED).
# Cached files are reused; delete them to refresh. Public APIs, no credentials.

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))
source(here::here("introduced_species.R"), local = FALSE)

if (!CITY_COUNTRY %in% names(GRIIS_DATASET_BY_COUNTRY)) {
  warning(sprintf(
    "No GRIIS register configured for %s — the opportunity gap will be skipped for %s.",
    CITY_COUNTRY, CITY_ID
  ), call. = FALSE)
} else {
  intro <- introduced_species(CITY_COUNTRY, BBOX_FETCH, fetch = TRUE)
  cat(sprintf(
    "Introduced species for %s: %d (%s); %d national entries kept as native (islands only)\n",
    CITY_ID, nrow(intro),
    paste(sprintf("%s %d", names(table(intro$source)), table(intro$source)), collapse = "; "),
    length(attr(intro, "island_only"))
  ))
  rm(intro)
}
