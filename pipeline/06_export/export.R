# NatureGap — Step 06: Export for Visualisation
# Converts processed outputs to web-ready formats:
#   - PMTiles (from Cloud-Optimised GeoTIFF) for raster layers
#   - GeoJSON / PostGIS import for vector layers
#
# Prerequisites:
#   - pmtiles CLI: `pip install pmtiles` or `brew install felt/tap/tippecanoe`
#   - GDAL >= 3.1 for COG output
#   - Supabase project with PostGIS enabled

library(sf)
library(terra)
library(tidyverse)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

dir.create(DATA_EXPORT, recursive = TRUE, showWarnings = FALSE)

run_pmtiles_convert <- function(input_path, output_path) {
  pmtiles_bin <- Sys.which("pmtiles")
  if (!nzchar(pmtiles_bin)) {
    stop("pmtiles CLI not found on PATH. Install it before running export.R.", call. = FALSE)
  }

  args <- shQuote(c("convert", input_path, output_path))
  cat(sprintf("Running: %s %s\n", pmtiles_bin, paste(args, collapse = " ")))
  status <- system2(pmtiles_bin, args = args)
  if (!identical(status, 0L)) {
    stop(sprintf("pmtiles convert failed with exit status %s", status), call. = FALSE)
  }
}

run_gdal_translate_mbtiles <- function(input_path, output_path) {
  gdal_translate_bin <- Sys.which("gdal_translate")
  if (!nzchar(gdal_translate_bin)) {
    stop("gdal_translate not found on PATH. Install GDAL before running export.R.", call. = FALSE)
  }

  if (file.exists(output_path)) unlink(output_path)
  args <- shQuote(c(
    "-of", "MBTILES",
    "-ot", "Byte",
    "-scale", "0", "1", "0", "255",
    "-co", "TILE_FORMAT=PNG",
    input_path,
    output_path
  ))
  cat(sprintf("Running: %s %s\n", gdal_translate_bin, paste(args, collapse = " ")))
  status <- system2(gdal_translate_bin, args = args)
  if (!identical(status, 0L)) {
    stop(sprintf("gdal_translate MBTiles export failed with exit status %s", status), call. = FALSE)
  }
}

run_gdaladdo <- function(input_path) {
  gdaladdo_bin <- Sys.which("gdaladdo")
  if (!nzchar(gdaladdo_bin)) {
    stop("gdaladdo not found on PATH. Install GDAL before running export.R.", call. = FALSE)
  }

  args <- shQuote(c("-r", "average", input_path, "2", "4", "8", "16"))
  cat(sprintf("Running: %s %s\n", gdaladdo_bin, paste(args, collapse = " ")))
  status <- system2(gdaladdo_bin, args = args)
  if (!identical(status, 0L)) {
    stop(sprintf("gdaladdo failed with exit status %s", status), call. = FALSE)
  }
}

write_geojson <- function(value, output_path) {
  if (file.exists(output_path)) unlink(output_path)
  st_write(value, output_path, delete_dsn = FALSE)
}

# Supabase Storage file limit — chunk outputs above this size (bytes).
MAX_UPLOAD_BYTES <- 45 * 1024^2

write_json_chunked <- function(obj, output_path, ...) {
  args <- list(...)
  pretty_out <- isTRUE(args$pretty)
  args$pretty <- FALSE  # fast size probe and chunk writes

  tmp <- tempfile(fileext = ".json")
  jsonlite::write_json(obj, tmp, ...)
  total_size <- file.info(tmp)$size

  if (total_size <= MAX_UPLOAD_BYTES) {
    if (pretty_out) {
      unlink(tmp)
      jsonlite::write_json(obj, output_path, ...)
    } else {
      file.copy(tmp, output_path, overwrite = TRUE)
      unlink(tmp)
    }
    return(invisible(NULL))
  }
  unlink(tmp)

  keys <- names(obj)
  n_parts <- max(2L, as.integer(ceiling(total_size / MAX_UPLOAD_BYTES)))
  base_name <- tools::file_path_sans_ext(basename(output_path))
  out_dir <- dirname(output_path)
  key_groups <- split(keys, cut(seq_along(keys), breaks = n_parts, labels = FALSE))
  chunk_files <- character(length(key_groups))

  cat(sprintf("  → Chunking %s (%.1f MB) into %d parts...\n",
              basename(output_path), total_size / 1024^2, length(key_groups)))

  for (i in seq_along(key_groups)) {
    part_name <- sprintf("%s-part-%03d.json", base_name, i)
    part_path <- file.path(out_dir, part_name)
    jsonlite::write_json(obj[key_groups[[i]]], part_path, ...)
    chunk_files[i] <- part_name
  }

  manifest_path <- file.path(out_dir, paste0(base_name, ".manifest.json"))
  jsonlite::write_json(
    list(version = 1L, chunks = as.list(chunk_files)),
    manifest_path,
    auto_unbox = TRUE
  )
  cat(sprintf(
    "  → Split %s into %d chunks (manifest: %s)\n",
    basename(output_path), length(chunk_files), basename(manifest_path)
  ))
}

