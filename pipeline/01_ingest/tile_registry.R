# NatureGap — Tile registry + halo generation for osmium regional extract
#
# Builds core tiles clipped to the AOI, buffers each by halo_m, writes halo
# GeoJSONs, generates osmium batch config(s), and runs osmium extract.
#
# Usage:
#   CITY <- "porto-center"; source("pipeline/config.R")
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
    ". Load a city first: CITY <- \"porto-center\"; source(\"config.R\").",
    call. = FALSE
  )
}

# osmium extract allocates a node-ID index per extract listed in the config and
# holds every one of them for the whole run, so peak memory grows with the
# number of extracts in a single invocation. Measured with `/usr/bin/time -l`,
# cutting Amsterdam tile halos out of noord-holland-latest.osm.pbf (188 MB) on a
# 16 GB machine:
#
#     extracts   peak footprint   wall
#            1           2.6 GB    1.1 s
#            2           6.1 GB    1.6 s
#            4          12.7 GB    3.9 s
#            8          25.4 GB    9.9 s
#
# ~3 GB per extract, and it is not a function of the input: a single extract out
# of a 4 MB tile PBF still peaks at 3.6 GB. The index is sized by the OSM
# node-ID space, which a city-sized file spans as sparsely as a regional one, so
# pre-clipping the PBF to the AOI would not buy anything.
#
# One extract per invocation is therefore the only setting that stays inside RAM
# -- and it is also the fastest, because a pass over the regional PBF is cheap
# (~1 s) while the memory is not. The 31 tiles of the 4-relation Amsterdam AOI
# rebuild in 35 s at a flat 3.8 GB peak. Batching them 8 at a time asks for
# 25 GB on a 16 GB machine: it completes, but only by swapping, and that
# swapping was the slowness this replaced.
#
# Verified equivalent: all 31 tiles built one-per-invocation are byte-identical
# to the same tiles built in batches of 8.
OSMIUM_MAX_EXTRACTS <- 1L

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

