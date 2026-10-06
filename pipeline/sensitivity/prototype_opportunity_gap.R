# NatureGap sensitivity prototype — the nature gap as opportunity: how many
# more species each place would support with attainable habitat and lower
# pressures.
#
#   SENS_CITY=porto Rscript --vanilla sensitivity/prototype_opportunity_gap.R
#
# Reads the grid and the observation files; writes nothing the pipeline or
# export reads. Outputs go to data/<city>/sensitivity/.
#
# Why: no test so far supports a gap measured place by place. The records say
# what is present, not reliably what is missing (prototype_spatial_gap.R,
# prototype_occupancy_gap.R). What they do support, pooled across the city, is
# which habitats and pressures go with which species — and the habitat and
# pressure layers cover every cell. So the gap here is between the species a
# place's surroundings support now and those they would support after an
# attainable change, from citywide relationships, with no per-place records.
#
# 4a  One occupancy model per species (every taxon group; species recorded at
#     MIN_SITES or more blocks), fitted on BLOCK_M blocks with visit-based
#     detection (occupancy_model.R). Occupancy covariates: habitat (trees,
#     grass/shrub, canopy height, 0.5 m vegetation, water, water proximity,
#     corridor importance, built cover, block size) and pressures (summer
#     surface-heat anomaly, artificial light, noise, traffic). Cross-validated
#     by block for 4d; refitted on every block for 4b-4c.
# 4b  Potential per 20 m cell: the covariates averaged over the cells within
#     WINDOW_M of it, standardised with the block statistics and passed
#     through every species' model. Expected species = sum of psi.
# 4c  Gap per cell, by lever, set against cells whose window has the same land
#     use (land_use_class() from 06_export/export.R, on the window's cover):
#       habitat   trees, grass/shrub, canopy height and 0.5 m vegetation raised
#                 to that land use's HABITAT_Q quantile where below it. Gains
#                 in tree and grass/shrub cover come out of built cover, never
#                 water, so a road is not turned into a forest.
#       pressure  heat, light, noise and traffic lowered to that land use's
#                 PRESSURE_Q quantile where above it.
#     Gap = expected species after the change - expected species now, per lever
#     and for both together, with the species gaining most.
# 4d  Pass/fail, fixed before the first run:
#       signal     in well-recorded blocks (P(recorded | present) >=
#                  WELL_RECORDED_P), cross-validated psi separates recorded from
#                  unrecorded species: the median within-species AUC exceeds
#                  the 97.5% quantile of the same median with psi permuted
#                  within species (N_PERM permutations), over all species.
#       records    per block, expected species (sum of cross-validated psi)
#                  predict species recorded beyond effort: partial Spearman
#                  rho >= PASS_PARTIAL_RHO with p < 0.05 after removing log
#                  visits, in every group with MIN_TEST_BLOCKS or more
#                  well-recorded blocks (median P(recorded | present) over the
#                  group's species >= WELL_RECORDED_P).
#       direction  woodland species (WOODLAND) gain under the habitat lever on
#                  average, and built-up species (BUILT_UP) have a positive
#                  built-cover coefficient; more than half of those modelled
#                  must point that way.
#       pressures  reported only as one combined lever unless separable: every
#                  pairwise |r| among the four below MAX_PRESSURE_R and every
#                  variance inflation factor below MAX_VIF, across blocks.
# 4e  Outputs: per-cell and per-species CSVs, and a map.
#
# NATIVE_ONLY=1 (default) leaves introduced species out of every sum, gap and
# test: they are still fitted — their records still lengthen the lists that
# measure everyone's detection — but a gap that rewards escaped parakeets is not
# a nature gap. introduced_species.R says which species and on what evidence.
# NATIVE_ONLY=0 keeps them.
#
# GROUPS=bird,mammal (comma-separated classify_taxon_group() labels, plus
# "other") restricts the species to those groups; unset means every group.
# Output names then carry the groups, so runs do not overwrite each other.
#
# Observations are rebuilt from data/<city>/raw with the pipeline's loader and
# quality gates (load_obs_for_tiling), with the GPS gate at half a block: 30 m
# (config.R) is set for the 20 m cell, and a record placed to within half a
# block is evidence about the block. OBS_FROM_RAW=0 reads the processed
# tiled_obs_all.rds instead; OBS_MAX_ACCURACY_M sets another gate.