write_geojson_chunked <- function(value, output_path) {
  tmp <- tempfile(fileext = ".geojson")
  write_geojson(value, tmp)
  total_size <- file.info(tmp)$size

  if (total_size <= MAX_UPLOAD_BYTES) {
    file.copy(tmp, output_path, overwrite = TRUE)
    unlink(tmp)
    return(invisible(NULL))
  }
  unlink(tmp)

  n <- nrow(value)
  n_parts <- max(2L, as.integer(ceiling(total_size / MAX_UPLOAD_BYTES)))
  rows_per <- ceiling(n / n_parts)
  base_name <- tools::file_path_sans_ext(basename(output_path))
  out_dir <- dirname(output_path)
  chunk_files <- character(n_parts)

  cat(sprintf("  → Chunking %s (%.1f MB) into %d parts...\n",
              basename(output_path), total_size / 1024^2, n_parts))

  for (i in seq_len(n_parts)) {
    row_start <- (i - 1L) * rows_per + 1L
    row_end <- min(i * rows_per, n)
    part_name <- sprintf("%s-part-%03d.geojson", base_name, i)
    part_path <- file.path(out_dir, part_name)
    write_geojson(value[row_start:row_end, ], part_path)
    chunk_files[i] <- part_name
    cat(sprintf("    part %d/%d (%d rows)\n", i, n_parts, row_end - row_start + 1L))
  }

  manifest_path <- file.path(out_dir, paste0(base_name, ".manifest.json"))
  jsonlite::write_json(
    list(version = 1L, chunks = as.list(chunk_files)),
    manifest_path,
    auto_unbox = TRUE
  )
  cat(sprintf(
    "  → Split %s into %d chunks (manifest: %s)\n",
    basename(output_path), length(chunk_files), basename(manifest_path)
  ))
}

export_upload_files <- function() {
  files <- c(
    "hexgrid.geojson", "hexgrid.manifest.json",
    "parks.geojson", "park-stats.json",
    "cells.json", "cells.manifest.json"
  )
  for (base in c("hexgrid", "cells")) {
    parts <- list.files(DATA_EXPORT, pattern = paste0("^", base, "-part-[0-9]+\\.(json|geojson)$"))
    files <- c(files, parts)
  }
  unique(files[sapply(file.path(DATA_EXPORT, files), file.exists)])
}

# Colour scale — must stay in sync with SCORE_COLORS in src/lib/config.ts
# and IMPACT_LEGEND in src/lib/utils.ts
score_color <- function(score) {
  case_when(
    is.na(score) ~ "#B8C9AE",   # treat missing as "as expected"
    score < -20  ~ "#C95B4B",   # much worse than expected
    score < -10  ~ "#E8A44C",   # worse than expected
    score <   5  ~ "#B8C9AE",   # as expected
    score <  15  ~ "#73A56D",   # better than expected
    TRUE         ~ "#2E6F40"    # much better than expected
  )
}

make_slug <- function(value) {
  value |>
    stringr::str_to_lower() |>
    stringr::str_replace_all("[^a-z0-9]+", "-") |>
    stringr::str_replace_all("(^-|-$)", "")
}

# ── Shared helpers for JSON export ───────────────────────────────────────────

score_status <- function(score) {
  dplyr::case_when(
    is.na(score) ~ "as-expected",
    score < -20  ~ "much-worse",
    score < -10  ~ "worse",
    score <   5  ~ "as-expected",
    score <  15  ~ "better",
    TRUE         ~ "much-better"
  )
}

habitat_potential <- function(hq_index) {
  dplyr::case_when(
    is.na(hq_index) ~ "moderate",
    hq_index >= 0.70 ~ "high",
    hq_index >= 0.40 ~ "moderate",
    TRUE             ~ "low"
  )
}

