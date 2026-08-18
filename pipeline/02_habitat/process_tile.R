# Per-tile habitat + observation processing (stages 02–03)
#
# process_tile() computes metrics on the halo extent and returns core cells only.
# run_tiled_processing() parallelises across tiles and combines with bind_rows().

library(sf)
library(terra)
library(tidyverse)
library(lubridate)
library(vegan)
library(jsonlite)
library(furrr)

# ── Habitat helpers (from habitat_model.R) ─────────────────────────────────────

rescale01 <- function(x) {
  x <- as.numeric(x)
  rng <- range(x, na.rm = TRUE)
  if (!all(is.finite(rng)) || diff(rng) == 0) return(rep(0, length(x)))
  pmin(1, pmax(0, (x - rng[1]) / diff(rng)))
}

fixed_rescale01 <- function(x, min_value, max_value) {
  x <- as.numeric(x)
  pmin(1, pmax(0, (x - min_value) / (max_value - min_value)))
}

percent_rank01 <- function(x) {
  x <- as.numeric(x)
  out <- rep(NA_real_, length(x))
  ok <- !is.na(x)
  n <- sum(ok)
  if (n == 0L) return(out)
  if (n == 1L) {
    out[ok] <- 0
    return(out)
  }
  out[ok] <- (rank(x[ok], ties.method = "average") - 1) / (n - 1)
  out
}

empty_sf <- function(crs) {
  st_sf(geometry = st_sfc(crs = crs))
}

line_density_by_cell <- function(lines, grid, weight_col = NULL, default_weight = 1) {
  if (nrow(lines) == 0L) return(rep(0, nrow(grid)))
  lines <- suppressWarnings(st_collection_extract(lines, "LINESTRING", warn = FALSE))
  if (nrow(lines) == 0L) return(rep(0, nrow(grid)))
  if (!is.null(weight_col) && weight_col %in% names(lines)) {
    lines$.weight <- as.numeric(lines[[weight_col]])
  } else {
    lines$.weight <- default_weight
  }
  inter <- suppressWarnings(safe_st_intersection(lines |> select(.weight), grid |> select(cell_id), y_prepared = TRUE))
  if (nrow(inter) == 0L) return(rep(0, nrow(grid)))
  inter$weighted_len_m <- as.numeric(st_length(inter)) * replace_na(inter$.weight, default_weight)
  density <- inter |>
    st_drop_geometry() |>
    group_by(cell_id) |>
    summarise(weighted_len_m = sum(weighted_len_m), .groups = "drop")
  out <- rep(0, nrow(grid))
  out[match(density$cell_id, grid$cell_id)] <- density$weighted_len_m
  out / (as.numeric(st_area(grid)) / 10000)
}

point_density_by_cell <- function(points, grid) {
  if (nrow(points) == 0L) return(rep(0, nrow(grid)))
  points <- suppressWarnings(st_collection_extract(points, "POINT", warn = FALSE))
  if (nrow(points) == 0L) return(rep(0, nrow(grid)))
  points_geom <- st_sf(geometry = st_geometry(points), crs = st_crs(points))
  joined <- st_join(points_geom, grid |> select(cell_id), join = st_within, left = FALSE)
  if (nrow(joined) == 0L) return(rep(0, nrow(grid)))
  counts <- joined |> st_drop_geometry() |> count(cell_id, name = "n")
  out <- rep(0, nrow(grid))
  out[match(counts$cell_id, grid$cell_id)] <- counts$n
  out / (as.numeric(st_area(grid)) / 10000)
}

distance_weighted_points <- function(points, centroids, radius_m, decay_m) {
  if (nrow(points) == 0L) return(rep(0, nrow(centroids)))
  points <- suppressWarnings(st_collection_extract(points, "POINT", warn = FALSE))
  if (nrow(points) == 0L) return(rep(0, nrow(centroids)))
  idx <- st_nearest_feature(centroids, points)
  d <- as.numeric(st_distance(centroids, points[idx, ], by_element = TRUE))
  if_else(d <= radius_m, exp(-d / decay_m), 0)
}

distance_weighted_lines <- function(lines, centroids, radius_m, decay_m, weights = NULL) {
  if (nrow(lines) == 0L) return(rep(0, nrow(centroids)))
  lines <- suppressWarnings(st_collection_extract(lines, "LINESTRING", warn = FALSE))
  if (nrow(lines) == 0L) return(rep(0, nrow(centroids)))
  if (is.null(weights)) weights <- rep(1, nrow(lines))
  idx <- st_nearest_feature(centroids, lines)
  d <- as.numeric(st_distance(centroids, lines[idx, ], by_element = TRUE))
  if_else(d <= radius_m, exp(-d / decay_m) * weights[idx], 0)
}

nearest_proximity <- function(features, centroids, radius_m) {
  if (nrow(features) == 0L) return(rep(0, nrow(centroids)))
  idx <- st_nearest_feature(centroids, features)
  d <- as.numeric(st_distance(centroids, features[idx, ], by_element = TRUE))
  if_else(d <= radius_m, pmax(0, 1 - d / radius_m), 0)
}

road_weight <- function(highway) {
  x <- tolower(as.character(highway))
  dplyr::case_when(
    x %in% c("motorway", "trunk") ~ 5,
    x == "primary" ~ 4,
    x == "secondary" ~ 3,
    x == "tertiary" ~ 2,
    x %in% c("residential", "unclassified") ~ 1,
    x %in% c("service", "living_street") ~ 0.6,
    TRUE ~ 1
  )
}

polygon_area_by_cell <- function(polygons, grid) {
  if (nrow(polygons) == 0L) {
    return(tibble(cell_id = grid$cell_id, area_m2 = 0))
  }
  inter <- suppressWarnings(safe_st_intersection(polygons, grid, y_prepared = TRUE))
  if (nrow(inter) == 0L) {
    return(tibble(cell_id = grid$cell_id, area_m2 = 0))
  }
  inter$area_m2 <- as.numeric(st_area(st_geometry(inter)))
  inter |>
    st_drop_geometry() |>
    group_by(cell_id) |>
    summarise(area_m2 = sum(area_m2), .groups = "drop")
}

classify_taxon_group <- function(label) {
  x <- tolower(as.character(label))
  dplyr::case_when(
    is.na(x) | x == "" ~ NA_character_,
    x %in% c("plantae", "chromista") ~ "plant",
    grepl("^(plant|magnoli|pinopsida|liliopsida|polypodi)", x) ~ "plant",
    x == "aves" | grepl("bird", x) ~ "bird",
    x %in% c("insecta", "arachnida") | grepl("insect|spider|arthropod", x) ~ "insect",
    x %in% c("mammalia", "amphibia", "reptilia", "actinopterygii", "animalia") ~ "mammal",
    x == "fungi" | grepl("fung", x) ~ "fungi",
    TRUE ~ NA_character_
  )
}

WC_TREE <- 10L
WC_SHRUB <- 20L
WC_GRASS <- 30L
WC_BUILT <- 50L
WC_WATER <- 80L
WC_WETLAND <- 90L
WC_MANGROVE <- 95L
WC_GREEN <- c(WC_TREE, WC_SHRUB, WC_GRASS, WC_WETLAND, WC_MANGROVE)

# ── OSM PBF helpers ───────────────────────────────────────────────────────────

