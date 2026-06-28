# NatureGap — Step 06: Export for Visualisation
# Converts processed outputs to Supabase-ready JSON + vector artifacts:
#   hexgrid.pmtiles, parks.geojson, park-stats.json
#
# Hex map layers are painted from PMTiles vector tiles. Full-city hex GeoJSON
# must not be uploaded or rendered by the frontend.

library(sf)
library(tidyverse)
library(jsonlite)
library(igraph)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

dir.create(DATA_EXPORT, recursive = TRUE, showWarnings = FALSE)

REPO_ROOT <- if (basename(PIPELINE_ROOT) == "pipeline") dirname(PIPELINE_ROOT) else PIPELINE_ROOT
DATA_VERSION <- Sys.getenv("NATUREGAP_DATA_VERSION", unset = "")
if (!nzchar(DATA_VERSION)) {
  DATA_VERSION <- format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC")
}
GENERATED_AT <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

STORAGE_EXPORT_ROOT <- file.path(REPO_ROOT, "pipeline-export")
VERSIONED_EXPORT_DIR <- file.path(STORAGE_EXPORT_ROOT, CITY_ID, DATA_VERSION)
CURRENT_POINTER_PATH <- file.path(STORAGE_EXPORT_ROOT, CITY_ID, "current.json")

PMTILES_SOURCE_LAYER <- "hexgrid"
PMTILES_REQUIRED_FIELDS <- c(
  "cellId",
  "parkId",
  "parkName",
  "impactScore",
  "natureGapScore",
  "expectedRichness",
  "ecologicalResidual",
  "ecologicalResidualNormalized",
  "habitatQuality",
  "observedRichness",
  "corridorImportance",
  "betweennessCentrality",
  "treeCover",
  "meanCanopy",
  "canopyHeightIdx",
  "heatExposure",
  "meanLst",
  "lstIdx",
  "landUseGreen",
  "landUseClass",
  "interventionRank",
  "ndviNorm",
  "canopyNorm",
  "lstNorm",
  "disturbanceNorm",
  "betweennessNorm",
  "residualNorm",
  "natureGapScoreNorm",
  "expectedNorm",
  "interventionRankNorm",
  "habitatQualityNorm"
)

validate_render_fields <- function(value) {
  missing <- setdiff(PMTILES_REQUIRED_FIELDS, names(value))
  if (length(missing) > 0L) {
    stop(sprintf(
      "PMTiles render data is missing required fields: %s",
      paste(missing, collapse = ", ")
    ), call. = FALSE)
  }
  invisible(TRUE)
}

write_geojson <- function(value, output_path) {
  if (file.exists(output_path)) unlink(output_path)
  st_write(value, output_path, delete_dsn = FALSE)
}

# Supabase Storage file limit — chunk outputs above this size (bytes).
MAX_UPLOAD_BYTES <- 45 * 1024^2

cleanup_chunked_outputs <- function(output_path, extension_pattern) {
  base_name <- tools::file_path_sans_ext(basename(output_path))
  out_dir <- dirname(output_path)
  stale <- c(
    file.path(out_dir, paste0(base_name, ".manifest.json")),
    list.files(
      out_dir,
      pattern = paste0("^", base_name, "-part-[0-9]+\\.", extension_pattern, "$"),
      full.names = TRUE
    )
  )
  stale <- stale[file.exists(stale)]
  if (length(stale) > 0L) unlink(stale)
}

