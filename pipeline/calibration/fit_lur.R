# Fit a land-use regression from OSM traffic predictors to modelled NO2, and
# test whether the fitted relationship transfers between cities.
#
# Offline calibration. NOT part of run_pipeline.R: it needs the reference
# air-quality rasters, which exist only for cities with an AIR_QUALITY_WCS
# entry. Its output is a committed JSON of coefficients that cities WITHOUT a
# reference surface (Porto, Yokohama) can then be scored with.
#
#   Rscript --vanilla calibration/fit_lur.R
#
# Method, and why it is shaped this way:
#
#   The dependent variable is a dispersion model's output, not a measurement.
#   Fitting to it means learning ATMO-Street and RIVM, including their biases —
#   it is not independent validation against real air. What it buys is a
#   training set covering every street in two cities, which no monitoring
#   network could provide.
#
#   The transfer test is the point. Fitting one model on pooled data and
#   reporting its R2 would say nothing about Porto, where there is no reference
#   surface at all. Instead: fit on city A, predict city B, and measure what is
#   lost. That number, not the in-sample fit, is what licenses extending the
#   layer to an uncalibrated city.

suppressMessages({library(sf); library(terra); library(dplyr)})

if (!exists("CONFIG_LOADED")) setwd(Sys.getenv("NATUREGAP_PIPELINE", "."))

CALIB_CITIES <- strsplit(Sys.getenv("LUR_CITIES", "gent,amsterdam"), ",")[[1]]
CALIB_DIR <- NULL  # set after the first config load
# Override to test which terms actually transfer, e.g.
#   LUR_TERMS="near_road_em,canyon" Rscript --vanilla calibration/fit_lur.R
LUR_TERMS <- strsplit(
  Sys.getenv("LUR_TERMS", "near_road_em,road_density_em,canyon,ndvi_mean"), ","
)[[1]]

# ── Assemble one city's training table ───────────────────────────────────────

load_city <- function(slug) {
  # config.R supports switching city inside one session: it resolves CITY from
  # globalenv and explicitly drops the previous city's optional values first.
  assign("CITY", slug, envir = globalenv())
  suppressMessages(source("config.R"))

  if (!file.exists(RAW_AIR_QUALITY)) {
    stop("No reference raster for ", slug, " — run 00_download/download_air_quality.R",
         call. = FALSE)
  }
  g <- st_read(PROC_GRID_HABITAT, quiet = TRUE)
  miss <- setdiff(c("near_road_em", "road_density_em", "ndvi_mean"), names(g))
  if (length(miss)) {
    stop(slug, " is missing ", paste(miss, collapse = ", "),
         " — rerun the habitat stage with FORCE_TILED_REPROCESS=1", call. = FALSE)
  }

  r <- rast(RAW_AIR_QUALITY)
  pts <- st_transform(st_centroid(st_geometry(g)), crs(r))
  d <- st_drop_geometry(g)
  d$no2 <- terra::extract(r, vect(pts))[, 2]
  d$canyon <- coalesce(d$impervious_fraction, d$built_fraction_wc, 0)
  d <- d[, c("no2", LUR_TERMS)]
  d$city <- CITY_ID
  d <- d[stats::complete.cases(d[, c("no2", LUR_TERMS)]), ]
  cat(sprintf("[lur] %-10s %6d cells with NO2 and predictors\n", slug, nrow(d)))
  d
}

cities <- lapply(CALIB_CITIES, load_city)
names(cities) <- CALIB_CITIES

fml <- stats::as.formula(paste("no2 ~", paste(LUR_TERMS, collapse = " + ")))

# ── Per-city fits ────────────────────────────────────────────────────────────

fits <- lapply(cities, \(d) stats::lm(fml, data = d))

cat("\n── In-sample fit ────────────────────────────────────────────────\n")
for (nm in names(fits)) {
  s <- summary(fits[[nm]])
  cat(sprintf("%-10s R2 = %.3f   residual SE = %.2f ug/m3   n = %d\n",
              nm, s$r.squared, s$sigma, nrow(cities[[nm]])))
}

cat("\n── Coefficients ─────────────────────────────────────────────────\n")
coefs <- sapply(fits, \(f) stats::coef(f))
print(round(coefs, 4))

# ── Cross-city transfer ──────────────────────────────────────────────────────
# Spearman says whether the SPATIAL PATTERN transfers — which streets are worst.
# RMSE and bias say whether the LEVEL transfers. They can diverge sharply, and
# the distinction decides what an uncalibrated city may claim: a ranking, or a
# number in ug/m3.