osm_tag_from_other <- function(other_tags, key) {
  if (is.na(other_tags) || !nzchar(other_tags)) return(NA_character_)
  pattern <- paste0("\"", key, "\"=>\"([^\"]*)\"")
  match <- regexpr(pattern, other_tags, perl = TRUE)
  if (match[1L] == -1L) return(NA_character_)
  substr(other_tags, match[1L] + nchar(key) + 4L, match[1L] + attr(match, "match.length") - 2L)
}

read_osm_layer <- function(pbf_path, layer, wkt_filter = NULL) {
  if (!file.exists(pbf_path)) return(empty_sf(CRS_LOCAL))
  args <- list(dsn = pbf_path, layer = layer, quiet = TRUE, int64_as_string = TRUE)
  if (!is.null(wkt_filter)) args$wkt_filter <- wkt_filter
  out <- tryCatch(do.call(st_read, args), error = function(e) empty_sf(CRS_LOCAL))
  if (nrow(out) == 0L) return(empty_sf(CRS_LOCAL))
  out <- st_make_valid(out)
  out <- out[!st_is_empty(out), , drop = FALSE]
  if (nrow(out) == 0L) return(empty_sf(CRS_LOCAL))
  if ("other_tags" %in% names(out)) {
    for (col in c("highway", "railway", "leisure", "landuse", "natural", "amenity", "lit", "waterway")) {
      if (!col %in% names(out)) out[[col]] <- NA_character_
      missing <- is.na(out[[col]]) | !nzchar(out[[col]])
      if (any(missing)) {
        out[[col]][missing] <- vapply(out$other_tags[missing], osm_tag_from_other, character(1L), key = col)
      }
    }
  }
  st_transform(out, CRS_LOCAL)
}

# read_osm_layer() only backfills tag columns when its OGR read returns rows;
# a tile with zero features of a layer (e.g. open water/bay) comes back with
# just a geometry column, so downstream filter(leisure %in% ...) etc. would
# error on a missing column instead of just matching zero rows.
ensure_tag_cols <- function(x, cols) {
  for (col in cols) {
    if (!col %in% names(x)) x[[col]] <- rep(NA_character_, nrow(x))
  }
  x
}

read_osm_lines <- function(pbf_path, wkt_filter) {
  bind_rows(
    read_osm_layer(pbf_path, "lines", wkt_filter),
    read_osm_layer(pbf_path, "multilinestrings", wkt_filter)
  ) |> ensure_tag_cols(c("highway", "railway", "lit", "waterway"))
}

read_osm_polygons <- function(pbf_path, wkt_filter) {
  read_osm_layer(pbf_path, "multipolygons", wkt_filter) |>
    ensure_tag_cols(c("leisure", "natural", "landuse", "amenity"))
}

read_osm_points <- function(pbf_path, wkt_filter) {
  read_osm_layer(pbf_path, "points", wkt_filter) |>
    ensure_tag_cols(c("highway", "amenity"))
}

wkt_filter_from_sf <- function(x, crs_local = CRS_LOCAL) {
  bb <- st_bbox(st_transform(st_as_sf(x), 4326))
  st_as_text(st_as_sfc(bb), trim = TRUE)
}

filter_core_cells <- function(grid, core_polygon) {
  centroids <- suppressWarnings(st_centroid(grid))
  inside <- st_intersects(centroids, core_polygon, sparse = FALSE)[, 1L]
  grid[inside, , drop = FALSE]
}

# ── process_tile ──────────────────────────────────────────────────────────────

safe_crop <- function(r, v, label = "raster") {
  tryCatch(terra::crop(r, v), error = function(e) {
    message(sprintf("[safe_crop] %s failed: %s", label, conditionMessage(e)))
    NULL
  })
}

# Crop in the raster's native CRS, then project only the tile-sized subset.
# Avoids projecting whole-city rasters inside every tile worker (canopy is ~30M cells).
crop_project_to_halo <- function(r, halo_extent, crs_local, method = "bilinear", label = "raster") {
  if (is.character(r)) {
    if (!file.exists(r)) return(NULL)
    r <- rast(r)
  }
  halo_src <- st_transform(st_as_sf(halo_extent), crs(r))
  cropped <- safe_crop(r, terra::vect(halo_src), label = paste(label, "crop"))
  if (is.null(cropped)) return(NULL)
  # same.crs(), not ==: crs() returns full WKT, so comparing it to an authority
  # string ("EPSG:3763") is never TRUE and every already-local raster was being
  # reprojected onto itself — ~6 s per tile for cir_ndvi/veg_fraction, plus a
  # pointless bilinear resample of data that was already in the target CRS.
  if (terra::same.crs(cropped, crs_local)) return(cropped)
  tryCatch(project(cropped, crs_local, method = method), error = function(e) {
    message(sprintf("[crop_project_to_halo] %s project failed: %s", label, conditionMessage(e)))
    NULL
  })
}

# terra::extract(fun=) walks polygon by polygon, so its cost scales with
# (n polygons x cells per polygon). On sub-metre rasters a 20 m hex covers
# ~1400 cells and this dominates everything else in the tile: measured on porto
# tile_0003 (7322 core cells), the cir_ndvi sd extract alone projects to ~1590 s.
# rasterize() + zonal() computes the same statistic in one C++ pass over the
# raster instead — 14.7 s for cir sd + veg mean together.
#
# Values are identical, not approximated: rasterize() and extract(touches=FALSE)
# both assign a raster cell by whether its centre falls inside the polygon, so
# the same cells feed the same statistic (max abs diff 5e-16 over 400 hexes).
#
# The one case rasterize cannot reproduce is a hex containing no cell centre at
# all, which extract(small=TRUE) still resolves. That only happens on rasters
# coarse relative to the hex, so those go down the original extract path, and
# any straggler with an empty zone is backfilled with extract — the result is
# unchanged for every cell either way.
zonal_stat_by_cell <- function(r, core_vect, fun, hex_area, zone = NULL) {
  n_cells <- nrow(core_vect)
  fine_enough <- is.finite(hex_area) && prod(terra::res(r)) * 4 <= hex_area
  if (!fine_enough) {
    return(list(
      values = terra::extract(r, core_vect, fun = fun, na.rm = TRUE)[[2L]],
      zone = zone
    ))
  }
  if (!is.null(zone) && !isTRUE(terra::compareGeom(r, zone, stopOnError = FALSE))) {
    zone <- NULL
  }
  if (is.null(zone)) zone <- terra::rasterize(core_vect, r, field = "zone_idx")
  agg <- terra::zonal(r, zone, fun = fun, na.rm = TRUE)
  out <- rep(NA_real_, n_cells)
  keep <- agg[[1L]] >= 1L & agg[[1L]] <= n_cells
  out[agg[[1L]][keep]] <- agg[[2L]][keep]
  gaps <- which(is.na(out))
  if (length(gaps) > 0L) {
    # The sub-metre rasters do not cover the whole city — crop() clips the halo
    # at the raster edge, so on an edge tile most core hexes lie outside the
    # raster and come back NA. extract() returns NA for those too, so sending
    # them down the fallback buys nothing and costs everything: on porto
    # tile_0002, 4770 of 4808 gaps were outside the extent and that fallback
    # alone took 1321 s. Only hexes that actually meet the raster can gain a
    # value from extract(small=TRUE) — there were 38, and all 38 do.
    footprint <- terra::as.polygons(terra::ext(r), crs = terra::crs(r))
    meets_raster <- terra::relate(core_vect[gaps, ], footprint, "intersects")[, 1L]
    gaps <- gaps[meets_raster]
  }
  if (length(gaps) > 0L) {
    out[gaps] <- terra::extract(r, core_vect[gaps, ], fun = fun, na.rm = TRUE)[[2L]]
  }
  list(values = out, zone = zone)
}

