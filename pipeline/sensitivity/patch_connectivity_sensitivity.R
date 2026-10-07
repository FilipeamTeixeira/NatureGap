# NatureGap — sensitivity of the patch connector fraction (dPC connector) to
# its two uncalibrated choices: the dispersal distance and the vegetation share
# that makes a cell part of a patch. docs/methodology.md §9b.
#
# Compared at cell level, because a different vegetation threshold makes
# different patches: each patch cell carries its patch's connector percentile.
# Reports, against the baseline (CONN_DISPERSAL_M, PATCH_MIN_VEGETATION):
#   rho      Spearman rank agreement over cells in patches under both settings
#   top10    overlap (Jaccard) of the cells in the top 10% of connector patches
# and, for the baseline, its agreement with cell-level corridor_importance —
# the connector should add to the corridor layer, not repeat it.
#
#   NATUREGAP_CITY=gent Rscript --vanilla sensitivity/patch_connectivity_sensitivity.R

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))
suppressMessages({library(sf); library(dplyr); library(igraph)})
source(here::here("04_connectivity", "connectivity_load.R"), local = FALSE)
source(here::here("04_connectivity", "patch_connectivity.R"), local = FALSE)

grid <- sf::st_read(PROC_GRID_HABITAT, quiet = TRUE)
routing <- build_routing_graph(grid)
cell_area_m2 <- as.numeric(stats::median(sf::st_area(grid)))
rm(grid); invisible(gc())

variants <- list(
  baseline   = list(veg = PATCH_MIN_VEGETATION, disp = CONN_DISPERSAL_M),
  disp_half  = list(veg = PATCH_MIN_VEGETATION, disp = CONN_DISPERSAL_M / 2),
  disp_twice = list(veg = PATCH_MIN_VEGETATION, disp = CONN_DISPERSAL_M * 2),
  veg_0.3    = list(veg = 0.3, disp = CONN_DISPERSAL_M)
)
cell_pct <- lapply(variants, function(v) {
  r <- compute_patch_dpc(routing, cell_area_m2, min_vegetation = v$veg, dispersal_m = v$disp,
                         max_link_m = PATCH_MAX_LINK_M * v$disp / CONN_DISPERSAL_M, verbose = FALSE)
  out <- r$patches$connector_pct[r$cells$patch_id]
  names(out) <- r$cells$cell_id
  attr(out, "patches") <- nrow(r$patches)
  out
})

base <- cell_pct$baseline
top_cells <- function(x) names(x)[x >= 0.9 & !is.na(x)]
rows <- lapply(names(cell_pct), function(nm) {
  x <- cell_pct[[nm]]; common <- intersect(names(base), names(x))
  tb <- top_cells(base); tx <- top_cells(x)
  data.frame(city = CITY_ID, variant = nm, patches = attr(x, "patches"),
             rho = suppressWarnings(cor(base[common], x[common], method = "spearman")),
             top10_jaccard = length(intersect(tb, tx)) / length(union(tb, tx)))
})
print(do.call(rbind, rows), digits = 3, row.names = FALSE)

nodes <- as.data.frame(arrow::read_parquet(connectivity_paths()$nodes))
ci <- nodes$corridor_importance[match(names(base), as.character(nodes$node_id))]
cat(sprintf("%s: baseline connector vs corridor_importance over patch cells: rho %.2f; top-10%% connector cells that are top-quartile corridor cells: %.0f%%\n",
            CITY_ID, suppressWarnings(cor(base, ci, method = "spearman", use = "complete.obs")),
            100 * mean(ci[base >= 0.9] >= 0.75, na.rm = TRUE)))
