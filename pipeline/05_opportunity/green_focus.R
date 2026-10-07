# NatureGap — Step 05: Green focus (the Nature gap classes)
#
# Which green places councils should look at, and why. docs/methodology.md §16;
# settings: the "Green focus" block in config.R.
#
# Every green cell — one the map draws in its Tree cover and Vegetation layers
# (in_render_grid(), config.R) — gets two yes/no tests, from facts the pipeline
# already has:
#   connectivity role  its habitat patch is a stepping stone (dPC connector
#                      percentile >= FOCUS_STEPPING_PCT, 04_connectivity/
#                      patch_connectivity.R), or it is in the top
#                      FOCUS_CORRIDOR_PCT of corridor_importance, or it lies on
#                      a corridor bottleneck, or it is thin green (outside every
#                      habitat patch) in the top FOCUS_THIN_CORRIDOR_PCT of
#                      corridor_importance among thin green cells with routes
#   species recorded   at least one native species recorded within
#                      FOCUS_SPECIES_RADIUS_M, through load_obs_for_tiling()'s
#                      gates; introduced species (introduced_species.R) are left
#                      out
# which give four classes:
#   focus     role and species   — "focus here"
#   link      role, no species   — "link worth keeping; nothing recorded yet"
#   protect   species, no role, exposure <= FOCUS_PROTECT_MAX_EXPOSURE
#                                — "worth protecting"
#   green     everything else    — green space
# Exposure is heat and disturbance (noise and traffic together) ranked among the
# city's green cells. It gates "protect" only; elsewhere it is a hint for what
# kind of action fits. Parks are context only.
#
# Nothing here predicts species. Exposure describes measured pressures; the
# city's own species models do not show them lowering occupancy (§16), so it is
# reported, not scored. Records follow where people look: "no species recorded
# yet" is a prompt to survey, not an absence.
#
# Never breaks a run: an error leaves a warning and no outputs (stale ones are
# removed first).
#
# Outputs:
#   PROC_GREEN_FOCUS        per green cell: cell_id, focus_class, role_stepping,
#                           role_corridor, role_bottleneck, stepping_pct,
#                           corridor_importance, species_nearby, species_in_cell,
#                           heat_pct, disturbance_pct, exposure, exposure_hint,
#                           in_park
#   PROC_GREEN_FOCUS_MODEL  settings, class counts, tests (effort, robustness,
#                           species radius)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))
suppressMessages({library(sf); library(dplyr)})
if (!exists("load_obs_for_tiling")) {
  suppressMessages(source(here::here("02_habitat", "process_tile.R"), local = FALSE))
}
source(here::here("introduced_species.R"), local = FALSE)
source(here::here("04_connectivity", "connectivity_load.R"), local = FALSE)

FOCUS_CLASSES <- c("focus", "link", "protect", "green")