process_tile <- function(core_polygon, halo_pbf_path, obs_tile = NULL, cfg = NULL) {
  if (is.null(cfg)) cfg <- list()
  crs_local <- cfg$CRS_LOCAL %||% CRS_LOCAL
  cell_size <- cfg$CELL_SIZE %||% CELL_SIZE
  halo_m <- cfg$halo_m %||% halo_m
  hex_grid_origin <- cfg$HEX_GRID_ORIGIN %||% HEX_GRID_ORIGIN
  path_radius_m <- cfg$PATH_RADIUS_M %||% PATH_RADIUS_M
  min_path_m <- cfg$MIN_PATH_M %||% MIN_PATH_M

  core_local <- st_transform(st_as_sf(core_polygon), crs_local)
  halo_extent <- st_buffer(core_local, dist = halo_m)
  wkt_filter <- wkt_filter_from_sf(halo_extent, crs_local)

  # offset is fixed city-wide (not derived from this tile's own halo bbox) and
  # the extent is snapped onto the lattice period, so every tile's hexagons
  # share one lattice phase and tile seamlessly. Both are required — see
  # hex_lattice_extent() in config.R for why offset alone leaves a seam along
  # every north-south core_tiles.gpkg boundary.
  grid <- st_make_grid(
    hex_lattice_extent(halo_extent, hex_grid_origin, cell_size),
    cellsize = cell_size,
    square = FALSE,
    offset = hex_grid_origin
  ) |>
    st_as_sf()

  # row_number() is only unique within this tile's own halo grid — two tiles
  # can independently produce the same integer for two different physical
  # hexes. Key on the (now lattice-aligned) centroid instead, so the same
  # physical hex always gets the same id no matter which tile built it.
  centroid_xy <- suppressWarnings(st_coordinates(st_centroid(grid)))
  grid$cell_id <- sprintf(
    "h%.0f_%.0f",
    round(centroid_xy[, "X"] * 1000),
    round(centroid_xy[, "Y"] * 1000)
  )
  # Grid geometry never changes after this point; validate/snap it once and
  # reuse for every OSM intersection below instead of repeating it per call.
  grid_valid <- geom_precision_snap(grid |> select(cell_id))

  # Local-only metrics (landcover, NDVI, canopy, LST, impervious) don't need
  # halo context at all — a hex's own habitat quality doesn't depend on its
  # neighbors. Only connectivity/path density genuinely needs the full halo.
  # Since adjacent tiles' halos overlap heavily (~3x core area at current
  # tile_size_m/halo_m), computing these for the full halo grid means a lot
  # of redundant work gets thrown away when filter_core_cells() runs at the
  # end anyway. Restrict extraction to core cells only; halo-only rows stay
  # NA for these columns, which is fine since they get discarded regardless.
  core_grid <- filter_core_cells(grid, core_local)
  # Numeric row index for zonal_stat_by_cell(): rasterize() needs a numeric
  # field, and cell_id is a character key with one level per hex.
  core_grid$zone_idx <- seq_len(nrow(core_grid))
  core_vect <- vect(core_grid)
  hex_area <- if (nrow(core_grid) > 0L) {
    stats::median(as.numeric(st_area(core_grid)))
  } else {
    NA_real_
  }

  tile_id <- sub("\\.osm\\.pbf$", "", basename(halo_pbf_path))
  message(sprintf("[tile %s] start %s", tile_id, format(Sys.time(), "%H:%M:%S")))

  # ── Rasters (crop to halo bbox) ───────────────────────────────────────────
  # Halo must be in crs_local when cropping an already-projected raster.
  halo_vect <- terra::vect(st_as_sf(halo_extent))
  # grid geometry is unchanged through the raster block below; convert once
  # instead of re-converting sf -> SpatVector for every terra::extract() call.
  grid_vect <- vect(grid)

  lc_path <- cfg$RAW_LANDCOVER %||% RAW_LANDCOVER
  message(sprintf("[tile %s] RAW_LANDCOVER path: %s (exists: %s)", tile_id, lc_path, file.exists(lc_path)))
  if (file.exists(lc_path)) {
    t_crop <- proc.time()
    lc <- crop_project_to_halo(lc_path, halo_extent, crs_local, method = "near", label = "landcover")
    message(sprintf("[tile %s] landcover crop+project: %.1fs", tile_id, (proc.time() - t_crop)[["elapsed"]]))
    if (!is.null(lc)) {
      t_extract <- proc.time()
      lc_vals <- terra::extract(lc, core_vect)
      message(sprintf("[tile %s] landcover extract (%d core cells): %.1fs", tile_id, nrow(core_grid), (proc.time() - t_extract)[["elapsed"]]))
      lc_fracs <- lc_vals |>
        as_tibble() |>
        rename(row_idx = ID, lc_class = 2) |>
        filter(!is.na(lc_class)) |>
        group_by(row_idx) |>
        summarise(
          tree_fraction = mean(lc_class == WC_TREE),
          shrub_fraction = mean(lc_class == WC_SHRUB),
          grass_fraction = mean(lc_class == WC_GRASS),
          built_fraction_wc = mean(lc_class == WC_BUILT),
          green_fraction_wc = mean(lc_class %in% WC_GREEN),
          water_fraction = mean(lc_class == WC_WATER),
          .groups = "drop"
        ) |>
        mutate(cell_id = core_grid$cell_id[row_idx]) |>
        select(-row_idx)
      grid <- grid |> left_join(lc_fracs, by = "cell_id") |>
        mutate(across(
          c(tree_fraction, shrub_fraction, grass_fraction, built_fraction_wc, green_fraction_wc, water_fraction),
          \(x) replace_na(x, 0)
        ))
    } else {
      grid <- grid |> mutate(
        tree_fraction = NA_real_, shrub_fraction = NA_real_, grass_fraction = NA_real_,
        built_fraction_wc = NA_real_, green_fraction_wc = NA_real_, water_fraction = NA_real_
      )
    }
  } else {
    grid <- grid |> mutate(
      tree_fraction = NA_real_, shrub_fraction = NA_real_, grass_fraction = NA_real_,
      built_fraction_wc = NA_real_, green_fraction_wc = NA_real_, water_fraction = NA_real_
    )
  }

  imp_path <- cfg$RAW_IMPERVIOUS %||% RAW_IMPERVIOUS
  if (file.exists(imp_path)) {
    t_crop <- proc.time()
    imp <- crop_project_to_halo(imp_path, halo_extent, crs_local, method = "bilinear", label = "impervious")
    message(sprintf("[tile %s] impervious crop+project: %.1fs", tile_id, (proc.time() - t_crop)[["elapsed"]]))
    if (!is.null(imp)) {
      t_extract <- proc.time()
      imp_mean <- terra::extract(imp, core_vect, fun = mean, na.rm = TRUE)
      message(sprintf("[tile %s] impervious extract: %.1fs", tile_id, (proc.time() - t_extract)[["elapsed"]]))
      grid$impervious_fraction <- NA_real_
      grid$impervious_fraction[match(core_grid$cell_id, grid$cell_id)] <- replace_na(imp_mean[[2]], 0)
    } else {
      grid$impervious_fraction <- NA_real_
    }
  } else {
    grid$impervious_fraction <- NA_real_
  }

  grid$ndvi_mean <- NA_real_
  grid$ndvi_idx <- NA_real_
  ndvi_path <- cfg$RAW_NDVI %||% RAW_NDVI
  message(sprintf("[tile %s] RAW_NDVI path: %s (exists: %s)", tile_id, ndvi_path, file.exists(ndvi_path)))
  if (file.exists(ndvi_path)) {
    t_crop <- proc.time()
    ndvi <- crop_project_to_halo(ndvi_path, halo_extent, crs_local, method = "bilinear", label = "ndvi")
    message(sprintf("[tile %s] ndvi crop+project: %.1fs", tile_id, (proc.time() - t_crop)[["elapsed"]]))
    if (!is.null(ndvi)) {
      t_extract <- proc.time()
      ndvi_mean <- terra::extract(ndvi, core_vect, fun = mean, na.rm = TRUE)
      message(sprintf("[tile %s] ndvi extract: %.1fs", tile_id, (proc.time() - t_extract)[["elapsed"]]))
      idx <- match(core_grid$cell_id, grid$cell_id)
      grid$ndvi_mean[idx] <- replace_na(ndvi_mean[[2]], NA_real_)
      grid$ndvi_idx[idx] <- fixed_rescale01(grid$ndvi_mean[idx], -0.2, 1.0)
    }
  }

  grid$veg_fraction <- NA_real_
  grid$ndvi_texture <- NA_real_
  cir_path <- cfg$RAW_CIR_NDVI %||% if (exists("RAW_CIR_NDVI")) RAW_CIR_NDVI else NA_character_
  veg_path <- cfg$RAW_VEG_FRACTION %||% if (exists("RAW_VEG_FRACTION")) RAW_VEG_FRACTION else NA_character_
  cir_threshold <- cfg$CIR_VEG_NDVI_THRESHOLD %||% if (exists("CIR_VEG_NDVI_THRESHOLD")) CIR_VEG_NDVI_THRESHOLD else 0.2
  message(sprintf(
    "[tile %s] RAW_CIR_NDVI path: %s (exists: %s)",
    tile_id, cir_path,
    is.character(cir_path) && !is.na(cir_path) && file.exists(cir_path)
  ))
  if (is.character(cir_path) && !is.na(cir_path) && file.exists(cir_path)) {
    t_crop <- proc.time()
    cir <- crop_project_to_halo(cir_path, halo_extent, crs_local, method = "bilinear", label = "cir_ndvi")
    message(sprintf("[tile %s] cir_ndvi crop+project: %.1fs", tile_id, (proc.time() - t_crop)[["elapsed"]]))
    if (!is.null(cir)) {
      t_extract <- proc.time()
      cir_sd <- zonal_stat_by_cell(cir, core_vect, "sd", hex_area)
      idx <- match(core_grid$cell_id, grid$cell_id)
      grid$ndvi_texture[idx] <- cir_sd$values
      if (is.character(veg_path) && !is.na(veg_path) && file.exists(veg_path)) {
        # Free the cir crop before loading veg: both are full-halo sub-metre
        # rasters (~290 MB each here) and every worker holds its own copy.
        rm(cir)
        veg <- crop_project_to_halo(veg_path, halo_extent, crs_local, method = "near", label = "veg_fraction")
        if (!is.null(veg)) {
          # veg_fraction shares cir_ndvi's grid, so the zone raster is reused;
          # zonal_stat_by_cell() re-rasterizes if that ever stops holding.
          veg_mean <- zonal_stat_by_cell(veg, core_vect, "mean", hex_area, zone = cir_sd$zone)
          grid$veg_fraction[idx] <- veg_mean$values
        }
      } else {
        veg_mean <- zonal_stat_by_cell(cir >= cir_threshold, core_vect, "mean", hex_area, zone = cir_sd$zone)
        grid$veg_fraction[idx] <- veg_mean$values
      }
      message(sprintf("[tile %s] cir veg_fraction/ndvi_texture extract: %.1fs", tile_id, (proc.time() - t_extract)[["elapsed"]]))
    }
  }

  grid$canopy_height_m <- NA_real_
  grid$canopy_height_idx <- NA_real_
  canopy_path <- cfg$CANOPY_HEIGHT_FILE %||% if (exists("CANOPY_HEIGHT_FILE")) CANOPY_HEIGHT_FILE else NA_character_
  message(sprintf(
    "[tile %s] CANOPY_HEIGHT_FILE path: %s (exists: %s)",
    tile_id, canopy_path,
    is.character(canopy_path) && !is.na(canopy_path) && file.exists(canopy_path)
  ))
  if (is.character(canopy_path) && !is.na(canopy_path) && file.exists(canopy_path)) {
    canopy_local_path <- cfg$CANOPY_LOCAL_PATH %||% NA_character_
    t_crop <- proc.time()
    canopy_height <- if (is.character(canopy_local_path) && !is.na(canopy_local_path) && file.exists(canopy_local_path)) {
      safe_crop(rast(canopy_local_path), halo_vect, label = "canopy_height")
    } else {
      crop_project_to_halo(canopy_path, halo_extent, crs_local, method = "bilinear", label = "canopy_height")
    }
    message(sprintf("[tile %s] canopy_height crop+project: %.1fs", tile_id, (proc.time() - t_crop)[["elapsed"]]))
    if (!is.null(canopy_height)) {
      t_extract <- proc.time()
      # canopy_height_local is 0.9 m, so ~430 raster cells per 20 m hex — the
      # same per-polygon extract cost that made cir_ndvi the tile bottleneck.
      canopy_height_mean <- zonal_stat_by_cell(canopy_height, core_vect, "mean", hex_area)
      message(sprintf("[tile %s] canopy_height extract: %.1fs", tile_id, (proc.time() - t_extract)[["elapsed"]]))
      idx <- match(core_grid$cell_id, grid$cell_id)
      grid$canopy_height_m[idx] <- replace_na(canopy_height_mean$values, NA_real_)
      grid$canopy_height_idx[idx] <- fixed_rescale01(grid$canopy_height_m[idx], 0, 30)
    }
  }

  grid$lst_celsius <- NA_real_
  lst_path <- cfg$RAW_LST %||% RAW_LST
  message(sprintf("[tile %s] RAW_LST path: %s (exists: %s)", tile_id, lst_path, file.exists(lst_path)))
  if (file.exists(lst_path)) {
    t_crop <- proc.time()
    lst <- crop_project_to_halo(lst_path, halo_extent, crs_local, method = "bilinear", label = "lst")
    message(sprintf("[tile %s] lst crop+project: %.1fs", tile_id, (proc.time() - t_crop)[["elapsed"]]))
    if (!is.null(lst)) {
      t_extract <- proc.time()
      lst_mean <- terra::extract(lst, core_vect, fun = mean, na.rm = TRUE)
      message(sprintf("[tile %s] lst extract: %.1fs", tile_id, (proc.time() - t_extract)[["elapsed"]]))
      idx <- match(core_grid$cell_id, grid$cell_id)
      grid$lst_celsius[idx] <- replace_na(lst_mean[[2]], NA_real_)
    }
  }

  # ── OSM from per-tile PBF ─────────────────────────────────────────────────
  lines <- read_osm_lines(halo_pbf_path, wkt_filter)
  polys <- read_osm_polygons(halo_pbf_path, wkt_filter)
  points <- read_osm_points(halo_pbf_path, wkt_filter)

  green <- polys |> filter(leisure %in% c("park", "nature_reserve", "garden"))
  ground_veg <- polys |> filter(
    natural %in% c("grassland", "scrub") |
      landuse %in% c("grass", "meadow", "allotments") |
      leisure == "garden"
  )
  water_polygons <- polys |> filter(natural == "water")
  paths <- lines |> filter(highway %in% c("path", "footway", "pedestrian", "steps", "track"))
  roads <- lines |> filter(highway %in% c(
    "motorway", "trunk", "primary", "secondary", "tertiary",
    "residential", "service", "unclassified", "living_street"
  ))
  rail <- lines |> filter(railway %in% c("rail", "light_rail", "subway", "tram"))
  lit_roads <- lines |> filter(lit == "yes")
  lamps <- {
    lamp_points <- points |> filter(highway == "street_lamp")
    lamp_line_centroids <- lines |>
      filter(highway == "street_lamp") |>
      suppressWarnings(st_centroid())
    if (nrow(lamp_points) == 0L && nrow(lamp_line_centroids) == 0L) {
      empty_sf(crs_local)
    } else if (nrow(lamp_points) == 0L) {
      lamp_line_centroids
    } else if (nrow(lamp_line_centroids) == 0L) {
      lamp_points
    } else {
      bind_rows(lamp_points, lamp_line_centroids)
    }
  }
  amenity_polys <- polys |> filter(!is.na(amenity) & nzchar(amenity))
  amenity_poly_centroids <- if (nrow(amenity_polys) > 0L) {
    suppressWarnings(st_centroid(amenity_polys))
  } else {
    empty_sf(crs_local)
  }
  amenities <- bind_rows(
    points |> filter(!is.na(amenity) & nzchar(amenity)),
    amenity_poly_centroids
  )
  water_lines <- lines |> filter(!is.na(waterway) & nzchar(waterway))
  water_features <- bind_rows(water_lines, water_polygons)

  cell_area <- cell_size^2
  green_area <- polygon_area_by_cell(green, grid_valid)
  grid <- grid |>
    left_join(green_area, by = "cell_id") |>
    mutate(
      green_area_m2 = replace_na(area_m2, 0),
      osm_green_fraction = pmin(green_area_m2 / cell_area, 1)
    ) |>
    select(-green_area_m2, -area_m2)

  ground_veg_area <- polygon_area_by_cell(ground_veg, grid_valid)
  grid <- grid |>
    left_join(ground_veg_area, by = "cell_id") |>
    mutate(
      ground_veg_area_m2 = replace_na(area_m2, 0),
      osm_ground_veg_fraction = pmin(ground_veg_area_m2 / cell_area, 1)
    ) |>
    select(-ground_veg_area_m2, -area_m2)

  water_poly_area <- polygon_area_by_cell(water_polygons, grid_valid)
  grid <- grid |>
    left_join(water_poly_area, by = "cell_id") |>
    mutate(
      water_poly_area_m2 = replace_na(area_m2, 0),
      osm_water_poly_fraction = pmin(water_poly_area_m2 / cell_area, 1)
    ) |>
    select(-water_poly_area_m2, -area_m2)

  if (nrow(paths) > 0L) {
    inter <- suppressWarnings(safe_st_intersection(paths, grid_valid, y_prepared = TRUE))
    inter$len_m <- as.numeric(st_length(st_geometry(inter)))
    path_length <- inter |>
      st_drop_geometry() |>
      group_by(cell_id) |>
      summarise(path_length_m = sum(len_m), .groups = "drop")
    grid <- grid |>
      left_join(path_length, by = "cell_id") |>
      mutate(path_length_m = replace_na(path_length_m, 0))
  } else {
    grid$path_length_m <- 0
  }

  # Effort is measured over a neighbourhood, not the cell alone. A 20 m hex is
  # ~350 m², so a path centreline only clips a narrow ribbon of cells and a
  # strict intersection marks a cell one hex off a footway as unsampled. Run on
  # the full halo grid (halo_m is 750 m, far wider than path_radius_m) so cells
  # near a tile edge get their real neighbourhood rather than a truncated one —
  # filter_core_cells() discards the halo rows later.
  cell_centroids <- suppressWarnings(st_centroid(grid))
  path_neighbours <- suppressWarnings(
    st_is_within_distance(st_geometry(cell_centroids), dist = path_radius_m)
  )
  grid <- grid |>
    mutate(
      path_km = path_length_m / 1000,
      path_local_m = vapply(
        path_neighbours,
        function(idx) sum(path_length_m[idx]),
        numeric(1)
      ),
      is_unsampled = path_local_m < min_path_m
    ) |>
    select(-path_length_m)

  cell_area_ha <- as.numeric(st_area(grid)) / 10000
  if (nrow(roads) > 0L) roads$.road_weight <- road_weight(roads$highway)
  # Pre-extract once; both the density and proximity helpers below would
  # otherwise each redo this same LINESTRING/POINT extraction independently.
  if (nrow(roads) > 0L) roads <- suppressWarnings(st_collection_extract(roads, "LINESTRING", warn = FALSE))
  if (nrow(rail) > 0L) rail <- suppressWarnings(st_collection_extract(rail, "LINESTRING", warn = FALSE))
  if (nrow(lamps) > 0L) lamps <- suppressWarnings(st_collection_extract(lamps, "POINT", warn = FALSE))

  road_density <- line_density_by_cell(roads, grid_valid, ".road_weight")
  rail_density <- line_density_by_cell(rail, grid_valid, default_weight = 3)
  road_proximity <- distance_weighted_lines(
    roads, cell_centroids, 150, 60,
    if (nrow(roads) > 0L) roads$.road_weight else NULL
  )
  rail_proximity <- distance_weighted_lines(rail, cell_centroids, 200, 80, rep(3, nrow(rail)))
  lamp_density <- point_density_by_cell(lamps, grid)
  lamp_proximity <- distance_weighted_points(lamps, cell_centroids, 80, 30)
  lit_road_density <- line_density_by_cell(lit_roads, grid_valid)
  path_density <- (grid$path_km * 1000) / pmax(cell_area_ha, 0.0001)
  amenity_proximity <- distance_weighted_points(amenities, cell_centroids, 120, 50)
  water_prox <- nearest_proximity(water_features, cell_centroids, 250)
  permeable_fraction <- pmin(1, pmax(0, 1 - replace_na(grid$impervious_fraction, 0)))

  grid <- grid |>
    mutate(
      road_density = road_density,
      rail_density = rail_density,
      road_proximity = road_proximity,
      rail_proximity = rail_proximity,
      lamp_density = lamp_density,
      lamp_proximity = lamp_proximity,
      lit_road_density = lit_road_density,
      path_density = path_density,
      amenity_proximity = amenity_proximity,
      water_prox = water_prox,
      permeable_fraction = permeable_fraction
    )

  # ── Observations (optional per-tile subset) ───────────────────────────────
  obs_defaults <- tibble(
    n_obs = 0L, raw_species_count = 0, species_richness = 0,
    n_survey_dates = 0L, n_observers = 0L,
    observed_dates_json = "[]", observer_ids_json = "[]",
    weighted_observation_effort = 0, has_structured_survey = FALSE,
    weekend_obs = 0L, weekday_obs = 0L, weekend_only = FALSE, temporal_bias_flag = FALSE,
    species_shannon = NA_real_,
    plant = 0L, bird = 0L, insect = 0L, mammal = 0L, fungi = 0L
  )

  if (!is.null(obs_tile) && nrow(obs_tile) > 0L && nrow(grid) > 0L) {
    # grid geometry hasn't changed since cell_centroids was computed above.
    nearest_idx <- st_nearest_feature(obs_tile, cell_centroids)
    obs_joined <- obs_tile |>
      mutate(
        cell_id = grid$cell_id[nearest_idx],
        path_km = grid$path_km[nearest_idx]
      )

    richness <- obs_joined |>
      st_drop_geometry() |>
      mutate(is_weekend = !is.na(observed_on) & wday(observed_on) %in% c(1L, 7L)) |>
      group_by(cell_id, taxon_name) |>
      mutate(taxon_weight = max(observation_weight, na.rm = TRUE)) |>
      ungroup() |>
      group_by(cell_id) |>
      summarise(
        n_obs = n(),
        raw_species_count = n_distinct(taxon_name[!is.na(taxon_name)]),
        species_richness = sum(taxon_weight[!duplicated(taxon_name)], na.rm = TRUE),
        n_survey_dates = n_distinct(observed_on[!is.na(observed_on)]),
        n_observers = n_distinct(observer_id[!is.na(observer_id) & nzchar(observer_id)]),
        observed_dates_json = as.character(toJSON(
          sort(unique(as.character(observed_on[!is.na(observed_on)]))), auto_unbox = TRUE
        )),
        observer_ids_json = as.character(toJSON(
          sort(unique(as.character(observer_id[!is.na(observer_id) & nzchar(observer_id)]))),
          auto_unbox = TRUE
        )),
        weighted_observation_effort = sum(observation_weight, na.rm = TRUE),
        has_structured_survey = any(observation_source == "structured_survey", na.rm = TRUE),
        weekend_obs = sum(is_weekend, na.rm = TRUE),
        weekday_obs = sum(!is_weekend & !is.na(observed_on), na.rm = TRUE),
        weekend_only = weekend_obs > 0L & weekday_obs == 0L,
        temporal_bias_flag = weekend_only,
        .groups = "drop"
      )

    if (nrow(obs_joined) > 0L) {
      species_matrix <- obs_joined |>
        st_drop_geometry() |>
        count(cell_id, taxon_name) |>
        pivot_wider(names_from = taxon_name, values_from = n, values_fill = 0) |>
        column_to_rownames("cell_id")
      shannon <- vegan::diversity(species_matrix, index = "shannon")
      diversity_df <- tibble(cell_id = rownames(species_matrix), species_shannon = shannon)
    } else {
      diversity_df <- tibble(cell_id = character(), species_shannon = numeric())
    }

    taxon_counts <- obs_joined |>
      st_drop_geometry() |>
      mutate(taxon_group = classify_taxon_group(iconic_taxon_name)) |>
      filter(!is.na(taxon_group)) |>
      group_by(cell_id, taxon_group) |>
      summarise(count = n_distinct(taxon_name), .groups = "drop") |>
      pivot_wider(names_from = taxon_group, values_from = count, values_fill = 0)
    for (col in c("plant", "bird", "insect", "mammal", "fungi")) {
      if (!col %in% names(taxon_counts)) taxon_counts[[col]] <- 0L
    }

    grid <- grid |>
      left_join(richness, by = "cell_id") |>
      left_join(diversity_df, by = "cell_id") |>
      left_join(taxon_counts, by = "cell_id")
  }

  for (col in names(obs_defaults)) {
    if (!col %in% names(grid)) grid[[col]] <- obs_defaults[[col]]
  }

  # ── Keep core cells only ──────────────────────────────────────────────────
  core_out <- filter_core_cells(grid, core_local) |>
    mutate(tile_id = tile_id)

  message(sprintf("[tile %s] done %s (%d core cells)", tile_id, format(Sys.time(), "%H:%M:%S"), nrow(core_out)))
  core_out
}

