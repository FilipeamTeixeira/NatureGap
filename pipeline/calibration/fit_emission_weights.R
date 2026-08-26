# Fit TRAFFIC_EMISSION_WEIGHTS to measured Telraam counts (Gent).
#
# Offline calibration. NOT part of run_pipeline.R: it needs a Telraam API key,
# it only makes sense in a city with dense sensor coverage, and its output is a
# committed JSON of numbers that every city then reuses.
#
#   NATUREGAP_CITY=gent Rscript --vanilla -e 'source("config.R"); source("00_download/download_telraam_counts.R")'
#   NATUREGAP_CITY=gent Rscript --vanilla -e 'source("config.R"); source("calibration/fit_emission_weights.R")'
#
# Method: per segment, average each hour-of-day separately and sum the 24
# means. Averaging raw hourly rows instead would let uneven coverage bias the
# result — a sensor that mostly reports at night would look like a quiet street
# regardless of its daytime traffic.
#
# Output: calibration/emission_weights.json, relative to residential = 1.

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

library(dplyr)
library(tidyr)  # replace_na()

CALIB_DIR <- file.path(PIPELINE_ROOT, "calibration")
CALIB_EMISSION_WEIGHTS <- file.path(CALIB_DIR, "emission_weights.json")

for (f in c(RAW_TELRAAM_SEGMENTS, RAW_TELRAAM_TRAFFIC, RAW_OSM_ROADS)) {
  if (!file.exists(f)) stop("Missing input: ", f, call. = FALSE)
}

segments <- st_read(RAW_TELRAAM_SEGMENTS, quiet = TRUE) |> st_transform(CRS_LOCAL)
traffic  <- readRDS(RAW_TELRAAM_TRAFFIC)
roads    <- st_read(RAW_OSM_ROADS, quiet = TRUE) |> st_transform(CRS_LOCAL)

id_col <- intersect(c("segment_id", "oidn", "id"), names(segments))[1]
if (is.na(id_col)) stop("No segment id column in the cached Telraam segments.", call. = FALSE)
segments$.segment_id <- as.character(segments[[id_col]])

# ── 1. Daily car-equivalent volume per segment ───────────────────────────────

