# NatureGap sensitivity prototype — a gap the records can support: expected
# species that the visits say are missing.
#
#   SENS_CITY=porto Rscript --vanilla sensitivity/prototype_occupancy_gap.R
#
# Reads the processed grid and observation points; writes nothing the pipeline
# or export reads. Outputs go to data/<city>/sensitivity/.
#
# Why not richness: the published residual is the observation with its sign
# flipped (docs/methodology.md §7.1), and a spatial smooth on richness found
# only "fewer species per record than nearby" (prototype_spatial_gap.R). A
# record says what was present; a gap needs evidence of what was absent.
#
# The evidence for absence is the visit. One observer on one date at one site
# is a visit, and the species of a taxon group they recorded is its list. A
# species missing from many long lists at a site is probably not there; one
# missing from a single photograph says nothing. Single-season occupancy models
# with list length as the detection covariate turn that into a probability
# (van Strien et al. 2013, J. Appl. Ecol. 50:1450; MacKenzie et al. 2002) —
# the standard treatment of opportunistic records that are not complete lists.
#
# Per species, per site s and visit v:
#
#   occupied_s ~ Bernoulli(psi_s),  logit psi_s = habitat mix of the site
#   recorded_sv | occupied ~ Bernoulli(p_v),
#                logit p_v = log(list length) + season (sin/cos day of year)
#
# Per site and taxon group:
#
#   expected  = sum of psi over the group's modelled species (habitat says)
#   supported = sum of P(occupied | what was and was not recorded)
#   gap       = expected - supported: positive where habitat predicts species
#               the visits say are missing, negative where more are recorded
#
# psi is cross-validated by site: a site's expectation comes from a model fitted
# without it, so its own absences cannot lower its own benchmark. A site counts
# as assessed for a group only if a typical species (the median over the
# group's species) would have been recorded at least once with probability
# ASSESSED_P over its visits; otherwise it is not assessed — excluded, not zero.
#
# Validation (VALIDATE_UNIT only), pass/fail fixed before the first run:
#
#   time      fit on records before TEST_START; species flagged missing
#             (psi >= FLAG_PSI, P(occupied) <= FLAG_POST) must be recorded at
#             those sites afterwards at under half the rate of the other
#             undetected species there.
#   observer  observers split at random into two halves, everything refitted
#             per half; site gaps must correlate at r >= 0.5.
#   effort    |Spearman(gap, log visits)| < 0.2 over assessed sites.
#   coverage  at least 30% of the city's cells in assessed sites.
#
# A taxon group that fails a test, or has too little data to be tested, is
# reported and left out of the combined gap; the combined gap is then tested
# again on the groups that remain.
#
# Options:
#   HABITAT_SET=basic  occupancy from tree, grass/shrub, water and built cover
#                      (WorldCover) and site size — the first run.
#   HABITAT_SET=rich   (default) adds canopy height, 0.5 m vegetated fraction,
#                      water proximity and corridor importance from the grid.
#   OBS_FROM_RAW=1     rebuild the observations from data/<city>/raw with the
#                      pipeline's own loader and quality gates
#                      (load_obs_for_tiling) instead of reading the processed
#                      tiled_obs_all.rds — for testing a fresh ingest without
#                      rerunning the habitat stage. Nothing processed is written.

suppressMessages({library(sf); library(dplyr); library(tidyr)})

CITY <- Sys.getenv("SENS_CITY", "porto")
if (!exists("CONFIG_LOADED")) setwd(Sys.getenv("NATUREGAP_PIPELINE", "."))
suppressMessages(source("config.R"))

# classify_taxon_group() and load_obs_for_tiling() are the pipeline's own.
# process_tile.R holds only library() calls and function definitions at top
# level, so sourcing it into its own environment runs nothing.
pipeline_fns <- new.env()
suppressMessages(sys.source(here::here("02_habitat", "process_tile.R"), envir = pipeline_fns))
classify_taxon_group <- pipeline_fns$classify_taxon_group