pct_index <- function(value) {
  as.integer(round(pmin(100, pmax(0, replace_na(value, 0) * 100))))
}

derive_pressures <- function(n_obs, n_survey_dates, richness_corrected,
                             expected_richness, ecological_residual,
                             fragmentation_index, corridor_importance) {
  pressures <- character(0)
  if (replace_na(n_obs, 0L) == 0L) {
    pressures <- c(pressures, "No biodiversity observations recorded in this cell")
  }
  if (replace_na(n_survey_dates, 0L) < 2L && replace_na(n_obs, 0L) > 0L) {
    pressures <- c(pressures, "Low survey effort — fewer than 2 distinct survey dates")
  }
  if (!is.na(ecological_residual) && ecological_residual < -20) {
    pressures <- c(
      pressures,
      sprintf(
        "Observed richness (%.1f, effort-corrected) is below the habitat expectation (%.0f)",
        replace_na(richness_corrected, 0),
        replace_na(expected_richness, 0)
      )
    )
  }
  if (!is.na(fragmentation_index) && fragmentation_index > 0.5) {
    pressures <- c(pressures, "High habitat fragmentation — relatively isolated from neighbouring patches")
  }
  if (!is.na(corridor_importance) && corridor_importance > 0.25) {
    pressures <- c(pressures, "Lies on an important habitat connectivity corridor")
  }
  pressures
}

action_category <- function(action) {
  dplyr::case_when(
    grepl("corridor", action, ignore.case = TRUE) ~ "corridor",
    grepl("canopy|green cover|shade tree", action, ignore.case = TRUE) ~ "canopy",
    grepl("native plant|diversity", action, ignore.case = TRUE) ~ "pollinator",
    grepl("isolation|connect", action, ignore.case = TRUE) ~ "corridor",
    TRUE ~ "ground"
  )
}

action_impact <- function(rank) {
  dplyr::case_when(
    rank <= 5L  ~ "high",
    rank <= 12L ~ "medium",
    TRUE        ~ "low"
  )
}

build_intervention <- function(cell_id, rank, action, composite, note, gain = NA_real_) {
  entry <- list(
    id          = sprintf("%s-rank-%d", cell_id, rank),
    title       = action,
    description = sprintf(
      "Ranked #%d for intervention priority (composite score %.2f). %s",
      rank, replace_na(composite, 0), note
    ),
    impact      = unbox(action_impact(rank)),
    category    = unbox(action_category(action))
  )
  if (length(gain) == 1L && !is.na(gain)) {
    entry$connectivityGain <- as.integer(round(gain))
  }
  entry
}

# jsonlite::write_json needs scalars unboxed for some fields
unbox <- function(x) x

species_list <- function(plant, bird, insect, mammal, fungi) {
  list(
    list(type = "plant",  count = as.integer(replace_na(plant, 0L))),
    list(type = "bird",   count = as.integer(replace_na(bird, 0L))),
    list(type = "insect", count = as.integer(replace_na(insect, 0L))),
    list(type = "mammal", count = as.integer(replace_na(mammal, 0L))),
    list(type = "fungi",  count = as.integer(replace_na(fungi, 0L)))
  )
}

cell_stats_row <- function(row, max_expected) {
  hq <- replace_na(row$habitat_quality, 0)
  list(
    parkId               = row$park_id,
    impactScore          = as.integer(round(replace_na(row$impact_score, 0))),
    habitatQuality       = pct_index(hq),
    habitatQualityIndex  = round(hq, 4),
    speciesRichnessRaw   = as.integer(replace_na(row$species_richness, 0L)),
    observedRichness     = round(replace_na(row$richness_corrected, 0), 1),
    expectedRichness     = round(replace_na(row$expected_richness, 0), 1),
    maxExpectedRichness  = as.integer(max_expected),
    ecologicalResidual   = round(replace_na(row$ecological_residual, 0), 1),
    nObs                 = as.integer(replace_na(row$n_obs, 0L)),
    nSurveyDates         = as.integer(replace_na(row$n_survey_dates, 0L)),
    status               = unbox(score_status(row$impact_score)),
    habitatPotential     = unbox(habitat_potential(hq)),
    observerEffortScore  = round(
      replace_na(row$n_obs, 0) / pmax(replace_na(row$path_km, 0), 0.01),
      1
    ),
    taxonomicDiversity = round(replace_na(row$taxonomic_shannon, 0), 1),
    species            = species_list(row$plant, row$bird, row$insect, row$mammal, row$fungi),
    corridorImportance = pct_index(row$corridor_importance),
    fragmentationIndex = pct_index(row$fragmentation_index),
    pressures          = as.list(derive_pressures(
      row$n_obs, row$n_survey_dates, row$richness_corrected,
      row$expected_richness, row$ecological_residual,
      row$fragmentation_index, row$corridor_importance
    )),
    interventions      = list()
  )
}

