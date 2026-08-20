# CONN_MAX_RESISTANCE sweep: recomputes corridor_importance with the pipeline's
# own build_habitat_graph(), then re-runs the intervention chain.
CITY <- Sys.getenv("SENS_CITY", "porto-center")
if (!exists("CONFIG_LOADED")) setwd(Sys.getenv("NATUREGAP_PIPELINE", "."))
suppressMessages(source("config.R"))
suppressMessages(source(here::here("04_connectivity", "connectivity_load.R")))
suppressMessages(source(here::here("05_residuals", "expected_model.R")))
suppressMessages({library(sf); library(igraph); library(dplyr); library(tidyr)})

gh <- st_read(PROC_GRID_HABITAT, quiet = TRUE)
g  <- st_read(PROC_GRID_RESID, quiet = TRUE) |> st_drop_geometry()

corridor_for <- function(R) {
  net <- build_habitat_graph(gh, max_resistance = R)
  bc <- igraph::betweenness(net$graph, weights = igraph::E(net$graph)$weight,
                            cutoff = CONN_DISPERSAL_M, normalized = TRUE)
  ci <- corridor_percentile(as.numeric(bc[as.character(net$nodes$node_id)]))
  tibble::tibble(cell_id = as.numeric(net$nodes$node_id), ci_new = ci)
}

chain <- function(ci_tbl) {
  d <- g |> select(-any_of("ci_new")) |> left_join(ci_tbl, by = "cell_id")
  d$connectivity_component <- pmin(1, pmax(0, replace_na(d$ci_new, 0)))
  d$habitat_component <- replace_na(d$habitat_quality, 0)
  m <- suppressWarnings(fit_expected_model(
    train = d |> filter(!replace_na(is_unsampled, TRUE), is.finite(effort_corrected_richness)),
    response = "species_richness", terms = EXPECTED_MODEL_TERMS,
    min_rows = EXPECTED_MODEL_MIN_CELLS, scale_label = "conn",
    offset_col = "survey_effort_units"))
  d$expected_richness <- m$predict(d)
  d$ecological_residual <- ifelse(replace_na(d$is_unsampled, TRUE), NA_real_,
                                  d$expected_richness - d$effort_corrected_richness)
  med <- stats::median(d$ecological_residual[is.finite(d$ecological_residual)])
  if (!is.finite(med)) med <- 0
  up <- pmax(0, d$ecological_residual - med)
  list(cell_id = d$cell_id,
       score = (replace_na(up, 0) * 0.5) * (replace_na(d$ci_new, 0) * 0.5),
       n_core = sum(replace_na(d$ci_new, 0) >= NET_CORE_IMPORTANCE))
}

topn <- function(cid, sc, n) cid[order(-sc, na.last = NA)][seq_len(min(n, sum(sc > 0, na.rm = TRUE)))]
base <- chain(corridor_for(CONN_MAX_RESISTANCE))
cat(sprintf("== %s == baseline R=%g: %d cells with positive score\n\n",
            CITY, CONN_MAX_RESISTANCE, sum(base$score > 0, na.rm = TRUE)))
cat(sprintf("%6s %8s %8s %9s %10s %10s %12s\n",
            "R","rho","top20","top100","top1000","n_pos","core cells"))
for (R in c(5, 10, 20, 30, 50, 100)) {
  a <- chain(corridor_for(R))
  pos <- (base$score > 0) | (a$score > 0)
  rho <- suppressWarnings(cor(base$score[pos], a$score[pos], method = "spearman", use = "complete.obs"))
  ov <- function(n) {
    x <- topn(base$cell_id, base$score, n); y <- topn(a$cell_id, a$score, n)
    if (!length(x)) return(NA_real_); length(intersect(x, y))/length(x)
  }
  cat(sprintf("%6g %8.4f %8.2f %9.2f %10.3f %10d %12d\n",
              R, rho, ov(20), ov(100), ov(1000), sum(a$score > 0, na.rm = TRUE), a$n_core))
}