SITE_UNITS    <- strsplit(Sys.getenv("SITE_UNITS", "250,500,park"), ",")[[1]]
VALIDATE_UNIT <- Sys.getenv("VALIDATE_UNIT", "250")
PERIOD_START  <- as.Date(Sys.getenv("PERIOD_START", "2019-01-01"))
TEST_START    <- as.Date(Sys.getenv("TEST_START", "2023-01-01"))
MIN_SITES     <- 10L      # sites a species must be recorded at to be modelled
CV_FOLDS      <- 5L
ASSESSED_P    <- 0.8
FLAG_PSI      <- 0.5
FLAG_POST     <- 0.2
# Weakly informative normal penalties on the logit scale (covariates are
# standardised). They only keep sparse species from running to a boundary.
PRIOR_SD_INTERCEPT <- 5
PRIOR_SD_SLOPE     <- 2.5
SEED <- 20261005L

HABITAT_SET  <- Sys.getenv("HABITAT_SET", "rich")
OBS_FROM_RAW <- identical(Sys.getenv("OBS_FROM_RAW", "0"), "1")
HABITAT_COVARIATES <- switch(
  HABITAT_SET,
  basic = c("tree", "grass_shrub", "water", "built", "log_cells"),
  rich  = c("tree", "grass_shrub", "water", "built", "log_cells",
            "canopy_height", "veg_fraction", "water_proximity", "corridor"),
  stop("HABITAT_SET must be 'basic' or 'rich'", call. = FALSE)
)
# OBS_MAX_ACCURACY_M=<metres>, with OBS_FROM_RAW=1, replaces the pipeline's GPS
# gate for this run only. config.R sets 30 m because the analytical cell is 20 m
# across; a record placed to within half a block is still evidence about the
# block, and at 30 m the gate drops half of Porto's iNaturalist records (median
# stated accuracy 31 m). load_obs_for_tiling() reads the global, so assigning it
# here is enough.
ACCURACY_OVERRIDE <- suppressWarnings(as.numeric(Sys.getenv("OBS_MAX_ACCURACY_M", "")))
if (is.finite(ACCURACY_OVERRIDE)) {
  if (!OBS_FROM_RAW) {
    stop("OBS_MAX_ACCURACY_M needs OBS_FROM_RAW=1: the processed observations are already gated.",
         call. = FALSE)
  }
  OBS_MAX_ACCURACY_M <- ACCURACY_OVERRIDE
}
# Output names carry the run's options, so runs do not overwrite each other.
RUN_TAG <- paste0(HABITAT_SET, if (OBS_FROM_RAW) "_raw" else "",
                  if (is.finite(ACCURACY_OVERRIDE)) sprintf("_acc%g", ACCURACY_OVERRIDE) else "")

PASS_OBSERVER_R <- 0.5
PASS_EFFORT_RHO <- 0.2
PASS_COVERAGE   <- 0.30
PASS_TIME_RATIO <- 0.5
MIN_TEST_SITES  <- 10L    # sites assessed in both halves for the observer test
MIN_TEST_PAIRS  <- 20L    # flagged species-site pairs for the time test

# Seen overhead, these say nothing about the site below: swifts, swallows and
# martins, gulls, cormorant, grey heron.
AERIAL_BIRDS <- "^(Apus|Tachymarptis|Hirundo|Cecropis|Delichon|Ptyonoprogne|Riparia|Larus|Chroicocephalus|Ichthyaetus)( |$)|^(Phalacrocorax carbo|Ardea cinerea)$"

OUT_DIR <- file.path(DATA_ROOT, "sensitivity")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# ── 1a. Records, sites, visits ──────────────────────────────────────────────

grid <- st_read(PROC_GRID_RESID, quiet = TRUE)
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
    cell_id, green_space_id,
    x = xy[, 1], y = xy[, 2],
    tree = tree_fraction,
    grass_shrub = grass_fraction + shrub_fraction,
    water = water_fraction,
    built = built_fraction_wc,
    canopy_height = canopy_height_m,
    veg_fraction,
    water_proximity,
    # NA where the connectivity stage scored no corridor; the pipeline reads
    # that as 0 too (connectivity_component in 05_residuals/residuals.R).
    corridor = replace_na(corridor_importance, 0)
  )
rm(grid, xy); invisible(gc())

