# NatureGap — introduced (non-native) species per city, so the opportunity gap
# (05_opportunity/opportunity_gap.R) counts native species only: a gap that
# rewards escaped parakeets or collection ducks is not a nature gap.
#
# Functions only. 01_ingest/introduced_species.R fetches and caches the sources
# (fetch = TRUE); everything downstream reads the caches and never makes a
# request, so a modelling run cannot depend on an API being up.
#
# Two sources:
#
#   GRIIS  the Global Register of Introduced and Invasive Species checklist of
#          the city's country (ISSG, published as GBIF checklist datasets;
#          GRIIS_DATASET_BY_COUNTRY in config.R). The authority, with one
#          correction: Portugal's national list carries no locality and
#          includes species introduced only on the Azores or Madeira — Perez's
#          frog and the Moorish gecko, both native to mainland Iberia. A
#          national species that an island register also lists, and that
#          iNaturalist does not flag inside the city, is taken to be introduced
#          on the islands only and kept as native.
#   iNat   species iNaturalist marks as introduced at observations inside the
#          city's fetch bbox. Used only to fill gaps in a thin national
#          register, and only for species another national register also lists
#          as introduced. Neither source is clean alone, measured 2026-10-06:
#          iNaturalist flags mallard and greater white-toothed shrew in Porto,
#          both native, and Portugal's register omits Egyptian goose, Muscovy
#          duck and mandarin duck; the Belgian register, applied to Porto, would
#          exclude laurustinus, which is native to Portugal.
#
# Names are matched on the binomial (genus + epithet), so a subspecies or a
# variety listed in a register excludes its species. Synonyms between
# iNaturalist and the GBIF backbone are not resolved. Whether a species counts
# follows each country's register: Belgium's lists the feral pigeon,
# Portugal's does not.

binomial <- function(name) {
  name <- trimws(as.character(name))
  ifelse(grepl("^\\S+ \\S+", name), sub("^(\\S+ \\S+).*$", "\\1", name), NA_character_)
}

introduced_get_json <- function(url) {
  httr2::request(url) |>
    httr2::req_user_agent("NatureGap pipeline (github.com/FilipeamTeixeira)") |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = TRUE)
}

introduced_missing <- function(path) {
  stop(sprintf(
    "Missing %s — run 01_ingest/introduced_species.R for this city first.", path
  ), call. = FALSE)
}

# Every name usage in a GRIIS checklist, cached as CSV under `label`.
griis_checklist <- function(label, key, fetch = FALSE, cache_dir = GRIIS_CACHE_DIR) {
  path <- file.path(cache_dir, paste0(gsub("[^a-z]+", "_", tolower(label)), ".csv"))
  if (file.exists(path)) return(utils::read.csv(path, stringsAsFactors = FALSE))
  if (!fetch) introduced_missing(path)

  rows <- list(); offset <- 0L
  repeat {
    page <- introduced_get_json(sprintf(
      "https://api.gbif.org/v1/species?datasetKey=%s&limit=1000&offset=%d", key, offset
    ))
    res <- page$results
    rows[[length(rows) + 1L]] <- data.frame(
      canonical_name = as.character(res$canonicalName),
      rank = as.character(res$rank),
      class = as.character(if (is.null(res$class)) NA else res$class),
      stringsAsFactors = FALSE
    )
    offset <- offset + 1000L
    if (isTRUE(page$endOfRecords)) break
  }
  out <- do.call(rbind, rows)
  out$dataset_key <- key
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(out, path, row.names = FALSE)
  out
}

# Species iNaturalist marks as introduced at observations inside the bbox.
inat_introduced <- function(bbox, fetch = FALSE, cache_path = RAW_INAT_INTRODUCED) {
  if (file.exists(cache_path)) return(utils::read.csv(cache_path, stringsAsFactors = FALSE))
  if (!fetch) introduced_missing(cache_path)
  names <- character(); page <- 1L
  repeat {
    url <- sprintf(paste0(
      "https://api.inaturalist.org/v1/observations/species_counts?",
      "swlat=%f&swlng=%f&nelat=%f&nelng=%f&introduced=true&per_page=500&page=%d"
    ), bbox[["ymin"]], bbox[["xmin"]], bbox[["ymax"]], bbox[["xmax"]], page)
    d <- introduced_get_json(url)
    if (length(d$results) == 0L) break
    names <- c(names, d$results$taxon$name)
    if (page * 500L >= d$total_results) break
    page <- page + 1L
    Sys.sleep(1)   # iNaturalist asks for at most ~1 request per second
  }
  out <- data.frame(taxon_name = unique(names), stringsAsFactors = FALSE)
  dir.create(dirname(cache_path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(out, cache_path, row.names = FALSE)
  out
}

# Introduced species for one city, as binomials with the evidence for each.
# attr(, "island_only") holds the national species kept as native because the
# registers place their introduction on the islands. Every configured register
# is read: the iNaturalist fill needs the other countries' lists.
introduced_species <- function(country, bbox, fetch = FALSE) {
  if (!country %in% names(GRIIS_DATASET_BY_COUNTRY)) {
    stop("No GRIIS register configured for ", country, " (GRIIS_DATASET_BY_COUNTRY).", call. = FALSE)
  }
  names_of <- function(label, key) {
    unique(stats::na.omit(binomial(griis_checklist(label, key, fetch)$canonical_name)))
  }
  national <- names_of(country, GRIIS_DATASET_BY_COUNTRY[[country]])
  others <- setdiff(names(GRIIS_DATASET_BY_COUNTRY), country)
  other <- unique(unlist(lapply(others, function(c) names_of(c, GRIIS_DATASET_BY_COUNTRY[[c]]))))
  flagged <- unique(stats::na.omit(binomial(inat_introduced(bbox, fetch)$taxon_name)))
  islands <- GRIIS_ISLANDS_BY_COUNTRY[[country]]
  on_islands <- if (length(islands)) {
    unique(unlist(lapply(names(islands), function(i) names_of(paste(country, i), islands[[i]]))))
  } else character()
  island_only <- setdiff(intersect(national, on_islands), flagged)
  national <- setdiff(national, island_only)
  filled <- setdiff(intersect(flagged, other), national)
  out <- rbind(
    data.frame(taxon_name = national, source = sprintf("GRIIS %s", country), stringsAsFactors = FALSE),
    data.frame(taxon_name = filled, source = "iNaturalist in city + GRIIS elsewhere", stringsAsFactors = FALSE)
  )
  attr(out, "island_only") <- island_only
  out
}