`%||%` <- function(x, y) if (is.null(x)) y else x

finish_citywide_metrics <- function(grid) {
  grid$lst_rank <- percent_rank01(grid$lst_celsius)
  grid$lst_idx <- 1 - grid$lst_rank
  grid$heat_exposure <- grid$lst_rank

  grid <- grid |>
    mutate(
      noise = rescale01(
        0.55 * rescale01(road_density) +
          0.20 * rescale01(road_proximity) +
          0.20 * rescale01(rail_density) +
          0.05 * rescale01(rail_proximity)
      ),
      light_pollution = rescale01(
        0.50 * rescale01(lamp_density) +
          0.30 * rescale01(lamp_proximity) +
          0.20 * rescale01(lit_road_density)
      ),
      osm_disturbance_idx = rescale01(
        0.60 * rescale01(path_density) +
          0.40 * rescale01(amenity_proximity)
      ),
      disturbance_idx = osm_disturbance_idx,
      disturbance_index = disturbance_idx,
      water_proximity = rescale01(
        0.70 * water_prox +
          0.30 * permeable_fraction
      ),
      habitat_quality = 0.50 * replace_na(ndvi_idx, 0) +
        0.286 * replace_na(lst_idx, 0) +
        0.214 * (1 - replace_na(disturbance_idx, 1)),
      path_km = replace_na(path_km, 0),
      path_local_m = replace_na(path_local_m, 0),
      # MIN_PATH_M, not the tile-local min_path_m: this runs city-wide in the
      # main session after bind_rows(), outside process_tile()'s cfg scope.
      is_unsampled = replace_na(path_local_m < MIN_PATH_M, TRUE),
      # log1p() of a length in metres. Taking log1p(path_km) here made the log
      # inert — a 20 m hex carries 0.002–0.04 km of path, and log1p(x) ≈ x that
      # close to zero, so correction degenerated into dividing richness by a
      # near-zero denominator and produced richness values in the tens of
      # thousands against an expected richness of ~20.
      survey_effort_units = if_else(is_unsampled, NA_real_, log1p(path_local_m)),
      effort_corrected_richness = if_else(
        is_unsampled,
        NA_real_,
        replace_na(species_richness, 0) / survey_effort_units
      ),
      observed_richness = effort_corrected_richness,
      richness_corrected = effort_corrected_richness,
      raw_species_count = if_else(is_unsampled, NA_real_, replace_na(raw_species_count, 0)),
      species_richness = if_else(is_unsampled, NA_real_, replace_na(species_richness, 0)),
      n_obs = replace_na(n_obs, 0L),
      n_survey_dates = replace_na(n_survey_dates, 0L),
      n_observers = replace_na(n_observers, 0L),
      observed_dates_json = replace_na(observed_dates_json, "[]"),
      observer_ids_json = replace_na(observer_ids_json, "[]"),
      weighted_observation_effort = replace_na(weighted_observation_effort, 0),
      has_structured_survey = replace_na(has_structured_survey, FALSE),
      weekend_obs = replace_na(weekend_obs, 0L),
      weekday_obs = replace_na(weekday_obs, 0L),
      weekend_only = replace_na(weekend_only, FALSE),
      temporal_bias_flag = replace_na(temporal_bias_flag, FALSE),
      plant = replace_na(plant, 0L),
      bird = replace_na(bird, 0L),
      insect = replace_na(insect, 0L),
      mammal = replace_na(mammal, 0L),
      fungi = replace_na(fungi, 0L)
    ) |>
    select(-any_of(c(
      "road_density", "rail_density", "road_proximity", "rail_proximity",
      "lamp_density", "lamp_proximity", "lit_road_density", "path_density",
      "amenity_proximity", "water_prox", "permeable_fraction"
    )))

  coords <- st_coordinates(suppressWarnings(st_centroid(grid)))
  grid <- grid[order(coords[, 2], coords[, 1]), ]
  grid$cell_id <- seq_len(nrow(grid))
  grid
}

