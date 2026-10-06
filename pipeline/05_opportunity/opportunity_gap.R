# NatureGap — Step 05: Opportunity gap
#
# How many more native species each 20 m cell's surroundings would support with
# the tree and vegetation cover that places of the same land use in this city
# already reach. docs/methodology.md §15.
#
# Why not a measured gap: Porto's and Gent's records say what is present, not
# reliably what is missing — every per-place test of absence failed
# (sensitivity/prototype_spatial_gap.R, prototype_occupancy_gap.R). What they do
# support, pooled across the city, is which habitats go with which species, and
# the habitat layers cover every cell. Validated in
# sensitivity/prototype_opportunity_gap.R on Porto and Gent.
#
# Method (settings: "Opportunity gap" in config.R):
#   1. One occupancy model per native species of every group in
#      OPPORTUNITY_GROUPS recorded at OPPORTUNITY_MIN_SITES or more blocks of
#      OPPORTUNITY_BLOCK_M, with visit-based detection
#      (05_opportunity/occupancy_model.R). Occupancy covariates: habitat
#      (trees, grass/shrub, canopy height, 0.5 m vegetation, water, water
#      proximity, corridor importance, built cover, block size) and pressures
#      (heat anomaly, light, noise, traffic).
#   2. Each cell reads those covariates averaged within OPPORTUNITY_WINDOW_M.
#      Expected species = sum of psi over the counted species, per group and in
#      total.
#   3. Opportunity gap = expected species with trees, grass/shrub, canopy height
#      and 0.5 m vegetation raised to OPPORTUNITY_HABITAT_Q of cells whose
#      window has the same land use (06_export/export.R land_use_class()) —
#      gains in tree and grass/shrub cover come out of built cover, never water
#      — minus expected species now. Pressures stay in the models but are not a
#      lever: across blocks they cannot be told apart (noise and traffic r >
#      0.8), and lowering them gave fewer species in places, which is roads'
#      verge habitat showing through, not harm undone.
#   4. Every recorded native species too rare to model is listed per cell as
#      found within the window, rarest first — a fact, not a prediction.
#
# Introduced species (introduced_species.R, cached by
# 01_ingest/introduced_species.R) are not fitted and are left out of every sum,
# gap, test and list. Their records still count towards each visit's list
# length, which measures everyone else's detection: visits are built from all
# records before any species is set aside. (Fitting them changed nothing and
# cost most of the run: 402 of Gent's 587 qualifying plants are introduced.)
#
# Every group counts. Each is labelled per city by its own records test, rerun
# every time, and the labels travel with the numbers (PROC_OPPORTUNITY_MODEL):
#   checked       per well-recorded block, the group's expected species predict
#                 its recorded species beyond effort: partial Spearman rho >=
#                 OPPORTUNITY_PASS_RHO, p < 0.05, after removing log visits.
#   mismatch      tested on OPPORTUNITY_MIN_TEST_BLOCKS or more well-recorded
#                 blocks and did not match — not a lack of data: Porto's plants
#                 have ~10,000 records that follow botanists and gardens.
#   insufficient  fewer well-recorded blocks than that: too few records to test.
# Two citywide diagnostics are recorded beside them: signal (in well-recorded
# blocks, cross-validated psi separates recorded from unrecorded species better
# than psi permuted within species; also per group) and direction (woodland
# species gain with trees, built-up species have a positive built-cover
# coefficient).
#
# Never breaks a run: missing inputs or an error leave a warning and no outputs
# — the previous run's are removed first, so a stale gap can never be exported
# against a rebuilt grid.
#
# Outputs:
#   PROC_OPPORTUNITY        per cell: cell_id, land_use_window,
#                           expected_species, opportunity_gap, top_species,
#                           and per group g of OPPORTUNITY_GROUPS expected_<g>,
#                           gap_<g>, top_<g>; rare_species_n, rare_species
#   PROC_OPPORTUNITY_MODEL  settings, data window, species counted, introduced
#                           species left out and why, group labels, rare
#                           species summary, lever quantiles, standardisation,
#                           coefficients, validation

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))
suppressMessages({library(sf); library(dplyr); library(tidyr); library(terra)})