aggregate_park_stats <- function(rows, max_expected) {
  if (nrow(rows) == 0) return(NULL)
  hq_mean <- mean(replace_na(rows$habitat_quality, 0))
  list(
    impactScore          = as.integer(round(stats::median(rows$impact_score, na.rm = TRUE))),
    habitatQuality       = pct_index(hq_mean),
    habitatQualityIndex  = round(hq_mean, 4),
    speciesRichnessRaw   = as.integer(sum(replace_na(rows$species_richness, 0L))),
    observedRichness     = round(sum(replace_na(rows$richness_corrected, 0)), 1),
    expectedRichness     = round(mean(replace_na(rows$expected_richness, 0)), 1),
    maxExpectedRichness  = as.integer(max_expected),
    ecologicalResidual   = round(sum(replace_na(rows$ecological_residual, 0)), 1),
    nObs                 = as.integer(sum(replace_na(rows$n_obs, 0L))),
    nSurveyDates         = as.integer(max(replace_na(rows$n_survey_dates, 0L))),
    status               = unbox(score_status(stats::median(rows$impact_score, na.rm = TRUE))),
    habitatPotential     = unbox(habitat_potential(hq_mean)),
    observerEffortScore  = round(
      mean(replace_na(rows$n_obs, 0) / pmax(replace_na(rows$path_km, 0), 0.01), na.rm = TRUE),
      1
    ),
    taxonomicDiversity = round(mean(replace_na(rows$taxonomic_shannon, 0), na.rm = TRUE), 1),
    species = species_list(
      sum(replace_na(rows$plant, 0L)),
      sum(replace_na(rows$bird, 0L)),
      sum(replace_na(rows$insect, 0L)),
      sum(replace_na(rows$mammal, 0L)),
      sum(replace_na(rows$fungi, 0L))
    ),
    corridorImportance = pct_index(mean(replace_na(rows$corridor_importance, 0), na.rm = TRUE)),
    fragmentationIndex = pct_index(mean(replace_na(rows$fragmentation_index, 0), na.rm = TRUE)),
    pressures = unique(unlist(lapply(seq_len(nrow(rows)), function(i) {
      derive_pressures(
        rows$n_obs[i], rows$n_survey_dates[i], rows$richness_corrected[i],
        rows$expected_richness[i], rows$ecological_residual[i],
        rows$fragmentation_index[i], rows$corridor_importance[i]
      )
    }))),
    interventions = list()
  )
}

# ── 1. Rasters → Cloud-Optimised GeoTIFF → PMTiles ───────────────────────────
#
# Map layer → pipeline source (must match src/lib/config.ts RASTER_LAYERS filenames):
#   habitat_quality.pmtiles  ← habitat_quality.tif        (step 02)
#   treecover.pmtiles        ← tree_fraction              (step 02 grid)
#   biodiversity.pmtiles     ← richness_corrected       (step 05 grid, normalised)
#   connectivity.pmtiles     ← corridor_importance      (step 04 grid)
#   landuse.pmtiles          ← green_fraction_wc        (step 02 grid)
#   lst.pmtiles              ← lst.tif                  (step 01 ingest, optional)

rasterize_grid_field <- function(grid_sf, field, out_path) {
  if (!field %in% names(grid_sf)) {
    message(sprintf("Skipping raster — field '%s' not in grid", field))
    return(invisible(FALSE))
  }
  v <- vect(grid_sf)
  template <- rast(ext(v), res = CELL_SIZE, crs = CRS_LOCAL)
  r <- rasterize(v, template, field = field)
  writeRaster(r, out_path, overwrite = TRUE)
  cat(sprintf("Written: %s (field: %s)\n", out_path, field))
  invisible(TRUE)
}

