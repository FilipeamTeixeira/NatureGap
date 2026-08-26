# Telraam citizen traffic counts -> cached segment geometry + hourly counts.
#
# Telraam (https://telraam.net) is a citizen-science network of window-mounted
# counters that report cars, heavy vehicles, cyclists and pedestrians per hour.
# It is dense in Flanders, which is why Gent is the calibration city for the
# traffic-emissions weights used by every city (see pipeline/calibration/).
#
# This is NOT a city input layer. Telraam counts never reach the exported grid:
# they are used once, offline, to fit TRAFFIC_EMISSION_WEIGHTS, and only those
# fitted numbers are committed. Check the Telraam data licence before
# redistributing anything beyond the weights themselves:
#   https://telraam.helpspace-docs.io/article/9/telraam-data-license-what-can-i-do-with-the-telraam-data
#
# API: https://app.swaggerhub.com/apis-docs/telraam/Telraam-API (v1.2.0)
#
# Setup:
#   1. Add TELRAAM_API_KEY=your_key_here to .env.local (repo root or pipeline/,
#      both work — see config.R's env_file search order)
#   2. Get your key from https://telraam.net -> account settings
#
# Usage:
#   NATUREGAP_CITY=gent Rscript --vanilla -e 'source("config.R"); source("00_download/download_telraam_counts.R")'

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(httr2)
library(dplyr)

TELRAAM_API_BASE <- "https://telraam-api.net"

telraam_api_key <- function() {
  key <- Sys.getenv("TELRAAM_API_KEY", unset = "")
  if (!nzchar(key)) {
    stop(
      "TELRAAM_API_KEY is not set. Add it to your .env.local ",
      "(repo root or pipeline/ both work — see config.R's env_file search order), e.g.\n",
      "  TELRAAM_API_KEY=your_key_here",
      call. = FALSE
    )
  }
  key
}

telraam_request <- function(path, body) {
  request(paste0(TELRAAM_API_BASE, path)) |>
    req_headers(`X-Api-Key` = telraam_api_key()) |>
    req_body_json(body) |>
    req_retry(max_tries = 3L, backoff = \(i) TELRAAM_RETRY_WAIT * i) |>
    req_perform()
}

telraam_post_raw <- function(path, body) {
  resp_body_string(telraam_request(path, body))
}

telraam_post <- function(path, body) {
  resp_body_json(telraam_request(path, body), simplifyVector = TRUE)
}

# ── Segments in the city AOI ─────────────────────────────────────────────────
# "area" as a bounding box is "lon1,lat1,lon2,lat2" (opposite corners). Only
# segments that have produced data are returned for the bbox form, which is
# what we want — a segment with no counts cannot calibrate anything.

fetch_telraam_segments <- function() {
  bb <- st_bbox(st_transform(aoi, 4326))
  area <- sprintf("%.6f,%.6f,%.6f,%.6f", bb[["xmin"]], bb[["ymax"]], bb[["xmax"]], bb[["ymin"]])
  cat(sprintf("[telraam] Requesting segments in bbox %s\n", area))

  body <- telraam_post_raw("/v1/segments/area", list(area = area))
  segs <- tryCatch(st_read(body, quiet = TRUE), error = function(e) {
    stop("Telraam segment response was not readable GeoJSON: ", conditionMessage(e), call. = FALSE)
  })
  if (nrow(segs) == 0L) stop("Telraam returned no segments for this AOI.", call. = FALSE)
  segs <- st_transform(segs, CRS_LOCAL)
  # Clip to the real AOI: the bbox request pulls in segments outside the city.
  segs <- segs[lengths(st_intersects(segs, st_transform(aoi, CRS_LOCAL))) > 0L, ]
  cat(sprintf("[telraam] %d segments inside the AOI\n", nrow(segs)))
  segs
}

# ── Sensor activity window ───────────────────────────────────────────────────
# /v1/segments/area returns every segment that has EVER produced data. In Gent
# that is 185 segments of which only ~51 are still live — the rest are sensors
# taken down years ago. Asking a dead segment for recent traffic returns HTTP
# 200 with an empty report, which looks exactly like a code bug. Filter on the
# reported activity interval rather than rediscovering this per segment.

telraam_window <- function() {
  end <- if (is.na(TELRAAM_WINDOW_END)) Sys.Date() else as.Date(TELRAAM_WINDOW_END)
  list(start = end - TELRAAM_WINDOW_DAYS, end = end)
}