# Tile IDs come from the position of each cell in a grid laid over the AOI's
# bounding box, so changing the AOI renumbers them: a tile_0006.osm.pbf from a
# previous, differently-sized AOI describes different ground than tile_0006 does
# now. connectivity_load.R globs every .osm.pbf in this directory rather than
# reading the registry, so leftovers from an earlier AOI would be read as if
# they belonged to the current grid. Remove the ones the current grid does not
# claim. These are derived artefacts, rebuilt from the regional PBF on demand --
# no source data is touched -- and every removal is logged.
prune_stale_tile_files <- function(tile_ids, tiles_dir, halos_dir) {
  pbfs <- list.files(tiles_dir, pattern = "^tile_[0-9]+\\.osm\\.pbf$", full.names = TRUE)
  stale_pbfs <- pbfs[!sub("\\.osm\\.pbf$", "", basename(pbfs)) %in% tile_ids]

  halos <- list.files(halos_dir, pattern = "^tile_[0-9]+_halo\\.geojson$", full.names = TRUE)
  stale_halos <- halos[!sub("_halo\\.geojson$", "", basename(halos)) %in% tile_ids]

  stale <- c(stale_pbfs, stale_halos)
  if (length(stale) == 0L) return(invisible(character(0)))

  message(sprintf(
    "[tile_registry] Removing %d file(s) left by a previous AOI (%d tile extract(s), %d halo(s)): %s",
    length(stale), length(stale_pbfs), length(stale_halos),
    paste(basename(stale), collapse = ", ")
  ))
  unlink(stale)
  invisible(stale)
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

  # A previous run with a different tile count leaves its own configs behind --
  # extracts.json from a single-batch run, or a longer extracts_batch_*.json
  # series. They are not read (config_paths drives the run) but they misreport
  # what was built, so clear the set before writing the current one.
  existing <- list.files(
    tiles_dir,
    pattern = "^extracts(_batch_[0-9]+)?\\.json$",
    full.names = TRUE
  )
  if (length(existing) > 0L) unlink(existing)

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

extracts_in_config <- function(config_path) {
  n <- tryCatch(length(jsonlite::fromJSON(config_path, simplifyVector = FALSE)$extracts),
                error = function(e) NA_integer_)
  if (is.null(n)) NA_integer_ else n
}

# osmium creates every output file up front and only fills them during the
# passes, so a run killed mid-pass leaves behind a full set of 0-byte .osm.pbf
# files. Exit status alone does not always catch that, and an empty tile is
# indistinguishable downstream from a tile with genuinely no OSM data.
empty_outputs <- function(config_path) {
  cfg <- tryCatch(jsonlite::fromJSON(config_path, simplifyVector = FALSE),
                  error = function(e) NULL)
  if (is.null(cfg)) return(character(0))
  outputs <- vapply(cfg$extracts, function(e) e$output, character(1L))
  paths <- file.path(dirname(config_path), outputs)
  outputs[file.exists(paths) & file.info(paths)$size == 0L]
}

run_osmium_extracts <- function(config_paths, regional_pbf) {
  if (!nzchar(Sys.which("osmium"))) {
    stop("osmium tool not found on PATH — install osmium-tool first.", call. = FALSE)
  }
  if (!file.exists(regional_pbf)) {
    stop("regional_pbf not found: ", regional_pbf, call. = FALSE)
  }

  status_codes <- vapply(seq_along(config_paths), function(i) {
    config_path <- config_paths[[i]]
    message(sprintf(
      "[tile_registry] osmium extract batch %d/%d (%d extract(s)) -c %s",
      i, length(config_paths), extracts_in_config(config_path), config_path
    ))

    # Run system2 inside PIPELINE_ROOT using withr
    result <- withr::with_dir(PIPELINE_ROOT, {
      system2(
        "osmium",
        # -s is --strategy; -S is --option (a strategy *option*). This was
        # "-S smart", which osmium warns about and ignores, so the effective
        # strategy has always been the default complete_ways. Stated explicitly
        # rather than switched to smart: smart costs slightly more memory
        # (25.2 vs 23.6 GB over 8 extracts) and completes relations too, which
        # would change what downstream stages read.
        c("extract", "-v", "-O", "-s", "complete_ways", "-c", config_path, regional_pbf),
        stdout = TRUE,
        stderr = TRUE
      )
    })

    # Return exit status (0 for success, non-zero attribute for error)
    status <- attr(result, "status")
    status <- if (is.null(status)) 0L else status

    # A batch that exits 0 but leaves 0-byte outputs has still failed.
    blank <- empty_outputs(config_path)
    if (status == 0L && length(blank) > 0L) {
      message(sprintf(
        "[tile_registry] osmium extract left %d of %d output(s) empty in %s: %s",
        length(blank), extracts_in_config(config_path), basename(config_path),
        paste(blank, collapse = ", ")
      ))
      status <- 1L
    }

    if (status != 0L) {
      message(
        "[tile_registry] osmium extract FAILED for ", config_path,
        " (exit ", status, "):\n", paste(result, collapse = "\n")
      )
    }
    status
  }, integer(1))

  failed <- config_paths[status_codes != 0L]
  if (length(failed) > 0L) {
    failed_tiles <- sum(vapply(failed, extracts_in_config, integer(1L)), na.rm = TRUE)
    total_tiles <- sum(vapply(config_paths, extracts_in_config, integer(1L)), na.rm = TRUE)
    stop(
      sprintf(
        "osmium extract failed for %d of %d batch(es), covering %d of %d tile(s): %s\nSee messages above for each batch's actual osmium error. Fix the underlying cause and re-run — a silent failure here means the affected tiles have no local .osm.pbf, and downstream steps (e.g. connectivity) will silently fall back to slower/less-consistent Overpass-sourced data instead of failing loudly.\nIf osmium was killed (exit 137) or left every output at 0 bytes, it ran out of memory: each extract needs ~3 GB and OSMIUM_MAX_EXTRACTS is %d, so lower it if it is above 1, otherwise free memory before re-running.",
        length(failed), length(config_paths), failed_tiles, total_tiles,
        paste(basename(failed), collapse = ", "), OSMIUM_MAX_EXTRACTS
      ),
      call. = FALSE
    )
  }

  invisible(status_codes)
}

message("[tile_registry] Building core tiles (", tile_size_m, " m) clipped to AOI…")
core_tiles <- build_core_tiles(aoi, tile_size_m, CRS_LOCAL)
message(sprintf("[tile_registry] %d core tiles", nrow(core_tiles)))

halo_tiles <- build_halo_tiles(core_tiles, halo_m)
message(sprintf("[tile_registry] Buffered cores by %d m halo", halo_m))

halo_paths <- write_halo_geojsons(halo_tiles, HALOS_DIR, CRS_LOCAL)
message(sprintf("[tile_registry] Wrote %d halo GeoJSONs to %s", length(halo_paths), HALOS_DIR))

prune_stale_tile_files(halo_tiles$tile_id, TILES_DIR, HALOS_DIR)

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