#' Rasterise a grid column scaled to 0–1 for web colour ramps.
rasterize_grid_normalized <- function(grid_sf, field, out_path, cap_quantile = 0.99) {
  if (!field %in% names(grid_sf)) {
    message(sprintf("Skipping raster — field '%s' not in grid", field))
    return(invisible(FALSE))
  }
  vals <- grid_sf[[field]]
  vals <- vals[!is.na(vals) & vals > 0]
  if (length(vals) == 0) {
    message(sprintf("Skipping raster — no positive values for '%s'", field))
    return(invisible(FALSE))
  }
  cap <- as.numeric(stats::quantile(vals, cap_quantile, na.rm = TRUE))
  if (!is.finite(cap) || cap <= 0) cap <- max(vals, na.rm = TRUE)
  grid_norm <- grid_sf |>
    mutate(.export_val = pmin(replace_na(.data[[field]], 0), cap) / cap)
  rasterize_grid_field(grid_norm, ".export_val", out_path)
}

prepare_layer_rasters <- function() {
  treecover_tif    <- file.path(DATA_EXPORT, "treecover.tif")
  biodiversity_tif <- file.path(DATA_EXPORT, "biodiversity.tif")
  connectivity_tif <- file.path(DATA_EXPORT, "connectivity.tif")
  landuse_tif      <- file.path(DATA_EXPORT, "landuse.tif")

  if (file.exists(PROC_GRID_HABITAT)) {
    grid_hab <- st_read(PROC_GRID_HABITAT, quiet = TRUE)
    rasterize_grid_field(grid_hab, "tree_fraction", treecover_tif)
    rasterize_grid_field(grid_hab, "green_fraction_wc", landuse_tif)
  } else {
    message(sprintf("Skipping treecover/landuse — %s not found", PROC_GRID_HABITAT))
  }

  if (file.exists(PROC_GRID_RESID)) {
    grid_resid <- st_read(PROC_GRID_RESID, quiet = TRUE) |>
      filter(habitat_quality > 0)
    rasterize_grid_normalized(grid_resid, "richness_corrected", biodiversity_tif)
  } else {
    message(sprintf("Skipping biodiversity — %s not found", PROC_GRID_RESID))
  }

  if (file.exists(PROC_GRID_CONN)) {
    grid_conn <- st_read(PROC_GRID_CONN, quiet = TRUE)
    rasterize_grid_field(grid_conn, "corridor_importance", connectivity_tif)
  } else {
    message(sprintf("Skipping connectivity — %s not found", PROC_GRID_CONN))
  }

  invisible(list(
    treecover = treecover_tif,
    biodiversity = biodiversity_tif,
    connectivity = connectivity_tif,
    landuse = landuse_tif
  ))
}

layer_tifs <- prepare_layer_rasters()

raster_layers <- c(
  "habitat_quality" = PROC_HABITAT_TIF,
  "treecover"       = layer_tifs$treecover,
  "biodiversity"    = layer_tifs$biodiversity,
  "connectivity"    = layer_tifs$connectivity,
  "landuse"         = layer_tifs$landuse,
  "lst"             = RAW_LST
)

for (layer_name in names(raster_layers)) {
  input_tif <- raster_layers[[layer_name]]
  if (!file.exists(input_tif)) {
    message(sprintf("Skipping %s — file not found", input_tif))
    next
  }

  cog_path    <- file.path(DATA_EXPORT, paste0(layer_name, "_cog.tif"))
  mbtiles_path <- file.path(DATA_EXPORT, paste0(layer_name, ".mbtiles"))
  pmtiles_path <- file.path(DATA_EXPORT, paste0(layer_name, ".pmtiles"))

  # Reproject to WGS84 (required for PMTiles web serving)
  r <- rast(input_tif) |> project("EPSG:4326")
  writeRaster(r, cog_path, gdal = c("COMPRESS=DEFLATE", "TILED=YES",
                                     "BLOCKXSIZE=512", "BLOCKYSIZE=512",
                                     "COPY_SRC_OVERVIEWS=YES"),
              overwrite = TRUE)

  # Convert COG → MBTiles → PMTiles (pmtiles CLI expects MBTiles input)
  run_gdal_translate_mbtiles(cog_path, mbtiles_path)
  run_gdaladdo(mbtiles_path)
  run_pmtiles_convert(mbtiles_path, pmtiles_path)
}

# ── 2. Park polygons → GeoJSON ───────────────────────────────────────────────