records_all <- obs |>
  transmute(
    cell_id, taxon_name,
    group = coalesce(classify_taxon_group(iconic_taxon_name), "other"),
    date = as.Date(observed_on),
    observer_id = if_else(is.na(observer_id) | !nzchar(observer_id), NA_character_, observer_id),
    # A record with no observer cannot be grouped into anyone's list, so it is
    # a visit of its own.
    observer_key = coalesce(observer_id, paste0("record-", row_number()))
  ) |>
  # Species only: a genus-level name would overlap the species under it.
  filter(!is.na(taxon_name), grepl(" ", taxon_name), !is.na(date), date >= PERIOD_START) |>
  filter(!(group == "bird" & grepl(AERIAL_BIRDS, taxon_name)))
rm(obs); invisible(gc())

# Site of every cell, per unit. Square blocks are keyed on the cell centroid,
# so a cell and its records always share a site. Parks use green_space_id.
site_of_cells <- function(unit) {
  # Character, so a park id is never mistaken for a row position when indexing.
  if (unit == "park") return(as.character(cells$green_space_id))
  size <- as.numeric(unit)
  paste(floor(cells$x / size), floor(cells$y / size), sep = "_")
}

# Habitat mix per site, standardised across every site in the unit (not only
# those with records), and log cell count for partial edge blocks and park size.
site_table <- function(unit) {
  cells |>
    mutate(site = site_of_cells(unit)) |>
    filter(!is.na(site)) |>
    group_by(site) |>
    summarise(across(c(tree, grass_shrub, water, built, canopy_height, veg_fraction,
                       water_proximity, corridor), \(v) mean(v, na.rm = TRUE)),
              n_cells = n(), .groups = "drop") |>
    mutate(log_cells = log(n_cells),
           across(all_of(HABITAT_COVARIATES),
                  \(v) { s <- stats::sd(v); if (is.finite(s) && s > 0) (v - mean(v)) / s else 0 },
                  .names = "z_{.col}"))
}

build_visits <- function(records, unit) {
  site_lookup <- setNames(site_of_cells(unit), cells$cell_id)
  r <- records |>
    mutate(site = unname(site_lookup[cell_id])) |>
    filter(!is.na(site)) |>
    distinct(group, site, observer_key, date, taxon_name)
  visits <- r |>
    group_by(group, site, observer_key, date) |>
    summarise(list_length = n(), .groups = "drop") |>
    mutate(visit_id = row_number(),
           doy = as.integer(format(date, "%j")))
  det <- r |>
    inner_join(visits |> select(group, site, observer_key, date, visit_id),
               by = c("group", "site", "observer_key", "date")) |>
    select(group, site, taxon_name, visit_id)
  list(visits = visits, det = det)
}

# ── 1c. Occupancy model ─────────────────────────────────────────────────────

softplus <- function(z) pmax(z, 0) + log1p(exp(-abs(z)))
logsumexp2 <- function(a, b) { m <- pmax(a, b); m + log1p(exp(-abs(a - b))) }

# Negative penalised log-likelihood and its gradient. With w_s the posterior
# probability that site s is occupied (1 where the species was recorded), the
# gradients reduce to X'(w - psi) for occupancy and Z'(y - p w) for detection.
occ_fn <- function(par, X, Z, site, y, detected, prior_sd) {
  kb <- ncol(X)
  eta <- drop(X %*% par[seq_len(kb)])
  zeta <- drop(Z %*% par[-seq_len(kb)])
  log_q <- -softplus(zeta)                       # log(1 - p)
  ll_visit <- ifelse(y == 1, -softplus(-zeta), log_q)
  S <- rowsum(ll_visit, site, reorder = TRUE)[, 1]
  log_psi <- -softplus(-eta)
  log_1m_psi <- -softplus(eta)
  ll_absent <- logsumexp2(log_psi + S, log_1m_psi)
  ll <- ifelse(detected, log_psi + S, ll_absent)
  w <- ifelse(detected, 1, exp(log_psi + S - ll_absent))
  psi <- exp(log_psi)
  p <- exp(-softplus(-zeta))
  g <- c(crossprod(X, w - psi), crossprod(Z, y - p * w[site]))
  list(value = -sum(ll) + sum(par^2 / (2 * prior_sd^2)),
       gradient = -g + par / prior_sd^2)
}