load_obs_for_tiling <- function(crs_local) {
  read_std <- function(path, source_name, mapper) {
    if (!file.exists(path)) {
      return(st_sf(
        taxon_name = character(), iconic_taxon_name = character(),
        observed_on = as.Date(character()), common_label = character(),
        observation_source = character(), observation_weight = numeric(),
        observer_id = character(), geometry = st_sfc(crs = crs_local)
      ))
    }
    raw <- st_read(path, quiet = TRUE)
    if (nrow(raw) == 0L) return(mapper(raw))
    mapper(raw)
  }

  inat_std <- read_std(RAW_INAT, "inat", function(raw) {
    if (!"common_name" %in% names(raw)) raw$common_name <- rep(NA_character_, nrow(raw))
    if (!"user.login" %in% names(raw)) raw[["user.login"]] <- rep(NA_character_, nrow(raw))
    raw |>
      st_transform(crs_local) |>
      mutate(
        taxon_name = scientific_name,
        observed_on = as_date(observed_on),
        common_label = as.character(common_name),
        observation_source = "inat",
        observation_weight = 1,
        observer_id = as.character(.data[["user.login"]])
      ) |>
      select(taxon_name, iconic_taxon_name, observed_on, common_label,
             observation_source, observation_weight, observer_id)
  })

  gbif_std <- read_std(RAW_GBIF, "gbif", function(raw) {
    if (!"vernacularName" %in% names(raw)) raw$vernacularName <- rep(NA_character_, nrow(raw))
    if (!"class" %in% names(raw)) raw$class <- rep(NA_character_, nrow(raw))
    if (!"recordedBy" %in% names(raw)) raw$recordedBy <- rep(NA_character_, nrow(raw))
    raw |>
      st_transform(crs_local) |>
      mutate(
        taxon_name = species,
        iconic_taxon_name = class,
        observed_on = as_date(parse_date_time(eventDate, orders = c("Ymd", "Ymd HMS", "Ymd HMSz"), quiet = TRUE)),
        common_label = as.character(vernacularName),
        observation_source = "gbif",
        observation_weight = 1,
        observer_id = as.character(recordedBy)
      ) |>
      select(taxon_name, iconic_taxon_name, observed_on, common_label,
             observation_source, observation_weight, observer_id)
  })

  supabase_observations_enabled <- identical(Sys.getenv("SUPABASE_OBSERVATIONS_ENABLED", unset = "0"), "1") ||
    identical(Sys.getenv("SUPABASE_OBSERVATIONS_REQUIRED", unset = "0"), "1")
  supabase_path <- if (exists("RAW_SUPABASE_OBS")) RAW_SUPABASE_OBS else NA_character_
  supabase_std <- if (
    supabase_observations_enabled &&
    is.character(supabase_path) &&
    file.exists(supabase_path)
  ) {
    raw <- st_read(supabase_path, quiet = TRUE)
    if (!"observer_id" %in% names(raw)) raw$observer_id <- rep(NA_character_, nrow(raw))
    raw |>
      st_transform(crs_local) |>
      mutate(
        taxon_name = as.character(taxon_name),
        iconic_taxon_name = as.character(iconic_taxon_name),
        observed_on = as_date(observed_on),
        common_label = as.character(common_label),
        observation_source = as.character(observation_source),
        observation_weight = case_when(
          observation_source == "structured_survey" ~ 3,
          observation_source == "quick_sighting" ~ 0,
          is.na(observation_weight) ~ 1,
          TRUE ~ as.numeric(observation_weight)
        ),
        observer_id = as.character(observer_id)
      ) |>
      select(taxon_name, iconic_taxon_name, observed_on, common_label,
             observation_source, observation_weight, observer_id)
  } else {
    st_sf(
      taxon_name = character(), iconic_taxon_name = character(),
      observed_on = as.Date(character()), common_label = character(),
      observation_source = character(), observation_weight = numeric(),
      observer_id = character(), geometry = st_sfc(crs = crs_local)
    )
  }

  bind_rows(inat_std, gbif_std, supabase_std) |>
    filter(!is.na(taxon_name)) |>
    mutate(observation_weight = replace_na(observation_weight, 1))
}