suppressMessages({library(sf); library(dplyr); library(tidyr); library(terra)})

CITY <- Sys.getenv("SENS_CITY", "porto")
if (!exists("CONFIG_LOADED")) setwd(Sys.getenv("NATUREGAP_PIPELINE", "."))
suppressMessages(source("config.R"))

# classify_taxon_group() and load_obs_for_tiling() are the pipeline's own.
# process_tile.R holds only library() calls and function definitions at top
# level, so sourcing it into its own environment runs nothing.
pipeline_fns <- new.env()
suppressMessages(sys.source(here::here("02_habitat", "process_tile.R"), envir = pipeline_fns))
classify_taxon_group <- pipeline_fns$classify_taxon_group
source(here::here("05_opportunity", "occupancy_model.R"))
source(here::here("introduced_species.R"))

# land_use_class() lives in 06_export/export.R, which runs the whole export
# when sourced. Only its definition is evaluated, so "same land use" means
# exactly what the map's Land use layer means.
for (e in parse(here::here("06_export", "export.R"))) {
  if (is.call(e) && identical(e[[1]], as.name("<-")) &&
      identical(e[[2]], as.name("land_use_class"))) eval(e, envir = globalenv())
}
if (!exists("land_use_class")) stop("land_use_class() not found in 06_export/export.R", call. = FALSE)

BLOCK_M        <- 250
WINDOW_M       <- 125
PERIOD_START   <- as.Date(Sys.getenv("PERIOD_START", "2019-01-01"))
MIN_SITES      <- 10L
CV_FOLDS       <- 5L
SEED           <- 20261005L
HABITAT_Q      <- 0.75
PRESSURE_Q     <- 0.25
WELL_RECORDED_P <- 0.5
N_PERM         <- 200L
PASS_PARTIAL_RHO <- 0.2
MIN_TEST_BLOCKS <- 20L
MAX_PRESSURE_R <- 0.7
MAX_VIF        <- 5

WOODLAND <- c("Erithacus rubecula", "Parus major", "Cyanistes caeruleus", "Sylvia atricapilla",
              "Certhia brachydactyla", "Aegithalos caudatus", "Columba palumbus")
BUILT_UP <- c("Passer domesticus", "Columba livia")

HABITAT  <- c("tree", "grass_shrub", "canopy_height", "veg_fraction", "water",
              "water_proximity", "corridor", "built")
PRESSURE <- c("heat", "light", "noise", "traffic")
COVARIATES <- c(HABITAT, PRESSURE, "log_cells")
HABITAT_LEVER <- c("tree", "grass_shrub", "canopy_height", "veg_fraction")

GROUPS <- Filter(nzchar, trimws(strsplit(Sys.getenv("GROUPS", ""), ",")[[1]]))
NATIVE_ONLY <- !identical(Sys.getenv("NATIVE_ONLY", "1"), "0")
OUT_TAG <- paste0(if (length(GROUPS)) paste0("_", paste(sort(GROUPS), collapse = "-")) else "",
                  if (NATIVE_ONLY) "_native" else "")

OBS_FROM_RAW <- !identical(Sys.getenv("OBS_FROM_RAW", "1"), "0")
if (OBS_FROM_RAW) {
  OBS_MAX_ACCURACY_M <- as.numeric(Sys.getenv("OBS_MAX_ACCURACY_M", as.character(BLOCK_M / 2)))
}

OUT_DIR <- file.path(DATA_ROOT, "sensitivity")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
t_start <- Sys.time()

# ── Data ────────────────────────────────────────────────────────────────────