fit_occupancy <- function(X, Z, site, y, detected) {
  prior_sd <- c(PRIOR_SD_INTERCEPT, rep(PRIOR_SD_SLOPE, ncol(X) - 1L),
                PRIOR_SD_INTERCEPT, rep(PRIOR_SD_SLOPE, ncol(Z) - 1L))
  start <- c(qlogis(min(0.95, max(0.05, mean(detected)))), rep(0, ncol(X) - 1L),
             qlogis(min(0.5, max(1e-3, mean(y)))), rep(0, ncol(Z) - 1L))
  # Value and gradient come from one pass; reuse it when optim asks for both
  # at the same parameters.
  last_par <- NULL
  last <- NULL
  at <- function(par) {
    if (!identical(par, last_par)) {
      last <<- occ_fn(par, X, Z, site, y, detected, prior_sd)
      last_par <<- par
    }
    last
  }
  o <- optim(start, function(p) at(p)$value, function(p) at(p)$gradient,
             method = "BFGS", control = list(maxit = 500))
  list(par = o$par, converged = o$convergence == 0L, kb = ncol(X))
}

# Expected occupancy, posterior occupancy, and P(recorded at least once | present)
# at held-out sites, from a fit that did not see them.
predict_sites <- function(fit, X, Z, site, y) {
  kb <- fit$kb
  eta <- drop(X %*% fit$par[seq_len(kb)])
  zeta <- drop(Z %*% fit$par[-seq_len(kb)])
  log_q <- -softplus(zeta)
  A <- rowsum(log_q, site, reorder = TRUE)[, 1]
  detected <- rowsum(y, site, reorder = TRUE)[, 1] > 0
  log_psi <- -softplus(-eta)
  post <- ifelse(detected, 1, exp(log_psi + A - logsumexp2(log_psi + A, -softplus(eta))))
  data.frame(psi = exp(log_psi), post = post, detected = detected, pstar = 1 - exp(A))
}

detection_design <- function(v) {
  cbind(1, log(v$list_length), sin(2 * pi * v$doy / 365.25), cos(2 * pi * v$doy / 365.25))
}

site_folds <- function(sites) {
  set.seed(SEED)
  setNames(sample(rep(seq_len(CV_FOLDS), length.out = length(sites))), sites)
}

# ── 1b–1d. One full analysis: species, fits, per-site scores ────────────────

run_analysis <- function(records, unit, label) {
  t0 <- Sys.time()
  st <- site_table(unit)
  folds_all <- site_folds(st$site)
  vis <- build_visits(records, unit)
  zcols <- paste0("z_", HABITAT_COVARIATES)

  per_group <- lapply(sort(unique(vis$visits$group)), function(grp) {
    v <- vis$visits[vis$visits$group == grp, ]
    det <- vis$det[vis$det$group == grp, ]
    # 1b: species recorded at MIN_SITES sites or more in this data.
    species <- det |> distinct(site, taxon_name) |> count(taxon_name) |>
      filter(n >= MIN_SITES) |> pull(taxon_name)
    if (length(species) == 0L) return(NULL)

    sites <- sort(unique(v$site))
    site_idx_all <- match(v$site, sites)
    X_all <- cbind(1, as.matrix(st[match(sites, st$site), zcols]))
    Z_all <- detection_design(v)
    fold_of_site <- folds_all[sites]
    det_by_species <- split(match(det$visit_id, v$visit_id), det$taxon_name)

    # Fold splits are shared by every species in the group.
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

    fits <- list()
    rows <- lapply(species, function(sp) {
      y_all <- integer(nrow(v)); y_all[unique(det_by_species[[sp]])] <- 1L
      fits[[sp]] <<- vector("list", CV_FOLDS)
      out <- lapply(seq_len(CV_FOLDS), function(k) {
        fp <- fold_parts[[k]]
        if (is.null(fp)) return(NULL)
        detected_tr <- rowsum(y_all[fp$tr_v], fp$tr_site, reorder = TRUE)[, 1] > 0
        fit <- fit_occupancy(fp$X_tr, fp$Z_tr, fp$tr_site, y_all[fp$tr_v], detected_tr)
        fits[[sp]][[k]] <<- fit
        pr <- predict_sites(fit, fp$X_te, fp$Z_te, fp$te_site, y_all[fp$te_v])
        data.frame(site = sites[fp$te_sites], taxon_name = sp, pr, converged = fit$converged)
      })
      do.call(rbind, out)
    })
    ss <- do.call(rbind, rows)
    ss$group <- grp
    visits_per_site <- v |> count(site, name = "n_visits")
    list(site_species = ss, fits = fits, visits_per_site = visits_per_site |> mutate(group = grp),
         detection = detection_summary(fits))
  })
  per_group <- Filter(Negate(is.null), per_group)

  site_species <- do.call(rbind, lapply(per_group, `[[`, "site_species"))
  site_group <- score_sites(site_species, do.call(rbind, lapply(per_group, `[[`, "visits_per_site")))
  fits <- setNames(lapply(per_group, `[[`, "fits"), vapply(per_group, function(g) g$site_species$group[1], ""))
  detection <- do.call(rbind, lapply(names(fits), function(g) cbind(group = g, per_group[[match(g, names(fits))]]$detection)))
  cat(sprintf("  %s, %s: %d species, %d site-groups, %.1f min\n", label,
              if (unit == "park") "parks" else paste(unit, "m"),
              n_distinct(site_species$taxon_name), nrow(site_group),
              as.numeric(Sys.time() - t0, units = "mins")))
  list(unit = unit, site_species = site_species, site_group = site_group, fits = fits,
       folds = folds_all, detection = detection, sites = st)
}