.tiled_cache <- new.env(parent = emptyenv())

run_tiled_processing <- function(force = FALSE) {
  cache_path <- file.path(DATA_PROC, "tiled_combined.rds")
  if (!force && exists("combined", envir = .tiled_cache, inherits = FALSE)) {
    return(get("combined", envir = .tiled_cache))
  }
  if (!force && file.exists(cache_path)) {
    message("[tile_processing] Loading cached combined tiles: ", cache_path)
    combined <- readRDS(cache_path)
    assign("combined", combined, envir = .tiled_cache)
    return(combined)
  }

  tiles_dir <- file.path(PIPELINE_ROOT, "data", "tiles", city)
  core_path <- file.path(tiles_dir, "core_tiles.gpkg")
  if (!file.exists(core_path)) {
    stop("core_tiles.gpkg not found — run tile_registry.R first.", call. = FALSE)
  }

  core_tiles <- st_read(core_path, quiet = TRUE) |> st_transform(CRS_LOCAL)
  pbf_paths <- file.path(tiles_dir, paste0(core_tiles$tile_id, ".osm.pbf"))
  missing_pbfs <- pbf_paths[!file.exists(pbf_paths)]
  if (length(missing_pbfs) > 0L) {
    stop(
      "Missing tile PBF(s): ", paste(basename(missing_pbfs), collapse = ", "),
      " — run tile_registry.R first.",
      call. = FALSE
    )
  }

  cfg <- list(
    CRS_LOCAL = CRS_LOCAL,
    CELL_SIZE = CELL_SIZE,
    halo_m = halo_m,
    HEX_GRID_ORIGIN = HEX_GRID_ORIGIN,
    PATH_RADIUS_M = PATH_RADIUS_M,
    MIN_PATH_M = MIN_PATH_M,
    RAW_LANDCOVER = RAW_LANDCOVER,
    RAW_IMPERVIOUS = RAW_IMPERVIOUS,
    RAW_NDVI = RAW_NDVI,
    RAW_CIR_NDVI = if (exists("RAW_CIR_NDVI")) RAW_CIR_NDVI else NA_character_,
    RAW_VEG_FRACTION = if (exists("RAW_VEG_FRACTION")) RAW_VEG_FRACTION else NA_character_,
    CIR_VEG_NDVI_THRESHOLD = if (exists("CIR_VEG_NDVI_THRESHOLD")) CIR_VEG_NDVI_THRESHOLD else 0.2,
    RAW_LST = RAW_LST,
    CANOPY_HEIGHT_FILE = if (exists("CANOPY_HEIGHT_FILE")) CANOPY_HEIGHT_FILE else NA_character_,
    CANOPY_LOCAL_PATH = NA_character_
  )

  canopy_path <- cfg$CANOPY_HEIGHT_FILE
  if (is.character(canopy_path) && !is.na(canopy_path) && file.exists(canopy_path)) {
    canopy_local_path <- file.path(DATA_PROC, "canopy_height_local.tif")
    cfg$CANOPY_LOCAL_PATH <- canopy_local_path
    message("[tile_processing] Pre-projecting canopy height once for all tiles…")
    t0 <- proc.time()
    if (!file.exists(canopy_local_path)) {
      writeRaster(
        project(rast(canopy_path), CRS_LOCAL, method = "bilinear"),
        canopy_local_path,
        overwrite = TRUE,
        gdal = c("TILED=YES", "BLOCKXSIZE=256", "BLOCKYSIZE=256", "COMPRESS=DEFLATE")
      )
    } else {
      message("[tile_processing] Reusing cached ", basename(canopy_local_path))
    }
    message(sprintf(
      "[tile_processing] Canopy ready in %.1f s",
      (proc.time() - t0)[["elapsed"]]
    ))
  }

  obs_all <- load_obs_for_tiling(CRS_LOCAL)
  obs_list <- lapply(seq_len(nrow(core_tiles)), function(i) {
    halo_bb <- st_buffer(core_tiles[i, ], dist = halo_m)
    if (nrow(obs_all) == 0L) return(obs_all)
    obs_all[st_intersects(obs_all, halo_bb, sparse = FALSE)[, 1L], , drop = FALSE]
  })

  workers <- suppressWarnings(as.integer(Sys.getenv("TILED_WORKERS", unset = "")))
  if (is.na(workers) || workers < 1L) {
    workers <- max(1L, parallel::detectCores() - 1L)
    canopy_active <- is.character(cfg$CANOPY_LOCAL_PATH) && !is.na(cfg$CANOPY_LOCAL_PATH)
    if (canopy_active) {
      # Memory-safety cap when large pre-projected rasters are in play —
      # scales with available cores instead of a hard 4, so this doesn't
      # needlessly throttle machines with more headroom. Was previously
      # checking !is.null(cfg$CANOPY_LOCAL_PATH), which is always TRUE (the
      # unset default is NA_character_, not NULL) — so this cap silently
      # applied on every run regardless of whether canopy was even in use.
      workers <- min(workers, max(6L, parallel::detectCores() %/% 2L))
    }
  }
  message(sprintf("[tile_processing] Processing %d tiles with %d workers…", nrow(core_tiles), workers))
  plan(multisession, workers = workers)

  core_list <- lapply(seq_len(nrow(core_tiles)), function(i) core_tiles[i, , drop = FALSE])

  tile_results <- future_map2(
    core_list,
    obs_list,
    function(core_row, obs_tile) {
      pbf <- file.path(tiles_dir, paste0(core_row$tile_id[[1L]], ".osm.pbf"))
      process_tile(core_row, pbf, obs_tile = obs_tile, cfg = cfg)
    },
    .options = furrr_options(seed = TRUE)
  )

  combined <- bind_rows(tile_results)
  combined <- finish_citywide_metrics(combined)

  assign("combined", combined, envir = .tiled_cache)
  assign("obs_all", obs_all, envir = .tiled_cache)
  saveRDS(combined, cache_path)
  saveRDS(obs_all, file.path(DATA_PROC, "tiled_obs_all.rds"))

  message(sprintf("[tile_processing] Combined %d core hex cells", nrow(combined)))
  combined
}