green_focus_run <- function() {
  t_start <- Sys.time()
  if (!requireNamespace("FNN", quietly = TRUE)) stop("package FNN is required")
  for (f in c(PROC_GRID_RESID, connectivity_paths()$nodes, PROC_PATCH_CONN, PROC_PATCH_CELLS, PROC_NETWORK_EDGES)) {
    if (!file.exists(f)) stop("missing input ", f, " — run 04_connectivity and 05_residuals first")
  }
  intro <- introduced_species(CITY_COUNTRY, BBOX_FETCH, fetch = FALSE)

  # ── Grid: green cells and their exposure ───────────────────────────────────
  have <- names(sf::st_read(PROC_GRID_RESID, query = "SELECT * FROM grid_residuals LIMIT 1", quiet = TRUE))
  want <- c("cell_id", "habitat_quality", "green_space_id", "veg_fraction", "tree_fraction",
            "shrub_fraction", "grass_fraction", "green_fraction_wc", "lst_celsius", "noise", "traffic_exposure",
            "path_km", "n_obs")
  geom_col <- attr(sf::st_read(PROC_GRID_RESID, query = "SELECT * FROM grid_residuals LIMIT 1", quiet = TRUE), "sf_column")
  grid <- sf::st_read(PROC_GRID_RESID, quiet = TRUE, query = sprintf(
    "SELECT %s, %s FROM grid_residuals", paste(intersect(want, have), collapse = ", "), geom_col))
  veg <- cell_vegetation(grid, verbose = FALSE)
  col <- function(v) if (v %in% names(grid)) grid[[v]] else rep(NA, nrow(grid))
  # Green = the cells the map draws (in_render_grid(), config.R), after the
  # export's own habitat_quality > 0 cut; parks by canonical green_space_id,
  # as the export's park attribution.
  green <- dplyr::coalesce(col("habitat_quality") > 0, FALSE) &
    in_render_grid(col("green_space_id"), col("tree_fraction"), col("shrub_fraction"),
                   col("grass_fraction"), col("green_fraction_wc"), col("veg_fraction"))
  xy <- sf::st_coordinates(suppressWarnings(sf::st_centroid(sf::st_geometry(grid))))
  cell_ids <- as.character(grid$cell_id)
  g_idx <- which(green)
  message(sprintf("[focus] %d of %d cells are green", length(g_idx), nrow(grid)))

  pct_rank <- function(v) { r <- rank(v, ties.method = "average", na.last = "keep"); r / sum(!is.na(v)) }
  heat_pct <- pct_rank(grid$lst_celsius[g_idx])
  disturbance_pct <- (pct_rank(grid$noise[g_idx]) + pct_rank(grid$traffic_exposure[g_idx])) / 2
  exposure <- rowMeans(cbind(heat_pct, disturbance_pct), na.rm = TRUE)
  exposure_hint <- as.character(cut(exposure, c(-Inf, FOCUS_EXPOSURE_BREAKS, Inf),
                                    labels = c("low", "moderate", "high")))

  # ── Connectivity role ──────────────────────────────────────────────────────
  nodes <- as.data.frame(arrow::read_parquet(connectivity_paths()$nodes))
  corridor <- nodes$corridor_importance[match(cell_ids[g_idx], as.character(nodes$node_id))]
  pcells <- as.data.frame(arrow::read_parquet(PROC_PATCH_CELLS))
  patches <- as.data.frame(arrow::read_parquet(PROC_PATCH_CONN))
  patch_id <- pcells$patch_id[match(cell_ids[g_idx], as.character(pcells$cell_id))]
  stepping <- patches$connector_pct[match(patch_id, patches$patch_id)]
  # Thin green — outside every habitat patch — ranked against its own kind.
  thin <- is.na(patch_id)
  thin_pct <- rep(NA_real_, length(g_idx))
  carries <- thin & !is.na(corridor) & corridor > 0
  thin_pct[carries] <- rank(corridor[carries], ties.method = "average") / sum(carries)
  edges <- sf::st_read(PROC_NETWORK_EDGES, quiet = TRUE)
  bn <- edges[edges$kind == "bottleneck", ]
  on_bottleneck <- if (nrow(bn) > 0L) {
    lengths(sf::st_intersects(sf::st_geometry(grid)[g_idx], sf::st_union(sf::st_transform(bn, sf::st_crs(grid))))) > 0L
  } else rep(FALSE, length(g_idx))

  # ── Parks (context only) ───────────────────────────────────────────────────
  in_park <- rep(FALSE, length(g_idx))
  if (file.exists(RAW_OSM_GREEN)) {
    gs <- sf::st_read(RAW_OSM_GREEN, quiet = TRUE)
    gs <- gs[!is.na(gs$leisure) & gs$leisure %in% c("park", "nature_reserve"), ]
    if (nrow(gs) > 0L) {
      gs <- sf::st_make_valid(sf::st_transform(gs, sf::st_crs(grid)))
      pts <- sf::st_as_sf(data.frame(x = xy[g_idx, 1], y = xy[g_idx, 2]), coords = c("x", "y"), crs = sf::st_crs(grid))
      in_park <- lengths(sf::st_intersects(pts, gs)) > 0L
    }
  }
  grid_crs <- sf::st_crs(grid)
  grid_geom <- sf::st_geometry(grid)
  path_km <- if ("path_km" %in% names(grid)) grid$path_km[g_idx] else rep(NA_real_, length(g_idx))
  n_obs <- if ("n_obs" %in% names(grid)) grid$n_obs[g_idx] else rep(NA_real_, length(g_idx))
  rm(grid); invisible(gc())

  # ── Native species recorded nearby ─────────────────────────────────────────
  obs <- load_obs_for_tiling(CRS_LOCAL)
  obs <- obs[!is.na(obs$taxon_name) & grepl(" ", obs$taxon_name) &
               !binomial(obs$taxon_name) %in% intro$taxon_name, ]
  obs <- sf::st_transform(obs, grid_crs)
  hit <- sf::st_intersects(obs, sf::st_sf(geometry = grid_geom))
  rec <- data.frame(cell = rep(seq_len(nrow(obs)), lengths(hit)), cidx = unlist(hit))
  rec$taxon <- binomial(obs$taxon_name)[rec$cell]
  rec <- dplyr::distinct(rec[, c("cidx", "taxon")])
  n_native_records <- nrow(obs)
  rm(obs, hit, grid_geom); invisible(gc())
  rec_cells <- sort(unique(rec$cidx))
  rec_by_cell <- split(rec$taxon, factor(rec$cidx, rec_cells))

  species_within <- function(radius) {
    k <- min(length(rec_cells), ceiling(pi * (radius + 25)^2 / (20^2 * sqrt(3) / 2)) + 5L)
    out <- integer(length(g_idx))
    for (ch in split(seq_along(g_idx), ceiling(seq_along(g_idx) / 50000))) {
      nn <- FNN::get.knnx(xy[rec_cells, , drop = FALSE], xy[g_idx[ch], , drop = FALSE], k = k)
      for (j in seq_along(ch)) {
        near <- nn$nn.index[j, nn$nn.dist[j, ] <= radius]
        if (length(near)) out[ch[j]] <- length(unique(unlist(rec_by_cell[near], use.names = FALSE)))
      }
    }
    out
  }
  species_nearby <- species_within(FOCUS_SPECIES_RADIUS_M)
  species_in_cell <- vapply(rec_by_cell[match(g_idx, rec_cells)], length, integer(1))

  # ── Classes ────────────────────────────────────────────────────────────────
  classify <- function(species, step_cut = FOCUS_STEPPING_PCT, corr_cut = FOCUS_CORRIDOR_PCT,
                       thin_cut = FOCUS_THIN_CORRIDOR_PCT, max_exposure = FOCUS_PROTECT_MAX_EXPOSURE) {
    role <- (!is.na(stepping) & stepping >= step_cut & stepping > 0) |
      (!is.na(corridor) & corridor >= corr_cut) | on_bottleneck |
      (!is.na(thin_pct) & thin_pct >= thin_cut)
    has_sp <- species > 0L
    calm <- !is.na(exposure) & exposure <= max_exposure
    factor(ifelse(role & has_sp, "focus", ifelse(role, "link", ifelse(has_sp & calm, "protect", "green"))),
           levels = FOCUS_CLASSES)
  }
  focus_class <- classify(species_nearby)

  # ── Tests ──────────────────────────────────────────────────────────────────
  agree <- function(alt) {
    list(sameClass = mean(alt == focus_class),
         focusJaccard = sum(alt == "focus" & focus_class == "focus") / max(1, sum(alt == "focus" | focus_class == "focus")))
  }
  rho <- function(a, b) suppressWarnings(stats::cor(as.numeric(a), as.numeric(b), method = "spearman", use = "complete.obs"))
  role_now <- focus_class %in% c("focus", "link")
  tests <- list(
    effort = list(
      note = "Spearman rho with path density (path_km) and record count (n_obs) over green cells",
      exposureVsPaths = rho(exposure, path_km),
      roleVsPaths = rho(role_now, path_km),
      speciesFloorVsPaths = rho(species_nearby > 0, path_km),
      roleVsRecords = rho(role_now, n_obs)
    ),
    robustness = list(
      steppingTopThird = agree(classify(species_nearby, step_cut = 2 / 3)),
      corridorTopThird = agree(classify(species_nearby, corr_cut = 2 / 3)),
      thinCorridorTopThird = agree(classify(species_nearby, thin_cut = 2 / 3)),
      protectExposureLowThird = agree(classify(species_nearby, max_exposure = 1 / 3)),
      speciesRadius100m = agree(classify(species_within(100)))
    ),
    speciesRadius = list(
      shareWithSpeciesNearby = mean(species_nearby > 0),
      shareWithSpeciesInCell = mean(species_in_cell > 0)
    )
  )

  cells_out <- data.frame(
    cell_id = cell_ids[g_idx],
    focus_class = as.character(focus_class),
    role_stepping = !is.na(stepping) & stepping >= FOCUS_STEPPING_PCT & stepping > 0,
    role_corridor = !is.na(corridor) & corridor >= FOCUS_CORRIDOR_PCT,
    role_bottleneck = on_bottleneck,
    role_thin_corridor = !is.na(thin_pct) & thin_pct >= FOCUS_THIN_CORRIDOR_PCT,
    stepping_pct = round(stepping, 4),
    corridor_importance = round(corridor, 4),
    thin_corridor_pct = round(thin_pct, 4),
    species_nearby = species_nearby,
    species_in_cell = species_in_cell,
    heat_pct = round(heat_pct, 4),
    disturbance_pct = round(disturbance_pct, 4),
    exposure = round(exposure, 4),
    exposure_hint = exposure_hint,
    in_park = in_park
  )
  counts <- table(focus_class)
  record <- list(
    cityId = CITY_ID,
    generatedAt = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    method = "docs/methodology.md §16",
    settings = list(greenRule = "in_render_grid()", cirVegRenderThreshold = CIR_VEG_RENDER_THRESHOLD,
                    steppingPct = FOCUS_STEPPING_PCT, corridorPct = FOCUS_CORRIDOR_PCT,
                    thinCorridorPct = FOCUS_THIN_CORRIDOR_PCT, protectMaxExposure = FOCUS_PROTECT_MAX_EXPOSURE,
                    speciesRadiusM = FOCUS_SPECIES_RADIUS_M, exposureBreaks = FOCUS_EXPOSURE_BREAKS,
                    maxAccuracyM = OBS_MAX_ACCURACY_M),
    cells = list(total = length(cell_ids), green = length(g_idx), inPark = sum(in_park)),
    records = list(nativeSpeciesLevel = n_native_records, cellsWithRecords = length(rec_cells)),
    classes = as.list(setNames(as.integer(counts), names(counts))),
    classesOutsideParks = as.list(table(factor(focus_class[!in_park], FOCUS_CLASSES))),
    roles = list(stepping = sum(cells_out$role_stepping), corridor = sum(cells_out$role_corridor),
                 bottleneck = sum(on_bottleneck), thinCorridor = sum(cells_out$role_thin_corridor),
                 thinGreenCells = sum(thin)),
    exposureByClass = lapply(split(exposure, focus_class), function(e) round(stats::median(e, na.rm = TRUE), 3)),
    tests = tests,
    runtimeMin = round(as.numeric(Sys.time() - t_start, units = "mins"), 2)
  )
  list(cells = cells_out, record = record)
}