# Median detection probability per visit for a list of 1 and of 10 species, at
# mid-year: shows how much a group's visits can say about absence at all.
detection_summary <- function(fits) {
  p_at <- function(len) {
    vapply(fits, function(f) {
      ok <- Filter(Negate(is.null), f)
      stats::median(vapply(ok, function(x) {
        a <- x$par[-seq_len(x$kb)]
        plogis(a[1] + a[2] * log(len) + a[3] * sin(pi) + a[4] * cos(pi))
      }, numeric(1)))
    }, numeric(1))
  }
  data.frame(p_list1 = stats::median(p_at(1)), p_list10 = stats::median(p_at(10)))
}

score_sites <- function(site_species, visits_per_site) {
  site_species |>
    mutate(flag = !detected & psi >= FLAG_PSI & post <= FLAG_POST) |>
    group_by(site, group) |>
    summarise(
      n_species = n(),
      expected = sum(psi),
      supported = sum(post),
      recorded = sum(detected),
      median_pstar = stats::median(pstar),
      flagged = sum(flag),
      # The five flagged species habitat predicts most strongly.
      missing = paste(head(taxon_name[flag][order(-psi[flag])], 5), collapse = "; "),
      .groups = "drop"
    ) |>
    left_join(visits_per_site, by = c("site", "group")) |>
    mutate(gap = expected - supported,
           rel_gap = gap / expected,
           assessed = median_pstar >= ASSESSED_P)
}

# Combined gap per site over the given groups, using only the groups assessed
# at that site.
combine_groups <- function(site_group, groups) {
  site_group |>
    filter(group %in% groups, assessed) |>
    group_by(site) |>
    summarise(groups = paste(sort(group), collapse = "+"),
              expected = sum(expected), supported = sum(supported),
              n_visits = sum(n_visits), flagged = sum(flagged), .groups = "drop") |>
    mutate(gap = expected - supported, rel_gap = gap / expected)
}

coverage_share <- function(sites_assessed, unit) {
  mean(site_of_cells(unit) %in% sites_assessed)
}

# ── Main analyses ───────────────────────────────────────────────────────────

cat(sprintf("Records from %s: %d (%s)\n", PERIOD_START, nrow(records_all),
            paste(sprintf("%s %d", names(table(records_all$group)), table(records_all$group)), collapse = ", ")))

main <- setNames(lapply(SITE_UNITS, function(u) run_analysis(records_all, u, "all records")), SITE_UNITS)

# ── 1e. Validation ──────────────────────────────────────────────────────────

V <- main[[VALIDATE_UNIT]]
groups_all <- unique(V$site_group$group)

# Time holdout.
train <- run_analysis(records_all |> filter(date < TEST_START), VALIDATE_UNIT, "before test period")
test_records <- records_all |> filter(date >= TEST_START)
test_vis <- build_visits(test_records, VALIDATE_UNIT)
later <- test_vis$det |> distinct(group, site, taxon_name) |> mutate(later = TRUE)

