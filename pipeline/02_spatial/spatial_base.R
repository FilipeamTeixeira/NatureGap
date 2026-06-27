# NatureGap — Step 02: Spatial Base
# Builds the canonical 20 m hex base and patch linkage only.
#
# Outputs:
#   data/processed/hex_cells.gpkg         — full 20 m hex grid, including non-green cells
#   data/processed/hex_cells_display.gpkg — display-clipped hex geometries inside green spaces
#   data/processed/green_spaces.gpkg      — base green-space polygons with stable IDs

library(sf)
library(tidyverse)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

dir.create(DATA_PROC, recursive = TRUE, showWarnings = FALSE)

make_slug <- function(value) {
  value <- iconv(as.character(value), to = "ASCII//TRANSLIT", sub = "")
  value <- tolower(value)
  value <- gsub("[^a-z0-9]+", "-", value)
  value <- gsub("(^-|-$)", "", value)
  value
}

empty_green_spaces <- function() {
  st_sf(
    source = character(),
    source_feature_id = character(),
    green_space_id = character(),
    name = character(),
    geometry = st_sfc(crs = CRS_LOCAL)
  )
}

first_existing_column <- function(value, candidates) {
  for (candidate in candidates) {
    if (candidate %in% names(value)) {
      return(as.character(value[[candidate]]))
    }
  }
  rep(NA_character_, nrow(value))
}

drop_extra_sfc_columns <- function(value) {
  active_geometry <- attr(value, "sf_column")
  extra_geometry <- names(value)[vapply(value, inherits, logical(1), "sfc") & names(value) != active_geometry]
  if (length(extra_geometry) > 0L) value[extra_geometry] <- NULL
  value
}

read_green_spaces <- function(path, source_name) {
  if (!file.exists(path)) {
    message(sprintf("%s not found — skipping %s green spaces", path, source_name))
    return(empty_green_spaces())
  }

  value <- st_read(path, quiet = TRUE)
  if (nrow(value) == 0L) return(empty_green_spaces())

  value <- suppressWarnings(
    value |>
      st_transform(CRS_LOCAL) |>
      st_collection_extract("POLYGON", warn = FALSE)
  )

  if (nrow(value) == 0L) return(empty_green_spaces())

  raw_id <- first_existing_column(value, c(
    "osm_id", "osm_way_id", "id", "fid", "objectid", "OBJECTID", "gml_id"
  ))
  raw_id <- if_else(is.na(raw_id) | !nzchar(raw_id), as.character(seq_len(nrow(value))), raw_id)

  raw_name <- first_existing_column(value, c("name", "NAME", "Name", "park_name", "PARK_NAME"))
  raw_name <- if_else(is.na(raw_name) | !nzchar(raw_name), NA_character_, raw_name)

  value |>
    mutate(
      source = source_name,
      source_feature_id = raw_id,
      name = raw_name,
      green_space_id = {
        base <- make_slug(coalesce(raw_name, source_feature_id))
        base <- if_else(nchar(base) > 0L, base, paste0("green-space-", source_feature_id))
        paste(source_name, base, sep = "-")
      }
    ) |>
    select(source, source_feature_id, green_space_id, name, everything())
}

bb <- unname(BBOX_CITY)

bbox_sf <- st_bbox(
  c(
    xmin = bb[1],
    ymin = bb[2],
    xmax = bb[3],
    ymax = bb[4]
  ),
  crs = 4326
) |>
  st_as_sfc() |>
  st_transform(CRS_LOCAL)

hex_cells <- st_make_grid(bbox_sf, cellsize = 20, square = FALSE) |>
  st_as_sf() |>
  mutate(cell_id = row_number())

green_spaces <- bind_rows(
  read_green_spaces(RAW_OSM_GREEN, "osm"),
  read_green_spaces(RAW_NATIONAL_GREEN, "national")
) |>
  drop_extra_sfc_columns()

if (nrow(green_spaces) > 0L) {
  green_spaces <- green_spaces |>
    group_by(green_space_id) |>
    mutate(green_space_id = if_else(
      n() == 1L,
      green_space_id,
      paste(green_space_id, row_number(), sep = "-")
    )) |>
    ungroup()

  overlap <- suppressWarnings(st_intersection(
    hex_cells |> select(cell_id),
    green_spaces |> select(green_space_id)
  ))
  overlap <- suppressWarnings(st_collection_extract(overlap, "POLYGON", warn = FALSE))

  if (nrow(overlap) > 0L) {
    overlap_rank <- overlap |>
      mutate(overlap_area_m2 = as.numeric(st_area(overlap))) |>
      st_drop_geometry() |>
      arrange(cell_id, desc(overlap_area_m2), green_space_id) |>
      group_by(cell_id) |>
      slice_head(n = 1L) |>
      ungroup() |>
      select(cell_id, green_space_id)

    hex_cells <- hex_cells |>
      left_join(overlap_rank, by = "cell_id")

    hex_cells_display <- overlap |>
      select(cell_id, green_space_id)
  } else {
    hex_cells <- hex_cells |>
      mutate(green_space_id = NA_character_)
    hex_cells_display <- st_sf(
      cell_id = integer(),
      green_space_id = character(),
      geometry = st_sfc(crs = CRS_LOCAL)
    )
  }
} else {
  hex_cells <- hex_cells |>
    mutate(green_space_id = NA_character_)
  hex_cells_display <- st_sf(
    cell_id = integer(),
    green_space_id = character(),
    geometry = st_sfc(crs = CRS_LOCAL)
  )
}

st_write(hex_cells, PROC_HEX_CELLS, delete_dsn = TRUE)
st_write(hex_cells_display, PROC_HEX_CELLS_DISPLAY, delete_dsn = TRUE)
st_write(green_spaces, PROC_GREEN_SPACES, delete_dsn = TRUE)

cat(sprintf("Written: %s (%d full hex cells)\n", PROC_HEX_CELLS, nrow(hex_cells)))
cat(sprintf("Written: %s (%d display-clipped hex geometries)\n", PROC_HEX_CELLS_DISPLAY, nrow(hex_cells_display)))
cat(sprintf("Written: %s (%d green-space polygons)\n", PROC_GREEN_SPACES, nrow(green_spaces)))