# load_obs_for_tiling() and classify_taxon_group(). Already loaded in a full
# run (step 2); process_tile.R defines functions only, so sourcing it alone
# runs nothing.
if (!exists("load_obs_for_tiling") || !exists("classify_taxon_group")) {
  suppressMessages(source(here::here("02_habitat", "process_tile.R"), local = FALSE))
}
source(here::here("05_opportunity", "occupancy_model.R"), local = FALSE)
source(here::here("introduced_species.R"), local = FALSE)

# land_use_class() lives in 06_export/export.R, which runs the whole export when
# sourced. Only its definition is evaluated, so "same land use" means exactly
# what the map's Land use layer means.
if (!exists("land_use_class")) {
  for (e in parse(here::here("06_export", "export.R"))) {
    if (is.call(e) && identical(e[[1]], as.name("<-")) &&
        identical(e[[2]], as.name("land_use_class"))) eval(e, envir = globalenv())
  }
}

OPPORTUNITY_HABITAT  <- c("tree", "grass_shrub", "canopy_height", "veg_fraction", "water",
                          "water_proximity", "corridor", "built")
OPPORTUNITY_PRESSURE <- c("heat", "light", "noise", "traffic")
OPPORTUNITY_COVARIATES <- c(OPPORTUNITY_HABITAT, OPPORTUNITY_PRESSURE, "log_cells")