pairs <- train$site_species |>
  inner_join(train$site_group |> filter(assessed) |> select(site, group), by = c("site", "group")) |>
  filter(!detected) |>
  mutate(flag = psi >= FLAG_PSI & post <= FLAG_POST) |>
  left_join(later, by = c("group", "site", "taxon_name")) |>
  mutate(later = coalesce(later, FALSE)) |>
  # Only sites visited again in the test period can show a later record.
  semi_join(test_vis$visits |> distinct(group, site), by = c("group", "site"))

# Diagnostic beside the pre-stated test: how often a flagged species would have
# been recorded in the test-period visits if it were present, from the
# training fit for that site's fold.
expected_if_present <- function(pairs_flagged) {
  if (nrow(pairs_flagged) == 0L) return(NA_real_)
  tv <- test_vis$visits
  rows_of <- split(seq_len(nrow(tv)), paste(tv$group, tv$site))
  vals <- mapply(function(grp, site, sp) {
    f <- train$fits[[grp]][[sp]][[train$folds[[site]]]]
    if (is.null(f)) return(NA_real_)
    vv <- tv[rows_of[[paste(grp, site)]], ]
    a <- f$par[-seq_len(f$kb)]
    1 - exp(sum(-softplus(drop(detection_design(vv) %*% a))))
  }, pairs_flagged$group, pairs_flagged$site, pairs_flagged$taxon_name)
  mean(vals, na.rm = TRUE)
}

time_test <- function(p) {
  f <- p[p$flag, ]; u <- p[!p$flag, ]
  rate_f <- if (nrow(f)) mean(f$later) else NA_real_
  rate_u <- if (nrow(u)) mean(u$later) else NA_real_
  data.frame(flagged_pairs = nrow(f), later_rate_flagged = rate_f,
             later_rate_unflagged = rate_u, ratio = rate_f / rate_u,
             if_present = expected_if_present(f),
             time_pass = nrow(f) >= MIN_TEST_PAIRS & is.finite(rate_f / rate_u) &
               rate_f / rate_u < PASS_TIME_RATIO)
}

# Observer halves. Records without an observer cannot be assigned to a
# recorder and are left out of both halves.
with_observer <- records_all |> filter(!is.na(observer_id))
observers <- sort(unique(with_observer$observer_id))
set.seed(SEED)
half_a <- observers[sample.int(length(observers), floor(length(observers) / 2))]
halves <- list(
  a = run_analysis(with_observer |> filter(observer_id %in% half_a), VALIDATE_UNIT, "observer half A"),
  b = run_analysis(with_observer |> filter(!observer_id %in% half_a), VALIDATE_UNIT, "observer half B")
)

observer_test <- function(groups) {
  ca <- combine_groups(halves$a$site_group, groups)
  cb <- combine_groups(halves$b$site_group, groups)
  j <- inner_join(ca, cb, by = "site", suffix = c("_a", "_b"))
  data.frame(sites_both = nrow(j),
             observer_r = if (nrow(j) >= 3L) stats::cor(j$gap_a, j$gap_b) else NA_real_)
}

effort_test <- function(comb) {
  if (nrow(comb) < 3L) return(NA_real_)
  stats::cor(comb$gap, log(comb$n_visits), method = "spearman")
}

group_tests <- do.call(rbind, lapply(groups_all, function(g) {
  sg <- V$site_group[V$site_group$group == g, ]
  comb <- combine_groups(V$site_group, g)
  tt <- time_test(pairs[pairs$group == g, ])
  ot <- observer_test(g)
  data.frame(
    group = g,
    species = n_distinct(V$site_species$taxon_name[V$site_species$group == g]),
    sites_with_data = nrow(sg),
    sites_assessed = sum(sg$assessed),
    coverage = coverage_share(sg$site[sg$assessed], VALIDATE_UNIT),
    p_list1 = V$detection$p_list1[V$detection$group == g],
    p_list10 = V$detection$p_list10[V$detection$group == g],
    tt, ot,
    effort_rho = effort_test(comb)
  ) |>
    mutate(observer_pass = sites_both >= MIN_TEST_SITES & is.finite(observer_r) & observer_r >= PASS_OBSERVER_R,
           effort_pass = is.finite(effort_rho) & abs(effort_rho) < PASS_EFFORT_RHO,
           group_pass = time_pass & observer_pass & effort_pass)
}))

