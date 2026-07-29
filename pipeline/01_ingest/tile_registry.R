# NatureGap — Tile registry + halo generation for osmium regional extract
#
# Builds core tiles clipped to the AOI, buffers each by halo_m, writes halo
# GeoJSONs, generates osmium batch config(s), and runs osmium extract.
#
# Usage:
#   source("pipeline/config_porto.R")
#   source("pipeline/01_ingest/tile_registry.R")

library(sf)
library(jsonlite)
library(dplyr)
library(here)

if (!exists("CONFIG_LOADED")) source(here::here("config.R"))

required_cfg <- c("aoi", "city", "halo_m", "tile_size_m", "regional_pbf", "CRS_LOCAL", "PIPELINE_ROOT")
missing_cfg <- required_cfg[!vapply(required_cfg, exists, logical(1L))]
if (length(missing_cfg) > 0L) {
  stop(
    "Missing config: ", paste(missing_cfg, collapse = ", "),
    ". Source a city config (e.g. config_porto.R) first.",
    call. = FALSE
  )
}

OSMIUM_MAX_EXTRACTS <- 500L

TILES_DIR <- file.path(PIPELINE_ROOT, "data", "tiles", city)
HALOS_DIR <- file.path(TILES_DIR, "halos")
dir.create(HALOS_DIR, recursive = TRUE, showWarnings = FALSE)

tile_id_label <- function(index) {
  sprintf("tile_%04d", as.integer(index))
}

build_core_tiles <- function(aoi_wgs84, tile_size_m, crs_local) {
  aoi_local <- st_transform(aoi_wgs84, crs_local)
  aoi_local <- st_make_valid(aoi_local)
  if (nrow(aoi_local) > 1L) {
    aoi_local <- st_sf(geometry = st_make_valid(st_union(st_geometry(aoi_local))))
  }

  grid <- st_make_grid(
    st_as_sfc(st_bbox(aoi_local), crs = crs_local),
    cellsize = tile_size_m,
    square = TRUE
  ) |>
    st_as_sf() |>
    mutate(cell_idx = row_number())

  centroids <- suppressWarnings(st_point_on_surface(grid))
  coords <- st_coordinates(centroids)
  grid <- grid |>
    arrange(coords[, 2], coords[, 1]) |>
    mutate(
      cell_idx = row_number(),
      tile_id = tile_id_label(cell_idx)
    )

  core <- suppressWarnings(st_intersection(grid[, c("cell_idx", "tile_id")], aoi_local))
  core <- core[as.numeric(st_area(core)) > 1, ]

  if (nrow(core) == 0L) {
    stop("No core tiles intersect the AOI — check aoi and tile_size_m.", call. = FALSE)
  }

  core$core_area_m2 <- as.numeric(st_area(core))
  core |>
    arrange(tile_id)
}

build_halo_tiles <- function(core_local, halo_m) {
  halos <- st_buffer(core_local, dist = halo_m)
  halos |>
    st_sf(
      cell_idx = core_local$cell_idx,
      tile_id = core_local$tile_id,
      core_area_m2 = core_local$core_area_m2,
      halo_area_m2 = as.numeric(st_area(halos)),
      geometry = st_geometry(halos)
    )
}

write_halo_geojsons <- function(halos_local, halos_dir, crs_local) {
  halos_wgs84 <- st_transform(halos_local, 4326)
  vapply(seq_len(nrow(halos_wgs84)), function(i) {
    out_path <- file.path(halos_dir, paste0(halos_wgs84$tile_id[[i]], "_halo.geojson"))
    st_write(halos_wgs84[i, "tile_id", drop = FALSE], out_path, delete_dsn = TRUE, quiet = TRUE)
    out_path
  }, character(1L))
}

make_extract_entries <- function(tile_ids) {
  lapply(tile_ids, function(tile_id) {
    list(
      output = paste0(tile_id, ".osm.pbf"),
      polygon = list(
        file_name = file.path("halos", paste0(tile_id, "_halo.geojson")),
        file_type = "geojson"
      )
    )
  })
}

