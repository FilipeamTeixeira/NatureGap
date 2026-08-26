# NatureGap sensitivity sweep — traffic_exposure composite parameters.
# Recomputes the layer analytically from stored components in grid_habitat.gpkg
# and reports how far the ranking moves when each uncalibrated knob is varied.
#
#   SENS_CITY=gent Rscript --vanilla sensitivity/sweep_traffic_exposure.R
#
# Scope: this sweeps the COMPOSITE parameters only — the three weights and the
# two fixed references. TRAFFIC_EMISSION_WEIGHTS act upstream, inside the tiled
# stage that produces road_density_em and near_road_em, so varying them needs a
# full tile reprocess. They are addressed by measurement instead, in
# calibration/fit_emission_weights.R.
suppressMessages({library(sf); library(dplyr); library(tidyr)})

CITY <- Sys.getenv("SENS_CITY", "porto")
if (!exists("CONFIG_LOADED")) setwd(Sys.getenv("NATUREGAP_PIPELINE", "."))
suppressMessages(source("config.R"))

g <- st_read(PROC_GRID_HABITAT, quiet = TRUE) |> st_drop_geometry()
for (col in c("near_road_em", "road_density_em")) {
  if (!col %in% names(g)) {
    stop("Missing ", col, " — rerun the habitat stage with FORCE_TILED_REPROCESS=1.",
         call. = FALSE)
  }
}

clamp01 <- function(x, lo, hi) pmin(1, pmax(0, (x - lo) / (hi - lo)))

compose <- function(w_near = TRAFFIC_W_NEAR, w_dens = TRAFFIC_W_DENSITY,
                    w_canyon = TRAFFIC_W_CANYON, near_ref = TRAFFIC_NEAR_ROAD_REF,
                    dens_ref = TRAFFIC_DENSITY_REF) {
  canyon <- coalesce(g$impervious_fraction, g$built_fraction_wc, 0)
  clamp01(
    w_near * clamp01(g$near_road_em, 0, near_ref) +
      w_dens * clamp01(g$road_density_em, 0, dens_ref) +
      w_canyon * canyon,
    0, 1
  )
}

baseline <- compose()
stopifnot(all(is.finite(baseline)))

# Agreement with the shipped layer, as a guard that this sweep models the same
# arithmetic the pipeline actually ran.
if ("traffic_exposure" %in% names(g)) {
  cat(sprintf("max |sweep - pipeline| = %.2e\n",
              max(abs(baseline - g$traffic_exposure), na.rm = TRUE)))
}

top_decile <- function(v) v >= quantile(v, 0.9, na.rm = TRUE)
base_top <- top_decile(baseline)

report <- function(label, v) {
  data.frame(
    variant = label,
    spearman = round(cor(v, baseline, method = "spearman", use = "complete.obs"), 4),
    top10_retained = round(mean(top_decile(v)[base_top]), 4),
    median = round(median(v, na.rm = TRUE), 4),
    max = round(max(v, na.rm = TRUE), 4)
  )
}

variants <- list(
  report("baseline", baseline),
  report("near-heavy   0.65/0.20/0.15", compose(w_near = 0.65, w_dens = 0.20, w_canyon = 0.15)),
  report("density-heavy 0.25/0.60/0.15", compose(w_near = 0.25, w_dens = 0.60, w_canyon = 0.15)),
  report("no canyon    0.55/0.45/0.00", compose(w_near = 0.55, w_dens = 0.45, w_canyon = 0.00)),
  report("canyon-heavy 0.35/0.25/0.40", compose(w_near = 0.35, w_dens = 0.25, w_canyon = 0.40)),
  report("near_ref 6",    compose(near_ref = 6)),
  report("near_ref 15",   compose(near_ref = 15)),
  report("dens_ref 3000", compose(dens_ref = 3000)),
  report("dens_ref 12000", compose(dens_ref = 12000))
)

cat(sprintf("\nCity: %s   cells: %d\n\n", CITY_ID, nrow(g)))
print(do.call(rbind, variants), row.names = FALSE)
cat("\ntop10_retained = share of baseline top-decile cells still in the variant's top decile.\n")
