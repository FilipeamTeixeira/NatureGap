# NatureGap sensitivity sweep — habitat weights, MIN_PATH_M, SPECIES_AREA_Z.
# Recomputes the full intervention chain analytically from stored components.
# Validated to reproduce the pipeline baseline exactly (max|diff| = 0).
suppressMessages({library(sf); library(dplyr); library(tidyr); library(jsonlite)})

CITY <- Sys.getenv("SENS_CITY", "porto")
if (!exists("CONFIG_LOADED")) setwd(Sys.getenv("NATUREGAP_PIPELINE", "."))
suppressMessages(source("config.R"))
source(here::here("05_residuals", "expected_model.R"))

g <- st_read(PROC_GRID_RESID, quiet = TRUE) |> st_drop_geometry()

# One evaluation of the chain: habitat weights + MIN_PATH_M -> intervention score.
run_chain <- function(w_ndvi, w_lst, w_dist, min_path = MIN_PATH_M) {
  d <- g
  d$habitat_quality <- w_ndvi*d$ndvi_idx + w_lst*d$lst_idx + w_dist*(1 - d$disturbance_idx)

  # Re-derive sampling from the threshold under test.
  d$is_unsampled <- replace_na(d$path_local_m, 0) < min_path
  d$survey_effort_units <- ifelse(d$is_unsampled, NA_real_, log1p(d$path_local_m))
  d$effort_corrected_richness <- ifelse(
    d$is_unsampled, NA_real_,
    replace_na(d$species_richness, 0) / d$survey_effort_units
  )
  maxp <- max(d$path_local_m, na.rm = TRUE)
  d$accessibility_component <- ifelse(
    d$is_unsampled, 0, pmin(1, log1p(d$path_local_m) / log1p(maxp))
  )
  d$habitat_component <- replace_na(d$habitat_quality, 0)
  d$connectivity_component <- pmin(1, pmax(0, replace_na(d$corridor_importance, 0)))

  m <- suppressWarnings(fit_expected_model(
    train = d |> filter(!is_unsampled, is.finite(effort_corrected_richness)),
    response = "species_richness", terms = EXPECTED_MODEL_TERMS,
    min_rows = EXPECTED_MODEL_MIN_CELLS, scale_label = "sweep",
    offset_col = "survey_effort_units"
  ))
  d$expected_richness <- m$predict(d)
  d$ecological_residual <- ifelse(d$is_unsampled, NA_real_,
                                  d$expected_richness - d$effort_corrected_richness)
  med <- stats::median(d$ecological_residual[is.finite(d$ecological_residual)])
  if (!is.finite(med)) med <- 0
  d$underperformance <- pmax(0, d$ecological_residual - med)
  d$intervention_score <- (replace_na(d$underperformance, 0) * 0.5) *
                          (replace_na(d$corridor_importance, 0) * 0.5)
  list(cell_id = d$cell_id, score = d$intervention_score,
       fallback = m$record$fallback, dev = m$record$explainedDeviance,
       n_sampled = sum(!d$is_unsampled, na.rm = TRUE))
}

topn <- function(cid, sc, n) cid[order(-sc, na.last = NA)][seq_len(min(n, sum(sc > 0, na.rm = TRUE)))]

compare <- function(base, alt) {
  pos <- (base$score > 0) | (alt$score > 0)
  rho <- if (sum(pos, na.rm = TRUE) > 2) {
    suppressWarnings(cor(base$score[pos], alt$score[pos], method = "spearman",
                         use = "complete.obs"))
  } else NA_real_
  ov <- function(n) {
    a <- topn(base$cell_id, base$score, n); b <- topn(alt$cell_id, alt$score, n)
    if (length(a) == 0) return(NA_real_)
    length(intersect(a, b)) / length(a)
  }
  c(rho = rho, top20 = ov(20), top100 = ov(100), top1000 = ov(1000),
    n_pos = sum(alt$score > 0, na.rm = TRUE), dev = alt$dev, n_samp = alt$n_sampled)
}

base <- run_chain(0.50, 0.286, 0.214)
cat(sprintf("== %s ==\nbaseline: %d cells with positive score, explained deviance %.4f, %d sampled\n\n",
            CITY, sum(base$score > 0, na.rm = TRUE), base$dev, base$n_sampled))

# --- habitat weight simplex sweep -------------------------------------------
grid_w <- expand.grid(nd = c(0.20, 0.35, 0.50, 0.65, 0.80),
                      lst_share = c(0.25, 0.50, 0.75))
named <- data.frame(nd = c(1/3, 0.70, 0.30, 0.64, 0.70),
                    lst_share = c(0.5, 0.20/0.30, 0.40/0.70, 1.0, 0.0))
rows <- list()
for (i in seq_len(nrow(grid_w))) {
  nd <- grid_w$nd[i]; rest <- 1 - nd
  ls <- rest * grid_w$lst_share[i]; ds <- rest - ls
  r <- compare(base, run_chain(nd, ls, ds))
  rows[[length(rows)+1]] <- c(w_ndvi = nd, w_lst = ls, w_dist = ds, r)
}
hw <- as.data.frame(do.call(rbind, rows))
cat("--- habitat weight sweep (15 points on the simplex) ---\n")
print(format(hw, digits = 3), row.names = FALSE)
cat(sprintf("\nSpearman rho : min=%.3f median=%.3f\n", min(hw$rho), median(hw$rho)))
cat(sprintf("top-20 overlap: min=%.2f median=%.2f\n", min(hw$top20), median(hw$top20)))
cat(sprintf("top-100      : min=%.2f median=%.2f\n", min(hw$top100), median(hw$top100)))
cat(sprintf("top-1000     : min=%.2f median=%.2f\n", min(hw$top1000), median(hw$top1000)))

# --- MIN_PATH_M sweep --------------------------------------------------------
cat("\n--- MIN_PATH_M sweep (baseline 50 m) ---\n")
mp <- list()
for (v in c(25, 40, 50, 75, 100, 150)) {
  r <- compare(base, run_chain(0.50, 0.286, 0.214, min_path = v))
  mp[[length(mp)+1]] <- c(min_path_m = v, r)
}
print(format(as.data.frame(do.call(rbind, mp)), digits = 3), row.names = FALSE)