fetch_telraam_activity <- function(segment_ids) {
  win <- telraam_window()
  keep <- vapply(seq_along(segment_ids), function(i) {
    sid <- segment_ids[[i]]
    j <- tryCatch(
      request(paste0(TELRAAM_API_BASE, "/v1/segments/id/", sid)) |>
        req_headers(`X-Api-Key` = telraam_api_key()) |>
        req_retry(max_tries = 3L, backoff = \(k) TELRAAM_RETRY_WAIT * k) |>
        req_perform() |>
        resp_body_json(simplifyVector = TRUE),
      error = function(e) NULL
    )
    Sys.sleep(TELRAAM_QUERY_DELAY)
    props <- j$features$properties
    if (is.null(props) || is.null(props$last_data_package)) return(FALSE)
    last  <- as.Date(substr(as.character(props$last_data_package[1]), 1, 10))
    first <- if (is.null(props$first_data_package)) NA else
      as.Date(substr(as.character(props$first_data_package[1]), 1, 10))
    if (is.na(last)) return(FALSE)
    # Overlap, not "live right now": a sensor that ran for part of the window
    # still contributes valid counts for the hours it did cover.
    last >= win$start && (is.na(first) || first <= win$end)
  }, logical(1))
  segment_ids[keep]
}

# ── Hourly counts per segment ────────────────────────────────────────────────
# Requested in windows because per-hour reports over a long span are large.
# Counts are already uptime-corrected by Telraam; `uptime` is still returned so
# low-coverage hours can be dropped at fit time.

fetch_telraam_traffic <- function(segment_ids) {
  win   <- telraam_window()
  end   <- win$end
  start <- win$start
  chunks <- seq(start, end, by = paste(TELRAAM_CHUNK_DAYS, "days"))
  if (tail(chunks, 1) < end) chunks <- c(chunks, end)

  out <- list()
  for (i in seq_along(segment_ids)) {
    sid <- segment_ids[[i]]
    for (j in seq_len(length(chunks) - 1L)) {
      body <- list(
        level = "segments", format = "per-hour", id = as.character(sid),
        time_start = paste0(format(chunks[j], "%Y-%m-%d"), " 00:00:00Z"),
        time_end   = paste0(format(chunks[j + 1L], "%Y-%m-%d"), " 00:00:00Z")
      )
      res <- tryCatch(telraam_post("/v1/reports/traffic", body), error = function(e) {
        warning(sprintf("segment %s window %s: %s", sid, chunks[j], conditionMessage(e)))
        NULL
      })
      rep <- res$report
      if (!is.null(rep) && length(rep) > 0L && is.data.frame(rep)) {
        out[[length(out) + 1L]] <- rep |>
          transmute(
            segment_id = as.character(sid),
            date = as.character(date),
            uptime = as.numeric(uptime),
            car = as.numeric(car),
            heavy = as.numeric(heavy)
          )
      }
      Sys.sleep(TELRAAM_QUERY_DELAY)
    }
    if (i %% 10L == 0L) cat(sprintf("[telraam] %d / %d segments fetched\n", i, length(segment_ids)))
  }
  if (length(out) == 0L) stop("Telraam returned no traffic rows.", call. = FALSE)
  bind_rows(out)
}

# ── Run ──────────────────────────────────────────────────────────────────────

if (file.exists(RAW_TELRAAM_SEGMENTS) && file.exists(RAW_TELRAAM_TRAFFIC) && OSM_SKIP_IF_EXISTS) {
  cat("[telraam] Cached segments and traffic present — skipping download.\n")
} else {
  segments <- fetch_telraam_segments()
  st_write(segments, RAW_TELRAAM_SEGMENTS, delete_dsn = TRUE, quiet = TRUE)
  cat(sprintf("Written: %s\n", RAW_TELRAAM_SEGMENTS))

  id_col <- intersect(c("segment_id", "oidn", "id"), names(segments))[1]
  if (is.na(id_col)) stop("No segment id column in the Telraam response.", call. = FALSE)

  candidates <- unique(as.character(segments[[id_col]]))
  active <- fetch_telraam_activity(candidates)
  cat(sprintf("[telraam] %d of %d segments reported data within the %d-day window\n",
              length(active), length(candidates), TELRAAM_WINDOW_DAYS))
  if (length(active) == 0L) {
    stop("No Telraam segment was active in the requested window — widen ",
         "TELRAAM_WINDOW_DAYS or pin TELRAAM_WINDOW_END to a period with coverage.",
         call. = FALSE)
  }
  segments <- segments[as.character(segments[[id_col]]) %in% active, ]
  st_write(segments, RAW_TELRAAM_SEGMENTS, delete_dsn = TRUE, quiet = TRUE)

  traffic <- fetch_telraam_traffic(active)
  saveRDS(traffic, RAW_TELRAAM_TRAFFIC)
  cat(sprintf("Written: %s (%d hourly rows)\n", RAW_TELRAAM_TRAFFIC, nrow(traffic)))
}