# Only the columns used: Gent's grid is ~350k cells and ~100 columns.
grid <- st_read(PROC_GRID_RESID, quiet = TRUE, query = paste(
  "SELECT cell_id, tree_fraction, shrub_fraction, grass_fraction, water_fraction,",
  "built_fraction_wc, canopy_height_m, veg_fraction, water_proximity,",
  "corridor_importance, lst_celsius, light_pollution, noise, traffic_exposure, geom",
  "FROM grid_residuals"
))
obs_points <- if (OBS_FROM_RAW) {
  pipeline_fns$load_obs_for_tiling(CRS_LOCAL)
} else {
  readRDS(file.path(DATA_PROC, "tiled_obs_all.rds"))
}
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
    # A spatial anomaly in degrees from the city's mean, not a temperature
    # (00_download/download_landsat_temp.R).
    heat = lst_celsius,
    light = light_pollution,
    noise,
    traffic = traffic_exposure
  ) |>
  mutate(block = paste(floor(x / BLOCK_M), floor(y / BLOCK_M), sep = "_"))
rm(grid, xy); invisible(gc())

records <- prepare_records(obs, PERIOD_START, classify_taxon_group)
if (length(GROUPS)) {
  unknown <- setdiff(GROUPS, unique(records$group))
  if (length(unknown)) stop("GROUPS not present in the records: ", paste(unknown, collapse = ", "), call. = FALSE)
  records <- records[records$group %in% GROUPS, ]
}
rm(obs); invisible(gc())

raw_vars <- c(HABITAT, PRESSURE)
blocks <- cells |>
  group_by(block) |>
  summarise(across(all_of(raw_vars), \(v) mean(v, na.rm = TRUE)), n_cells = n(), .groups = "drop") |>
  mutate(log_cells = log(n_cells))

# Block statistics standardise both the blocks and the cell windows, so the
# fitted coefficients mean the same thing in both.
scale_mu <- vapply(COVARIATES, \(v) mean(blocks[[v]], na.rm = TRUE), numeric(1))
scale_sd <- vapply(COVARIATES, \(v) { s <- stats::sd(blocks[[v]], na.rm = TRUE); if (is.finite(s) && s > 0) s else 1 }, numeric(1))
design <- function(df) {
  z <- vapply(COVARIATES, \(v) { u <- (df[[v]] - scale_mu[[v]]) / scale_sd[[v]]; replace(u, !is.finite(u), 0) },
              numeric(nrow(df)))
  cbind(1, matrix(z, nrow = nrow(df), dimnames = list(NULL, COVARIATES)))
}

vis <- build_site_visits(records, setNames(cells$block, cells$cell_id))
folds_all <- assign_folds(blocks$block, CV_FOLDS, SEED)

cat(sprintf("Records from %s: %d over %d blocks of %d m (%s)\n", PERIOD_START, nrow(records),
            nrow(blocks), BLOCK_M,
            paste(sprintf("%s %d", names(table(records$group)), table(records$group)), collapse = ", ")))

# ── 4a. Species models ──────────────────────────────────────────────────────