cat("\n── Transfer: fit on A, predict B ────────────────────────────────\n")
rows <- list()
for (a in names(fits)) for (b in names(cities)) {
  if (a == b) next
  obs  <- cities[[b]]$no2
  pred <- stats::predict(fits[[a]], newdata = cities[[b]])
  rows[[length(rows) + 1L]] <- data.frame(
    fit_on = a, predict = b,
    spearman = round(cor(pred, obs, method = "spearman"), 3),
    r2 = round(1 - sum((obs - pred)^2) / sum((obs - mean(obs))^2), 3),
    rmse = round(sqrt(mean((obs - pred)^2)), 2),
    bias = round(mean(pred - obs), 2),
    # A city cannot act on an absolute number it does not trust, but it CAN act
    # on "which streets are worst". This asks whether the transferred model
    # finds the same worst decile, independent of level.
    hotspot_agreement = round(
      mean(pred >= quantile(pred, 0.9))[1] * 0 +
      mean((pred >= quantile(pred, 0.9))[obs >= quantile(obs, 0.9)]), 3
    )
  )
}
transfer <- if (length(rows)) do.call(rbind, rows) else NULL
if (is.null(transfer)) {
  cat("only one city loaded — no transfer test possible\n")
} else {
  print(transfer, row.names = FALSE)
}
cat("\nr2 here is out-of-sample and CAN go negative — that means the transferred\n")
cat("model predicts worse than the target city's own mean.\n")

# ── Pooled model, for cities without a reference surface ─────────────────────

pooled_data <- bind_rows(cities)
pooled <- stats::lm(fml, data = pooled_data)
ps <- summary(pooled)
cat(sprintf("\npooled     R2 = %.3f   residual SE = %.2f ug/m3   n = %d\n",
            ps$r.squared, ps$sigma, nrow(pooled_data)))

# Refuse to write a one-city fit under the name "pooled": the committed file is
# what uncalibrated cities get scored with, and a single-city fit carries no
# transfer evidence at all.
if (length(cities) < 2L) {
  cat("\nOnly ", length(cities), " city loaded — not writing coefficients. ",
      "The committed file must carry a transfer test.\n", sep = "")
  quit(save = "no")
}

# Verdict, computed rather than asserted. The committed file is what an
# uncalibrated city would be scored with, so it has to state plainly whether
# that is defensible. Thresholds: out-of-sample R2 must beat predicting the
# target city's mean by a clear margin, and the model must find most of the
# real worst decile — a hotspot map that misses half its hotspots would
# misdirect spending rather than inform it.
transfer_ok <- all(transfer$r2 > 0.30) && all(transfer$hotspot_agreement > 0.60)
verdict <- if (transfer_ok) {
  "transferable: may be applied to cities without a reference surface, within the reported error"
} else {
  paste("NOT transferable: must not be applied outside the fitted cities.",
        "Cities without a reference air-quality surface ship traffic_exposure",
        "as a unitless traffic-pressure index only, never a concentration.")
}
cat("\n── Verdict ──────────────────────────────────────────────────────\n")
cat(verdict, "\n")

CALIB_DIR <- file.path(getwd(), "calibration")
out_path <- file.path(CALIB_DIR, "lur_coefficients.json")
jsonlite::write_json(
  list(
    verdict = verdict,
    transferable = transfer_ok,
    terms = LUR_TERMS,
    coefficients = as.list(round(stats::coef(pooled), 6)),
    pooled_r2 = round(ps$r.squared, 4),
    residual_se_ugm3 = round(ps$sigma, 3),
    transfer = transfer,
    cities = as.list(sapply(cities, nrow)),
    provenance = list(
      response = "modelled annual mean NO2 (ug/m3)",
      sources = "Gent: ATMO-Street v7.2 2024 (IRCELINE/VMM/VITO, CC BY 4.0). Amsterdam: RIVM NSL 2024 (Atlas Leefomgeving).",
      caveat = paste(
        "Fitted to dispersion-model output, not measurements: inherits those",
        "models' biases. No meteorology, no point sources. Apply to a city",
        "outside the fitted set only within the transfer error reported above,",
        "and label output a modelled estimate, never compliance data."
      )
    )
  ),
  out_path, pretty = TRUE, auto_unbox = TRUE, na = "null"
)
cat(sprintf("\nWritten: %s\n", out_path))