kept <- group_tests$group[group_tests$group_pass]
combined <- combine_groups(V$site_group, kept)
combined_tests <- cbind(
  data.frame(groups = if (length(kept)) paste(kept, collapse = "+") else "(none)",
             sites_assessed = nrow(combined),
             coverage = coverage_share(combined$site, VALIDATE_UNIT)),
  time_test(pairs[pairs$group %in% kept, ]),
  observer_test(kept),
  effort_rho = effort_test(combined)
) |>
  mutate(observer_pass = sites_both >= MIN_TEST_SITES & is.finite(observer_r) & observer_r >= PASS_OBSERVER_R,
         effort_pass = is.finite(effort_rho) & abs(effort_rho) < PASS_EFFORT_RHO,
         coverage_pass = coverage >= PASS_COVERAGE,
         all_pass = length(kept) > 0L & time_pass & observer_pass & effort_pass & coverage_pass)

# ── 1f. Outputs ─────────────────────────────────────────────────────────────

for (u in SITE_UNITS) {
  m <- main[[u]]
  out <- bind_rows(
    m$site_group |> mutate(group = as.character(group)),
    combine_groups(m$site_group, kept) |> mutate(group = "combined", assessed = TRUE)
  )
  write.csv(out, file.path(OUT_DIR, sprintf("occupancy_gap_sites_%s_%s.csv", u, RUN_TAG)), row.names = FALSE)
}
write.csv(V$site_species, file.path(OUT_DIR, sprintf("occupancy_gap_species_%s_%s.csv", VALIDATE_UNIT, RUN_TAG)), row.names = FALSE)
write.csv(group_tests, file.path(OUT_DIR, sprintf("occupancy_gap_tests_%s.csv", RUN_TAG)), row.names = FALSE)

draw_map <- function(m, path) {
  if (m$unit == "park" || !requireNamespace("ggplot2", quietly = TRUE)) return(invisible(NULL))
  library(ggplot2)
  size <- as.numeric(m$unit)
  centre <- function(site) {
    k <- do.call(rbind, strsplit(site, "_", fixed = TRUE))
    data.frame(site = site, cx = (as.numeric(k[, 1]) + 0.5) * size, cy = (as.numeric(k[, 2]) + 0.5) * size)
  }
  all_sites <- centre(unique(site_of_cells(m$unit)))
  panels <- c(sort(unique(m$site_group$group)), "combined")
  long <- do.call(rbind, lapply(panels, function(g) {
    sg <- if (g == "combined") combine_groups(m$site_group, kept) |> mutate(assessed = TRUE)
          else m$site_group[m$site_group$group == g, ]
    all_sites |>
      left_join(sg |> select(site, assessed, rel_gap), by = "site") |>
      mutate(panel = if (g == "combined") sprintf("combined (%s)", if (length(kept)) paste(kept, collapse = "+") else "no group passed") else g,
             state = case_when(is.na(assessed) ~ "no records", !assessed ~ "not assessed", TRUE ~ "assessed"),
             fill = if_else(state == "assessed", pmax(-0.5, pmin(0.5, rel_gap)), NA_real_))
  }))
  p <- ggplot(long, aes(cx, cy)) +
    geom_tile(data = long[long$state == "no records", ], fill = "#EEF0EA", width = size, height = size) +
    geom_tile(data = long[long$state == "not assessed", ], fill = "#C9CDC5", width = size, height = size) +
    geom_tile(data = long[long$state == "assessed", ], aes(fill = fill), width = size, height = size) +
    scale_fill_gradient2(low = "#2E6F40", mid = "#F2EFE6", high = "#B5532F", midpoint = 0,
                         limits = c(-0.5, 0.5), labels = scales::percent,
                         name = "Expected species\nthe visits say\nare missing") +
    coord_equal() + facet_wrap(~ panel, ncol = 2) +
    theme_void(base_size = 9) +
    theme(strip.text = element_text(hjust = 0, face = "bold"),
          plot.background = element_rect(fill = "white", colour = NA)) +
    labs(title = sprintf("%s - occupancy gap prototype, %s m blocks (%s)", CITY_NAME, m$unit, RUN_TAG),
         subtitle = "Red: habitat predicts species the visits say are missing. Green: more recorded than expected.\nMid grey: records too few or too sparse to assess. Pale: no records.")
  ggsave(path, p, width = 8, height = 11, dpi = 150)
}
for (u in SITE_UNITS) draw_map(main[[u]], file.path(OUT_DIR, sprintf("occupancy_gap_map_%s_%s.png", u, RUN_TAG)))

