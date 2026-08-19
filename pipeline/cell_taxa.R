# NatureGap — shared per-cell taxa access
#
# PROC_CELL_TAXA is written by 03_observations via build_cell_taxa_json() in
# 02_habitat/process_tile.R: a JSON object keyed by *local* cell_id (no CITY_ID
# prefix), each value holding label vectors per taxon group.
#
# Two stages need it — 05_patch to pool distinct taxa across a park, and
# 06_export for the park species breakdown — so the readers live here rather
# than being written twice and drifting apart.
#
# Labels are "common name (Scientific name)" strings, so a union of labels is a
# distinct-taxa set. Note that these labels carry no observation weight: the
# structured-survey weighting of docs/methodology.md §3 is applied to the hex
# `species_richness` in process_tile.R and does NOT propagate into a pooled
# label union. Patch pooled richness is therefore an unweighted distinct count.

TAXON_GROUPS <- c("plant", "bird", "insect", "mammal", "fungi")

normalize_cell_taxa <- function(taxa) {
  if (is.null(taxa)) return(NULL)
  if (length(taxa) == 1L && is.list(taxa[[1L]]) && !is.null(taxa[[1L]]$plant)) {
    taxa <- taxa[[1L]]
  }
  out <- stats::setNames(vector("list", length(TAXON_GROUPS)), TAXON_GROUPS)
  for (t in TAXON_GROUPS) {
    val <- taxa[[t]]
    if (is.null(val)) {
      out[[t]] <- character()
    } else if (is.character(val)) {
      out[[t]] <- val
    } else {
      out[[t]] <- as.character(unlist(val))
    }
  }
  out
}

read_cell_taxa <- function(path = PROC_CELL_TAXA) {
  if (!file.exists(path)) {
    message(sprintf("No %s — pooled taxa counts unavailable", path))
    return(list())
  }
  lookup <- tryCatch(
    jsonlite::read_json(path, simplifyVector = FALSE),
    error = function(e) {
      warning(sprintf("Unreadable cell taxa file %s: %s", path, conditionMessage(e)),
              call. = FALSE)
      list()
    }
  )
  cat(sprintf("  → Loaded taxa names for %d cells\n", length(lookup)))
  lookup
}

# Distinct labels per taxon group across the given cells. Cell ids must be local
# (strip any CITY_ID prefix first).
union_cell_taxa <- function(local_cell_ids, lookup) {
  out <- stats::setNames(vector("list", length(TAXON_GROUPS)), TAXON_GROUPS)
  for (t in TAXON_GROUPS) {
    out[[t]] <- sort(unique(unlist(lapply(local_cell_ids, function(cid) {
      tx <- normalize_cell_taxa(lookup[[as.character(cid)]])
      if (is.null(tx)) return(character())
      tx[[t]]
    }))))
  }
  out
}

# Total distinct taxa across the given cells. This is the pooled richness a patch
# actually holds: unlike a sum of per-cell counts it does not count a species
# once per cell it occupies (on the 2026-08-19 Porto export the summed field read
# 1,049 for the largest park against 637 distinct, 1.2x inflation city-wide).
count_cell_taxa <- function(local_cell_ids, lookup) {
  if (length(lookup) == 0L) return(NA_integer_)
  as.integer(sum(lengths(union_cell_taxa(local_cell_ids, lookup))))
}
