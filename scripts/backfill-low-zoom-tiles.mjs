#!/usr/bin/env node
/**
 * Extends an existing hexgrid.pmtiles archive downward to a lower minimum zoom.
 *
 * Why this exists: the hexgrid archives were built with `--minimum-zoom 14`
 * (pipeline/06_export/export.R), so MapLibre had no analytical tiles at
 * city/region zoom and the map fell back to drawing OSM park polygons — a
 * different geometry answering a different question. export.R now emits zoom 11
 * directly, but re-running the full R pipeline just to retile already-exported
 * cities is not worth it, so this backfills the low zooms from the archive
 * itself.
 *
 * This is a cartographic level-of-detail addition and nothing more. Every cell
 * keeps the exact attribute values it already had — the low zooms are built from
 * the archive's own z14 features, and the existing z14-18 tiles are copied
 * through byte-for-byte by tile-join. No value is recomputed, aggregated or
 * averaged, and no cell is dropped.
 *
 * Usage: node scripts/backfill-low-zoom-tiles.mjs <city-dir> [--min-zoom 11]
 */

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, statSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const DEFAULT_MIN_ZOOM = 11;
/** The zoom the archives are currently cut at — also the level we decode from. */
const SOURCE_ZOOM = 14;

function need(bin) {
  try { execFileSync('which', [bin], { stdio: 'pipe' }); }
  catch { throw new Error(`${bin} is required and was not found on PATH.`); }
}

/** PMTiles v3 header: min/max zoom are single bytes at offsets 100/101. */
function zoomRange(path) {
  const b = readFileSync(path, { flag: 'r' }).subarray(0, 127);
  return { min: b.readUInt8(100), max: b.readUInt8(101) };
}

/**
 * Decode one zoom level and keep one copy of each cell.
 *
 * Tiles carry a buffer, so a cell near a tile edge is emitted more than once —
 * clipped in the tile it overhangs, whole in its neighbour. The largest-area
 * copy is the intact hexagon, and because the buffer is wider than a 20 m cell
 * an intact copy always exists.
 */
function decodeUniqueCells(archive, zoom) {
  const raw = execFileSync('tippecanoe-decode', ['-z', String(zoom), '-Z', String(zoom), archive], {
    maxBuffer: 1 << 30, stdio: ['ignore', 'pipe', 'ignore'],
  }).toString('utf8');

  const ringArea = (ring) => {
    let a = 0;
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      a += ring[j][0] * ring[i][1] - ring[i][0] * ring[j][1];
    }
    return Math.abs(a / 2);
  };

  const best = new Map();
  let seen = 0;
  for (const tile of JSON.parse(raw).features) {
    for (const layer of tile.features) {
      for (const feature of layer.features) {
        seen++;
        const id = feature.properties?.cellId;
        if (!id || feature.geometry?.type !== 'Polygon') continue;
        const area = ringArea(feature.geometry.coordinates[0]);
        const current = best.get(id);
        if (!current || area > current.area) best.set(id, { area, feature });
      }
    }
  }
  return { features: [...best.values()].map((v) => v.feature), seen };
}

function main() {
  const [cityDir, ...rest] = process.argv.slice(2);
  if (!cityDir) throw new Error('Usage: node scripts/backfill-low-zoom-tiles.mjs <city-dir> [--min-zoom N]');
  const minZoomArg = rest.indexOf('--min-zoom');
  const minZoom = minZoomArg === -1 ? DEFAULT_MIN_ZOOM : Number(rest[minZoomArg + 1]);

  for (const bin of ['tippecanoe', 'tippecanoe-decode', 'tile-join']) need(bin);

  const archive = join(cityDir, 'hexgrid.pmtiles');
  const before = zoomRange(archive);
  if (before.min <= minZoom) {
    console.log(`${cityDir}: already starts at z${before.min}, nothing to do.`);
    return;
  }
  if (before.min !== SOURCE_ZOOM) {
    throw new Error(`${archive}: expected minzoom ${SOURCE_ZOOM}, found ${before.min}.`);
  }

  const work = mkdtempSync(join(tmpdir(), 'ng-lod-'));
  try {
    const { features, seen } = decodeUniqueCells(archive, SOURCE_ZOOM);
    const source = join(work, 'cells.geojson');
    writeFileSync(source, JSON.stringify({ type: 'FeatureCollection', features }));

    const low = join(work, 'low.pmtiles');
    execFileSync('tippecanoe', [
      '--output', low, '--layer', 'hexgrid', '--force',
      '--no-feature-limit', '--no-tile-size-limit',
      // Every cell must survive to the lowest zoom: dropping sub-pixel cells
      // would punch holes in what has to read as a continuous surface.
      '--no-tiny-polygon-reduction',
      '--minimum-zoom', String(minZoom),
      '--maximum-zoom', String(SOURCE_ZOOM - 1),
      source,
    ], { stdio: ['ignore', 'ignore', 'pipe'] });

    const merged = join(work, 'merged.pmtiles');
    execFileSync('tile-join', [
      '--output', merged, '--force', '--no-tile-size-limit', low, archive,
    ], { stdio: ['ignore', 'ignore', 'pipe'] });

    const after = zoomRange(merged);
    if (after.min !== minZoom || after.max !== before.max) {
      throw new Error(`merged archive has z${after.min}-${after.max}, expected z${minZoom}-${before.max}`);
    }

    const sizeBefore = statSync(archive).size, sizeAfter = statSync(merged).size;
    copyFileSync(merged, archive);
    console.log(
      `${cityDir}: z${before.min}-${before.max} → z${after.min}-${after.max}, `
      + `${features.length} cells (${seen} decoded incl. tile-buffer copies), `
      + `${(sizeBefore / 1048576).toFixed(1)}MB → ${(sizeAfter / 1048576).toFixed(1)}MB`,
    );
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

main();
