# NatureGap — shared expected-richness model helper
#
# expected_richness must be the conditional expectation of the *observed*
# quantity, so that
#
#   ecological_residual = expected_richness - observed
#
# is a residual in the statistical sense: the same units on both sides, centred
# on zero, and orthogonal to the predictors it was fitted on. A residual is the
# part of the observation the predictors could not account for; that only holds
# if the prediction predicts the thing that was measured.
#
# This replaces a fixed weighted index multiplied by an arbitrary constant, and
# then OLS on the pre-divided ratio. See config.R (Expected richness model) for
# the measured failures that motivated each step and docs/methodology.md §6-§7
# for the interpretation.
#
# Used by 05_residuals/residuals.R (hex scale) and 05_patch/patch_aggregation.R
# (patch scale). Both record their fit in PROC_EXPECTED_MODEL so every run's
# expected-richness assumptions stay auditable (docs/methodology.md §14).

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

# Hex-scale predictors. Patch scale uses its own term list (area + quality).
EXPECTED_MODEL_TERMS <- c(
  "habitat_component",
  "connectivity_component",
  "accessibility_component"
)

# Fit an expected *rate* for `response` per unit `offset_col`, from `terms`, on
# `train` only.
#
# Quasi-Poisson with a log link and log(exposure) as an offset — the textbook
# form for a count observed under varying effort. It replaces OLS on the
# pre-divided ratio, which was wrong in two ways on this data:
#
#   * OLS can predict a negative richness. On the 2026-08-19 Porto export 19.5%
#     of sampled cells did, and were clamped to 0, so for a fifth of the grid the
#     "expected" value was a floor artefact and the residual was just -observed.
#   * A linear model on a 89%-zero count understates the relationship. Measured
#     on the same data: OLS R² 0.0148 against explained deviance 0.199 at hex
#     scale, and 0.0532 against 0.236 at patch scale.
#
# Dispersion is ~10.5 (hex) and ~6.3 (patch), so the response is heavily
# overdispersed and the quasi- family is required; plain Poisson would report
# standard errors that are far too small.
#
# Returns list(record, predict):
#   record  — auditable description of the fit (family, coefficients, dispersion,
#             explained deviance, n)
#   predict — function(newdata) giving the expected count per unit exposure
#
# Because the offset is log(exposure) with coefficient fixed at 1, the expected
# *rate* is exp(X·beta) and needs no exposure at prediction time. That is what
# makes the log link the right choice here beyond positivity: an unsampled cell
# has no effort, yet still receives an expected value, so the export contract of
# docs/methodology.md §6.1 holds without inventing a reference exposure.
#
# Refuses to fit below `min_rows` usable rows, when the response or every
# predictor is constant, or when the fit fails to converge or yields non-finite
# coefficients. In those cases it falls back to a constant rate
# (sum(response) / sum(exposure), the constant-rate MLE), which keeps the units
# correct, and marks the record as a fallback rather than failing silently.
fit_expected_model <- function(train, response, terms, min_rows, scale_label,
                               offset_col) {
  stopifnot(is.data.frame(train), length(terms) > 0L)

  needed <- c(response, terms, offset_col)
  missing_cols <- setdiff(needed, names(train))
  if (length(missing_cols) > 0L) {
    stop(sprintf(
      "expected richness (%s scale): training data lacks %s",
      scale_label, paste(missing_cols, collapse = ", ")
    ), call. = FALSE)
  }

  train <- as.data.frame(train)[, needed, drop = FALSE]
  train <- train[stats::complete.cases(train), , drop = FALSE]
  for (col in needed) {
    train <- train[is.finite(train[[col]]), , drop = FALSE]
  }
  # Exposure must be strictly positive to take its log, and a count cannot be
  # negative.
  train <- train[train[[offset_col]] > 0 & train[[response]] >= 0, , drop = FALSE]

  ref_rate <- if (nrow(train) > 0L && sum(train[[offset_col]]) > 0) {
    sum(train[[response]]) / sum(train[[offset_col]])
  } else {
    0
  }

  fallback_reason <- NULL
  if (nrow(train) < min_rows) {
    fallback_reason <- sprintf("%d usable rows, %d required", nrow(train), min_rows)
  } else if (!isTRUE(stats::var(train[[response]]) > 0)) {
    fallback_reason <- "response has zero variance"
  } else if (!any(vapply(
    terms, function(t) isTRUE(stats::var(train[[t]]) > 0), logical(1)
  ))) {
    fallback_reason <- "no predictor varies"
  }

  fit <- NULL
  if (is.null(fallback_reason)) {
    # The offset goes in the FORMULA, not the `offset =` argument. predict.lm
    # evaluates `object$call$offset` against newdata, so passing an expression
    # like log(train[[offset_col]]) makes prediction resolve `train` from this
    # closure and add the whole fitted offset vector to every row — silently
    # returning nrow(train) values for any newdata and inflating each by another
    # row's exposure. With the offset in the formula, prediction is controlled by
    # the exposure column in newdata, which the predictor below sets explicitly.
    form <- stats::as.formula(sprintf(
      "%s ~ %s + offset(log(%s))",
      response, paste(terms, collapse = " + "), offset_col
    ))
    fit <- tryCatch(
      stats::glm(
        form,
        family = stats::quasipoisson(link = "log"),
        data = train
      ),
      error = function(e) {
        fallback_reason <<- sprintf("glm failed: %s", conditionMessage(e))
        NULL
      }
    )
    if (!is.null(fit) && !isTRUE(fit$converged)) {
      fallback_reason <- "fit did not converge"
      fit <- NULL
    }
    if (!is.null(fit) && !all(is.finite(stats::coef(fit)))) {
      fallback_reason <- "non-finite coefficients (collinear predictors)"
      fit <- NULL
    }
  }

  if (is.null(fit)) {
    warning(sprintf(
      paste0(
        "expected richness (%s scale): %s — falling back to a constant rate ",
        "(%.6f per effort unit). Residuals remain unit-correct but carry no ",
        "predictor information; recorded as a fallback in %s."
      ),
      scale_label, fallback_reason, ref_rate, basename(PROC_EXPECTED_MODEL)
    ), call. = FALSE)

    record <- list(
      scale          = scale_label,
      response       = response,
      offset         = offset_col,
      family         = "constant rate",
      link           = "identity",
      terms          = as.list(terms),
      formula        = paste(response, "~ 1 + offset(log(", offset_col, "))"),
      fallback       = TRUE,
      fallbackReason = fallback_reason,
      nTrain         = nrow(train),
      coefficients   = list(rate = round(ref_rate, 8)),
      dispersion     = NA_real_,
      explainedDeviance = NA_real_
    )

    return(list(
      record  = record,
      predict = function(newdata) rep(ref_rate, nrow(newdata))
    ))
  }

  dispersion <- summary(fit)$dispersion
  explained <- if (is.finite(fit$null.deviance) && fit$null.deviance > 0) {
    1 - fit$deviance / fit$null.deviance
  } else {
    NA_real_
  }

  record <- list(
    scale             = scale_label,
    response          = response,
    offset            = offset_col,
    family            = "quasipoisson",
    link              = "log",
    terms             = as.list(terms),
    formula           = sprintf(
      "%s ~ %s + offset(log(%s))",
      response, paste(terms, collapse = " + "), offset_col
    ),
    fallback          = FALSE,
    fallbackReason    = NULL,
    nTrain            = nrow(train),
    coefficients      = as.list(round(stats::coef(fit), 6)),
    dispersion        = round(dispersion, 4),
    explainedDeviance = round(explained, 6)
  )

  cat(sprintf(
    "Expected richness (%s scale): %s | n = %d, explained deviance = %.4f, dispersion = %.2f\n",
    scale_label, record$formula, record$nTrain, explained, dispersion
  ))

  list(
    record  = record,
    predict = function(newdata) {
      nd <- as.data.frame(newdata)
      # Predict the RATE: force exposure to 1 so the formula's offset contributes
      # log(1) = 0 and exp(eta) is the expected count per unit effort. This is
      # also why an unsampled cell, which has no effort at all, still receives an
      # expected value.
      nd[[offset_col]] <- 1
      eta <- suppressWarnings(as.numeric(
        stats::predict(fit, newdata = nd, type = "link")
      ))
      if (length(eta) != nrow(nd)) {
        stop(sprintf(
          paste0(
            "expected richness (%s scale): predict returned %d values for %d rows. ",
            "An offset or contrast is being resolved outside newdata; predictions ",
            "would be silently misaligned."
          ),
          scale_label, length(eta), nrow(nd)
        ), call. = FALSE)
      }
      out <- exp(eta)
      out[!is.finite(out)] <- ref_rate
      out
    }
  )
}

# Merge one scale's fit record into PROC_EXPECTED_MODEL. residuals.R runs first
# in the chain and passes reset = TRUE so a stale patch block from an earlier run
# cannot be mistaken for this one.
record_expected_model <- function(scale_key, record, reset = FALSE,
                                  path = PROC_EXPECTED_MODEL) {
  existing <- list()
  if (!reset && file.exists(path)) {
    existing <- tryCatch(
      jsonlite::read_json(path, simplifyVector = FALSE),
      error = function(e) list()
    )
    if (!is.list(existing)) existing <- list()
  }

  existing[[scale_key]] <- record
  existing$cityId      <- CITY_ID
  existing$cellSizeM   <- CELL_SIZE
  existing$generatedAt <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    existing, path,
    auto_unbox = TRUE, null = "null", na = "null", pretty = TRUE
  )
  cat(sprintf("Written: %s (%s scale)\n", basename(path), scale_key))
  invisible(path)
}