write_extract_configs <- function(extracts, tiles_dir, pipeline_root, max_per_batch = OSMIUM_MAX_EXTRACTS) {
  batches <- split(extracts, ceiling(seq_along(extracts) / max_per_batch))
  rel_directory <- gsub("\\\\", "/", sub(
    paste0("^", gsub("\\\\", "/", pipeline_root), "/?"),
    "",
    gsub("\\\\", "/", tiles_dir)
  ))
  if (!endsWith(rel_directory, "/")) rel_directory <- paste0(rel_directory, "/")

  config_paths <- character(length(batches))
  for (i in seq_along(batches)) {
    config_path <- if (length(batches) == 1L) {
      file.path(tiles_dir, "extracts.json")
    } else {
      file.path(tiles_dir, sprintf("extracts_batch_%03d.json", i))
    }
    config_paths[[i]] <- config_path
    write_json(
      list(
        directory = rel_directory,
        extracts = batches[[i]]
      ),
      config_path,
      auto_unbox = TRUE,
      pretty = TRUE
    )
  }
  config_paths
}

run_osmium_extracts <- function(config_paths, regional_pbf) {
  if (!nzchar(Sys.which("osmium"))) {
    stop("osmium tool not found on PATH — install osmium-tool first.", call. = FALSE)
  }
  if (!file.exists(regional_pbf)) {
    stop("regional_pbf not found: ", regional_pbf, call. = FALSE)
  }

  # status_codes <- vapply(config_paths, function(config_path) {
  #   message("[tile_registry] osmium extract -c ", config_path)
  #   result <- system2(
  #     "osmium",
  #     c("extract", "-v", "-c", config_path, "-S", "smart", regional_pbf),
  #     stdout = TRUE,
  #     stderr = TRUE,
  #     wd = PIPELINE_ROOT
  #   )
  #   exit_code <- attr(result, "status")
  #   if (!is.null(exit_code) && exit_code != 0L) {
  #     stop(
  #       "osmium extract failed for ", config_path, " (exit ", exit_code, ")\n",
  #       paste(result, collapse = "\n"),
  #       call. = FALSE
  #     )
  #   }
  #   0L
  # }, integer(1L))


  status_codes <- vapply(config_paths, function(config_path) {
    message("[tile_registry] osmium extract -c ", config_path)

    # Run system2 inside PIPELINE_ROOT using withr
    result <- withr::with_dir(PIPELINE_ROOT, {
      system2(
        "osmium",
        c("extract", "-v", "-O", "-c", config_path, "-S", "smart", regional_pbf),
        stdout = TRUE,
        stderr = TRUE
      )
    })

    # Return exit status (0 for success, non-zero attribute for error)
    status <- attr(result, "status")
    if (is.null(status)) 0L else status
  }, integer(1))


  invisible(status_codes)
}

message("[tile_registry] Building core tiles (", tile_size_m, " m) clipped to AOI…")
core_tiles <- build_core_tiles(aoi, tile_size_m, CRS_LOCAL)
message(sprintf("[tile_registry] %d core tiles", nrow(core_tiles)))

halo_tiles <- build_halo_tiles(core_tiles, halo_m)
message(sprintf("[tile_registry] Buffered cores by %d m halo", halo_m))

halo_paths <- write_halo_geojsons(halo_tiles, HALOS_DIR, CRS_LOCAL)
message(sprintf("[tile_registry] Wrote %d halo GeoJSONs to %s", length(halo_paths), HALOS_DIR))

registry_path <- file.path(TILES_DIR, "tile_registry.gpkg")
st_write(
  halo_tiles |> select(tile_id, cell_idx, core_area_m2, halo_area_m2),
  registry_path,
  delete_dsn = TRUE,
  quiet = TRUE
)
message("[tile_registry] Wrote registry: ", registry_path)

core_registry_path <- file.path(TILES_DIR, "core_tiles.gpkg")
st_write(
  core_tiles |> select(tile_id, cell_idx, core_area_m2),
  core_registry_path,
  delete_dsn = TRUE,
  quiet = TRUE
)
message("[tile_registry] Wrote core tiles: ", core_registry_path)

extracts <- make_extract_entries(halo_tiles$tile_id)
config_paths <- write_extract_configs(extracts, TILES_DIR, PIPELINE_ROOT)
message(sprintf(
  "[tile_registry] Wrote %d osmium config(s): %s",
  length(config_paths),
  paste(basename(config_paths), collapse = ", ")
))

if (nrow(halo_tiles) > OSMIUM_MAX_EXTRACTS) {
  message(sprintf(
    "[tile_registry] %d tiles exceed osmium batch limit (%d) — split into %d config(s)",
    nrow(halo_tiles),
    OSMIUM_MAX_EXTRACTS,
    length(config_paths)
  ))
}

run_osmium_extracts(config_paths, regional_pbf)
message("[tile_registry] Done — tiles in ", TILES_DIR)
