# NatureGap — Step 03: Biodiversity Observation Layer
# Aggregates biodiversity records per cell with observer-effort correction.
#
# Key output: effort-corrected species richness per cell.
# Observer effort = accessible pedestrian path length from OSM. Cells with no
# accessible path are marked UNSAMPLED and excluded from downstream inference.
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
library(jsonlite)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

# ── 1. Load grid ──────────────────────────────────────────────────────────────

grid <- st_read(PROC_GRID_HABITAT, quiet = TRUE)

if (!"path_km" %in% names(grid)) {
  stop("grid_habitat.gpkg must contain path_km from OSM pedestrian paths", call. = FALSE)
}

# ── 2. Load and standardise observations ──────────────────────────────────────
# Both sources are transformed to the grid CRS here and held in that CRS
# throughout — no round-trip through 4326.
#
# Dates are parsed with lubridate before rbind so both sources arrive as Date:
#   - iNat observed_on is typically "YYYY-MM-DD" (plain Date or character)
#   - GBIF eventDate can be "YYYY-MM-DDTHH:MM:SS" (ISO 8601 datetime string)
# as.Date() alone chokes on the datetime format, hence parse_date_time() for GBIF.

inat_raw <- st_read(RAW_INAT, quiet = TRUE)
if (nrow(inat_raw) == 0L) {
  inat_std <- inat_raw |>
    mutate(
      taxon_name = character(),
      observed_on = as.Date(character()),
      common_label = character(),
      observation_source = character(),
      observation_weight = numeric()
    ) |>
    select(taxon_name, iconic_taxon_name, observed_on, common_label,
           observation_source, observation_weight)
} else {
  if (!"common_name" %in% names(inat_raw)) inat_raw$common_name <- NA_character_
  inat_std <- inat_raw |>
    st_transform(st_crs(grid)) |>
    mutate(
      taxon_name   = scientific_name,
      observed_on  = as_date(observed_on),
      common_label = as.character(common_name),
      observation_source = "inat",
      observation_weight = 1
    ) |>
    select(taxon_name, iconic_taxon_name, observed_on, common_label,
           observation_source, observation_weight)
}

st_geometry(inat_std) <- "geometry"

gbif_raw <- st_read(RAW_GBIF, quiet = TRUE)
if (nrow(gbif_raw) == 0L) {
  gbif_std <- gbif_raw |>
    mutate(
      taxon_name = character(),
      iconic_taxon_name = character(),
      observed_on = as.Date(character()),
      common_label = character(),
      observation_source = character(),
      observation_weight = numeric()
    ) |>
    select(taxon_name, iconic_taxon_name, observed_on, common_label,
           observation_source, observation_weight)
} else {
  if (!"vernacularName" %in% names(gbif_raw)) gbif_raw$vernacularName <- NA_character_
  if (!"class" %in% names(gbif_raw)) gbif_raw$class <- NA_character_
  gbif_std <- gbif_raw |>
    st_transform(st_crs(grid)) |>
    mutate(
      taxon_name        = species,
      iconic_taxon_name = class,
      observed_on       = as_date(
        parse_date_time(eventDate,
                        orders = c("Ymd", "Ymd HMS", "Ymd HMSz"),
                        quiet  = TRUE)
      ),
      common_label      = as.character(vernacularName),
      observation_source = "gbif",
      observation_weight = 1
    ) |>
    select(taxon_name, iconic_taxon_name, observed_on, common_label,
           observation_source, observation_weight)
}

st_geometry(gbif_std) <- "geometry"

obs_all <- rbind(inat_std, gbif_std) |>
  filter(!is.na(taxon_name)) |>
  mutate(
    observation_weight = replace_na(observation_weight, 1),
    is_structured_survey = observation_source == "structured_survey"
  )

cat(sprintf("Total observations loaded: %d\n", nrow(obs_all)))

# ── 3. Snap observations to nearest 20 m hex centroid ────────────────────────
# Raw observation geometry is preserved; only cell attribution is snapped.

if (nrow(obs_all) > 0L && nrow(grid) > 0L) {
  grid_centroids <- st_centroid(grid)
  nearest_idx <- st_nearest_feature(obs_all, grid_centroids)
  nearest_cells <- grid |>
    st_drop_geometry() |>
    select(cell_id, path_km) |>
    slice(nearest_idx)

  obs_joined <- obs_all |>
    mutate(
      cell_id = nearest_cells$cell_id,
      path_km = nearest_cells$path_km
    )
} else {
  obs_joined <- obs_all |>
    mutate(cell_id = integer(), path_km = numeric())
}

cat(sprintf("Observations snapped to 20 m hex cells: %d\n", nrow(obs_joined)))

# ── 4. Species richness per cell ─────────────────────────────────────────────
# n_distinct() has no na.rm — NAs are excluded by subsetting before passing in.

richness <- obs_joined |>
  st_drop_geometry() |>
  mutate(is_weekend = !is.na(observed_on) & wday(observed_on) %in% c(1L, 7L)) |>
  group_by(cell_id) |>
  summarise(
    n_obs            = n(),
    species_richness = n_distinct(taxon_name),
    n_survey_dates   = n_distinct(observed_on[!is.na(observed_on)]),
    weighted_observation_effort = sum(observation_weight, na.rm = TRUE),
    has_structured_survey = any(is_structured_survey, na.rm = TRUE),
    weekend_obs = sum(is_weekend, na.rm = TRUE),
    weekday_obs = sum(!is_weekend & !is.na(observed_on), na.rm = TRUE),
    weekend_only = weekend_obs > 0L & weekday_obs == 0L,
    temporal_bias_flag = weekend_only,
    .groups = "drop"
  )

