# NatureGap — Step 03: Biodiversity Observation Layer
# Aggregates citizen science records per cell with observer-effort correction.
#
# Key output: effort-corrected species richness per cell.
# Observer effort = distinct survey dates per cell (temporal sampling intensity,
# preferred over obs/km which conflates path coverage with observer behaviour).
#
# Inputs:
#   data/raw/inat_observations.gpkg
#   data/raw/gbif_observations.gpkg
#   data/processed/grid_habitat.gpkg   (cell grid with path_km field)
#
# Outputs:
#   data/processed/grid_observations.gpkg

library(sf)
library(tidyverse)
library(lubridate)
library(vegan)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

# ── 1. Load grid ──────────────────────────────────────────────────────────────

grid <- st_read(PROC_GRID_HABITAT, quiet = TRUE)

# ── 2. Load and standardise observations ──────────────────────────────────────
# Both sources are transformed to the grid CRS here and held in that CRS
# throughout — no round-trip through 4326.
#
# Dates are parsed with lubridate before rbind so both sources arrive as Date:
#   - iNat observed_on is typically "YYYY-MM-DD" (plain Date or character)
#   - GBIF eventDate can be "YYYY-MM-DDTHH:MM:SS" (ISO 8601 datetime string)
# as.Date() alone chokes on the datetime format, hence parse_date_time() for GBIF.

inat_std <- st_read(RAW_INAT, quiet = TRUE) |>
  st_transform(st_crs(grid)) |>
  mutate(
    taxon_name  = scientific_name,
    observed_on = as_date(observed_on)
  ) |>
  select(taxon_name, iconic_taxon_name, observed_on)

st_geometry(inat_std) <- "geometry"

gbif_std <- st_read(RAW_GBIF, quiet = TRUE) |>
  st_transform(st_crs(grid)) |>
  mutate(
    taxon_name        = species,
    iconic_taxon_name = class,
    observed_on       = as_date(
      parse_date_time(eventDate,
                      orders = c("Ymd", "Ymd HMS", "Ymd HMSz"),
                      quiet  = TRUE)
    )
  ) |>
  select(taxon_name, iconic_taxon_name, observed_on)

st_geometry(gbif_std) <- "geometry"

obs_all <- rbind(inat_std, gbif_std) |>
  filter(!is.na(taxon_name))

cat(sprintf("Total observations loaded: %d\n", nrow(obs_all)))

# ── 3. Spatial join to grid ───────────────────────────────────────────────────
# st_join is a left join: obs outside the study boundary receive cell_id = NA.
# These are dropped immediately rather than propagating as a spurious group.

obs_joined <- st_join(obs_all, grid |> select(cell_id, path_km)) |>
  filter(!is.na(cell_id))

cat(sprintf("Observations within study boundary: %d\n", nrow(obs_joined)))

# ── 4. Species richness per cell ─────────────────────────────────────────────
# n_distinct() has no na.rm — NAs are excluded by subsetting before passing in.

richness <- obs_joined |>
  st_drop_geometry() |>
  group_by(cell_id) |>
  summarise(
    n_obs            = n(),
    species_richness = n_distinct(taxon_name),
    n_survey_dates   = n_distinct(observed_on[!is.na(observed_on)]),
    .groups = "drop"
  )

# ── 5. Species-level Shannon diversity ────────────────────────────────────────
# Shannon is computed on species counts, not iconic-taxon groupings.
# The original iconic-taxon approach was ecologically unsound: GBIF class and
# iNat iconic_taxon_name are not equivalent fields, and both are too coarse
# (6–10 categories across all life) for meaningful within-study variation.

species_matrix <- obs_joined |>
  st_drop_geometry() |>
  count(cell_id, taxon_name) |>
  pivot_wider(names_from = taxon_name, values_from = n, values_fill = 0) |>
  column_to_rownames("cell_id")

shannon <- vegan::diversity(species_matrix, index = "shannon")

diversity_df <- tibble(
  cell_id         = as.integer(rownames(species_matrix)),
  species_shannon = shannon
)

# ── 5b. Taxonomic group counts (distinct taxa per UI category) ───────────────
# Maps iNaturalist iconic_taxon_name and GBIF class to the five frontend groups.

classify_taxon_group <- function(label) {
  x <- tolower(as.character(label))
  dplyr::case_when(
    is.na(x) | x == "" ~ NA_character_,
    x %in% c("plantae", "chromista") ~ "plant",
    grepl("^(plant|magnoli|pinopsida|liliopsida|polypodi)", x) ~ "plant",
    x == "aves" | grepl("bird", x) ~ "bird",
    x %in% c("insecta", "arachnida") | grepl("insect|spider|arthropod", x) ~ "insect",
    x %in% c("mammalia", "amphibia", "reptilia", "actinopterygii", "animalia") ~ "mammal",
    x == "fungi" | grepl("fung", x) ~ "fungi",
    TRUE ~ NA_character_
  )
}

taxon_counts <- obs_joined |>
  st_drop_geometry() |>
  mutate(taxon_group = classify_taxon_group(iconic_taxon_name)) |>
  filter(!is.na(taxon_group)) |>
  group_by(cell_id, taxon_group) |>
  summarise(count = n_distinct(taxon_name), .groups = "drop") |>
  pivot_wider(names_from = taxon_group, values_from = count, values_fill = 0)

for (col in c("plant", "bird", "insect", "mammal", "fungi")) {
  if (!col %in% names(taxon_counts)) taxon_counts[[col]] <- 0L
}

# ── 6. Effort correction ──────────────────────────────────────────────────────
# Corrected richness = species_richness / log1p(n_survey_dates)
#
# log1p is preferred over sqrt(effort + 1): it is standard in rarefaction-
# adjacent corrections and scales more conservatively at high effort.
# pmax(..., 1) guards against cells where all observed_on are NA (degenerate
# case: log1p(0) = 0 would produce division by zero).
#
# Note: this is a lightweight pre-correction only. Effort enters as a formal
# covariate in the residual model at Step 05.

richness_corrected <- richness |>
  left_join(grid |> st_drop_geometry() |> select(cell_id, path_km), by = "cell_id") |>
  left_join(diversity_df, by = "cell_id") |>
  left_join(taxon_counts, by = "cell_id") |>
  mutate(
    path_km            = replace_na(path_km, 0),
    richness_corrected = species_richness / log1p(pmax(n_survey_dates, 1))
  )

# ── 7. Merge back to grid and write ──────────────────────────────────────────

grid_obs <- grid |>
  left_join(richness_corrected |> select(-path_km), by = "cell_id") |>
  mutate(
    n_obs              = replace_na(n_obs, 0L),
    species_richness   = replace_na(species_richness, 0L),
    richness_corrected = replace_na(richness_corrected, 0),
    n_survey_dates     = replace_na(n_survey_dates, 0L),
    plant              = replace_na(plant, 0L),
    bird               = replace_na(bird, 0L),
    insect             = replace_na(insect, 0L),
    mammal             = replace_na(mammal, 0L),
    fungi              = replace_na(fungi, 0L)
  )

st_write(grid_obs, PROC_GRID_OBS, delete_dsn = TRUE)
cat(sprintf("Written: grid_observations.gpkg (%d cells)\n", nrow(grid_obs)))

