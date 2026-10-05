# NatureGap sensitivity — introduced (non-native) species for a city, so the
# opportunity gap counts native species only: a gap that rewards escaped
# parakeets or collection ducks is not a nature gap.
#
# Functions and constants only. Two sources, each cached under data/ so a
# rerun makes no requests:
#
#   GRIIS  the Global Register of Introduced and Invasive Species checklist of
#          the city's country (ISSG, published as GBIF checklist datasets).
#          The authority, with one correction: Portugal's national list
#          carries no locality, and includes species introduced only on the
#          Azores or Madeira — Perez's frog and the Moorish gecko, both native
#          to mainland Iberia. A national species that an island register also
#          lists, and that iNaturalist does not flag inside the city, is taken
#          to be introduced on the islands only and kept as native.
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
# iNaturalist and the GBIF backbone are not resolved.

GRIIS_DATASETS <- c(
  "Portugal"        = "61b67ae8-c623-42a9-9172-3283f2f1473b",
  "Belgium"         = "6d9e952f-948c-4483-9807-575348147c7e",
  "The Netherlands" = "6e74aa5e-d156-4fd9-9299-049307da6fe8",
  "Japan"           = "5c5a6e45-d510-45ed-b7bf-6d0624fac056"
)

# Island registers of a country whose national list folds them in.
GRIIS_ISLANDS <- list(
  "Portugal" = c(
    "Azores"  = "e69281bf-debf-4443-812f-3fb130673273",
    "Madeira" = "7c822f4a-3eb7-4956-af71-052a2c0167bc"
  )
)

binomial <- function(name) {
  name <- trimws(as.character(name))
  ifelse(grepl("^\\S+ \\S+", name), sub("^(\\S+ \\S+).*$", "\\1", name), NA_character_)
}

get_json <- function(url) {
  httr2::request(url) |>
    httr2::req_user_agent("NatureGap pipeline (sensitivity; github.com/FilipeamTeixeira)") |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = TRUE)
}

# Every name usage in a GRIIS checklist, cached as CSV under `label`.
griis_checklist <- function(label, key = GRIIS_DATASETS[[label]],
                            cache_dir = file.path(DATA_IMPORT, "griis")) {
  if (is.null(key)) stop("No GRIIS dataset configured for ", label, call. = FALSE)
  path <- file.path(cache_dir, paste0(gsub("[^a-z]+", "_", tolower(label)), ".csv"))
  if (file.exists(path)) return(utils::read.csv(path, stringsAsFactors = FALSE))

  rows <- list(); offset <- 0L
  repeat {
    page <- get_json(sprintf("https://api.gbif.org/v1/species?datasetKey=%s&limit=1000&offset=%d", key, offset))
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

# Species iNaturalist marks as introduced at observations inside the bbox,
# cached per city.
inat_introduced <- function(bbox, cache_path = file.path(DATA_RAW, "inat_introduced.csv")) {
  if (file.exists(cache_path)) return(utils::read.csv(cache_path, stringsAsFactors = FALSE))
  names <- character(); page <- 1L
  repeat {
    url <- sprintf(paste0(
      "https://api.inaturalist.org/v1/observations/species_counts?",
      "swlat=%f&swlng=%f&nelat=%f&nelng=%f&introduced=true&per_page=500&page=%d"
    ), bbox[["ymin"]], bbox[["xmin"]], bbox[["ymax"]], bbox[["xmax"]], page)
    d <- get_json(url)
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
# registers place their introduction on the islands.
introduced_species <- function(country, bbox) {
  names_of <- function(label, key = GRIIS_DATASETS[[label]]) {
    unique(stats::na.omit(binomial(griis_checklist(label, key)$canonical_name)))
  }
  national <- names_of(country)
  other <- unique(unlist(lapply(setdiff(names(GRIIS_DATASETS), country), names_of)))
  flagged <- unique(stats::na.omit(binomial(inat_introduced(bbox)$taxon_name)))
  islands <- GRIIS_ISLANDS[[country]]
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