green_path <- RAW_OSM_GREEN
if (file.exists(green_path)) {
  green_raw <- st_read(green_path, quiet = TRUE) |>
    st_transform(4326) |>
    st_collection_extract("POLYGON")

  if (!"osm_id" %in% names(green_raw)) green_raw$osm_id <- seq_len(nrow(green_raw))
  if (!"name" %in% names(green_raw)) green_raw$name <- NA_character_
  if (!"name:ja" %in% names(green_raw)) green_raw[["name:ja"]] <- NA_character_

  green <- green_raw |>
    mutate(
      source_id = coalesce(as.character(osm_id), as.character(row_number())),
      name = coalesce(as.character(name), paste("Green space", source_id)),
      nameJa = coalesce(as.character(.data[["name:ja"]]), name),
      # make_slug() returns '' for non-ASCII-only names (e.g. Japanese);
      # fall back to "park-{osm_id}" so every park gets a stable, non-empty id.
      id = {
        slug <- make_slug(coalesce(name, source_id))
        dplyr::if_else(nchar(slug) > 0L, slug, paste0("park-", source_id))
      },
      wardId = NA_character_
    ) |>
    select(id, name, nameJa, wardId)

  parks_path <- file.path(DATA_EXPORT, "parks.geojson")
  write_geojson(green, parks_path)
  cat(sprintf("Written: %s\n", parks_path))
} else {
  message(sprintf("Skipping parks.geojson — %s not found", green_path))
}

# ── 3. Vector grid → GeoJSON (for PostGIS import + frontend cells) ───────────

grid_raw <- st_read(PROC_GRID_RESID, quiet = TRUE) |>
  st_transform(4326)

if (!exists("MAX_EXPECTED_RICHNESS")) MAX_EXPECTED_RICHNESS <- 350L

if (!"is_habitat" %in% names(grid_raw)) {
  grid_raw$is_habitat <- grid_raw$habitat_quality > 0
}
if (!"species_richness" %in% names(grid_raw)) {
  grid_raw$species_richness <- grid_raw$richness_corrected
}
if (!"taxonomic_shannon" %in% names(grid_raw) && "species_shannon" %in% names(grid_raw)) {
  grid_raw$taxonomic_shannon <- grid_raw$species_shannon
}
for (col in c("plant", "bird", "insect", "mammal", "fungi", "n_survey_dates", "path_km")) {
  if (!col %in% names(grid_raw)) grid_raw[[col]] <- 0
}

grid <- grid_raw |>
  select(
    cell_id, habitat_quality, impact_score, composite, intervention_rank, is_habitat,
    any_of(c("tree_fraction", "shrub_fraction", "grass_fraction",
             "built_fraction_wc", "green_fraction_wc",
             "impervious_fraction", "osm_green_fraction")),
    any_of(c("ndvi_mean", "lst_rank")),
    corridor_importance, fragmentation_index, patch_area_ha,
    n_obs, species_richness, richness_corrected, taxonomic_shannon,
    n_survey_dates, path_km,
    plant, bird, insect, mammal, fungi,
    expected_richness, ecological_residual
  ) |>
  filter(habitat_quality > 0)

n_total  <- nrow(grid_raw)
n_green  <- nrow(grid)
cat(sprintf("  → %d / %d cells retained (habitat_quality > 0)\n", n_green, n_total))

grid <- grid |> mutate(cell_id = paste0(CITY_ID, "-", cell_id))

# ── Assign each cell to its containing OSM park ──────────────────────────────

osm_parks_path <- RAW_OSM_GREEN

if (file.exists(osm_parks_path)) {
  osm_parks_4326 <- st_read(osm_parks_path, quiet = TRUE) |>
    st_transform(4326) |>
    st_collection_extract("POLYGON") |>
    transmute(
      park_id = {
        slug <- make_slug(coalesce(as.character(name), paste0("park-", row_number())))
        dplyr::if_else(nchar(slug) > 0L, slug, paste0("park-", row_number()))
      },
      park_name = coalesce(as.character(name), paste("Green area", row_number()))
    )

  park_assignment <- grid |>
    st_centroid() |>
    st_join(osm_parks_4326, join = st_within, left = TRUE) |>
    st_drop_geometry() |>
    select(cell_id, park_id, park_name)

  grid <- grid |>
    left_join(park_assignment, by = "cell_id") |>
    mutate(
      park_id   = coalesce(park_id,   "city-green"),
      park_name = coalesce(park_name, "Green area")
    )
  cat(sprintf("  → Park attribution: %d cells assigned to named parks\n",
              sum(park_assignment$park_id != "city-green", na.rm = TRUE)))
} else {
  grid <- grid |>
    mutate(park_id = "city-green", park_name = "Green area")
  message("osm_green_spaces.gpkg not found — all cells assigned to 'city-green'")
}