# ── Report ──────────────────────────────────────────────────────────────────

fmt <- function(df) { df[] <- lapply(df, function(v) if (is.numeric(v)) signif(v, 3) else v); df }

cat(sprintf("\n== %s == occupancy gap prototype (%s), %s to %s\n", CITY_ID, RUN_TAG, PERIOD_START, max(records_all$date)))
cat(sprintf("habitat covariates: %s\n", paste(HABITAT_COVARIATES, collapse = ", ")))
cat(sprintf("observations: %s, GPS gate %s m\n",
            if (OBS_FROM_RAW) "rebuilt from raw" else "processed tiled_obs_all.rds",
            if (OBS_FROM_RAW) format(OBS_MAX_ACCURACY_M) else "as processed"))
cat(sprintf("records with an observer: %s\n", paste(sprintf("%s %.0f%%", names(tapply(!is.na(records_all$observer_id), records_all$group, mean)), 100 * tapply(!is.na(records_all$observer_id), records_all$group, mean)), collapse = ", ")))
for (u in SITE_UNITS) {
  m <- main[[u]]
  cov <- m$site_group |> group_by(group) |>
    summarise(species = n_distinct(m$site_species$taxon_name[m$site_species$group == first(group)]),
              sites_with_data = n(), sites_assessed = sum(assessed),
              median_rel_gap = stats::median(rel_gap[assessed]), .groups = "drop") |>
    mutate(coverage = vapply(group, function(g) coverage_share(m$site_group$site[m$site_group$group == g & m$site_group$assessed], u), numeric(1)))
  cat(sprintf("\n-- %s%s: coverage per group --\n", u, if (u == "park") "" else " m blocks"))
  print(fmt(as.data.frame(cov)), row.names = FALSE)
  cat(sprintf("non-converged fits: %d of %d\n", sum(!m$site_species$converged), nrow(m$site_species)))
}

cat(sprintf("\n-- validation, %s m: per group --\n", VALIDATE_UNIT))
print(fmt(group_tests), row.names = FALSE)
cat(sprintf("\n-- validation, %s m: combined over groups that passed --\n", VALIDATE_UNIT))
print(fmt(combined_tests), row.names = FALSE)

top <- combined |> arrange(desc(gap)) |> head(8) |>
  left_join(V$site_group |> filter(assessed) |> group_by(site) |>
              summarise(missing = paste(missing[nzchar(missing)], collapse = "; "), .groups = "drop"),
            by = "site")
cat(sprintf("\n-- largest combined gaps, %s m --\n", VALIDATE_UNIT))
print(fmt(as.data.frame(top |> select(site, groups, n_visits, expected, supported, gap, rel_gap, missing))), row.names = FALSE)

cat("\nexpected / supported : sum of habitat occupancy / of occupancy given the visits.\n")
cat("assessed             : a typical species would have been recorded at least once with p >= ", ASSESSED_P, ".\n", sep = "")
cat("p_list1 / p_list10   : median chance a visit records a present species, for lists of 1 and 10.\n")
cat("time                 : later-record rate of flagged-missing vs other undetected species; pass if ratio < ",
    PASS_TIME_RATIO, ". if_present: rate expected if flagged species were present.\n", sep = "")
cat("observer_r           : correlation of site gaps fitted on two random halves of observers; pass if >= ", PASS_OBSERVER_R, ".\n", sep = "")
cat("effort_rho           : Spearman(gap, log visits); pass if |rho| < ", PASS_EFFORT_RHO, ".\n", sep = "")
cat("coverage             : share of the city's cells in assessed sites; pass if >= ", PASS_COVERAGE, ".\n", sep = "")
cat(sprintf("\nWritten to %s\n", OUT_DIR))