opportunity_run <- function() {
  t_start <- Sys.time()
  if (!exists("land_use_class")) stop("land_use_class() not found in 06_export/export.R")
  # Fail fast, before any fitting, if the introduced-species caches are absent.
  intro <- introduced_species(CITY_COUNTRY, BBOX_FETCH, fetch = FALSE)

  grid <- st_read(PROC_GRID_RESID, quiet = TRUE, query = paste(
    "SELECT cell_id, tree_fraction, shrub_fraction, grass_fraction, water_fraction,",
    "built_fraction_wc, canopy_height_m, veg_fraction, water_proximity,",
    "corridor_importance, lst_celsius, light_pollution, noise, traffic_exposure, geom",
    "FROM grid_residuals"
  ))

  # The pipeline's own loader and quality gates, with the GPS gate at this
  # stage's scale. load_obs_for_tiling() reads the global, so it is swapped for
  # the call and always restored.
  saved_gate <- OBS_MAX_ACCURACY_M
  assign("OBS_MAX_ACCURACY_M", OPPORTUNITY_MAX_ACCURACY_M, envir = globalenv())
  obs_points <- tryCatch(
    load_obs_for_tiling(CRS_LOCAL),
    finally = assign("OBS_MAX_ACCURACY_M", saved_gate, envir = globalenv())
  )
  obs <- st_join(st_transform(obs_points, st_crs(grid)), grid["cell_id"],
                 join = st_within, left = FALSE) |>
    st_drop_geometry()
  rm(obs_points)

  xy <- st_coordinates(suppressWarnings(st_centroid(st_geometry(grid))))
  cells <- grid |>
    st_drop_geometry() |>
    transmute(
      cell_id,
      x = xy[, 1], y = xy[, 2],
      tree = tree_fraction, shrub = shrub_fraction, grass = grass_fraction,
      grass_shrub = grass_fraction + shrub_fraction,
      water = water_fraction,
      built = built_fraction_wc,
      canopy_height = canopy_height_m,
      veg_fraction,
      water_proximity,
      # NA where the connectivity stage scored no corridor; the pipeline reads
      # that as 0 too (connectivity_component in 05_residuals/residuals.R).
      corridor = replace_na(corridor_importance, 0),
      # A spatial anomaly in degrees from the city's mean, not a temperature.
      heat = lst_celsius,
      light = light_pollution,
      noise,
      traffic = traffic_exposure
    ) |>
    mutate(block = paste(floor(x / OPPORTUNITY_BLOCK_M), floor(y / OPPORTUNITY_BLOCK_M), sep = "_"))
  grid_crs <- st_crs(grid)
  rm(grid, xy); invisible(gc())

  # Every record passing the pipeline's gates feeds the rare-species list; the
  # models use the OPPORTUNITY_PERIOD_START window, over which each block's
  # community is assumed stable.
  all_records <- prepare_records(obs, as.Date("1900-01-01"), classify_taxon_group)
  all_records <- all_records[all_records$group %in% OPPORTUNITY_GROUPS, ]
  records <- all_records[all_records$date >= OPPORTUNITY_PERIOD_START, ]
  rm(obs); invisible(gc())
  if (nrow(records) == 0L) stop("no records of ", paste(OPPORTUNITY_GROUPS, collapse = ", "))

  raw_vars <- c(OPPORTUNITY_HABITAT, OPPORTUNITY_PRESSURE)
  blocks <- cells |>
    group_by(block) |>
    summarise(across(all_of(raw_vars), \(v) mean(v, na.rm = TRUE)), n_cells = n(), .groups = "drop") |>
    mutate(log_cells = log(n_cells))

  # Block statistics standardise both the blocks and the cell windows, so the
  # coefficients mean the same thing in both.
  scale_mu <- vapply(OPPORTUNITY_COVARIATES, \(v) mean(blocks[[v]], na.rm = TRUE), numeric(1))
  scale_sd <- vapply(OPPORTUNITY_COVARIATES, \(v) {
    s <- stats::sd(blocks[[v]], na.rm = TRUE); if (is.finite(s) && s > 0) s else 1
  }, numeric(1))
  design <- function(df) {
    z <- vapply(OPPORTUNITY_COVARIATES, \(v) {
      u <- (df[[v]] - scale_mu[[v]]) / scale_sd[[v]]; replace(u, !is.finite(u), 0)
    }, numeric(nrow(df)))
    cbind(1, matrix(z, nrow = nrow(df), dimnames = list(NULL, OPPORTUNITY_COVARIATES)))
  }

  vis <- build_site_visits(records, setNames(cells$block, cells$cell_id))
  folds_all <- assign_folds(blocks$block, OPPORTUNITY_CV_FOLDS, OPPORTUNITY_SEED)

  # ── 1. Species models: cross-validated for the tests, full for the map ────
  fit_group <- function(grp) {
    v <- vis$visits[vis$visits$group == grp, ]
    det <- vis$det[vis$det$group == grp, ]
    qualifying <- det |> distinct(site, taxon_name) |> count(taxon_name) |>
      filter(n >= OPPORTUNITY_MIN_SITES) |> pull(taxon_name)
    is_intro <- binomial(qualifying) %in% intro$taxon_name
    species <- qualifying[!is_intro]
    introduced_q <- data.frame(taxon_name = qualifying[is_intro], group = rep(grp, sum(is_intro)))
    if (length(species) == 0L) return(list(introduced = introduced_q))

    sites <- sort(unique(v$site))
    site_idx_all <- match(v$site, sites)
    X_all <- design(blocks[match(sites, blocks$block), ])
    Z_all <- detection_design(v)
    fold_of_site <- folds_all[sites]
    det_by_species <- split(match(det$visit_id, v$visit_id), det$taxon_name)

    fold_parts <- lapply(seq_len(OPPORTUNITY_CV_FOLDS), function(k) {
      tr_sites <- which(fold_of_site != k)
      te_sites <- which(fold_of_site == k)
      if (length(te_sites) == 0L || length(tr_sites) == 0L) return(NULL)
      tr_v <- which(site_idx_all %in% tr_sites)
      te_v <- which(site_idx_all %in% te_sites)
      list(te_sites = te_sites, tr_v = tr_v, te_v = te_v,
           tr_site = match(site_idx_all[tr_v], tr_sites),
           te_site = match(site_idx_all[te_v], te_sites),
           X_tr = X_all[tr_sites, , drop = FALSE], X_te = X_all[te_sites, , drop = FALSE],
           Z_tr = Z_all[tr_v, , drop = FALSE], Z_te = Z_all[te_v, , drop = FALSE])
    })

    per_species <- lapply(species, function(sp) {
      y_all <- integer(nrow(v)); y_all[unique(det_by_species[[sp]])] <- 1L
      cv <- do.call(rbind, lapply(seq_len(OPPORTUNITY_CV_FOLDS), function(k) {
        fp <- fold_parts[[k]]
        if (is.null(fp)) return(NULL)
        detected_tr <- rowsum(y_all[fp$tr_v], fp$tr_site, reorder = TRUE)[, 1] > 0
        fit <- fit_occupancy(fp$X_tr, fp$Z_tr, fp$tr_site, y_all[fp$tr_v], detected_tr)
        pr <- predict_sites(fit, fp$X_te, fp$Z_te, fp$te_site, y_all[fp$te_v])
        data.frame(block = sites[fp$te_sites], taxon_name = sp, group = grp, pr)
      }))
      detected_all <- rowsum(y_all, site_idx_all, reorder = TRUE)[, 1] > 0
      full <- fit_occupancy(X_all, Z_all, site_idx_all, y_all, detected_all)
      list(cv = cv, beta = full$par[seq_len(full$kb)], converged = full$converged)
    })
    list(
      cv = do.call(rbind, lapply(per_species, `[[`, "cv")),
      beta = do.call(rbind, lapply(per_species, `[[`, "beta")),
      species = data.frame(taxon_name = species, group = grp,
                           converged = vapply(per_species, `[[`, logical(1), "converged")),
      visits = v |> count(site, name = "n_visits") |> rename(block = site) |> mutate(group = grp),
      introduced = introduced_q
    )
  }

  fitted <- lapply(sort(unique(vis$visits$group)), fit_group)
  excluded <- do.call(rbind, lapply(fitted, `[[`, "introduced"))
  excluded$source <- intro$source[match(binomial(excluded$taxon_name), intro$taxon_name)]
  fits <- Filter(function(f) !is.null(f$beta), fitted)
  if (length(fits) == 0L) stop("no native species recorded at ", OPPORTUNITY_MIN_SITES, " or more blocks")
  site_species <- do.call(rbind, lapply(fits, `[[`, "cv"))
  beta <- do.call(rbind, lapply(fits, `[[`, "beta"))
  colnames(beta) <- c("intercept", OPPORTUNITY_COVARIATES)
  species_tab <- do.call(rbind, lapply(fits, `[[`, "species"))
  block_visits <- do.call(rbind, lapply(fits, `[[`, "visits"))
  rownames(beta) <- species_tab$taxon_name

  island_kept <- species_tab$taxon_name[binomial(species_tab$taxon_name) %in% attr(intro, "island_only")]

  # ── 2. Each cell's window ──────────────────────────────────────────────────
  # Window means through a 20 m raster: each raster cell holds the sum of its
  # cells' values and how many are non-missing; a circular focal sum adds both
  # up over the window, and their ratio is the window mean. Raster cells with
  # no grid cell contribute nothing, so the AOI edge is a partial window.
  r0 <- rast(xmin = min(cells$x) - 20, xmax = max(cells$x) + 20,
             ymin = min(cells$y) - 20, ymax = max(cells$y) + 20, resolution = 20)
  ri <- cellFromXY(r0, cbind(cells$x, cells$y))
  kernel <- focalMat(r0, OPPORTUNITY_WINDOW_M, "circle"); kernel[kernel > 0] <- 1
  focal_sum <- function(values) {
    r <- r0; vals <- numeric(ncell(r0))
    agg <- tapply(values, ri, sum)
    vals[as.integer(names(agg))] <- agg
    values(r) <- vals
    focal(r, w = kernel, fun = "sum", na.rm = TRUE, fillvalue = 0)[ri][, 1]
  }
  window_n <- focal_sum(rep(1, nrow(cells)))
  window_vars <- c(raw_vars, "shrub", "grass")
  W <- as.data.frame(lapply(setNames(window_vars, window_vars), function(v) {
    x <- cells[[v]]
    focal_sum(replace_na(x, 0)) / pmax(focal_sum(as.numeric(!is.na(x))), 1)
  }))
  # Block size in the block's units: the window's cell count scaled to a
  # block's area, so an interior window reads as a full block.
  W$log_cells <- log(pmax(window_n, 1) * OPPORTUNITY_BLOCK_M^2 / (pi * OPPORTUNITY_WINDOW_M^2))
  W$land_use <- land_use_class(W$tree, W$shrub, W$grass, W$water, W$built)

  # ── 3. The trees-and-vegetation lever ──────────────────────────────────────
  lever_q <- W |>
    group_by(land_use) |>
    summarise(across(all_of(OPPORTUNITY_HABITAT_LEVER),
                     \(v) quantile(v, OPPORTUNITY_HABITAT_Q, na.rm = TRUE)),
              cells = n(), .groups = "drop")
  Q <- lever_q[match(W$land_use, lever_q$land_use), ]
  W_lever <- W
  for (v in OPPORTUNITY_HABITAT_LEVER) W_lever[[v]] <- pmax(W[[v]], Q[[v]])
  gain <- (W_lever$tree - W$tree) + (W_lever$grass_shrub - W$grass_shrub)
  f <- ifelse(gain > W$built & gain > 0, W$built / gain, 1)
  W_lever$tree <- W$tree + (W_lever$tree - W$tree) * f
  W_lever$grass_shrub <- W$grass_shrub + (W_lever$grass_shrub - W$grass_shrub) * f
  W_lever$built <- W$built - gain * f

  X_now <- design(W)
  X_lever <- design(W_lever)
  n_cells <- nrow(cells)
  sp_group <- species_tab$group[match(rownames(beta), species_tab$taxon_name)]
  expected_g <- matrix(0, n_cells, length(OPPORTUNITY_GROUPS), dimnames = list(NULL, OPPORTUNITY_GROUPS))
  gap_g <- expected_g
  mean_gain <- setNames(numeric(nrow(beta)), rownames(beta))

  # Running top 3 species by gain per cell, overall and per group, without a
  # cells x species matrix.
  top_new <- function() list(v = matrix(-Inf, n_cells, 3), i = matrix(NA_integer_, n_cells, 3))
  top_push <- function(top, d, s) {
    v <- top$v; i <- top$i
    g1 <- d > v[, 1]; g2 <- !g1 & d > v[, 2]; g3 <- !g1 & !g2 & d > v[, 3]
    s12 <- g1 | g2
    v[s12, 3] <- v[s12, 2]; i[s12, 3] <- i[s12, 2]
    v[g1, 2] <- v[g1, 1];   i[g1, 2] <- i[g1, 1]
    v[g1, 1] <- d[g1];      i[g1, 1] <- s
    v[g2, 2] <- d[g2];      i[g2, 2] <- s
    v[g3, 3] <- d[g3];      i[g3, 3] <- s
    list(v = v, i = i)
  }
  # Only species gaining at least 0.01 in occupancy probability are named.
  top_names <- function(top) {
    out <- character(n_cells)
    for (k in 1:3) {
      ok <- !is.na(top$i[, k]) & top$v[, k] >= 0.01
      nm <- rownames(beta)[top$i[ok, k]]
      out[ok] <- ifelse(nzchar(out[ok]), paste0(out[ok], "; ", nm), nm)
    }
    out
  }
  top_all <- top_new()
  top_g <- setNames(lapply(OPPORTUNITY_GROUPS, function(g) top_new()), OPPORTUNITY_GROUPS)

  for (s in seq_len(nrow(beta))) {
    g <- sp_group[s]
    p_now <- plogis(drop(X_now %*% beta[s, ]))
    d <- plogis(drop(X_lever %*% beta[s, ])) - p_now
    expected_g[, g] <- expected_g[, g] + p_now
    gap_g[, g] <- gap_g[, g] + d
    mean_gain[s] <- mean(d)
    top_all <- top_push(top_all, d, s)
    top_g[[g]] <- top_push(top_g[[g]], d, s)
  }

  cells_out <- data.frame(
    cell_id = cells$cell_id,
    land_use_window = W$land_use,
    expected_species = round(rowSums(expected_g), 4),
    opportunity_gap = round(rowSums(gap_g), 4),
    top_species = top_names(top_all)
  )
  # Every configured group gets its columns, zero where it has no species, so
  # the file's shape does not depend on the city.
  for (g in OPPORTUNITY_GROUPS) {
    cells_out[[paste0("expected_", g)]] <- round(expected_g[, g], 4)
    cells_out[[paste0("gap_", g)]] <- round(gap_g[, g], 4)
    cells_out[[paste0("top_", g)]] <- top_names(top_g[[g]])
  }
  rm(top_all, top_g, X_now, X_lever); invisible(gc())

  # ── Rare species recorded nearby ───────────────────────────────────────────
  # Every recorded native species the models do not count — too rarely recorded
  # to learn where it lives — listed per cell where recorded within the window,
  # rarest (fewest cells citywide) first.
  rare <- all_records |>
    filter(!binomial(taxon_name) %in% intro$taxon_name, !taxon_name %in% rownames(beta)) |>
    distinct(cell_id, taxon_name)
  sp_rank <- rare |> count(taxon_name, name = "n_cells") |> arrange(n_cells, taxon_name)
  rare_records <- sum(all_records$taxon_name %in% sp_rank$taxon_name)
  rare_n <- integer(n_cells)
  rare_names <- character(n_cells)
  if (nrow(rare) > 0L) {
    rare$sp <- match(rare$taxon_name, sp_rank$taxon_name)
    rec_cells <- unique(rare$cell_id)
    pts <- st_as_sf(data.frame(x = cells$x, y = cells$y), coords = c("x", "y"), crs = grid_crs)
    nb <- st_is_within_distance(pts[match(rec_cells, cells$cell_id), ], pts, dist = OPPORTUNITY_WINDOW_M)
    pairs <- data.frame(cell_id = rep(rec_cells, lengths(nb)), hex = unlist(nb))
    hex_sp <- inner_join(pairs, rare[, c("cell_id", "sp")], by = "cell_id",
                         relationship = "many-to-many") |>
      distinct(hex, sp) |>
      arrange(hex, sp)
    rare_n <- tabulate(hex_sp$hex, nbins = n_cells)
    first <- hex_sp[stats::ave(hex_sp$sp, hex_sp$hex, FUN = seq_along) <= OPPORTUNITY_RARE_LISTED, ]
    listed <- tapply(sp_rank$taxon_name[first$sp], first$hex, paste, collapse = "; ")
    rare_names[as.integer(names(listed))] <- listed
    rm(pairs, hex_sp, first, listed, nb, pts)
  }
  cells_out$rare_species_n <- rare_n
  cells_out$rare_species <- rare_names

  # ── 4. Validation ──────────────────────────────────────────────────────────
  auc <- function(score, y) {
    n1 <- sum(y); n0 <- length(y) - n1
    if (n1 == 0 || n0 == 0) return(NA_real_)
    (sum(rank(score)[y == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0)
  }
  well <- site_species[site_species$pstar >= OPPORTUNITY_WELL_RECORDED_P, ]
  well_by_sp <- Filter(function(d) nrow(d) >= 15 && sum(d$detected) >= 3 && sum(!d$detected) >= 3,
                       split(well, well$taxon_name))
  sp_auc <- vapply(well_by_sp, function(d) auc(d$psi, d$detected), numeric(1))
  set.seed(OPPORTUNITY_SEED)
  null_median <- replicate(OPPORTUNITY_N_PERM, median(vapply(
    well_by_sp, function(d) auc(sample(d$psi), d$detected), numeric(1)
  )))
  signal <- list(
    speciesTested = length(sp_auc),
    medianAuc = if (length(sp_auc)) median(sp_auc) else NA_real_,
    nullQ975 = if (length(sp_auc)) unname(quantile(null_median, 0.975)) else NA_real_
  )
  signal$pass <- isTRUE(signal$medianAuc > signal$nullQ975)
  # Per group, against a per-group permutation null.
  auc_group <- species_tab$group[match(names(sp_auc), species_tab$taxon_name)]
  signal$byGroup <- list()
  if (length(sp_auc) > 0L) {
  set.seed(OPPORTUNITY_SEED)
  null_by_group <- replicate(OPPORTUNITY_N_PERM, tapply(vapply(
    well_by_sp, function(d) auc(sample(d$psi), d$detected), numeric(1)
  ), auc_group, median))
  null_by_group <- matrix(null_by_group, nrow = length(unique(auc_group)),
                          dimnames = list(sort(unique(auc_group)), NULL))
  signal$byGroup <- lapply(setNames(rownames(null_by_group), rownames(null_by_group)), function(g) {
    a <- sp_auc[auc_group == g]
    list(speciesTested = length(a), medianAuc = median(a),
         nullQ975 = unname(quantile(null_by_group[g, ], 0.975)),
         pass = median(a) > quantile(null_by_group[g, ], 0.975))
  })
  }

  block_scores <- site_species |>
    group_by(group, block) |>
    summarise(expected = sum(psi), recorded = sum(detected), median_pstar = median(pstar), .groups = "drop") |>
    left_join(block_visits, by = c("group", "block"))
  records_by_group <- lapply(split(block_scores, block_scores$group), function(d) {
    d <- d[d$median_pstar >= OPPORTUNITY_WELL_RECORDED_P, ]
    out <- list(blocks = nrow(d), rho = NA_real_, p = NA_real_,
                tested = nrow(d) >= OPPORTUNITY_MIN_TEST_BLOCKS)
    if (out$tested) {
      z <- log(d$n_visits)
      ra <- resid(lm(rank(d$expected) ~ rank(z))); rb <- resid(lm(rank(d$recorded) ~ rank(z)))
      ct <- suppressWarnings(stats::cor.test(ra, rb))
      out$rho <- unname(ct$estimate); out$p <- ct$p.value
    }
    out$pass <- out$tested && isTRUE(out$rho >= OPPORTUNITY_PASS_RHO && out$p < 0.05)
    out
  })
  tested <- Filter(function(r) r$tested, records_by_group)
  records_pass <- length(tested) > 0 && all(vapply(tested, `[[`, logical(1), "pass"))

  woodland_in <- intersect(OPPORTUNITY_WOODLAND, rownames(beta))
  built_in <- intersect(OPPORTUNITY_BUILT_UP, rownames(beta))
  direction <- rbind(
    data.frame(taxon_name = woodland_in, expect = rep("gains with trees/vegetation", length(woodland_in)),
               value = unname(mean_gain[woodland_in])),
    data.frame(taxon_name = built_in, expect = rep("positive built-cover coefficient", length(built_in)),
               value = unname(beta[built_in, "built"]))
  )
  direction$right <- direction$value > 0
  direction_pass <- nrow(direction) > 0 && sum(direction$right) > nrow(direction) / 2

  # The labels are what the map uses; pass is kept as a summary only: every
  # tested group checked, and both citywide diagnostics passed.
  labels <- setNames(lapply(OPPORTUNITY_GROUPS, function(g) {
    r <- records_by_group[[g]]
    label <- if (is.null(r) || !r$tested) "insufficient" else if (r$pass) "checked" else "mismatch"
    list(label = label,
         species = sum(species_tab$group == g),
         records = sum(records$group == g),
         wellRecordedBlocks = if (is.null(r)) 0L else r$blocks,
         rho = if (is.null(r)) NA_real_ else r$rho,
         p = if (is.null(r)) NA_real_ else r$p,
         gapShare = if (sum(gap_g) != 0) sum(gap_g[, g]) / sum(gap_g) else NA_real_)
  }), OPPORTUNITY_GROUPS)

  validation <- list(
    pass = signal$pass && records_pass && direction_pass,
    labels = labels,
    signal = signal,
    records = list(pass = records_pass, byGroup = records_by_group),
    direction = list(pass = direction_pass, checks = direction)
  )

  record <- list(
    cityId = CITY_ID,
    generatedAt = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    method = "docs/methodology.md §15",
    settings = list(
      blockM = OPPORTUNITY_BLOCK_M, windowM = OPPORTUNITY_WINDOW_M,
      maxAccuracyM = OPPORTUNITY_MAX_ACCURACY_M, periodStart = format(OPPORTUNITY_PERIOD_START),
      minSites = OPPORTUNITY_MIN_SITES, cvFolds = OPPORTUNITY_CV_FOLDS, seed = OPPORTUNITY_SEED,
      groups = OPPORTUNITY_GROUPS, habitatLever = OPPORTUNITY_HABITAT_LEVER,
      habitatQuantile = OPPORTUNITY_HABITAT_Q, covariates = OPPORTUNITY_COVARIATES
    ),
    data = list(
      periodEnd = format(max(records$date)),
      records = as.list(table(records$group)),
      blocks = nrow(blocks),
      cells = n_cells
    ),
    species = list(
      counted = nrow(species_tab),
      byGroup = as.list(table(species_tab$group)),
      notConverged = species_tab$taxon_name[!species_tab$converged],
      introducedLeftOut = excluded,
      keptNativeIslandOnly = island_kept
    ),
    rare = list(
      species = nrow(sp_rank),
      records = rare_records,
      cellsWithAny = sum(rare_n > 0L),
      listedPerCell = OPPORTUNITY_RARE_LISTED
    ),
    leverQuantiles = lever_q,
    standardisation = list(mean = as.list(scale_mu), sd = as.list(scale_sd)),
    coefficients = lapply(split(beta, seq_len(nrow(beta))), function(b) as.list(setNames(b, colnames(beta)))) |>
      setNames(rownames(beta)),
    summary = list(
      expectedMedian = median(cells_out$expected_species),
      gapMedian = median(cells_out$opportunity_gap),
      gapP90 = unname(quantile(cells_out$opportunity_gap, 0.9)),
      checkedGapShare = sum(vapply(labels, function(l) if (l$label == "checked") l$gapShare else 0, numeric(1)), na.rm = TRUE)
    ),
    validation = validation,
    runtimeMin = round(as.numeric(Sys.time() - t_start, units = "mins"), 2)
  )
  list(cells = cells_out, record = record)
}

# Stale outputs never survive a run.
unlink(c(PROC_OPPORTUNITY, PROC_OPPORTUNITY_MODEL))
opportunity_result <- tryCatch(opportunity_run(), error = function(e) {
  warning(sprintf("Opportunity gap skipped for %s: %s", CITY_ID, conditionMessage(e)), call. = FALSE)
  NULL
})

if (!is.null(opportunity_result)) {
  dir.create(dirname(PROC_OPPORTUNITY), recursive = TRUE, showWarnings = FALSE)
  if (requireNamespace("data.table", quietly = TRUE)) {
    data.table::fwrite(opportunity_result$cells, PROC_OPPORTUNITY)
  } else {
    utils::write.csv(opportunity_result$cells, PROC_OPPORTUNITY, row.names = FALSE)
  }
  jsonlite::write_json(opportunity_result$record, PROC_OPPORTUNITY_MODEL,
                       auto_unbox = TRUE, pretty = TRUE, digits = NA, null = "null", na = "null")
  rec <- opportunity_result$record
  cat(sprintf(
    "Opportunity gap (%s): %d native species counted (%s), %d introduced left out; expected median %.1f, gap median %.2f, p90 %.2f\n",
    CITY_ID, rec$species$counted,
    paste(sprintf("%s %d", names(rec$species$byGroup), unlist(rec$species$byGroup)), collapse = ", "),
    nrow(rec$species$introducedLeftOut),
    rec$summary$expectedMedian, rec$summary$gapMedian, rec$summary$gapP90
  ))
  v <- rec$validation
  cat("  labels: ", paste(vapply(names(v$labels), function(g) {
    l <- v$labels[[g]]
    sprintf("%s %s (%d species%s)", g, l$label, l$species,
            if (is.finite(l$rho)) sprintf(", rho %.2f", l$rho) else "")
  }, character(1)), collapse = "; "), "\n", sep = "")
  cat(sprintf(
    "  checked share of the gap %.0f%%; signal AUC %.3f vs %.3f (%s); direction %d of %d (%s); rare species listed: %d (%d records)\n",
    100 * rec$summary$checkedGapShare,
    v$signal$medianAuc, v$signal$nullQ975, if (v$signal$pass) "pass" else "fail",
    sum(v$direction$checks$right), nrow(v$direction$checks), if (v$direction$pass) "pass" else "fail",
    rec$rare$species, rec$rare$records
  ))
  cat(sprintf("Written: %s, %s (%.1f min)\n", basename(PROC_OPPORTUNITY),
              basename(PROC_OPPORTUNITY_MODEL), rec$runtimeMin))
  rm(rec, v)
}
rm(opportunity_result); invisible(gc())