fit_group <- function(grp) {
  v <- vis$visits[vis$visits$group == grp, ]
  det <- vis$det[vis$det$group == grp, ]
  species <- det |> distinct(site, taxon_name) |> count(taxon_name) |>
    filter(n >= MIN_SITES) |> pull(taxon_name)
  if (length(species) == 0L) return(NULL)

  sites <- sort(unique(v$site))
  site_idx_all <- match(v$site, sites)
  X_all <- design(blocks[match(sites, blocks$block), ])
  Z_all <- detection_design(v)
  fold_of_site <- folds_all[sites]
  det_by_species <- split(match(det$visit_id, v$visit_id), det$taxon_name)

  fold_parts <- lapply(seq_len(CV_FOLDS), function(k) {
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
  detected_all_site <- function(y) rowsum(y, site_idx_all, reorder = TRUE)[, 1] > 0

  per_species <- lapply(species, function(sp) {
    y_all <- integer(nrow(v)); y_all[unique(det_by_species[[sp]])] <- 1L
    cv <- do.call(rbind, lapply(seq_len(CV_FOLDS), function(k) {
      fp <- fold_parts[[k]]
      if (is.null(fp)) return(NULL)
      detected_tr <- rowsum(y_all[fp$tr_v], fp$tr_site, reorder = TRUE)[, 1] > 0
      fit <- fit_occupancy(fp$X_tr, fp$Z_tr, fp$tr_site, y_all[fp$tr_v], detected_tr)
      pr <- predict_sites(fit, fp$X_te, fp$Z_te, fp$te_site, y_all[fp$te_v])
      data.frame(block = sites[fp$te_sites], taxon_name = sp, group = grp, pr)
    }))
    full <- fit_occupancy(X_all, Z_all, site_idx_all, y_all, detected_all_site(y_all))
    list(cv = cv, beta = full$par[seq_len(full$kb)], converged = full$converged)
  })
  list(
    cv = do.call(rbind, lapply(per_species, `[[`, "cv")),
    beta = do.call(rbind, lapply(per_species, `[[`, "beta")),
    species = data.frame(taxon_name = species, group = grp,
                         converged = vapply(per_species, `[[`, logical(1), "converged")),
    visits = v |> count(site, name = "n_visits") |> rename(block = site) |> mutate(group = grp)
  )
}

groups <- sort(unique(vis$visits$group))
fits <- Filter(Negate(is.null), lapply(groups, function(g) {
  t0 <- Sys.time(); r <- fit_group(g)
  if (!is.null(r)) cat(sprintf("  4a %-7s %3d species, %.1f min\n", g, nrow(r$species),
                               as.numeric(Sys.time() - t0, units = "mins")))
  r
}))
site_species <- do.call(rbind, lapply(fits, `[[`, "cv"))
beta <- do.call(rbind, lapply(fits, `[[`, "beta"))
colnames(beta) <- c("intercept", COVARIATES)
species_tab <- do.call(rbind, lapply(fits, `[[`, "species"))
block_visits <- do.call(rbind, lapply(fits, `[[`, "visits"))
rownames(beta) <- species_tab$taxon_name

excluded <- species_tab[0, c("taxon_name", "group")]
excluded$source <- character()
if (NATIVE_ONLY) {
  intro <- introduced_species(CITY_COUNTRY, BBOX_FETCH, fetch = TRUE)
  src <- intro$source[match(binomial(species_tab$taxon_name), intro$taxon_name)]
  is_intro <- !is.na(src)
  excluded <- data.frame(taxon_name = species_tab$taxon_name[is_intro],
                         group = species_tab$group[is_intro], source = src[is_intro])
  island_kept <- species_tab$taxon_name[binomial(species_tab$taxon_name) %in% attr(intro, "island_only")]
  beta <- beta[!is_intro, , drop = FALSE]
  species_tab <- species_tab[!is_intro, ]
  site_species <- site_species[!site_species$taxon_name %in% excluded$taxon_name, ]
}

# ── 4b. Potential per 20 m cell ─────────────────────────────────────────────

# Window means through a 20 m raster: each raster cell holds the sum of its
# cells' values and their count, a circular focal sum adds both up over the
# window, and their ratio is the window mean. Raster cells with no grid cell
# contribute nothing, so the AOI edge is a partial window, not a zero.
r0 <- rast(xmin = min(cells$x) - 20, xmax = max(cells$x) + 20,
           ymin = min(cells$y) - 20, ymax = max(cells$y) + 20, resolution = 20)
ri <- cellFromXY(r0, cbind(cells$x, cells$y))
kernel <- focalMat(r0, WINDOW_M, "circle"); kernel[kernel > 0] <- 1
focal_sum <- function(values) {
  r <- r0; vals <- numeric(ncell(r0))
  agg <- tapply(values, ri, sum, na.rm = TRUE)
  vals[as.integer(names(agg))] <- agg
  values(r) <- vals
  focal(r, w = kernel, fun = "sum", na.rm = TRUE, fillvalue = 0)[ri][, 1]
}
window_n <- focal_sum(rep(1, nrow(cells)))
window_vars <- c(raw_vars, "shrub", "grass")
W <- as.data.frame(lapply(setNames(window_vars, window_vars), function(v) {
  focal_sum(replace_na(cells[[v]], 0)) / pmax(window_n, 1)
}))
# Block size, in the block's units: the window's cell count scaled to a
# block's area, so an interior window reads as a full block.
W$log_cells <- log(pmax(window_n, 1) * BLOCK_M^2 / (pi * WINDOW_M^2))
W$land_use <- land_use_class(W$tree, W$shrub, W$grass, W$water, W$built)

# ── 4c. Levers ──────────────────────────────────────────────────────────────

lever_q <- W |>
  group_by(land_use) |>
  summarise(across(all_of(HABITAT_LEVER), \(v) quantile(v, HABITAT_Q, na.rm = TRUE), .names = "hq_{.col}"),
            across(all_of(PRESSURE), \(v) quantile(v, PRESSURE_Q, na.rm = TRUE), .names = "pq_{.col}"),
            .groups = "drop")
Q <- lever_q[match(W$land_use, lever_q$land_use), ]

apply_habitat <- function(df) {
  out <- df
  for (v in HABITAT_LEVER) out[[v]] <- pmax(df[[v]], Q[[paste0("hq_", v)]])
  gain <- (out$tree - df$tree) + (out$grass_shrub - df$grass_shrub)
  f <- ifelse(gain > df$built & gain > 0, df$built / gain, 1)
  out$tree <- df$tree + (out$tree - df$tree) * f
  out$grass_shrub <- df$grass_shrub + (out$grass_shrub - df$grass_shrub) * f
  out$built <- df$built - gain * f
  out
}
apply_pressure <- function(df, which = PRESSURE) {
  out <- df
  for (v in which) out[[v]] <- pmin(df[[v]], Q[[paste0("pq_", v)]])
  out
}

# Pressures separable? Decided on blocks, before any gap is computed.
pressure_cor <- stats::cor(blocks[, PRESSURE], use = "pairwise.complete.obs")
# A singular correlation matrix means some pressure is a combination of the
# others: not separable by definition.
vif <- tryCatch(
  diag(solve(stats::cor(blocks[, c(HABITAT, PRESSURE)], use = "pairwise.complete.obs")))[PRESSURE],
  error = function(e) setNames(rep(Inf, length(PRESSURE)), PRESSURE)
)
max_pair_r <- max(abs(pressure_cor[upper.tri(pressure_cor)]))
pressures_separable <- max_pair_r < MAX_PRESSURE_R && all(vif < MAX_VIF)

scenarios <- list(now = W, habitat = apply_habitat(W), pressure = apply_pressure(W))
scenarios$both <- apply_pressure(scenarios$habitat)
if (pressures_separable) {
  for (v in PRESSURE) scenarios[[paste0("pressure_", v)]] <- apply_pressure(W, v)
}
X <- lapply(scenarios, design)

n_cells <- nrow(cells)
sums <- lapply(X, function(x) numeric(n_cells))
mean_delta <- matrix(0, nrow(beta), 2, dimnames = list(rownames(beta), c("habitat", "pressure")))

# Running top 3 species by gain per cell, without holding a cells x species matrix.
top_init <- function() list(v = matrix(-Inf, n_cells, 3), i = matrix(NA_integer_, n_cells, 3))
top_update <- function(top, delta, s) {
  v <- top$v; i <- top$i
  g1 <- delta > v[, 1]
  g2 <- !g1 & delta > v[, 2]
  g3 <- !g1 & !g2 & delta > v[, 3]
  s12 <- g1 | g2
  v[s12, 3] <- v[s12, 2]; i[s12, 3] <- i[s12, 2]
  v[g1, 2] <- v[g1, 1];   i[g1, 2] <- i[g1, 1]
  v[g1, 1] <- delta[g1];  i[g1, 1] <- s
  v[g2, 2] <- delta[g2];  i[g2, 2] <- s
  v[g3, 3] <- delta[g3];  i[g3, 3] <- s
  list(v = v, i = i)
}
top <- list(habitat = top_init(), pressure = top_init())

for (s in seq_len(nrow(beta))) {
  psi <- lapply(X, function(x) plogis(drop(x %*% beta[s, ])))
  for (k in names(psi)) sums[[k]] <- sums[[k]] + psi[[k]]
  d_h <- psi$habitat - psi$now
  d_p <- psi$pressure - psi$now
  mean_delta[s, ] <- c(mean(d_h), mean(d_p))
  top$habitat <- top_update(top$habitat, d_h, s)
  top$pressure <- top_update(top$pressure, d_p, s)
}

top_names <- function(t, min_gain = 0.01) {
  vapply(seq_len(n_cells), function(r) {
    keep <- which(t$v[r, ] >= min_gain)
    paste(rownames(beta)[t$i[r, keep]], collapse = "; ")
  }, character(1))
}

out <- data.frame(
  cell_id = cells$cell_id, x = cells$x, y = cells$y,
  land_use = W$land_use,
  expected_now = sums$now,
  gap_habitat = sums$habitat - sums$now,
  gap_pressure = sums$pressure - sums$now,
  gap_total = sums$both - sums$now,
  top_habitat = top_names(top$habitat),
  top_pressure = top_names(top$pressure)
)
if (pressures_separable) {
  for (v in PRESSURE) out[[paste0("gap_", v)]] <- sums[[paste0("pressure_", v)]] - sums$now
}

# ── 4d. Validation ──────────────────────────────────────────────────────────

auc <- function(score, y) {
  n1 <- sum(y); n0 <- length(y) - n1
  if (n1 == 0 || n0 == 0) return(NA_real_)
  (sum(rank(score)[y == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}

# signal
well <- site_species[site_species$pstar >= WELL_RECORDED_P, ]
well_by_sp <- Filter(function(d) nrow(d) >= 15 && sum(d$detected) >= 3 && sum(!d$detected) >= 3,
                     split(well, well$taxon_name))
sp_auc <- vapply(well_by_sp, function(d) auc(d$psi, d$detected), numeric(1))
set.seed(SEED)
null_median <- replicate(N_PERM, median(vapply(well_by_sp, function(d) auc(sample(d$psi), d$detected), numeric(1))))
signal <- data.frame(
  species_tested = length(sp_auc),
  median_auc = median(sp_auc),
  null_q975 = unname(quantile(null_median, 0.975)),
  signal_pass = median(sp_auc) > quantile(null_median, 0.975)
)
signal_by_group <- data.frame(taxon_name = names(sp_auc), auc = sp_auc) |>
  left_join(species_tab, by = "taxon_name") |>
  group_by(group) |> summarise(species = n(), median_auc = median(auc), .groups = "drop")

# records
block_scores <- site_species |>
  group_by(group, block) |>
  summarise(expected = sum(psi), recorded = sum(detected), median_pstar = median(pstar), .groups = "drop") |>
  left_join(block_visits, by = c("group", "block"))
partial_spearman <- function(a, b, z) {
  ra <- resid(lm(rank(a) ~ rank(z))); rb <- resid(lm(rank(b) ~ rank(z)))
  ct <- suppressWarnings(stats::cor.test(ra, rb))
  c(rho = unname(ct$estimate), p = ct$p.value)
}
records_test <- block_scores |>
  filter(median_pstar >= WELL_RECORDED_P) |>
  group_by(group) |>
  group_modify(function(d, key) {
    if (nrow(d) < MIN_TEST_BLOCKS) return(data.frame(blocks = nrow(d), rho = NA_real_, p = NA_real_))
    ps <- partial_spearman(d$expected, d$recorded, log(d$n_visits))
    data.frame(blocks = nrow(d), rho = ps[["rho"]], p = ps[["p"]])
  }) |>
  ungroup() |>
  mutate(tested = blocks >= MIN_TEST_BLOCKS,
         records_pass = tested & rho >= PASS_PARTIAL_RHO & p < 0.05)
records_pass <- any(records_test$tested) && all(records_test$records_pass[records_test$tested])

# direction
woodland_in <- intersect(WOODLAND, rownames(beta))
built_in <- intersect(BUILT_UP, rownames(beta))
dir_rows <- rbind(
  data.frame(taxon_name = woodland_in, expect = rep("gains with trees/vegetation", length(woodland_in)),
             value = unname(mean_delta[woodland_in, "habitat"])),
  data.frame(taxon_name = built_in, expect = rep("positive built-cover coefficient", length(built_in)),
             value = unname(beta[built_in, "built"]))
)
dir_rows$right <- dir_rows$value > 0
direction_pass <- nrow(dir_rows) > 0 && sum(dir_rows$right) > nrow(dir_rows) / 2

all_pass <- isTRUE(signal$signal_pass) && records_pass && direction_pass

# ── 4e. Outputs ─────────────────────────────────────────────────────────────

write.csv(out, file.path(OUT_DIR, paste0("opportunity_gap_cells", OUT_TAG, ".csv")), row.names = FALSE)
species_out <- species_tab |>
  mutate(auc_well_recorded = unname(sp_auc[taxon_name]),
         built_coef = beta[taxon_name, "built"],
         mean_gain_habitat = mean_delta[taxon_name, "habitat"],
         mean_gain_pressure = mean_delta[taxon_name, "pressure"])
write.csv(species_out, file.path(OUT_DIR, paste0("opportunity_gap_species", OUT_TAG, ".csv")), row.names = FALSE)
if (NATIVE_ONLY) write.csv(excluded, file.path(OUT_DIR, paste0("opportunity_gap_introduced", OUT_TAG, ".csv")), row.names = FALSE)

png_path <- file.path(OUT_DIR, paste0("opportunity_gap_map", OUT_TAG, ".png"))
if (requireNamespace("ggplot2", quietly = TRUE)) {
  library(ggplot2)
  panel <- function(col, title) data.frame(x = out$x, y = out$y, value = out[[col]], panel = title)
  rel <- function(v) v / max(abs(stats::quantile(v, c(0.01, 0.99), na.rm = TRUE)), 1e-9)
  long <- rbind(
    panel("expected_now", "Expected species now") |> mutate(value = (value - min(value)) / diff(range(value))),
    panel("gap_habitat", "Gap: trees and vegetation") |> mutate(value = rel(value)),
    panel("gap_pressure", "Gap: heat, light, noise, traffic") |> mutate(value = rel(value)),
    panel("gap_total", "Gap: both") |> mutate(value = rel(value))
  )
  long$panel <- factor(long$panel, levels = unique(long$panel))
  p <- ggplot(long, aes(x, y, colour = pmax(-1, pmin(1, value)))) +
    geom_point(size = 0.05, shape = 15) +
    scale_colour_gradient2(low = "#3B6EA8", mid = "#F2EFE6", high = "#2E6F40", midpoint = 0,
                           limits = c(-1, 1), name = "Relative\nscale") +
    coord_equal() + facet_wrap(~ panel, ncol = 1) +
    theme_void(base_size = 9) +
    theme(strip.text = element_text(hjust = 0, face = "bold"),
          plot.background = element_rect(fill = "white", colour = NA)) +
    labs(title = sprintf("%s - opportunity gap prototype (%s)", CITY_NAME,
                         if (length(GROUPS)) paste(GROUPS, collapse = ", ") else "all groups"),
         subtitle = sprintf("Species models fitted on %d m blocks; each 20 m cell reads the %d m around it.\nGreen: more species with the change. Gaps are relative within each panel.", BLOCK_M, WINDOW_M))
  ggsave(png_path, p, width = 7, height = 13, dpi = 150)
}

# ── Report ──────────────────────────────────────────────────────────────────

fmt <- function(df) { df <- as.data.frame(df); df[] <- lapply(df, function(v) if (is.numeric(v)) signif(v, 3) else v); df }
cat(sprintf("\n== %s == opportunity gap prototype (%s), %s to %s, GPS gate %s m\n", CITY_ID,
            if (length(GROUPS)) paste(GROUPS, collapse = ", ") else "all groups", PERIOD_START,
            max(records$date), if (OBS_FROM_RAW) format(OBS_MAX_ACCURACY_M) else "as processed"))
if (NATIVE_ONLY) {
  cat(sprintf("introduced species left out: %d\n", nrow(excluded)))
  if (nrow(excluded)) print(fmt(excluded), row.names = FALSE)
  if (length(island_kept)) {
    cat(sprintf("kept as native, register places their introduction on the islands only: %s\n",
                paste(island_kept, collapse = ", ")))
  }
}
cat(sprintf("species modelled%s: %d (%s); full fits not converged: %d\n",
            if (NATIVE_ONLY) " and counted (native)" else "", nrow(species_tab),
            paste(sprintf("%s %d", names(table(species_tab$group)), table(species_tab$group)), collapse = ", "),
            sum(!species_tab$converged)))

cat("\n-- 4b/4c: per cell --\n")
print(fmt(out |> summarise(
  cells = n(), expected_median = median(expected_now),
  habitat_gap_median = median(gap_habitat), habitat_gap_p90 = quantile(gap_habitat, 0.9),
  pressure_gap_median = median(gap_pressure), pressure_gap_p90 = quantile(gap_pressure, 0.9),
  total_gap_median = median(gap_total), total_gap_p90 = quantile(gap_total, 0.9))), row.names = FALSE)
cat("\nby window land use:\n")
print(fmt(out |> group_by(land_use) |> summarise(cells = n(), expected = median(expected_now),
  gap_habitat = median(gap_habitat), gap_pressure = median(gap_pressure), gap_total = median(gap_total),
  .groups = "drop") |> arrange(desc(cells))), row.names = FALSE)

cat(sprintf("\n-- 4d: validation --\nsignal: median within-species AUC %.3f over %d species vs permutation 97.5%% %.3f -> %s\n",
            signal$median_auc, signal$species_tested, signal$null_q975, if (signal$signal_pass) "PASS" else "FAIL"))
print(fmt(signal_by_group), row.names = FALSE)
cat("\nrecords: partial Spearman of expected vs recorded species, beyond log visits, in well-recorded blocks\n")
print(fmt(records_test), row.names = FALSE)
cat(sprintf("-> %s\n", if (records_pass) "PASS" else "FAIL"))
cat("\ndirection:\n")
print(fmt(dir_rows), row.names = FALSE)
cat(sprintf("-> %d of %d right: %s\n", sum(dir_rows$right), nrow(dir_rows), if (direction_pass) "PASS" else "FAIL"))
cat(sprintf("\npressures: max pairwise |r| %.2f, VIF %s -> %s\n", max_pair_r,
            paste(sprintf("%s %.1f", names(vif), vif), collapse = ", "),
            if (pressures_separable) "separable, per-pressure gaps reported" else "combined lever only"))
cat(sprintf("\nOVERALL: %s\n", if (all_pass) "PASS" else "FAIL"))

top_blocks <- out |>
  mutate(block = cells$block) |>
  group_by(block) |>
  summarise(cells = n(), land_use = names(sort(table(land_use), decreasing = TRUE))[1],
            expected = mean(expected_now), gap_total = mean(gap_total),
            gap_habitat = mean(gap_habitat), gap_pressure = mean(gap_pressure),
            top = {
              sp <- unlist(strsplit(c(top_habitat, top_pressure), "; ", fixed = TRUE))
              sp <- sp[nzchar(sp)]
              paste(head(names(sort(table(sp), decreasing = TRUE)), 3), collapse = "; ")
            },
            .groups = "drop") |>
  filter(cells >= 50) |>
  arrange(desc(gap_total)) |>
  head(8)
cat(sprintf("\n-- largest gaps, %d m blocks (mean over cells) --\n", BLOCK_M))
print(fmt(top_blocks), row.names = FALSE)
cat(sprintf("\nWritten to %s (%.1f min)\n", OUT_DIR, as.numeric(Sys.time() - t_start, units = "mins")))