get_tiled_results <- function(force = FALSE) {
  run_tiled_processing(force = force)
}

get_tiled_obs <- function() {
  cache_path <- file.path(DATA_PROC, "tiled_obs_all.rds")
  if (exists("obs_all", envir = .tiled_cache, inherits = FALSE)) {
    return(get("obs_all", envir = .tiled_cache))
  }
  if (file.exists(cache_path)) {
    return(readRDS(cache_path))
  }
  run_tiled_processing()
  if (file.exists(cache_path)) readRDS(cache_path) else get("obs_all", envir = .tiled_cache)
}

build_cell_taxa_json <- function(grid, obs_all) {
  format_taxon_label <- function(scientific, common) {
    sci <- as.character(scientific)
    com <- as.character(common)
    com <- com[!is.na(com) & nzchar(com)]
    if (length(com) > 0L) return(paste0(com[1], " (", sci, ")"))
    sci
  }

  if (nrow(obs_all) == 0L || nrow(grid) == 0L) {
    write_json(list(), PROC_CELL_TAXA, auto_unbox = TRUE, null = "null")
    return(invisible(list()))
  }

  grid_centroids <- suppressWarnings(st_centroid(grid))
  nearest_idx <- st_nearest_feature(obs_all, grid_centroids)
  obs_joined <- obs_all |>
    mutate(cell_id = grid$cell_id[nearest_idx]) |>
    filter(!is.na(taxon_name))

  cell_taxa_rows <- obs_joined |>
    st_drop_geometry() |>
    mutate(taxon_group = classify_taxon_group(iconic_taxon_name)) |>
    filter(!is.na(taxon_group), nzchar(taxon_name)) |>
    group_by(cell_id, taxon_group, taxon_name) |>
    summarise(common_label = dplyr::first(na.omit(common_label)), .groups = "drop") |>
    rowwise() |>
    mutate(label = format_taxon_label(taxon_name, common_label)) |>
    ungroup() |>
    group_by(cell_id, taxon_group) |>
    summarise(names = list(sort(unique(label))), .groups = "drop") |>
    pivot_wider(names_from = taxon_group, values_from = names, values_fill = list(list()))

  for (col in c("plant", "bird", "insect", "mammal", "fungi")) {
    if (!col %in% names(cell_taxa_rows)) cell_taxa_rows[[col]] <- list()
  }

  cell_taxa_out <- stats::setNames(
    lapply(seq_len(nrow(cell_taxa_rows)), function(i) {
      row <- cell_taxa_rows[i, ]
      stats::setNames(
        lapply(c("plant", "bird", "insect", "mammal", "fungi"), function(group) {
          val <- row[[group]][[1]]
          if (is.null(val) || length(val) == 0L) list() else as.list(as.character(unlist(val)))
        }),
        c("plant", "bird", "insect", "mammal", "fungi")
      )
    }),
    as.character(cell_taxa_rows$cell_id)
  )

  write_json(cell_taxa_out, PROC_CELL_TAXA, auto_unbox = TRUE, null = "null")
  cell_taxa_out
}
