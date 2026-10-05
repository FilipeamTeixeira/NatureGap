# NatureGap sensitivity prototype — a spatial gap term, and effort read from the
# records themselves.
#
#   SENS_CITY=porto Rscript --vanilla sensitivity/prototype_spatial_gap.R
#
# Reads the processed grid and observation points; writes nothing the pipeline
# or export reads. Outputs go to data/<city>/sensitivity/.
#
# The question: the published residual (expected − observed) is the observation
# with its sign flipped in every city (docs/methodology.md §7.1), and coarser
# grain does not fix it. Two changes are tested here instead, each against the
# current specification:
#
#   1. The gap as a model term, not a subtraction. A spatial smooth s(x, y) is
#      added to the expected-richness fit, and the gap is minus that smooth:
#      where richness sits below what habitat predicts, consistently across
#      neighbouring cells. REML chooses how coarse the surface is, so the data
#      rather than a grid size set its resolution, and the smooth's standard
#      error says where the data are too thin to speak.
#
#   2. Effort from the records (target-group effort, Phillips et al. 2009). The
#      number of records in a cell, entered as a smooth because richness
#      saturates with records rather than scaling with them. Path length is
#      dropped entirely, so effort enters once (paper R6), and every cell
#      holding a record is admitted rather than only those passing MIN_PATH_M.
#
# Three fits, each with the spatial term:
#
#   path    — the pipeline's specification and admission rule, plus s(x, y).
#   records — all taxa; effort = s(log records); cells with >= 1 record.
#   birds   — the same on birds only, whose records share one detection process.
#             All-taxa richness per record also maps WHO records where (birders
#             log many records of few species; generalists the reverse), which
#             the bird-only fit removes.
#
# Read it this way, per fit:
#
#   credible    — share of fitted cells whose gap excludes zero at 95%
#                 (pointwise; Bayesian intervals from mgcv). `material` also
#                 requires a gap of 20% or more of expected richness.
#   split_r     — observers are split at random into two halves, each half is
#                 refitted from its own records, and the two gap surfaces are
#                 correlated at every fitted cell. Noise does not reproduce
#                 across independent recorders; a real pattern should.
#   cor_effort  — Spearman correlation of the gap with log records. A large
#                 value means the gap is still mostly recording effort.
#   cor_publ    — correlation with the published ecological_residual on the
#                 pipeline's sampled cells, for comparison with what ships now.
#
# The gap is usable only if split_r is clearly positive, `material` is a
# non-trivial share, and cor_effort is small. Pointwise intervals overstate
# certainty across many cells; treat `credible` as an upper bound.

suppressMessages({library(sf); library(dplyr); library(tidyr); library(mgcv)})

CITY <- Sys.getenv("SENS_CITY", "porto")
if (!exists("CONFIG_LOADED")) setwd(Sys.getenv("NATUREGAP_PIPELINE", "."))
suppressMessages(source("config.R"))
source(here::here("residual_diagnostics.R"))

# Basis dimension of s(x, y): the most detail the surface may take. REML then
# chooses how much of it to use; the edf printed below shows whether k binds.
SPATIAL_K <- as.integer(Sys.getenv("SPATIAL_K", "400"))
MATERIAL_GAP <- 0.20
SPLIT_SEED <- 20261005L
OUT_DIR <- file.path(DATA_ROOT, "sensitivity")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

grid <- st_read(PROC_GRID_RESID, quiet = TRUE)

obs_path <- file.path(DATA_PROC, "tiled_obs_all.rds")
if (!file.exists(obs_path)) stop("Missing ", obs_path, " — rerun the habitat stage.", call. = FALSE)
# Points inside a hex are the points nearest its centroid, which is how
# process_tile.R assigns them; points outside the grid are dropped.
obs <- st_join(
  st_transform(readRDS(obs_path), st_crs(grid)),
  grid["cell_id"],
  join = st_within, left = FALSE
) |>
  st_drop_geometry() |>
  select(cell_id, taxon_name, iconic_taxon_name, observation_weight, observer_id)

xy <- st_coordinates(suppressWarnings(st_centroid(st_geometry(grid))))
cells <- grid |>
  st_drop_geometry() |>
  transmute(
    cell_id,
    x = xy[, 1] - mean(xy[, 1]),
    y = xy[, 2] - mean(xy[, 2]),
    is_unsampled = replace_na(is_unsampled, TRUE),
    survey_effort_units,
    habitat_component, connectivity_component, accessibility_component,
    expected_richness, effort_corrected_richness, ecological_residual,
    n_obs_pipeline = n_obs,
    richness_pipeline = species_richness
  )
