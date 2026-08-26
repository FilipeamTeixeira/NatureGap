# NatureGap sensitivity sweep — expected-richness fit versus analysis grain.
#
#   SENS_CITY=porto Rscript --vanilla sensitivity/sweep_grain_scale.R
#
# The question: the hex-scale expected-richness model explains 0.9%-14% of
# deviance depending on the city (docs/methodology.md section 6.1). Is that
# because the 20 m analysis unit is too small to carry a richness signal, or
# because the observation data is too thin at any scale? Those have opposite
# consequences — the first is fixed by reporting at a coarser grain, the second
# means the residual is exploratory and no aggregation rescues it.
#
# Method: refit the SAME specification on progressively coarser square blocks
# and read explained deviance, dispersion and the habitat coefficient at each.
#
# Two things this script is careful about:
#
#   1. Species richness is NOT additive. Summing per-cell richness across a
#      block counts a species once per cell it appears in. Richness is therefore
#      recomputed from the observation points at every grain, using the
#      pipeline's own weighted definition (02_habitat/process_tile.R:815): per
#      distinct taxon take the maximum observation_weight, then sum those.
#
#   2. Effort is not additive either. path_local_m is a 40 m NEIGHBOURHOOD
#      length, so neighbouring cells overlap and summing it inflates effort.
#      This uses path_km — length inside the cell — which is genuinely additive.
#      That differs from the pipeline's own offset, so the 20 m row here will
#      not reproduce the pipeline's hex figure exactly. Consistency ACROSS
#      grains is what this measures; the pipeline's own number is printed
#      separately for context.

suppressMessages({library(sf); library(dplyr); library(tidyr); library(lubridate)})

CITY <- Sys.getenv("SENS_CITY", "porto")
if (!exists("CONFIG_LOADED")) setwd(Sys.getenv("NATUREGAP_PIPELINE", "."))
suppressMessages(source("config.R"))
suppressMessages(source(here::here("05_residuals", "expected_model.R")))

GRAINS <- as.numeric(strsplit(Sys.getenv("GRAINS", "20,60,100,200,500,1000"), ",")[[1]])

grid <- st_read(PROC_GRID_RESID, quiet = TRUE)
obs_path <- file.path(DATA_PROC, "tiled_obs_all.rds")
if (!file.exists(obs_path)) {
  stop("Missing ", obs_path, " — rerun the habitat stage.", call. = FALSE)
}
obs <- readRDS(obs_path)
obs <- st_transform(obs, st_crs(grid))

grid_xy <- st_coordinates(suppressWarnings(st_centroid(st_geometry(grid))))
obs_xy  <- st_coordinates(obs)
obs_tab <- st_drop_geometry(obs)
grid_tab <- st_drop_geometry(grid)

block_id <- function(xy, g) paste(floor(xy[, 1] / g), floor(xy[, 2] / g), sep = "_")

fit_at_grain <- function(g) {
  gb <- block_id(grid_xy, g)
  ob <- block_id(obs_xy, g)

  # Richness recomputed from points, pipeline definition, at this grain.
  rich <- obs_tab |>
    mutate(blk = ob) |>
    filter(!is.na(taxon_name)) |>
    group_by(blk, taxon_name) |>
    mutate(taxon_weight = max(observation_weight, na.rm = TRUE)) |>
    ungroup() |>
    group_by(blk) |>
    summarise(
      species_richness = sum(taxon_weight[!duplicated(taxon_name)], na.rm = TRUE),
      raw_species_count = n_distinct(taxon_name),
      n_obs = n(),
      .groups = "drop"
    )

  cov <- grid_tab |>
    mutate(blk = gb) |>
    group_by(blk) |>
    summarise(
      habitat_quality = mean(habitat_quality, na.rm = TRUE),
      corridor_importance = mean(corridor_importance, na.rm = TRUE),
      path_m = sum(replace_na(path_km, 0) * 1000),
      # A block is sampled if it contains at least one cell the pipeline itself
      # judged sampled, rather than by rescaling MIN_PATH_M to block area.
      any_sampled = any(!replace_na(is_unsampled, TRUE)),
      n_cells = n(),
      .groups = "drop"
    )

  d <- cov |>
    left_join(rich, by = "blk") |>
    mutate(
      species_richness = replace_na(species_richness, 0),
      raw_species_count = replace_na(raw_species_count, 0L),
      is_unsampled = !any_sampled | path_m <= 0,
      survey_effort_units = if_else(is_unsampled, NA_real_, log1p(path_m)),
      effort_corrected_richness = if_else(is_unsampled, NA_real_,
                                          species_richness / survey_effort_units),
      habitat_component = replace_na(habitat_quality, 0),
      connectivity_component = pmin(1, pmax(0, replace_na(corridor_importance, 0)))
    )
  maxp <- max(d$path_m[!d$is_unsampled], na.rm = TRUE)
  d$accessibility_component <- if_else(
    d$is_unsampled | !is.finite(maxp) | maxp <= 0, 0,
    pmin(1, log1p(d$path_m) / log1p(maxp))
  )

  train <- d |> filter(!is_unsampled, is.finite(effort_corrected_richness))
  if (nrow(train) < 30L) {
    return(data.frame(grain_m = g, units = nrow(d), sampled = sum(!d$is_unsampled),
                      zero_pct = NA, dev = NA, disp = NA, habitat = NA,
                      conn = NA, access = NA, fallback = NA))
  }

  m <- suppressWarnings(fit_expected_model(
    train = train, response = "species_richness", terms = EXPECTED_MODEL_TERMS,
    min_rows = EXPECTED_MODEL_MIN_CELLS, scale_label = paste0("grain", g),
    offset_col = "survey_effort_units"
  ))
  cf <- m$record$coefficients
  data.frame(
    grain_m = g,
    units = nrow(d),
    sampled = nrow(train),
    zero_pct = round(100 * mean(train$species_richness == 0), 1),
    dev = round(m$record$explainedDeviance, 4),
    disp = round(m$record$dispersion, 1),
    habitat = round(cf[["habitat_component"]], 3),
    conn = round(cf[["connectivity_component"]], 3),
    access = round(cf[["accessibility_component"]], 3),
    fallback = m$record$fallback
  )
}

res <- do.call(rbind, lapply(GRAINS, fit_at_grain))

pipe_dev <- tryCatch({
  j <- jsonlite::fromJSON(file.path(DATA_PROC, "expected_richness_model.json"))
  sprintf("%.4f (dispersion %.1f)", j$hex$explainedDeviance, j$hex$dispersion)
}, error = function(e) "unavailable")

cat(sprintf("\n== %s == expected richness vs analysis grain\n", CITY_ID))
cat(sprintf("Pipeline's own 20 m hex fit, for context: %s\n", pipe_dev))
cat("(this script's 20 m row uses additive path_km effort, so it will differ)\n\n")
print(res, row.names = FALSE)
cat("\ndev = explained deviance. zero_pct = share of sampled units with zero weighted richness.\n")
cat("Rising dev with grain => the 20 m unit is destroying signal that exists.\n")
cat("Flat, low dev at every grain => observation density cannot support richness estimation.\n")