unlink(c(PROC_GREEN_FOCUS, PROC_GREEN_FOCUS_MODEL))
focus_result <- tryCatch(green_focus_run(), error = function(e) {
  warning(sprintf("Green focus skipped for %s: %s", CITY_ID, conditionMessage(e)), call. = FALSE)
  NULL
})
if (!is.null(focus_result)) {
  data.table::fwrite(focus_result$cells, PROC_GREEN_FOCUS)
  jsonlite::write_json(focus_result$record, PROC_GREEN_FOCUS_MODEL,
                       auto_unbox = TRUE, pretty = TRUE, digits = NA, null = "null", na = "null")
  rec <- focus_result$record
  cat(sprintf("Green focus (%s): %d green cells — focus %d, link %d, protect %d, green %d (%d in parks)\n",
              CITY_ID, rec$cells$green, rec$classes$focus, rec$classes$link, rec$classes$protect,
              rec$classes$green, rec$cells$inPark))
  rb <- rec$tests$robustness
  cat("  robustness (same class / focus overlap): ",
      paste(sprintf("%s %.2f / %.2f", names(rb),
                    vapply(rb, `[[`, numeric(1), "sameClass"), vapply(rb, `[[`, numeric(1), "focusJaccard")),
            collapse = "; "), "\n", sep = "")
  ef <- rec$tests$effort
  cat(sprintf("  effort: rho with path density — exposure %.2f, role %.2f, species floor %.2f; role vs records %.2f\n",
              ef$exposureVsPaths, ef$roleVsPaths, ef$speciesFloorVsPaths, ef$roleVsRecords))
  cat(sprintf("  species within %g m: %.0f%% of green cells; in the cell itself: %.0f%%\n",
              FOCUS_SPECIES_RADIUS_M, 100 * rec$tests$speciesRadius$shareWithSpeciesNearby,
              100 * rec$tests$speciesRadius$shareWithSpeciesInCell))
  cat(sprintf("Written: %s, %s (%.1f min)\n", basename(PROC_GREEN_FOCUS), basename(PROC_GREEN_FOCUS_MODEL), rec$runtimeMin))
  rm(rec, rb, ef)
}
rm(focus_result); invisible(gc())