rm(grid, xy); invisible(gc())

# Per-cell records and richness, with the pipeline's own definition
# (02_habitat/process_tile.R): per distinct taxon the maximum
# observation_weight, summed. Kept identical, NA taxon included, so the all-taxa
# result can be checked against the grid below.
cell_richness <- function(records) {
  records |>
    group_by(cell_id, taxon_name) |>
    mutate(taxon_weight = max(observation_weight, na.rm = TRUE)) |>
    ungroup() |>
    group_by(cell_id) |>
    summarise(
      n_obs = n(),
      species_richness = sum(taxon_weight[!duplicated(taxon_name)], na.rm = TRUE),
      .groups = "drop"
    )
}

# The grid sets species_richness to NA in every cell MIN_PATH_M excludes, records
# or not (process_tile.R), so richness is compared only where the grid kept it.
# Those excluded cells are why richness is recomputed from the points at all.
check <- cells |>
  select(cell_id, n_obs_pipeline, richness_pipeline) |>
  left_join(cell_richness(obs), by = "cell_id") |>
  mutate(across(c(n_obs, species_richness), ~ replace_na(.x, 0)))
mismatch <- sum(check$n_obs != replace_na(check$n_obs_pipeline, 0) |
                (!is.na(check$richness_pipeline) &
                   abs(check$species_richness - check$richness_pipeline) > 1e-9))
if (mismatch > 0L) {
  stop(sprintf("%d cells differ from the grid's own n_obs / species_richness; the join or the richness definition has drifted.", mismatch), call. = FALSE)
}
rm(check)

# ── Fit specifications ──────────────────────────────────────────────────────

SPECS <- list(
  path = list(
    label = "path effort (pipeline spec) + s(x,y)",
    taxa = NULL,
    admit = function(d) !d$is_unsampled,
    formula_fixed = "species_richness ~ habitat_component + connectivity_component + accessibility_component + offset(log(survey_effort_units))"
  ),
  records = list(
    label = "record effort, all taxa + s(x,y)",
    taxa = NULL,
    admit = function(d) d$n_obs >= 1,
    formula_fixed = "species_richness ~ habitat_component + connectivity_component + s(log_n, k = 10)"
  ),
  birds = list(
    label = "record effort, birds only + s(x,y)",
    taxa = "Aves",
    admit = function(d) d$n_obs >= 1,
    formula_fixed = "species_richness ~ habitat_component + connectivity_component + s(log_n, k = 10)"
  )
)

spatial_term <- sprintf("s(x, y, k = %d)", SPATIAL_K)
# The label mgcv gives that term in summaries, predict() and concurvity().
spatial_label <- "s(x,y)"

# One model's training frame from a set of records.
model_frame <- function(spec, records) {
  if (!is.null(spec$taxa)) records <- records[records$iconic_taxon_name %in% spec$taxa, , drop = FALSE]
  d <- cells |>
    left_join(cell_richness(records), by = "cell_id") |>
    mutate(
      n_obs = replace_na(n_obs, 0L),
      species_richness = replace_na(species_richness, 0),
      log_n = log(pmax(n_obs, 1L))
    )
  d[spec$admit(d), , drop = FALSE]
}

fit_bam <- function(form, d) {
  suppressWarnings(bam(
    as.formula(form), data = d, family = quasipoisson(link = "log"),
    method = "fREML", discrete = TRUE, nthreads = 2L
  ))
}

# gap = minus the spatial smooth: positive where richness sits below what the
# other terms predict, matching ecological_residual's sign (§7). On the log
# scale, so exp(-gap) - 1 is the proportional shortfall.
gap_at <- function(fit, newdata) {
  nd <- newdata
  nd$log_n <- 0
  nd$survey_effort_units <- 1
  p <- predict(fit, newdata = nd, type = "terms", terms = spatial_label,
               se.fit = TRUE, block.size = 20000L)
  data.frame(gap = -as.numeric(p$fit), se = as.numeric(p$se.fit))
}

