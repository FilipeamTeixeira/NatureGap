# NatureGap — Step 03: Biodiversity Observation Layer
# Aggregates citizen science records per cell with observer-effort correction.
#
# Key output: effort-corrected species richness per cell.
# Observer effort = observations per km of accessible path per cell.
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
library(vegan)   # for diversity indices

DATA_RAW  <- here::here("data/raw")
DATA_PROC <- here::here("data/processed")

# ── 1. Load grid and observations ────────────────────────────────────────────

grid <- st_read(file.path(DATA_PROC, "grid_habitat.gpkg"), quiet = TRUE)

inat <- st_read(file.path(DATA_RAW, "inat_observations.gpkg"), quiet = TRUE) |>
  select(taxon_name, iconic_taxon_name, observed_on, geometry)

gbif <- st_read(file.path(DATA_RAW, "gbif_observations.gpkg"), quiet = TRUE) |>
  select(species, class, eventDate, geometry) |>
  rename(taxon_name = species, iconic_taxon_name = class, observed_on = eventDate)

obs_all <- bind_rows(inat, gbif) |>
  filter(!is.na(taxon_name))

cat(sprintf("Total observations: %d\n", nrow(obs_all)))

# ── 2. Spatial join observations to grid ─────────────────────────────────────

obs_joined <- st_join(obs_all, grid |> select(cell_id, path_km))

# ── 3. Species richness per cell ─────────────────────────────────────────────

richness <- obs_joined |>
  st_drop_geometry() |>
  group_by(cell_id) |>
  summarise(
    n_obs            = n(),
    species_richness = n_distinct(taxon_name),
    n_survey_dates   = n_distinct(as.Date(observed_on), na.rm = TRUE),
    .groups = "drop"
  )

# ── 4. Taxonomic diversity (order-level Shannon index) ───────────────────────

order_matrix <- obs_joined |>
  st_drop_geometry() |>
  count(cell_id, iconic_taxon_name) |>
  pivot_wider(names_from = iconic_taxon_name, values_from = n, values_fill = 0) |>
  column_to_rownames("cell_id")

shannon <- diversity(order_matrix, index = "shannon")

diversity_df <- tibble(
  cell_id          = as.integer(rownames(order_matrix)),
  taxonomic_shannon = shannon
)

# ── 5. Observer effort correction ─────────────────────────────────────────────
# Effort = observations per km of path in cell.
# Corrected richness = raw richness / sqrt(effort + 1)
# (sqrt dampens the correction for very high-effort cells)

richness_corrected <- richness |>
  left_join(grid |> st_drop_geometry() |> select(cell_id, path_km), by = "cell_id") |>
  left_join(diversity_df, by = "cell_id") |>
  mutate(
    path_km            = replace_na(path_km, 0),
    effort             = n_obs / pmax(path_km, 0.1),   # obs per km; floor at 0.1 km
    richness_corrected = species_richness / sqrt(effort + 1)
  )

# ── 6. Merge back to grid ─────────────────────────────────────────────────────

grid_obs <- grid |>
  left_join(richness_corrected |> select(-path_km), by = "cell_id") |>
  mutate(
    n_obs              = replace_na(n_obs, 0L),
    species_richness   = replace_na(species_richness, 0L),
    richness_corrected = replace_na(richness_corrected, 0)
  )

st_write(grid_obs, file.path(DATA_PROC, "grid_observations.gpkg"), delete_dsn = TRUE)
cat(sprintf("Written: grid_observations.gpkg (%d cells)\n", nrow(grid_obs)))