write_json_chunked <- function(obj, output_path, ...) {
  args <- list(...)
  pretty_out <- isTRUE(args$pretty)
  args$pretty <- FALSE  # fast size probe and chunk writes

  tmp <- tempfile(fileext = ".json")
  jsonlite::write_json(obj, tmp, ...)
  total_size <- file.info(tmp)$size

  if (total_size <= MAX_UPLOAD_BYTES) {
    cleanup_chunked_outputs(output_path, "json")
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
    cleanup_chunked_outputs(output_path, "geojson")
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

validate_pmtiles_contract <- function(output_path) {
  node <- Sys.getenv("NODE_BIN", unset = "")
  if (!nzchar(node)) node <- Sys.which("node")
  if (node == "") {
    stop("node is required to validate hexgrid.pmtiles metadata. Set NODE_BIN if node is not on PATH.", call. = FALSE)
  }

  validator <- file.path(PIPELINE_ROOT, "06_export", "validate_pmtiles.mjs")
  if (!file.exists(validator)) {
    stop(sprintf("PMTiles validator not found: %s", validator), call. = FALSE)
  }

  args <- shQuote(c(
    normalizePath(validator, winslash = "/", mustWork = TRUE),
    normalizePath(output_path, winslash = "/", mustWork = TRUE),
    PMTILES_SOURCE_LAYER,
    PMTILES_REQUIRED_FIELDS
  ))
  result <- system2(node, args = args, stdout = TRUE, stderr = TRUE)
  status <- attr(result, "status")
  if (!is.null(status) && status != 0) {
    stop(sprintf(
      "PMTiles validation failed for %s:\n%s",
      output_path,
      paste(result, collapse = "\n")
    ), call. = FALSE)
  }

  cat(sprintf(
    "Validated: %s (source-layer: %s; fields: %s)\n",
    output_path,
    PMTILES_SOURCE_LAYER,
    paste(PMTILES_REQUIRED_FIELDS, collapse = ", ")
  ))
  jsonlite::fromJSON(paste(result, collapse = "\n"))
}

write_hexgrid_pmtiles <- function(value, output_path) {
  tippecanoe <- Sys.which("tippecanoe")
  if (tippecanoe == "") {
    stop("tippecanoe is required to generate hexgrid.pmtiles. Install tippecanoe and rerun the export step.")
  }
  validate_render_fields(value)

  tmp <- tempfile(fileext = ".geojson")
  on.exit(unlink(tmp), add = TRUE)
  write_geojson(value, tmp)

  tmp_pmtiles <- tempfile(fileext = ".pmtiles")
  on.exit(unlink(tmp_pmtiles), add = TRUE)
  if (file.exists(output_path)) unlink(output_path)

  # Internal vector tile source-layer is exactly "hexgrid".
  # Frontend URL format:
  # pmtiles://<SUPABASE_URL>/storage/v1/object/public/pipeline-export/<CITY_ID>/<DATA_VERSION>/hexgrid.pmtiles
  args <- c(
    "--output", tmp_pmtiles,
    "--layer", PMTILES_SOURCE_LAYER,
    "--force",
    "--no-feature-limit",
    "--no-tile-size-limit",
    "--no-tiny-polygon-reduction",
    "--minimum-zoom", "0",
    "--maximum-zoom", "18",
    tmp
  )
  status <- system2(tippecanoe, args = args)
  if (is.na(status) || status != 0) {
    stop(sprintf("tippecanoe failed to generate hexgrid.pmtiles (exit status: %s)", status))
  }
  if (!file.exists(tmp_pmtiles) || file.info(tmp_pmtiles)$size <= 0) {
    stop(sprintf(
      "tippecanoe exited successfully but did not create a PMTiles file at %s",
      tmp_pmtiles
    ))
  }
  if (!file.copy(tmp_pmtiles, output_path, overwrite = TRUE)) {
    stop(sprintf("Failed to copy generated PMTiles to %s", output_path))
  }
  validate_pmtiles_contract(output_path)
}

export_upload_files <- function(export_dir = DATA_EXPORT) {
  files <- c(
    "hexgrid.pmtiles",
    "parks.geojson", "park-stats.json", "cell_attributes.geojson",
    "cell_attributes.manifest.json", "corridor-links.geojson",
    "corridor-links.manifest.json", "top_interventions.json"
  )
  for (base in c("cell_attributes", "corridor-links")) {
    parts <- list.files(export_dir, pattern = paste0("^", base, "-part-[0-9]+\\.(json|geojson)$"))
    files <- c(files, parts)
  }
  unique(files[sapply(file.path(export_dir, files), file.exists)])
}

stage_versioned_exports <- function(validation, cell_count, park_count) {
  dir.create(VERSIONED_EXPORT_DIR, recursive = TRUE, showWarnings = FALSE)

  files <- export_upload_files(DATA_EXPORT)
  for (file_name in files) {
    source_path <- file.path(DATA_EXPORT, file_name)
    target_path <- file.path(VERSIONED_EXPORT_DIR, file_name)
    if (!file.copy(source_path, target_path, overwrite = TRUE)) {
      stop(sprintf("Failed to stage %s to %s", source_path, target_path), call. = FALSE)
    }
  }

  file_entries <- lapply(files, function(file_name) {
    path <- file.path(VERSIONED_EXPORT_DIR, file_name)
    list(
      path = file_name,
      bytes = unname(file.info(path)$size)
    )
  })
  names(file_entries) <- files

  manifest <- list(
    schemaVersion = 1L,
    cityId = CITY_ID,
    cityName = if (exists("CITY_NAME")) CITY_NAME else CITY_ID,
    cityCountry = if (exists("CITY_COUNTRY")) CITY_COUNTRY else NA_character_,
    datasetId = DATA_VERSION,
    dataVersion = DATA_VERSION,
    generatedAt = GENERATED_AT,
    cellSizeM = CELL_SIZE,
    crsLocal = CRS_LOCAL,
    sourceLayer = PMTILES_SOURCE_LAYER,
    requiredRenderFields = as.list(PMTILES_REQUIRED_FIELDS),
    metricDefinitions = list(
      observedRichness = list(
        sourceField = "observed_richness",
        definition = "Effort-normalised observed richness per survey effort unit.",
        formula = "species_richness / survey_effort_units",
        surveyEffortUnits = "log1p(path_km)",
        missingValueRule = "Unsampled cells keep observed_richness and survey_effort_units as null; sampled cells with no observations use 0."
      ),
      effortCorrectedRichness = list(
        sourceField = "effort_corrected_richness",
        definition = "Canonical alias of observed_richness for residual calculation and backwards-compatible consumers."
      ),
      ecologicalResidual = list(
        sourceField = "ecological_residual",
        definition = "Raw expected_richness minus effort_corrected_richness. Separate from nature_gap_score."
      ),
      natureGapScore = list(
        sourceField = "nature_gap_score",
        definition = "Composite headline: 0.50 biodiversity residual + 0.30 habitat deficit + 0.20 connectivity deficit, scaled to [-100, 100]."
      ),
      ecologicalResidualNormalized = list(
        sourceField = "ecological_residual_normalized",
        definition = "City-wise z-score of raw ecological_residual using finite sampled cells.",
        formula = "(ecological_residual - city_mean(ecological_residual)) / city_stddev(ecological_residual)",
        visualizationRule = "Map render fields clamp ecologicalResidualNormalized * 25 to [-50, 50]; raw and normalized backend values are not clamped."
      )
    ),
    database = list(
      datasetTable = "pipeline_datasets",
      immutableCellTable = "pipeline_cell_attributes",
      immutableGreenSpaceTable = "pipeline_green_spaces",
      activeCellProjection = "cell_attributes",
      activeGreenSpaceProjection = "green_spaces",
      importFunction = "import_pipeline_dataset"
    ),
    products = list(
      pmtiles = list(path = "hexgrid.pmtiles", purpose = "MapLibre rendering only"),
      parks = list(path = "parks.geojson", purpose = "Green-space polygons for Storage and PostgreSQL import"),
      cellAttributes = list(path = "cell_attributes.geojson", purpose = "Authoritative ecological cell outputs for PostgreSQL import"),
      corridorLinks = list(path = "corridor-links.geojson", purpose = "Full connectivity graph edges for MapLibre line rendering"),
      parkStats = list(path = "park-stats.json", purpose = "Frontend detail statistics"),
      topInterventions = list(path = "top_interventions.json", purpose = "Pipeline audit output"),
      chunkManifest = list(path = "cell_attributes.manifest.json", purpose = "Large cell attribute chunk index when needed")
    ),
    counts = list(
      renderCells = as.integer(cell_count),
      parks = as.integer(park_count)
    ),
    pmtiles = list(
      path = "hexgrid.pmtiles",
      sourceLayer = PMTILES_SOURCE_LAYER,
      minZoom = validation$minZoom,
      maxZoom = validation$maxZoom,
      bounds = as.list(validation$bounds)
    ),
    files = file_entries
  )

  manifest_path <- file.path(VERSIONED_EXPORT_DIR, "manifest.json")
  jsonlite::write_json(
    manifest,
    manifest_path,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null",
    na = "null"
  )

  current <- list(
    schemaVersion = 1L,
    cityId = CITY_ID,
    datasetId = DATA_VERSION,
    dataVersion = DATA_VERSION,
    generatedAt = manifest$generatedAt,
    manifest = paste0(DATA_VERSION, "/manifest.json"),
    sourceLayer = PMTILES_SOURCE_LAYER,
    hexgrid = paste0(DATA_VERSION, "/hexgrid.pmtiles")
  )

  dir.create(dirname(CURRENT_POINTER_PATH), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    current,
    CURRENT_POINTER_PATH,
    pretty = TRUE,
    auto_unbox = TRUE
  )

  cat(sprintf("Written: %s\n", manifest_path))
  cat(sprintf("Written: %s\n", CURRENT_POINTER_PATH))
  invisible(list(manifest = manifest_path, current = CURRENT_POINTER_PATH, files = files))
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

# ── Per-city normalisation helpers (for export) ────────────────────────────────

norm_sequential <- function(x) {
  finite_vals <- x[is.finite(x)]
  if (length(finite_vals) == 0L) return(rep(NA_real_, length(x)))
  p5  <- quantile(finite_vals, 0.05, names = FALSE)
  p95 <- quantile(finite_vals, 0.95, names = FALSE)
  if (!is.finite(p5) || !is.finite(p95) || p5 == p95) {
    return(rep(0.5, length(x)))
  }
  pmin(1, pmax(0, (x - p5) / (p95 - p5)))
}

norm_diverging <- function(x) {
  finite_vals <- x[is.finite(x)]
  if (length(finite_vals) == 0L) return(rep(NA_real_, length(x)))
  p10 <- quantile(finite_vals, 0.10, names = FALSE)
  p90 <- quantile(finite_vals, 0.90, names = FALSE)
  bound <- max(abs(p10), abs(p90), na.rm = TRUE)
  if (!is.finite(bound) || bound == 0) return(rep(0, length(x)))
  pmin(1, pmax(-1, x / bound))
}

norm_rank <- function(x) {
  finite_vals <- x[is.finite(x)]
  if (length(finite_vals) == 0L) return(rep(NA_real_, length(x)))
  max_rank <- max(finite_vals)
  min_rank <- min(finite_vals)
  if (max_rank == min_rank) return(rep(1.0, length(x)))
  1 - ((x - min_rank) / (max_rank - min_rank))
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

index_or_pct <- function(value) {
  value <- replace_na(value, 0)
  scaled <- ifelse(abs(value) <= 1, value * 100, value)
  as.integer(round(pmin(100, pmax(0, scaled))))
}

finite_median <- function(value) {
  value <- as.numeric(value)
  value <- value[is.finite(value)]
  if (length(value) == 0L) return(NA_real_)
  stats::median(value)
}

finite_mean <- function(value) {
  value <- as.numeric(value)
  value <- value[is.finite(value)]
  if (length(value) == 0L) return(NA_real_)
  mean(value)
}

finite_max <- function(value) {
  value <- as.numeric(value)
  value <- value[is.finite(value)]
  if (length(value) == 0L) return(NA_real_)
  max(value)
}

finite_min <- function(value) {
  value <- as.numeric(value)
  value <- value[is.finite(value)]
  if (length(value) == 0L) return(NA_real_)
  min(value)
}

finite_first <- function(value) {
  value <- as.numeric(value)
  value <- value[is.finite(value)]
  if (length(value) == 0L) return(NA_real_)
  value[[1L]]
}

land_use_class <- function(tree, shrub, grass, water = NA_real_, built = NA_real_, bare = NA_real_) {
  tree_v <- replace_na(tree, -Inf)
  shrub_v <- replace_na(shrub, -Inf)
  grass_v <- replace_na(grass, -Inf)
  water_v <- replace_na(water, -Inf)
  built_v <- replace_na(built, -Inf)
  bare_v <- replace_na(bare, -Inf)
  fractions <- c(tree_v, shrub_v, grass_v, water_v, built_v, bare_v)
  max_v <- max(fractions)
  sorted <- sort(fractions[fractions > -Inf], decreasing = TRUE)
  second_v <- if (length(sorted) >= 2L) sorted[[2L]] else 0

  case_when(
    !is.finite(max_v) ~ "unknown",
    max_v < 0.35 ~ "mixed",
    (max_v - second_v) < 0.12 ~ "mixed",
    tree_v == max_v ~ "tree",
    shrub_v == max_v ~ "shrub",
    grass_v == max_v ~ "grass",
    water_v == max_v ~ "water",
    built_v == max_v ~ "built",
    bare_v == max_v ~ "bare",
    TRUE ~ "mixed"
  )
}

derive_pressures <- function(n_obs, n_survey_dates, richness_corrected,
                             expected_richness, ecological_residual,
                             fragmentation_index, corridor_importance,
                             is_unsampled = FALSE, temporal_bias_flag = FALSE) {
  pressures <- character(0)
  if (isTRUE(is_unsampled)) {
    return(c("Unsampled cell — no accessible pedestrian path length from OSM"))
  }
  if (replace_na(n_obs, 0L) == 0L) {
    pressures <- c(pressures, "No biodiversity observations recorded in this cell")
  }
  if (isTRUE(temporal_bias_flag)) {
    pressures <- c(pressures, "Temporal sampling bias — observations are weekend-only")
  }
  if (replace_na(n_survey_dates, 0L) < 2L && replace_na(n_obs, 0L) > 0L) {
    pressures <- c(pressures, "Low survey effort — fewer than 2 distinct survey dates")
  }
  if (!is.na(ecological_residual) && ecological_residual > 20) {
    pressures <- c(
      pressures,
      sprintf(
        "Effort-corrected richness (%.1f) is below the habitat expectation (%.0f)",
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

species_list <- function(plant, bird, insect, mammal, fungi, taxa = NULL) {
  types <- c("plant", "bird", "insect", "mammal", "fungi")
  counts <- list(plant, bird, insect, mammal, fungi)
  lapply(seq_along(types), function(i) {
    entry <- list(
      type  = types[i],
      count = as.integer(replace_na(counts[[i]], 0L))
    )
    if (!is.null(taxa)) {
      nm <- taxa[[types[i]]]
      if (!is.null(nm) && length(nm) > 0L) {
        entry$names <- I(as.list(as.character(unlist(nm))))
      }
    }
    entry
  })
}

merge_park_taxa <- function(cell_ids, cell_taxa_lookup) {
  types <- c("plant", "bird", "insect", "mammal", "fungi")
  out <- setNames(vector("list", length(types)), types)
  for (t in types) {
    out[[t]] <- sort(unique(unlist(lapply(cell_ids, function(cid) {
      local_id <- sub(paste0("^", CITY_ID, "-"), "", cid)
      tx <- normalize_cell_taxa(cell_taxa_lookup[[local_id]])
      if (is.null(tx)) return(character())
      tx[[t]]
    }))))
  }
  out
}

normalize_cell_taxa <- function(taxa) {
  if (is.null(taxa)) return(NULL)
  if (length(taxa) == 1L && is.list(taxa[[1L]]) && !is.null(taxa[[1L]]$plant)) {
    taxa <- taxa[[1L]]
  }
  types <- c("plant", "bird", "insect", "mammal", "fungi")
  out <- stats::setNames(vector("list", length(types)), types)
  for (t in types) {
    val <- taxa[[t]]
    if (is.null(val)) {
      out[[t]] <- character()
    } else if (is.character(val)) {
      out[[t]] <- val
    } else {
      out[[t]] <- as.character(unlist(val))
    }
  }
  out
}

cell_stats_row <- function(row, max_expected, cell_taxa_lookup = list()) {
  hq <- replace_na(row$habitat_quality, 0)
  local_id <- sub(paste0("^", CITY_ID, "-"), "", row$cell_id)
  taxa <- normalize_cell_taxa(cell_taxa_lookup[[local_id]])
  nature_gap <- if (isTRUE(row$is_unsampled)) NA_real_ else round(replace_na(row$nature_gap_score, 0), 1)
  list(
    parkId               = row$park_id,
    impactScore          = as.integer(round(replace_na(nature_gap, 0))),
    natureGapScore       = nature_gap,
    habitatQuality       = pct_index(hq),
    habitatQualityIndex  = round(hq, 4),
    speciesRichnessRaw   = as.integer(replace_na(row$species_richness, 0L)),
    observedRichness     = if (isTRUE(row$is_unsampled)) NA_real_ else round(replace_na(row$observed_richness, 0), 1),
    effortCorrectedRichness = if (isTRUE(row$is_unsampled)) NA_real_ else round(replace_na(row$effort_corrected_richness, row$richness_corrected), 1),
    expectedRichness     = round(replace_na(row$expected_richness, 0), 1),
    maxExpectedRichness  = as.integer(max_expected),
    ecologicalResidual   = if (isTRUE(row$is_unsampled)) NA_real_ else round(replace_na(row$ecological_residual, 0), 1),
    ecologicalResidualNormalized = if (isTRUE(row$is_unsampled)) NA_real_ else round(replace_na(row$ecological_residual_normalized, 0), 4),
    isUnsampled          = isTRUE(row$is_unsampled),
    temporalBiasFlag     = isTRUE(row$temporal_bias_flag),
    pathKm               = round(replace_na(row$path_km, 0), 4),
    nObs                 = as.integer(replace_na(row$n_obs, 0L)),
    nSurveyDates         = as.integer(replace_na(row$n_survey_dates, 0L)),
    status               = unbox(score_status(nature_gap)),
    habitatPotential     = unbox(habitat_potential(hq)),
    observerEffortScore  = round(
      replace_na(row$n_obs, 0) / pmax(replace_na(row$path_km, 0), 0.01),
      1
    ),
    taxonomicDiversity = round(replace_na(row$taxonomic_shannon, 0), 1),
    species            = species_list(
      row$plant, row$bird, row$insect, row$mammal, row$fungi, taxa = taxa
    ),
    corridorImportance = pct_index(row$corridor_importance),
    betweennessCentrality = pct_index(row$betweenness_centrality),
    fragmentationIndex = pct_index(row$fragmentation_index),
    treeCover          = pct_index(row$tree_fraction),
    meanCanopy         = index_or_pct(row$mean_canopy),
    canopyHeightIdx    = pct_index(row$canopy_height_idx),
    heatExposure       = pct_index(row$lst_rank),
    meanLst            = index_or_pct(row$mean_lst),
    lstIdx             = pct_index(row$lst_idx),
    landUseGreen       = pct_index(row$green_fraction_wc),
    landUseClass       = unbox(land_use_class(
      row$tree_fraction, row$shrub_fraction, row$grass_fraction,
      row$water_fraction, row$built_fraction_wc, row$bare_fraction
    )),
    interventionRank   = as.integer(replace_na(row$intervention_rank, 50L)),
    pressures          = as.list(derive_pressures(
      row$n_obs, row$n_survey_dates, row$observed_richness,
      row$expected_richness, row$ecological_residual,
      row$fragmentation_index, row$corridor_importance,
      row$is_unsampled, row$temporal_bias_flag
    )),
    interventions      = list()
  )
}

aggregate_park_stats <- function(rows, max_expected, cell_taxa_lookup = list(), patch_metrics = NULL) {
  if (nrow(rows) == 0) return(NULL)
  sampled <- !rows$is_unsampled
  hq_mean <- finite_mean(rows$habitat_quality)
  patch_habitat_quality <- finite_first(patch_metrics$habitat_quality_index)
  patch_observed <- finite_first(patch_metrics$observed_richness)
  patch_effort_corrected <- finite_first(patch_metrics$effort_corrected_richness)
  patch_expected <- finite_first(patch_metrics$expected_richness)
  patch_residual <- finite_first(patch_metrics$ecological_residual)
  patch_residual_normalized <- finite_first(patch_metrics$ecological_residual_normalized)
  patch_data_availability <- finite_first(patch_metrics$data_availability_ratio)
  patch_nature_gap <- finite_first(patch_metrics$nature_gap_score)
  aggregate_nature_gap <- if (is.finite(patch_nature_gap)) {
    round(patch_nature_gap, 1)
  } else if (any(sampled)) {
    round(replace_na(finite_mean(rows$nature_gap_score[sampled]), 0), 1)
  } else {
    NA_real_
  }
  patch_corridor <- finite_first(patch_metrics$corridor_importance)
  patch_betweenness <- finite_first(patch_metrics$betweenness_centrality)
  patch_rank <- finite_first(patch_metrics$intervention_rank)
  park_taxa <- merge_park_taxa(rows$cell_id, cell_taxa_lookup)
  list(
    impactScore          = as.integer(round(replace_na(aggregate_nature_gap, 0))),
    natureGapScore       = aggregate_nature_gap,
    habitatQuality       = pct_index(coalesce(patch_habitat_quality, hq_mean)),
    habitatQualityIndex  = round(replace_na(coalesce(patch_habitat_quality, hq_mean), 0), 4),
    speciesRichnessRaw   = as.integer(sum(replace_na(rows$species_richness, 0L))),
    observedRichness     = if (is.finite(patch_observed)) round(patch_observed, 1) else if (any(sampled)) round(sum(replace_na(rows$observed_richness[sampled], 0)), 1) else NA_real_,
    effortCorrectedRichness = if (is.finite(patch_effort_corrected)) round(patch_effort_corrected, 1) else if (any(sampled)) round(sum(replace_na(rows$effort_corrected_richness[sampled], 0)), 1) else NA_real_,
    expectedRichness     = if (is.finite(patch_expected)) round(patch_expected, 1) else round(replace_na(finite_mean(rows$expected_richness), 0), 1),
    maxExpectedRichness  = as.integer(max_expected),
    ecologicalResidual   = if (is.finite(patch_residual)) round(patch_residual, 1) else if (any(sampled)) round(finite_mean(rows$ecological_residual[sampled]), 1) else NA_real_,
    ecologicalResidualNormalized = if (is.finite(patch_residual_normalized)) round(patch_residual_normalized, 4) else if (any(sampled)) round(finite_mean(rows$ecological_residual_normalized[sampled]), 4) else NA_real_,
    habitatQualityNorm = round(replace_na(finite_first(patch_metrics$habitat_quality_norm), 0.5), 4),
    effortCorrectedRichnessNorm = round(replace_na(finite_first(patch_metrics$effort_corrected_richness_norm), 0.5), 4),
    expectedRichnessNorm = round(replace_na(finite_first(patch_metrics$expected_richness_norm), 0.5), 4),
    corridorImportanceNorm = round(replace_na(finite_first(patch_metrics$corridor_importance_norm), 0.5), 4),
    meanCanopyNorm = round(replace_na(finite_first(patch_metrics$mean_canopy_norm), 0.5), 4),
    meanLstNorm = round(replace_na(finite_first(patch_metrics$mean_lst_norm), 0.5), 4),
    ecologicalResidualNorm = round(replace_na(finite_first(patch_metrics$ecological_residual_norm), 0), 4),
    natureGapScoreNorm = round(replace_na(finite_first(patch_metrics$nature_gap_score_norm), 0), 4),
    interventionRankNorm = round(replace_na(finite_first(patch_metrics$intervention_rank_norm), 0.5), 4),
    dataAvailabilityRatio = if (is.finite(patch_data_availability)) round(patch_data_availability, 4) else if (nrow(rows) > 0) round(sum(sampled, na.rm = TRUE) / nrow(rows), 4) else NA_real_,
    nObs                 = as.integer(sum(replace_na(rows$n_obs, 0L))),
    nSurveyDates         = as.integer(max(replace_na(rows$n_survey_dates, 0L))),
    status               = unbox(score_status(aggregate_nature_gap)),
    habitatPotential     = unbox(habitat_potential(hq_mean)),
    observerEffortScore  = round(
      replace_na(finite_mean(replace_na(rows$n_obs, 0) / pmax(replace_na(rows$path_km, 0), 0.01)), 0),
      1
    ),
    taxonomicDiversity = round(replace_na(finite_mean(rows$taxonomic_shannon), 0), 1),
    species = species_list(
      sum(replace_na(rows$plant, 0L)),
      sum(replace_na(rows$bird, 0L)),
      sum(replace_na(rows$insect, 0L)),
      sum(replace_na(rows$mammal, 0L)),
      sum(replace_na(rows$fungi, 0L)),
      taxa = park_taxa
    ),
    corridorImportance = pct_index(if (is.finite(patch_corridor)) patch_corridor else finite_max(rows$corridor_importance)),
    betweennessCentrality = pct_index(if (is.finite(patch_betweenness)) patch_betweenness else finite_max(rows$betweenness_centrality)),
    fragmentationIndex = pct_index(finite_mean(rows$fragmentation_index)),
    treeCover          = pct_index(finite_mean(rows$tree_fraction)),
    meanCanopy         = index_or_pct(finite_mean(rows$mean_canopy)),
    canopyHeightIdx    = pct_index(finite_mean(rows$canopy_height_idx)),
    heatExposure       = pct_index(finite_mean(rows$lst_rank)),
    meanLst            = index_or_pct(finite_mean(rows$mean_lst)),
    lstIdx             = pct_index(finite_mean(rows$lst_idx)),
    landUseGreen       = pct_index(finite_mean(rows$green_fraction_wc)),
    landUseClass       = unbox(land_use_class(
      finite_mean(rows$tree_fraction),
      finite_mean(rows$shrub_fraction),
      finite_mean(rows$grass_fraction),
      finite_mean(rows$water_fraction),
      finite_mean(rows$built_fraction_wc),
      finite_mean(rows$bare_fraction)
    )),
    interventionRank   = as.integer(if (is.finite(patch_rank)) patch_rank else finite_min(rows$intervention_rank)),
    pressures = unique(unlist(lapply(seq_len(nrow(rows)), function(i) {
      derive_pressures(
        rows$n_obs[i], rows$n_survey_dates[i], rows$observed_richness[i],
        rows$expected_richness[i], rows$ecological_residual[i],
        rows$fragmentation_index[i], rows$corridor_importance[i],
        rows$is_unsampled[i], rows$temporal_bias_flag[i]
      )
    }))),
    interventions = list()
  )
}

# ── 1. Park polygons → GeoJSON ───────────────────────────────────────────────

park_lookup <- tibble(park_id = character(), park_name = character())
green_metrics <- tibble(
  park_id = character(),
  habitat_quality_index = numeric(),
  observed_richness = numeric(),
  effort_corrected_richness = numeric(),
  survey_effort_units = numeric(),
  expected_richness = numeric(),
  ecological_residual = numeric(),
  ecological_residual_normalized = numeric(),
  data_availability_ratio = numeric(),
  nature_gap_score = numeric(),
  corridor_importance = numeric(),
  betweenness_centrality = numeric(),
  intervention_rank = numeric()
)
green <- NULL
green_path <- if (file.exists(PROC_GREEN_SPACES)) PROC_GREEN_SPACES else RAW_OSM_GREEN

if (file.exists(green_path)) {
  green_raw <- suppressWarnings(
    st_read(green_path, quiet = TRUE) |>
      st_transform(4326) |>
      st_collection_extract("POLYGON", warn = FALSE)
  )

  if (!"green_space_id" %in% names(green_raw)) green_raw$green_space_id <- NA_character_
  if (!"osm_id" %in% names(green_raw)) green_raw$osm_id <- seq_len(nrow(green_raw))
  if (!"source_feature_id" %in% names(green_raw)) green_raw$source_feature_id <- NA_character_
  if (!"name" %in% names(green_raw)) green_raw$name <- NA_character_
  if (!"name:ja" %in% names(green_raw)) green_raw[["name:ja"]] <- NA_character_
  if (!"nameJa" %in% names(green_raw)) green_raw$nameJa <- NA_character_
  if (!"wardId" %in% names(green_raw)) green_raw$wardId <- NA_character_
  for (col in c(
    "habitat_quality_index", "observed_richness", "effort_corrected_richness",
    "survey_effort_units", "expected_richness",
    "ecological_residual", "ecological_residual_normalized",
    "data_availability_ratio", "nature_gap_score", "corridor_importance",
    "betweenness_centrality", "intervention_rank", "mean_canopy", "mean_lst"
  )) {
    if (!col %in% names(green_raw)) green_raw[[col]] <- NA_real_
  }

  green <- green_raw |>
    mutate(
      source_id = coalesce(as.character(source_feature_id), as.character(osm_id), as.character(row_number())),
      name = coalesce(as.character(name), paste("Green space", source_id)),
      nameJa = coalesce(as.character(nameJa), as.character(.data[["name:ja"]]), name),
      id = if_else(
        !is.na(green_space_id) & nzchar(green_space_id),
        green_space_id,
        {
          slug <- make_slug(coalesce(name, source_id))
          dplyr::if_else(nchar(slug) > 0L, slug, paste0("park-", source_id))
        }
      ),
      wardId = coalesce(as.character(wardId), NA_character_)
    ) |>
    mutate(
      habitat_quality_norm           = norm_sequential(habitat_quality_index),
      effort_corrected_richness_norm = norm_sequential(effort_corrected_richness),
      expected_richness_norm         = norm_sequential(expected_richness),
      corridor_importance_norm       = norm_sequential(corridor_importance),
      mean_canopy_norm               = norm_sequential(mean_canopy),
      mean_lst_norm                  = norm_sequential(mean_lst),
      ecological_residual_norm       = norm_diverging(ecological_residual),
      nature_gap_score_norm          = norm_diverging(nature_gap_score),
      intervention_rank_norm         = norm_rank(intervention_rank)
    ) |>
    select(
      id, name, nameJa, wardId,
      habitat_quality_index, observed_richness, effort_corrected_richness,
      survey_effort_units, expected_richness,
      ecological_residual, ecological_residual_normalized,
      data_availability_ratio, nature_gap_score, corridor_importance,
      betweenness_centrality, intervention_rank,
      habitat_quality_norm, effort_corrected_richness_norm, expected_richness_norm,
      corridor_importance_norm, mean_canopy_norm, mean_lst_norm,
      ecological_residual_norm, nature_gap_score_norm, intervention_rank_norm
    )

  park_lookup <- green |>
    st_drop_geometry() |>
    transmute(park_id = id, park_name = name)

  green_metrics <- green |>
    st_drop_geometry() |>
    transmute(
      park_id = id,
      habitat_quality_index,
      observed_richness,
      effort_corrected_richness,
      survey_effort_units,
      expected_richness,
      ecological_residual,
      ecological_residual_normalized,
      data_availability_ratio,
      nature_gap_score,
      corridor_importance,
      betweenness_centrality,
      intervention_rank,
      habitat_quality_norm,
      effort_corrected_richness_norm,
      expected_richness_norm,
      corridor_importance_norm,
      mean_canopy_norm,
      mean_lst_norm,
      ecological_residual_norm,
      nature_gap_score_norm,
      intervention_rank_norm
    )

} else {
  message(sprintf("Skipping parks.geojson — %s not found", green_path))
}

# ── 3. Vector grid → PMTiles (frontend) + GeoJSON (PostGIS import) ───────────

grid_raw <- st_read(PROC_GRID_RESID, quiet = TRUE) |>
  st_transform(4326)

if (!exists("MAX_EXPECTED_RICHNESS")) MAX_EXPECTED_RICHNESS <- 350L

if (!"is_habitat" %in% names(grid_raw)) {
  grid_raw$is_habitat <- grid_raw$habitat_quality > 0
}
if (!"effort_corrected_richness" %in% names(grid_raw)) {
  grid_raw$effort_corrected_richness <- grid_raw$richness_corrected
}
if (!"species_richness" %in% names(grid_raw)) grid_raw$species_richness <- grid_raw$richness_corrected
if (!"path_km" %in% names(grid_raw)) grid_raw$path_km <- 0
if (!"observed_richness" %in% names(grid_raw)) grid_raw$observed_richness <- grid_raw$effort_corrected_richness
if (!"ecological_residual_normalized" %in% names(grid_raw)) grid_raw$ecological_residual_normalized <- NA_real_
if (!"ecological_residual_mean" %in% names(grid_raw)) grid_raw$ecological_residual_mean <- NA_real_
if (!"ecological_residual_std" %in% names(grid_raw)) grid_raw$ecological_residual_std <- NA_real_
if (!"survey_effort_units" %in% names(grid_raw)) {
  grid_raw$survey_effort_units <- if_else(
    replace_na(grid_raw$path_km, 0) <= 0,
    NA_real_,
    log1p(replace_na(grid_raw$path_km, 0))
  )
}
if (!"nature_gap_score" %in% names(grid_raw)) grid_raw$nature_gap_score <- NA_real_
if (!"mean_canopy" %in% names(grid_raw)) grid_raw$mean_canopy <- grid_raw$tree_fraction
if (!"canopy_height_idx" %in% names(grid_raw)) grid_raw$canopy_height_idx <- NA_real_
if (!"mean_lst" %in% names(grid_raw)) {
  grid_raw$mean_lst <- grid_raw$lst_rank
}
if (!"lst_idx" %in% names(grid_raw)) grid_raw$lst_idx <- NA_real_
if (!"betweenness_centrality" %in% names(grid_raw)) grid_raw$betweenness_centrality <- grid_raw$corridor_importance
if (!"is_unsampled" %in% names(grid_raw)) grid_raw$is_unsampled <- replace_na(grid_raw$path_km, 0) <= 0
if (!"temporal_bias_flag" %in% names(grid_raw)) grid_raw$temporal_bias_flag <- FALSE
if (!"taxonomic_shannon" %in% names(grid_raw) && "species_shannon" %in% names(grid_raw)) {
  grid_raw$taxonomic_shannon <- grid_raw$species_shannon
}
for (col in c("plant", "bird", "insect", "mammal", "fungi", "n_survey_dates", "path_km")) {
  if (!col %in% names(grid_raw)) grid_raw[[col]] <- 0
}
for (col in c(
  "tree_fraction", "shrub_fraction", "grass_fraction", "water_fraction",
  "built_fraction_wc", "bare_fraction", "impervious_fraction",
  "green_fraction_wc", "lst_rank"
)) {
  if (!col %in% names(grid_raw)) grid_raw[[col]] <- NA_real_
}

grid <- grid_raw |>
  select(
    cell_id, any_of("green_space_id"), habitat_quality, impact_score, nature_gap_score, composite, intervention_rank, is_habitat,
    any_of(c("tree_fraction", "shrub_fraction", "grass_fraction",
             "built_fraction_wc", "green_fraction_wc",
             "water_fraction", "bare_fraction",
             "impervious_fraction", "osm_green_fraction")),
    any_of(c("ndvi_mean", "lst_rank", "heat_exposure", "noise",
             "light_pollution", "disturbance_index", "water_proximity",
             "mean_canopy", "mean_lst",
             "canopy_height_idx", "lst_idx")),
    corridor_importance, connectivity_score, node_importance,
    betweenness_centrality,
    fragmentation_index, patch_area_ha,
    n_obs, species_richness, richness_corrected, observed_richness,
    effort_corrected_richness, survey_effort_units,
    taxonomic_shannon, is_unsampled, temporal_bias_flag,
    n_survey_dates, path_km,
    plant, bird, insect, mammal, fungi,
    expected_richness, ecological_residual, ecological_residual_normalized,
    ecological_residual_mean, ecological_residual_std
  )

n_total  <- nrow(grid_raw)
n_green  <- sum(replace_na(grid$habitat_quality, 0) > 0)
cat(sprintf("  → %d / %d cells retained (habitat_quality > 0)\n", n_green, n_total))

grid_all <- grid |> mutate(cell_id = paste0(CITY_ID, "-", cell_id))

# (Helpers defined globally above)

for (col in c(
  "ndvi_mean", "canopy_height_idx", "lst_idx",
  "disturbance_index", "betweenness_centrality", "ecological_residual", "nature_gap_score",
  "expected_richness", "intervention_rank", "habitat_quality"
)) {
  if (!col %in% names(grid_all)) grid_all[[col]] <- NA_real_
}

grid_all <- grid_all |>
  mutate(
    ndvi_norm             = norm_sequential(ndvi_mean),
    canopy_norm           = norm_sequential(canopy_height_idx),
    lst_norm              = norm_sequential(lst_idx),
    disturbance_norm      = norm_sequential(disturbance_index),
    betweenness_norm      = norm_sequential(betweenness_centrality),
    residual_norm         = norm_diverging(ecological_residual),
    nature_gap_score_norm = norm_diverging(nature_gap_score),
    expected_richness_norm = norm_sequential(expected_richness),
    intervention_rank_norm = norm_rank(intervention_rank),
    habitat_quality_norm  = norm_sequential(habitat_quality)
  )

grid <- grid_all |> filter(habitat_quality > 0)

# ── Assign each cell to its canonical green-space patch ─────────────────────

osm_parks_path <- RAW_OSM_GREEN

if ("green_space_id" %in% names(grid) && nrow(park_lookup) > 0L) {
  grid <- grid |>
    left_join(park_lookup, by = c("green_space_id" = "park_id")) |>
    mutate(
      park_id = green_space_id,
      park_name = coalesce(park_name, green_space_id, "Green area")
    )
  cat(sprintf("  → Park attribution: %d cells linked by canonical green_space_id\n",
              sum(!is.na(grid$park_id), na.rm = TRUE)))
} else if (file.exists(osm_parks_path)) {
  osm_parks_4326 <- suppressWarnings(
    st_read(osm_parks_path, quiet = TRUE) |>
      st_transform(4326) |>
      st_collection_extract("POLYGON", warn = FALSE)
  ) |>
    transmute(
      park_id = {
        slug <- make_slug(coalesce(as.character(name), paste0("park-", row_number())))
        dplyr::if_else(nchar(slug) > 0L, slug, paste0("park-", row_number()))
      },
      park_name = coalesce(as.character(name), paste("Green area", row_number()))
    )

  park_assignment <- grid |>
    (\(x) suppressWarnings(st_centroid(x)))() |>
    st_join(osm_parks_4326, join = st_within, left = TRUE) |>
    st_drop_geometry() |>
    select(cell_id, park_id, park_name) |>
    group_by(cell_id) |>
    summarise(
      park_id = dplyr::first(park_id[!is.na(park_id)]),
      park_name = dplyr::first(park_name[!is.na(park_name)]),
      .groups = "drop"
    )

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

grid_df <- st_drop_geometry(grid)
n_cells <- nrow(grid_df)

cell_taxa_lookup <- list()
if (file.exists(PROC_CELL_TAXA)) {
  cell_taxa_lookup <- jsonlite::read_json(PROC_CELL_TAXA, simplifyVector = FALSE)
  cat(sprintf("  → Loaded taxa names for %d cells\n", length(cell_taxa_lookup)))
} else {
  message(sprintf("No %s — species counts only (no name lists)", PROC_CELL_TAXA))
}

# Top interventions with park attribution. Full intervention descriptions are
# stored in PostgreSQL for click-time detail, not in PMTiles.
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

hexgrid_render <- grid |>
  filter(!is.na(park_id), park_id != "city-green")

if (!is.null(green)) {
  metric_park_ids <- unique(hexgrid_render$park_id)
  green_export <- green |>
    filter(id %in% metric_park_ids)

  parks_path <- file.path(DATA_EXPORT, "parks.geojson")
  write_geojson(green_export, parks_path)
  cat(sprintf("Written: %s (%d metric-backed parks)\n", parks_path, nrow(green_export)))
}

cat(sprintf(
  "  → PMTiles render grid: %d / %d cells inside named green spaces\n",
  nrow(hexgrid_render), nrow(grid)
))

hexgrid_tiles <- hexgrid_render |>
  transmute(
    cellId             = cell_id,
    parkId             = park_id,
    parkName           = park_name,
    impactScore        = as.integer(round(replace_na(nature_gap_score, 0))),
    natureGapScore     = if_else(is_unsampled, 0, round(replace_na(nature_gap_score, 0), 1)),
    expectedRichness   = round(replace_na(expected_richness, 0), 1),
    ecologicalResidual = if_else(is_unsampled, 0, round(replace_na(ecological_residual, 0), 1)),
    ecologicalResidualNormalized = if_else(is_unsampled, 0, round(replace_na(ecological_residual_normalized, 0), 4)),
    habitatQuality     = pct_index(habitat_quality),
    observedRichness   = if_else(is_unsampled, 0, round(replace_na(observed_richness, 0), 1)),
    corridorImportance = pct_index(corridor_importance),
    betweennessCentrality = pct_index(betweenness_centrality),
    treeCover          = pct_index(tree_fraction),
    meanCanopy         = index_or_pct(mean_canopy),
    canopyHeightIdx    = pct_index(canopy_height_idx),
    heatExposure       = pct_index(lst_rank),
    meanLst            = index_or_pct(mean_lst),
    lstIdx             = pct_index(lst_idx),
    landUseGreen       = pct_index(green_fraction_wc),
    landUseClass       = land_use_class(
      tree_fraction, shrub_fraction, grass_fraction,
      water_fraction, built_fraction_wc, bare_fraction
    ),
    interventionRank   = as.integer(replace_na(intervention_rank, 50L)),
    ndviNorm           = if_else(is_unsampled, 0, round(replace_na(ndvi_norm, 0), 4)),
    canopyNorm         = if_else(is_unsampled, 0, round(replace_na(canopy_norm, 0), 4)),
    lstNorm            = if_else(is_unsampled, 0, round(replace_na(lst_norm, 0), 4)),
    disturbanceNorm    = if_else(is_unsampled, 0, round(replace_na(disturbance_norm, 0), 4)),
    betweennessNorm    = if_else(is_unsampled, 0, round(replace_na(betweenness_norm, 0), 4)),
    residualNorm       = if_else(is_unsampled, 0, round(replace_na(residual_norm, 0), 4)),
    natureGapScoreNorm = if_else(is_unsampled, 0, round(replace_na(nature_gap_score_norm, 0), 4)),
    expectedNorm       = if_else(is_unsampled, 0, round(replace_na(expected_richness_norm, 0), 4)),
    interventionRankNorm = if_else(is_unsampled, 0, round(replace_na(intervention_rank_norm, 0), 4)),
    habitatQualityNorm = if_else(is_unsampled, 0, round(replace_na(habitat_quality_norm, 0), 4))
  )

hexgrid_pmtiles_path <- file.path(DATA_EXPORT, "hexgrid.pmtiles")
pmtiles_validation <- write_hexgrid_pmtiles(hexgrid_tiles, hexgrid_pmtiles_path)
cat(sprintf("Written: %s (source-layer: %s)\n", hexgrid_pmtiles_path, PMTILES_SOURCE_LAYER))

if (exists("PROC_CONNECTIVITY_GRAPH") && file.exists(PROC_CONNECTIVITY_GRAPH)) {
  connectivity_graph <- readRDS(PROC_CONNECTIVITY_GRAPH)
  graph_edges <- igraph::as_data_frame(connectivity_graph, what = "edges")
  graph_vertices <- igraph::as_data_frame(connectivity_graph, what = "vertices") |>
    select(name, x, y)

  if (nrow(graph_edges) > 0L && all(c("from", "to", "weight") %in% names(graph_edges))) {
    edge_coords <- graph_edges |>
      left_join(graph_vertices |> rename(from = name, x_from = x, y_from = y), by = "from") |>
      left_join(graph_vertices |> rename(to = name, x_to = x, y_to = y), by = "to") |>
      filter(
        is.finite(x_from), is.finite(y_from),
        is.finite(x_to), is.finite(y_to)
      )

    corridor_links <- st_sf(
      linkId = paste(edge_coords$from, edge_coords$to, sep = "--"),
      fromCellId = as.character(edge_coords$from),
      toCellId = as.character(edge_coords$to),
      weight = edge_coords$weight,
      geometry = st_sfc(
        lapply(seq_len(nrow(edge_coords)), function(i) {
          st_linestring(matrix(
            c(
              edge_coords$x_from[i], edge_coords$y_from[i],
              edge_coords$x_to[i], edge_coords$y_to[i]
            ),
            ncol = 2,
            byrow = TRUE
          ))
        }),
        crs = CRS_LOCAL
      )
    ) |>
      st_transform(4326)

    corridor_links_path <- file.path(DATA_EXPORT, "corridor-links.geojson")
    write_geojson_chunked(corridor_links, corridor_links_path)
    cat(sprintf("Written: corridor-links.geojson (%d graph edges)\n", nrow(corridor_links)))
  }
} else {
  message(sprintf("Skipping corridor-links.geojson — %s not found", PROC_CONNECTIVITY_GRAPH))
}

if (exists("PROC_CELL_ATTR") && file.exists(PROC_CELL_ATTR)) {
  cell_attr_base <- st_read(PROC_CELL_ATTR, quiet = TRUE) |>
    st_transform(4326) |>
    select(-any_of(c("nature_gap_score", "observed_richness")))
} else {
  cell_attr_base <- grid |>
    transmute(
      cell_id,
      expected_richness,
      effort_corrected_richness,
      survey_effort_units,
      ecological_residual,
      ecological_residual_normalized,
      ecological_residual_mean,
      ecological_residual_std,
      nature_gap_score,
      corridor_importance,
      intervention_rank,
      heat_exposure = lst_rank,
      noise = NA_real_,
      light_pollution = NA_real_,
      disturbance_index = NA_real_,
      fragmentation = fragmentation_index,
      fragmentation_index,
      water_proximity = NA_real_,
      connectivity_score = coalesce(connectivity_score, corridor_importance),
      node_importance = NA_real_,
      path_km,
      is_unsampled,
      temporal_bias_flag,
      last_updated = Sys.time()
    )
}

cell_detail_attrs <- grid_all |>
  rowwise() |>
  mutate(
    species = list(species_list(plant, bird, insect, mammal, fungi, taxa = normalize_cell_taxa(
      cell_taxa_lookup[[sub(paste0("^", CITY_ID, "-"), "", cell_id)]]
    ))),
    pressures = list(derive_pressures(
      n_obs, n_survey_dates, observed_richness,
      expected_richness, ecological_residual,
      fragmentation_index, corridor_importance,
      is_unsampled, temporal_bias_flag
    )),
    interventions = list({
      iv <- intervention_lookup[[cell_id]]
      if (is.null(iv)) list() else list(iv)
    })
  ) |>
  ungroup() |>
  st_drop_geometry() |>
  transmute(
    cell_id,
    impact_score = as.integer(round(replace_na(nature_gap_score, 0))),
    nature_gap_score = if_else(is_unsampled, NA_real_, round(replace_na(nature_gap_score, 0), 1)),
    habitat_quality = pct_index(habitat_quality),
    habitat_quality_index = round(replace_na(habitat_quality, 0), 4),
    species_richness_raw = as.integer(replace_na(species_richness, 0L)),
    observed_richness = if_else(is_unsampled, NA_real_, round(replace_na(observed_richness, 0), 1)),
    max_expected_richness = as.integer(MAX_EXPECTED_RICHNESS),
    n_obs = as.integer(replace_na(n_obs, 0L)),
    n_survey_dates = as.integer(replace_na(n_survey_dates, 0L)),
    habitat_potential = habitat_potential(habitat_quality),
    observer_effort_score = round(replace_na(n_obs, 0) / pmax(replace_na(path_km, 0), 0.01), 1),
    taxonomic_diversity = round(replace_na(taxonomic_shannon, 0), 1),
    species = vapply(
      species,
      jsonlite::toJSON,
      character(1),
      auto_unbox = TRUE, null = "null", na = "null"
    ),
    pressures = vapply(
      pressures,
      jsonlite::toJSON,
      character(1),
      auto_unbox = TRUE, null = "null", na = "null"
    ),
    interventions = vapply(
      interventions,
      jsonlite::toJSON,
      character(1),
      auto_unbox = TRUE, null = "null", na = "null"
    ),
    tree_cover = pct_index(tree_fraction),
    land_use_green = pct_index(green_fraction_wc)
  )

cell_attr <- cell_attr_base |>
  left_join(cell_detail_attrs, by = "cell_id") |>
  mutate(
    city_id = CITY_ID,
    dataset_id = DATA_VERSION,
    generated_at = GENERATED_AT
  )

cell_attr_path <- file.path(DATA_EXPORT, "cell_attributes.geojson")
write_geojson_chunked(cell_attr, cell_attr_path)
cat(sprintf("Written: %s\n", cell_attr_path))

# ── 4. Per-cell stats + park aggregates + interventions ───────────────────────

cat(sprintf("Building park aggregate stats from %d cells...\n", n_cells))

park_stats_out <- list()
for (pid in unique(grid_df$park_id)) {
  rows <- grid_df |> filter(park_id == pid)
  stats <- aggregate_park_stats(
    rows,
    MAX_EXPECTED_RICHNESS,
    cell_taxa_lookup,
    green_metrics |> filter(park_id == pid)
  )
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

staged <- stage_versioned_exports(
  pmtiles_validation,
  cell_count = nrow(hexgrid_tiles),
  park_count = length(park_stats_out)
)

storage_folder <- paste0("pipeline-export/", CITY_ID, "/", DATA_VERSION, "/")
cat(sprintf("\nExport complete for city: %s\n", CITY_ID))
cat(sprintf("Data version: %s\n", DATA_VERSION))
cat(sprintf("Upload these files to Supabase Storage folder '%s':\n", storage_folder))
for (f in staged$files) {
  p <- file.path(VERSIONED_EXPORT_DIR, f)
  sz <- file.info(p)$size / 1024^2
  cat(sprintf("  ✓ %s (%.1f MB)\n", f, sz))
}
cat(sprintf("Also upload/update stable pointer: pipeline-export/%s/current.json\n", CITY_ID))