summarise_fit <- function(name, spec, records) {
  d <- model_frame(spec, records)
  base <- fit_bam(spec$formula_fixed, d)
  full <- fit_bam(paste(spec$formula_fixed, "+", spatial_term), d)

  st <- summary(full)$s.table
  sp_row <- st[rownames(st) == spatial_label, , drop = FALSE]
  conc <- tryCatch(concurvity(full, full = TRUE)["worst", spatial_label], error = function(e) NA_real_)

  g <- gap_at(full, d)
  z <- g$gap / g$se
  credible <- abs(z) > qnorm(0.975)
  shortfall <- exp(-g$gap) - 1          # proportional change vs expected
  material <- credible & abs(shortfall) >= MATERIAL_GAP

  publ <- d$ecological_residual
  ok_publ <- is.finite(publ) & !d$is_unsampled

  # Split-half by observer. Records without an observer id cannot be assigned
  # to a recorder and are left out of both halves.
  with_obs <- records[!is.na(records$observer_id) & nzchar(records$observer_id), , drop = FALSE]
  observers <- sort(unique(with_obs$observer_id))
  set.seed(SPLIT_SEED)
  half_a <- observers[sample.int(length(observers), floor(length(observers) / 2))]
  halves <- split(with_obs, with_obs$observer_id %in% half_a)
  half_gaps <- lapply(halves, function(rec) {
    dh <- model_frame(spec, rec)
    gap_at(fit_bam(paste(spec$formula_fixed, "+", spatial_term), dh), d)$gap
  })
  split_r <- stats::cor(half_gaps[[1]], half_gaps[[2]])
  # Stricter, per cell: a material gap counts as replicated only if each
  # observer half, fitted alone, puts that cell on the same side of zero.
  replicated <- material &
    sign(half_gaps[[1]]) == sign(g$gap) & sign(half_gaps[[2]]) == sign(g$gap)
  half_records <- vapply(halves, function(rec) {
    sum(model_frame(spec, rec)$n_obs)
  }, numeric(1))

  out <- data.frame(
    model = name,
    cells = nrow(d),
    records = sum(d$n_obs),
    zero_pct = round(100 * mean(d$species_richness == 0), 1),
    dev_base = round(summary(base)$dev.expl, 4),
    dev_full = round(summary(full)$dev.expl, 4),
    hab = round(coef(full)[["habitat_component"]], 3),
    hab_base = round(coef(base)[["habitat_component"]], 3),
    edf = round(sp_row[1, "edf"], 1),
    k = SPATIAL_K - 1L,
    concurvity = round(conc, 3),
    credible = round(100 * mean(credible), 1),
    below = round(100 * mean(credible & g$gap > 0), 1),
    above = round(100 * mean(credible & g$gap < 0), 1),
    material = round(100 * mean(material), 1),
    replicated = round(100 * mean(replicated), 1),
    cor_effort = round(stats::cor(g$gap, log1p(d$n_obs), method = "spearman"), 3),
    cor_publ = if (sum(ok_publ) > 2L) round(stats::cor(g$gap[ok_publ], publ[ok_publ]), 3) else NA_real_,
    split_r = round(split_r, 3),
    split_records = paste(half_records, collapse = "/")
  )

  # Surface over every grid cell, for the map and for inspection. Cells with no
  # records still get a value — the smooth is a surface — so credibility, not
  # presence of data, decides what the map shows.
  all_gap <- gap_at(full, cells)
  per_cell <- data.frame(
    cell_id = cells$cell_id,
    fitted = cells$cell_id %in% d$cell_id,
    gap = all_gap$gap,
    se = all_gap$se,
    gap_half_a = NA_real_,
    gap_half_b = NA_real_
  )
  fitted_rows <- match(d$cell_id, cells$cell_id)
  per_cell$gap_half_a[fitted_rows] <- half_gaps[[1]]
  per_cell$gap_half_b[fitted_rows] <- half_gaps[[2]]
  names(per_cell)[-1] <- paste0(name, "_", names(per_cell)[-1])

  list(summary = out, per_cell = per_cell)
}

results <- lapply(names(SPECS), function(name) {
  cat(sprintf("Fitting %s …\n", SPECS[[name]]$label))
  summarise_fit(name, SPECS[[name]], obs)
})
names(results) <- names(SPECS)

