# NatureGap — what the published residual is made of, and how much data it covers
#
# ecological_residual is R = expected_richness - effort_corrected_richness. The
# expected model's fit statistic (explained deviance) says how well the
# expectation tracks the observation; it does not say what the difference map is
# made of. With lambda = Var(expected) / Var(observed) and rho = cor(expected,
# observed):
#
#   cor(R, -observed) = (1 - rho * sqrt(lambda)) /
#                       sqrt(1 + lambda - 2 * rho * sqrt(lambda))
#
# so lambda decides whether R is a third quantity or one of its inputs
# re-rendered. On the 2026-08-26 exports lambda was 0.0002-0.028 at hex scale in
# all four cities, and the residual shared 97-99.98% of its variance with the
# observation. The expected-richness specification before that sat at the
# opposite extreme (cor(R, expected) 0.999). See docs/methodology.md §7.1.
#
# observation_coverage() says how much of the grid, and of the record stream,
# the effort-corrected observation speaks for: the MIN_PATH_M admission rule
# excludes cells, and records falling in them never reach the model.
#
# Both are written to the export manifest. Neither gates or alters any output.

# Variance decomposition of R = expected - observed over rows where both are
# finite. Population variance throughout, matching paper/analysis/theory.py.
residual_window <- function(expected, observed, window = RESIDUAL_WINDOW_LAMBDA) {
  ok <- is.finite(expected) & is.finite(observed)
  e <- expected[ok]
  y <- observed[ok]
  n <- length(e)
  pvar <- function(v) mean((v - mean(v))^2)
  var_e <- if (n > 0L) pvar(e) else NA_real_
  var_y <- if (n > 0L) pvar(y) else NA_real_

  record <- list(
    n = n,
    varExpected = signif(var_e, 6),
    varObserved = signif(var_y, 6),
    lambda = NA_real_,
    rho = NA_real_,
    corResidualNegObserved = NA_real_,
    corResidualNegObservedPredicted = NA_real_,
    corResidualExpected = NA_real_,
    sharedVarianceWithObserved = NA_real_,
    regime = "undetermined",
    window = as.list(window)
  )
  # An observation with no spread leaves lambda undefined.
  if (n < 2L || !is.finite(var_y) || var_y <= 0) return(record)

  lambda <- var_e / var_y
  r <- e - y
  # A constant expectation (the constant-rate fallback) has no correlation with
  # anything; lambda is then 0 and rho drops out of the prediction below.
  rho <- if (var_e > 0) stats::cor(e, y) else NA_real_
  cor_neg_obs <- if (pvar(r) > 0) stats::cor(r, -y) else NA_real_
  cor_exp <- if (pvar(r) > 0 && var_e > 0) stats::cor(r, e) else NA_real_
  rho0 <- if (is.finite(rho)) rho else 0
  predicted <- (1 - rho0 * sqrt(lambda)) / sqrt(1 + lambda - 2 * rho0 * sqrt(lambda))

  record$lambda <- signif(lambda, 6)
  record$rho <- round(rho, 6)
  record$corResidualNegObserved <- round(cor_neg_obs, 6)
  record$corResidualNegObservedPredicted <- round(predicted, 6)
  record$corResidualExpected <- round(cor_exp, 6)
  record$sharedVarianceWithObserved <- round(cor_neg_obs^2, 4)
  record$regime <- if (lambda < window[["lower"]]) {
    "observation-dominated"
  } else if (lambda > window[["upper"]]) {
    "model-dominated"
  } else {
    "informative"
  }
  record
}

# Cells admitted by the effort rule, how many of them hold data, and the share
# of all records that fall in excluded cells.
observation_coverage <- function(is_unsampled, n_obs, species_richness) {
  admitted <- !is.na(is_unsampled) & !is_unsampled
  records <- as.numeric(n_obs)
  records[!is.finite(records)] <- 0
  species <- as.numeric(species_richness)
  species[!is.finite(species)] <- 0
  share <- function(part, whole) if (whole > 0) round(part / whole, 4) else NA_real_

  n_admitted <- sum(admitted)
  with_records <- sum(admitted & records > 0)
  with_species <- sum(admitted & species > 0)
  total_records <- sum(records)
  discarded <- sum(records[!admitted])

  list(
    rule = sprintf(
      "A cell is admitted when OSM pedestrian path within %d m of its centroid is at least %d m.",
      PATH_RADIUS_M, MIN_PATH_M
    ),
    cellsTotal = length(admitted),
    cellsAdmitted = n_admitted,
    admittedShare = share(n_admitted, length(admitted)),
    admittedWithRecords = with_records,
    admittedWithRecordsShare = share(with_records, n_admitted),
    admittedWithSpecies = with_species,
    admittedWithSpeciesShare = share(with_species, n_admitted),
    recordsTotal = total_records,
    recordsInExcludedCells = discarded,
    recordsDiscardedShare = share(discarded, total_records)
  )
}

# One export-log line per residual_window() record.
format_residual_window <- function(scale, record) {
  if (!is.finite(record$lambda)) {
    return(sprintf("Residual window (%s): undetermined (n = %d)", scale, record$n))
  }
  sprintf(
    "Residual window (%s): lambda = %s over %d units, %s; the residual shares %.1f%% of its variance with the observation",
    scale, format(record$lambda, digits = 3), record$n, record$regime,
    100 * record$sharedVarianceWithObserved
  )
}
