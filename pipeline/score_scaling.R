# NatureGap — robust within-city scaling for the headline score
#
# nature_gap_score composes three terms. Each was previously scaled in a way that
# could not survive its own data:
#
#  - The biodiversity term divided the residual by max|residual|, which one
#    outlier destroys. On the 2026-08-19 Porto export the fitted residual has
#    sd 0.44 while a single hex reaches -50.6 (272 species in ~350 m²), so the
#    term spanned -0.17..+0.14 of its nominal ±50: the headline score contained
#    no measurable biodiversity signal at all.
#  - (1 - habitat_quality) and (1 - corridor_importance) are non-negative by
#    construction, and corridor_importance is 0 in 88% of sampled cells, so the
#    connectivity term sat at exactly +20 across most of the grid — a constant,
#    not a measurement. Together the two imposed a ~+38 floor and every Porto
#    cell landed in the `much-worse` band, leaving the five-band scale carrying
#    no information.
#
# robust_centre puts a term on a signed [-1, 1] scale around this city's median,
# using a percentile spread so outliers cannot compress it. Zero therefore means
# "typical cell for this city": the score is explicitly within-city relative, and
# its parameters are per-city per-run. See docs/methodology.md §8.
#
# Params are derived from the scored subset and then applied to every row, so an
# unsampled cell cannot shift the median that scored cells are measured against.

# Median and percentile half-spread of `v`, for use by apply_robust_centre.
robust_centre_params <- function(v, lower = 0.10, upper = 0.90) {
  finite <- v[is.finite(v)]
  if (length(finite) == 0L) {
    return(list(
      median = NA_real_, spread = NA_real_, lowerQuantile = lower,
      upperQuantile = upper, n = 0L, clampedShare = NA_real_, degenerate = TRUE
    ))
  }

  mid <- stats::median(finite)
  qs <- stats::quantile(finite, c(lower, upper), names = FALSE)
  spread <- max(abs(qs[1] - mid), abs(qs[2] - mid))

  if (!is.finite(spread) || spread <= 0) {
    # A term with no spread across the scored cells carries no information. It
    # contributes 0 rather than dividing by zero or being clamped to one arm.
    return(list(
      median = round(mid, 6), spread = 0, lowerQuantile = lower,
      upperQuantile = upper, n = length(finite), clampedShare = 0,
      degenerate = TRUE
    ))
  }

  list(
    median        = round(mid, 6),
    spread        = round(spread, 6),
    lowerQuantile = lower,
    upperQuantile = upper,
    n             = length(finite),
    clampedShare  = round(mean(abs((finite - mid) / spread) > 1), 4),
    degenerate    = FALSE
  )
}

# Apply params to any vector. Non-finite input stays NA; a degenerate term
# contributes 0 wherever it has a value.
apply_robust_centre <- function(v, params) {
  out <- rep(NA_real_, length(v))
  ok <- is.finite(v)
  if (!any(ok)) return(out)
  if (isTRUE(params$degenerate) || !is.finite(params$spread) || params$spread <= 0) {
    out[ok] <- 0
    return(out)
  }
  out[ok] <- pmax(-1, pmin(1, (v[ok] - params$median) / params$spread))
  out
}

# Convenience for the render normalisers: centre and scale in one call.
robust_centre <- function(v, lower = 0.10, upper = 0.90) {
  apply_robust_centre(v, robust_centre_params(v, lower, upper))
}

# Merge one scale's scaling parameters into PROC_SCORE_SCALING. residuals.R runs
# first in the chain and passes reset = TRUE so a stale patch block from an
# earlier run cannot be read as belonging to this one.
record_score_scaling <- function(scale_key, params, reset = FALSE,
                                 path = PROC_SCORE_SCALING) {
  existing <- list()
  if (!reset && file.exists(path)) {
    existing <- tryCatch(
      jsonlite::read_json(path, simplifyVector = FALSE),
      error = function(e) list()
    )
    if (!is.list(existing)) existing <- list()
  }

  existing[[scale_key]] <- params
  existing$cityId      <- CITY_ID
  existing$weights     <- list(
    biodiversity = 0.50, habitatDeficit = 0.30, connectivityDeficit = 0.20
  )
  existing$generatedAt <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    existing, path,
    auto_unbox = TRUE, null = "null", na = "null", pretty = TRUE
  )
  cat(sprintf("Written: %s (%s scale)\n", basename(path), scale_key))
  invisible(path)
}