res <- do.call(rbind, lapply(results, `[[`, "summary"))
per_cell <- Reduce(function(a, b) left_join(a, b, by = "cell_id"), lapply(results, `[[`, "per_cell"))
per_cell <- cbind(cells[, c("x", "y")], per_cell)

csv_path <- file.path(OUT_DIR, "spatial_gap_cells.csv")
write.csv(per_cell, csv_path, row.names = FALSE)

publ_window <- with(
  cells[!cells$is_unsampled, ],
  residual_window(expected_richness, effort_corrected_richness)
)

# ── Map ─────────────────────────────────────────────────────────────────────
png_path <- file.path(OUT_DIR, "spatial_gap_map.png")
if (requireNamespace("ggplot2", quietly = TRUE)) {
  library(ggplot2)
  long <- do.call(rbind, lapply(names(SPECS), function(name) {
    col <- function(suffix) per_cell[[paste0(name, "_", suffix)]]
    gap <- col("gap")
    change <- exp(-gap) - 1
    # Only cells that hold data and pass every test above: credible, material,
    # and on the same side of zero in both observer halves.
    shown <- col("fitted") & abs(gap / col("se")) > qnorm(0.975) &
      abs(change) >= MATERIAL_GAP &
      replace_na(sign(col("gap_half_a")) == sign(gap) & sign(col("gap_half_b")) == sign(gap), FALSE)
    data.frame(
      x = per_cell$x, y = per_cell$y, model = SPECS[[name]]$label, shown = shown,
      change = ifelse(shown, pmax(-0.6, pmin(0.6, change)), NA_real_)
    )
  }))
  long$model <- factor(long$model, levels = vapply(SPECS, `[[`, "", "label"))
  p <- ggplot(long, aes(x, y, colour = change)) +
    geom_point(data = long[!long$shown, ], size = 0.05, shape = 15) +
    geom_point(data = long[long$shown, ], size = 0.3, shape = 15) +
    scale_colour_gradient2(
      low = "#B5532F", mid = "#F2EFE6", high = "#2E6F40", midpoint = 0,
      na.value = "#C9CDC5", limits = c(-0.6, 0.6), labels = scales::percent,
      name = "Richness vs\nexpected\n(replicated\ncells only)"
    ) +
    coord_equal() +
    facet_wrap(~ model, ncol = 1) +
    theme_void(base_size = 9) +
    theme(legend.position = "right", strip.text = element_text(hjust = 0, face = "bold"),
          plot.background = element_rect(fill = "white", colour = NA)) +
    labs(title = sprintf("%s - spatial gap prototype", CITY_NAME),
         subtitle = "Red: fewer species than expected. Green: more. Grey: no data, or fails a test.")
  ggsave(png_path, p, width = 7, height = 11, dpi = 150)
}

# ── Report ──────────────────────────────────────────────────────────────────
cat(sprintf("\n== %s == spatial gap prototype (s(x,y) k = %d)\n", CITY_ID, SPATIAL_K))
cat(sprintf("Published hex residual for context: n = %d, lambda = %s (%s)\n\n",
            publ_window$n, signif(publ_window$lambda, 3), publ_window$regime))
print(res, row.names = FALSE)
cat("\ncells / records : fitted cells and the records they hold. zero_pct: cells with no species.\n")
cat("dev_base / full : explained deviance without and with s(x,y).\n")
cat("hab / hab_base  : habitat coefficient with and without s(x,y).\n")
cat("edf / k         : effective df of s(x,y) against its maximum; edf near k means k binds.\n")
cat("concurvity      : worst-case concurvity of s(x,y) with the other terms (1 = indistinguishable).\n")
cat("credible        : % of fitted cells whose gap excludes zero at 95%; below / above split it by sign.\n")
cat(sprintf("material        : credible AND at least %d%% from expected richness.\n", round(100 * MATERIAL_GAP)))
cat("replicated      : material AND on the same side of zero in both observer halves.\n")
cat("cor_effort      : Spearman correlation of the gap with log records.\n")
cat("cor_publ        : correlation with the published ecological_residual, on the pipeline's sampled cells.\n")
cat("split_r         : correlation of the gap surfaces fitted on two random halves of observers.\n")
cat("split_records   : records each half contributes to its fit.\n")
cat(sprintf("\nWritten: %s\n", csv_path))
if (file.exists(png_path)) cat(sprintf("Written: %s\n", png_path))