hexgrid <- grid |>
  transmute(
    cellId   = cell_id,
    parkId   = park_id,
    parkName = park_name,
    wardId   = NA_character_,
    score    = as.integer(impact_score),
    color    = score_color(impact_score)
  )

hexgrid_path <- file.path(DATA_EXPORT, "hexgrid.geojson")
write_geojson_chunked(hexgrid, hexgrid_path)
cat(sprintf("Written: %s\n", hexgrid_path))

# ── 4. Per-cell stats + park aggregates + interventions ───────────────────────

grid_df <- st_drop_geometry(grid)
n_cells <- nrow(grid_df)
cat(sprintf("Building cell stats for %d cells...\n", n_cells))

# Top interventions with park attribution
top <- read_csv(PROC_TOP_INTER, show_col_types = FALSE) |>
  mutate(cell_id = paste0(CITY_ID, "-", cell_id)) |>
  left_join(grid_df |> select(cell_id, park_id), by = "cell_id")

intervention_by_cell <- top |>
  mutate(
    intervention = pmap(
      list(cell_id, intervention_rank, primary_action, composite,
           counterfactual_note, connectivity_gain_pct),
      function(cid, rank, action, comp, note, gain) {
        build_intervention(cid, rank, action, comp, note, gain)
      }
    )
  ) |>
  select(cell_id, intervention)

intervention_lookup <- setNames(
  intervention_by_cell$intervention,
  intervention_by_cell$cell_id
)

park_interventions <- top |>
  group_by(park_id) |>
  summarise(
    interventions = list(lapply(seq_len(n()), function(i) {
      build_intervention(
        cell_id[i], intervention_rank[i], primary_action[i], composite[i],
        counterfactual_note[i], connectivity_gain_pct[i]
      )
    })),
    .groups = "drop"
  )
park_intervention_lookup <- setNames(park_interventions$interventions, park_interventions$park_id)

cells_out <- list()
for (i in seq_len(n_cells)) {
  row <- grid_df[i, ]
  stats <- cell_stats_row(row, MAX_EXPECTED_RICHNESS)
  cid <- row$cell_id
  if (!is.null(intervention_lookup[[cid]])) {
    stats$interventions <- list(intervention_lookup[[cid]])
  }
  cells_out[[cid]] <- stats
  if (i %% 10000L == 0L) cat(sprintf("  … %d / %d cells\n", i, n_cells))
}

cat("Writing cells.json...\n")
write_json_chunked(
  cells_out,
  file.path(DATA_EXPORT, "cells.json"),
  auto_unbox = TRUE, null = "null", na = "null"
)
cat("Written: cells.json\n")

park_stats_out <- list()
for (pid in unique(grid_df$park_id)) {
  rows <- grid_df |> filter(park_id == pid)
  stats <- aggregate_park_stats(rows, MAX_EXPECTED_RICHNESS)
  if (!is.null(stats)) {
    park_iv <- park_intervention_lookup[[pid]]
    if (!is.null(park_iv)) stats$interventions <- park_iv
    park_stats_out[[pid]] <- stats
  }
}

jsonlite::write_json(
  park_stats_out,
  file.path(DATA_EXPORT, "park-stats.json"),
  pretty = TRUE, auto_unbox = TRUE, null = "null", na = "null"
)
cat(sprintf("Written: park-stats.json (%d parks)\n", length(park_stats_out)))

jsonlite::write_json(top, file.path(DATA_EXPORT, "top_interventions.json"), pretty = TRUE)
cat("Written: top_interventions.json\n")

# ── 5. Summary ────────────────────────────────────────────────────────────────

storage_folder <- paste0("pipeline-export/", CITY_ID, "/")
cat(sprintf("\nExport complete for city: %s\n", CITY_ID))
cat(sprintf("Upload these files to Supabase Storage folder '%s':\n", storage_folder))
for (f in export_upload_files()) {
  p <- file.path(DATA_EXPORT, f)
  sz <- file.info(p)$size / 1024^2
  cat(sprintf("  ✓ %s (%.1f MB)\n", f, sz))
}