# Telraam timestamps are "2026-05-28T13:00:00.000Z". Bare as.POSIXct() parses
# that as a date and silently drops the time — every row comes back as hour 00,
# which does not error, it just collapses the hour-of-day grouping to one bin
# and quietly discards every segment. Parse the format explicitly.
telraam_hour <- function(x) {
  ts <- as.POSIXct(sub("\\.[0-9]+Z?$", "", sub("Z$", "", x)),
                   format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  as.integer(format(ts, "%H"))
}

probe_hours <- telraam_hour(traffic$date)
if (all(is.na(probe_hours)) || length(unique(probe_hours[!is.na(probe_hours)])) < 12L) {
  stop(
    "Telraam timestamps did not parse into a spread of hours (got ",
    length(unique(probe_hours[!is.na(probe_hours)])),
    " distinct hours) — check the `date` format in the cached traffic data.",
    call. = FALSE
  )
}

volumes <- traffic |>
  filter(!is.na(uptime), uptime >= TELRAAM_MIN_UPTIME) |>
  mutate(
    hour = telraam_hour(date),
    car_equiv = replace_na(car, 0) + TELRAAM_HEAVY_FACTOR * replace_na(heavy, 0),
    heavy_share = replace_na(heavy, 0) / pmax(replace_na(car, 0) + replace_na(heavy, 0), 1)
  ) |>
  group_by(segment_id, hour) |>
  summarise(
    hour_mean = mean(car_equiv, na.rm = TRUE),
    hour_heavy_share = mean(heavy_share, na.rm = TRUE),
    n_hours = n(),
    .groups = "drop"
  ) |>
  group_by(segment_id) |>
  summarise(
    daily_car_equiv = sum(hour_mean),
    heavy_share = mean(hour_heavy_share, na.rm = TRUE),
    hours_observed = sum(n_hours),
    hours_of_day = n(),
    .groups = "drop"
  ) |>
  filter(hours_observed >= TELRAAM_MIN_HOURS, hours_of_day >= 20L)

cat(sprintf("[fit] %d segments with >= %d qualifying hours\n",
            nrow(volumes), TELRAAM_MIN_HOURS))

# ── 2. Match each segment to an OSM road class ───────────────────────────────
# NOT st_nearest_feature(). Telraam segment geometry is derived from OSM and
# frequently sits at 0 m from BOTH the street it watches and a service road or
# driveway running alongside it; nearest-feature then picks arbitrarily. In Gent
# that mislabelled sensors on a secondary and a primary road as "service" and
# produced a service weight of 3.3x residential — a driveway carrying 4,700
# car-equivalents a day, which is not a finding, it is a bug.
#
# Match on maximum shared length inside a small buffer instead, breaking ties
# toward the more major class: a window sensor watches a street, not the alley
# beside it.

class_rank <- c(
  motorway = 9, trunk = 8, primary = 7, secondary = 6, tertiary = 5,
  unclassified = 4, residential = 3, living_street = 2, service = 1
)

segments <- segments |> filter(.segment_id %in% volumes$segment_id)
if (nrow(segments) == 0L) stop("No Telraam segment survived the coverage filter.", call. = FALSE)

seg_buf <- st_buffer(segments |> select(.segment_id), TELRAAM_MATCH_TOLERANCE_M)
roads_lm <- roads |>
  mutate(.highway = tolower(as.character(highway))) |>
  filter(!is.na(.highway)) |>
  select(.highway)

overlap <- suppressWarnings(st_intersection(roads_lm, seg_buf))
overlap <- suppressWarnings(st_collection_extract(overlap, "LINESTRING", warn = FALSE))

matched <- overlap |>
  mutate(shared_m = as.numeric(st_length(overlap))) |>
  st_drop_geometry() |>
  group_by(.segment_id, .highway) |>
  summarise(shared_m = sum(shared_m), .groups = "drop") |>
  mutate(rank = unname(class_rank[.highway])) |>
  arrange(.segment_id, desc(shared_m), desc(rank)) |>
  group_by(.segment_id) |>
  slice_head(n = 1L) |>
  ungroup() |>
  transmute(segment_id = .segment_id, highway = .highway, shared_m) |>
  inner_join(volumes, by = "segment_id")

cat(sprintf("[fit] %d of %d segments matched by shared length within %d m\n",
            nrow(matched), nrow(segments), TELRAAM_MATCH_TOLERANCE_M))

# ── 3. Median volume per class, expressed relative to residential ────────────

by_class <- matched |>
  group_by(highway) |>
  summarise(
    n_segments = n(),
    median_daily_car_equiv = median(daily_car_equiv),
    median_heavy_share = median(heavy_share),
    .groups = "drop"
  )

print(as.data.frame(by_class))

ref <- by_class |> filter(highway == "residential")
if (nrow(ref) == 0L || ref$n_segments[[1]] < TELRAAM_MIN_SEGMENTS_PER_CLASS) {
  stop(
    "Cannot calibrate: residential is the reference class and has ",
    if (nrow(ref) == 0L) 0L else ref$n_segments[[1]],
    " usable segments (need >= ", TELRAAM_MIN_SEGMENTS_PER_CLASS, ").",
    call. = FALSE
  )
}
ref_volume <- ref$median_daily_car_equiv[[1]]

# ── 4. Merge with the reasoned defaults ──────────────────────────────────────
# Volunteer sensors cluster on residential streets, so thinly-sampled classes
# keep their default rather than inheriting a median drawn from two windows.

classes <- names(TRAFFIC_EMISSION_WEIGHTS)
fitted <- lapply(classes, function(cls) {
  row <- by_class[by_class$highway == cls, ]
  usable <- nrow(row) == 1L && row$n_segments[[1]] >= TELRAAM_MIN_SEGMENTS_PER_CLASS
  list(
    weight = if (usable) {
      round(unname(row$median_daily_car_equiv[[1]] / ref_volume), 3)
    } else {
      unname(TRAFFIC_EMISSION_WEIGHTS[[cls]])
    },
    source = if (usable) "telraam" else "default",
    n_segments = if (nrow(row) == 1L) row$n_segments[[1]] else 0L,
    median_heavy_share = if (nrow(row) == 1L) round(row$median_heavy_share[[1]], 4) else NA_real_
  )
})
names(fitted) <- classes

# as.list(), so jsonlite writes {"motorway": 10, ...}. A named atomic vector
# serialises as a bare array, which drops the class names — and the config.R
# loader then matches nothing and silently keeps the defaults.
out <- list(
  weights = as.list(vapply(fitted, \(f) f$weight, numeric(1))),
  source = as.list(vapply(fitted, \(f) f$source, character(1))),
  n_segments = as.list(vapply(fitted, \(f) as.integer(f$n_segments), integer(1))),
  median_heavy_share = as.list(vapply(fitted, \(f) f$median_heavy_share, numeric(1))),
  provenance = list(
    city = CITY_ID,
    reference_class = "residential",
    reference_daily_car_equiv = round(ref_volume, 1),
    window_days = TELRAAM_WINDOW_DAYS,
    window_end = if (is.na(TELRAAM_WINDOW_END)) as.character(Sys.Date()) else TELRAAM_WINDOW_END,
    min_uptime = TELRAAM_MIN_UPTIME,
    min_hours = TELRAAM_MIN_HOURS,
    min_segments_per_class = TELRAAM_MIN_SEGMENTS_PER_CLASS,
    heavy_factor = TELRAAM_HEAVY_FACTOR,
    match_tolerance_m = TELRAAM_MATCH_TOLERANCE_M,
    segments_matched = nrow(matched),
    note = paste(
      "Fitted from Telraam citizen counts. Classes marked source='default' had",
      "too few sensors and keep the reasoned value from config.R."
    )
  )
)

dir.create(CALIB_DIR, recursive = TRUE, showWarnings = FALSE)
write_json(out, CALIB_EMISSION_WEIGHTS, pretty = TRUE, auto_unbox = TRUE, na = "null")
cat(sprintf("Written: %s\n", CALIB_EMISSION_WEIGHTS))
cat("\nFitted weights (residential = 1):\n")
print(data.frame(class = classes, weight = out$weights, source = out$source,
                 n = out$n_segments, row.names = NULL))
