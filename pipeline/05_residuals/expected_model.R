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
# This replaces a fixed weighted index multiplied by an arbitrary constant. See
# config.R (Expected richness model) for the measured failure that motivated it
# and docs/methodology.md §6-§7 for the interpretation.
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

# Fit expected values for `response` from `terms`, on `train` only.
#
# Returns list(record, predict):
#   record  — auditable description of the fit (coefficients, R², RMSE, n)
#   predict — function(newdata) giving non-negative fitted values
#
# Refuses to fit below `min_rows` usable rows, or when the response or every
# predictor is constant, or when collinearity yields non-finite coefficients.
# In those cases it falls back to an intercept-only model (expected = mean
# observed), which keeps both sides of the residual in the same units, and marks
# the record as a fallback rather than failing silently.
fit_expected_model <- function(train, response, terms, min_rows, scale_label) {
  stopifnot(is.data.frame(train), length(terms) > 0L)

  needed <- c(response, terms)
  missing_cols <- setdiff(needed, names(train))
  if (length(missing_cols) > 0L) {
    stop(sprintf(
      "expected richness (%s scale): training data lacks %s",
      scale_label, paste(missing_cols, collapse = ", ")
    ), call. = FALSE)
  }

  train <- as.data.frame(train)[, needed, drop = FALSE]
  train <- train[stats::complete.cases(train), , drop = FALSE]
  train <- train[is.finite(train[[response]]), , drop = FALSE]
  for (term in terms) {
    train <- train[is.finite(train[[term]]), , drop = FALSE]
  }

  fallback_reason <- NULL
  if (nrow(train) < min_rows) {
    fallback_reason <- sprintf(
      "%d usable rows, %d required", nrow(train), min_rows
    )
  } else if (!isTRUE(stats::var(train[[response]]) > 0)) {
    fallback_reason <- "response has zero variance"
  } else if (!any(vapply(
    terms, function(t) isTRUE(stats::var(train[[t]]) > 0), logical(1)
  ))) {
    fallback_reason <- "no predictor varies"
  }

  fit <- NULL
  if (is.null(fallback_reason)) {
    form <- stats::as.formula(paste(response, "~", paste(terms, collapse = " + ")))
    fit <- stats::lm(form, data = train)
    if (!all(is.finite(stats::coef(fit)))) {
      fallback_reason <- "non-finite coefficients (collinear predictors)"
      fit <- NULL
    }
  }

  mean_obs <- if (nrow(train) > 0L) max(0, mean(train[[response]])) else 0

  if (is.null(fit)) {
    warning(sprintf(
      paste0(
        "expected richness (%s scale): %s — falling back to an intercept-only ",
        "model (expected = %.6f). Residuals remain unit-correct but carry no ",
        "predictor information; recorded as a fallback in %s."
      ),
      scale_label, fallback_reason, mean_obs, basename(PROC_EXPECTED_MODEL)
    ), call. = FALSE)

    record <- list(
      scale          = scale_label,
      response       = response,
      terms          = as.list(terms),
      formula        = paste(response, "~ 1"),
      fallback       = TRUE,
      fallbackReason = fallback_reason,
      nTrain         = nrow(train),
      coefficients   = list(`(Intercept)` = round(mean_obs, 6)),
      rSquared       = NA_real_,
      rmse           = NA_real_
    )

    return(list(
      record  = record,
      predict = function(newdata) rep(mean_obs, nrow(newdata))
    ))
  }

  fit_resid <- stats::residuals(fit)
  record <- list(
    scale          = scale_label,
    response       = response,
    terms          = as.list(terms),
    formula        = paste(deparse(stats::formula(fit)), collapse = " "),
    fallback       = FALSE,
    fallbackReason = NULL,
    nTrain         = nrow(train),
    coefficients   = as.list(round(stats::coef(fit), 6)),
    rSquared       = round(summary(fit)$r.squared, 6),
    rmse           = round(sqrt(mean(fit_resid^2)), 6)
  )

  cat(sprintf(
    "Expected richness (%s scale): %s | n = %d, R² = %.4f, RMSE = %.4f\n",
    scale_label, record$formula, record$nTrain, record$rSquared, record$rmse
  ))

  list(
    record  = record,
    predict = function(newdata) {
      preds <- suppressWarnings(as.numeric(
        stats::predict(fit, newdata = as.data.frame(newdata))
      ))
      # A predictor NA would otherwise silently drop a cell's expected value.
      preds[!is.finite(preds)] <- mean_obs
      pmax(0, preds)
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