# ── 5. Species-level Shannon diversity ────────────────────────────────────────
# Shannon is computed on species counts, not iconic-taxon groupings.
# The original iconic-taxon approach was ecologically unsound: GBIF class and
# iNat iconic_taxon_name are not equivalent fields, and both are too coarse
# (6–10 categories across all life) for meaningful within-study variation.

if (nrow(obs_joined) > 0L) {
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
} else {
  diversity_df <- tibble(cell_id = integer(), species_shannon = numeric())
}

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

# ── 5c. Taxon names per cell (for detail panel species lists) ─────────────────

format_taxon_label <- function(scientific, common) {
  sci <- as.character(scientific)
  com <- as.character(common)
  com <- com[!is.na(com) & nzchar(com)]
  if (length(com) > 0L) {
    return(paste0(com[1], " (", sci, ")"))
  }
  sci
}

cell_taxa_rows <- obs_joined |>
  st_drop_geometry() |>
  mutate(taxon_group = classify_taxon_group(iconic_taxon_name)) |>
  filter(!is.na(taxon_group), !is.na(taxon_name), nzchar(taxon_name)) |>
  group_by(cell_id, taxon_group, taxon_name) |>
  summarise(
    common_label = dplyr::first(na.omit(common_label)),
    .groups = "drop"
  ) |>
  rowwise() |>
  mutate(label = format_taxon_label(taxon_name, common_label)) |>
  ungroup() |>
  group_by(cell_id, taxon_group) |>
  summarise(names = list(sort(unique(label))), .groups = "drop") |>
  pivot_wider(names_from = taxon_group, values_from = names, values_fill = list(list()))

for (col in c("plant", "bird", "insect", "mammal", "fungi")) {
  if (!col %in% names(cell_taxa_rows)) cell_taxa_rows[[col]] <- list()
}

cell_taxa_out <- stats::setNames(
  lapply(seq_len(nrow(cell_taxa_rows)), function(i) {
    row <- cell_taxa_rows[i, ]
    stats::setNames(
      lapply(c("plant", "bird", "insect", "mammal", "fungi"), function(group) {
        val <- row[[group]][[1]]
        if (is.null(val) || length(val) == 0L) {
          list()
        } else {
          as.list(as.character(unlist(val)))
        }
      }),
      c("plant", "bird", "insect", "mammal", "fungi")
    )
  }),
  as.character(cell_taxa_rows$cell_id)
)

jsonlite::write_json(
  cell_taxa_out,
  PROC_CELL_TAXA,
  auto_unbox = TRUE,
  null = "null"
)
cat(sprintf("Written: %s (%d cells with taxa)\n", PROC_CELL_TAXA, length(cell_taxa_out)))

# ── 6. Effort correction ──────────────────────────────────────────────────────
# Corrected richness = species_richness / log1p(path_km)
#
# Cells with no accessible OSM pedestrian path length are marked unsampled and
# retain NA for corrected richness so they are excluded from inference.

richness_corrected <- richness |>
  left_join(grid |> st_drop_geometry() |> select(cell_id, path_km), by = "cell_id") |>
  left_join(diversity_df, by = "cell_id") |>
  left_join(taxon_counts, by = "cell_id") |>
  mutate(
    path_km            = replace_na(path_km, 0),
    is_unsampled       = path_km <= 0,
    effort_corrected_richness = if_else(
      is_unsampled,
      NA_real_,
      species_richness / log1p(path_km)
    ),
    richness_corrected = effort_corrected_richness
  )

# ── 7. Merge back to grid and write ──────────────────────────────────────────

grid_obs <- grid |>
  left_join(richness_corrected |> select(-path_km), by = "cell_id") |>
  mutate(
    is_unsampled        = replace_na(path_km <= 0, TRUE),
    n_obs              = replace_na(n_obs, 0L),
    species_richness   = if_else(is_unsampled, NA_integer_, replace_na(species_richness, 0L)),
    effort_corrected_richness = if_else(
      is_unsampled,
      NA_real_,
      replace_na(effort_corrected_richness, 0)
    ),
    richness_corrected = effort_corrected_richness,
    n_survey_dates     = replace_na(n_survey_dates, 0L),
    weighted_observation_effort = replace_na(weighted_observation_effort, 0),
    has_structured_survey = replace_na(has_structured_survey, FALSE),
    weekend_obs = replace_na(weekend_obs, 0L),
    weekday_obs = replace_na(weekday_obs, 0L),
    weekend_only = replace_na(weekend_only, FALSE),
    temporal_bias_flag = replace_na(temporal_bias_flag, FALSE),
    plant              = replace_na(plant, 0L),
    bird               = replace_na(bird, 0L),
    insect             = replace_na(insect, 0L),
    mammal             = replace_na(mammal, 0L),
    fungi              = replace_na(fungi, 0L)
  )

st_write(grid_obs, PROC_GRID_OBS, delete_dsn = TRUE)
cat(sprintf("Written: grid_observations.gpkg (%d cells)\n", nrow(grid_obs)))
