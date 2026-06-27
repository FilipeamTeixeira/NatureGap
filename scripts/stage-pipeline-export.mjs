#!/usr/bin/env node
import { copyFile, mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, '..');

const REQUIRED_RENDER_FIELDS = [
  'cellId',
  'parkId',
  'parkName',
  'impactScore',
  'expectedRichness',
  'ecologicalResidual',
  'habitatQuality',
  'observedRichness',
  'corridorImportance',
  'treeCover',
  'heatExposure',
  'landUseGreen',
  'interventionRank',
];

function usage() {
  console.error(`Usage:
  npm run stage:pipeline-export -- --city yokohama-honmoku --version 20260627T120000Z

Options:
  --city <id>       City folder under pipeline/data/<city>/export
  --version <id>    Dataset version, format YYYYMMDDTHHMMSSZ
  --source <path>   Optional source export folder
`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = new Map();
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) usage();
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) usage();
    args.set(key.slice(2), value);
    i += 1;
  }
  return {
    city: args.get('city') ?? 'yokohama-honmoku',
    version: args.get('version'),
    source: args.get('source'),
  };
}

function assertVersion(version) {
  if (!version || !/^[0-9]{8}T[0-9]{6}Z$/.test(version)) {
    throw new Error('Missing or invalid --version. Expected YYYYMMDDTHHMMSSZ, for example 20260627T120000Z.');
  }
}

async function fileExists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

async function listExportFiles(sourceDir) {
  const names = await readdir(sourceDir);
  const wanted = names.filter((name) => (
    name === 'hexgrid.pmtiles'
    || name === 'parks.geojson'
    || name === 'park-stats.json'
    || name === 'cell_attributes.geojson'
    || name === 'cell_attributes.manifest.json'
    || name === 'top_interventions.json'
    || /^cell_attributes-part-[0-9]+\.(json|geojson)$/.test(name)
  ));
  if (!wanted.includes('hexgrid.pmtiles')) {
    throw new Error(`Missing required file: ${join(sourceDir, 'hexgrid.pmtiles')}`);
  }
  return wanted.sort();
}

async function validatePmtiles(pmtilesPath) {
  const validator = join(REPO_ROOT, 'pipeline', '06_export', 'validate_pmtiles.mjs');
  if (!existsSync(validator)) return null;

  const { stdout } = await execFileAsync(process.execPath, [
    validator,
    pmtilesPath,
    'hexgrid',
    ...REQUIRED_RENDER_FIELDS,
  ]);
  return JSON.parse(stdout);
}

async function maybeJson(path) {
  if (!await fileExists(path)) return null;
  return JSON.parse(await readFile(path, 'utf8'));
}

async function main() {
  const { city, version, source } = parseArgs(process.argv.slice(2));
  assertVersion(version);

  const sourceDir = resolve(REPO_ROOT, source ?? join('pipeline', 'data', city, 'export'));
  if (!await fileExists(sourceDir)) {
    throw new Error(`Source export folder does not exist: ${sourceDir}`);
  }

  const targetDir = join(REPO_ROOT, 'pipeline-export', city, version);
  const currentPath = join(REPO_ROOT, 'pipeline-export', city, 'current.json');
  await mkdir(targetDir, { recursive: true });

  const files = await listExportFiles(sourceDir);
  for (const file of files) {
    await copyFile(join(sourceDir, file), join(targetDir, file));
  }

  const pmtilesPath = join(targetDir, 'hexgrid.pmtiles');
  const validation = await validatePmtiles(pmtilesPath);
  const generatedAt = `${version.slice(0, 4)}-${version.slice(4, 6)}-${version.slice(6, 8)}T${version.slice(9, 11)}:${version.slice(11, 13)}:${version.slice(13, 15)}Z`;

  const fileEntries = {};
  for (const file of files) {
    const info = await stat(join(targetDir, file));
    fileEntries[file] = { path: file, bytes: info.size };
  }

  const cellAttributes = await maybeJson(join(targetDir, 'cell_attributes.geojson'));
  const parks = await maybeJson(join(targetDir, 'parks.geojson'));

  const manifest = {
    schemaVersion: 1,
    cityId: city,
    datasetId: version,
    dataVersion: version,
    generatedAt,
    sourceLayer: 'hexgrid',
    requiredRenderFields: REQUIRED_RENDER_FIELDS,
    counts: {
      cells: Array.isArray(cellAttributes?.features) ? cellAttributes.features.length : null,
      parks: Array.isArray(parks?.features) ? parks.features.length : null,
    },
    pmtiles: {
      path: 'hexgrid.pmtiles',
      sourceLayer: 'hexgrid',
      minZoom: validation?.minZoom ?? null,
      maxZoom: validation?.maxZoom ?? null,
      bounds: validation?.bounds ?? null,
    },
    files: fileEntries,
  };

  const current = {
    schemaVersion: 1,
    cityId: city,
    datasetId: version,
    dataVersion: version,
    generatedAt,
    manifest: `${version}/manifest.json`,
    sourceLayer: 'hexgrid',
    hexgrid: `${version}/hexgrid.pmtiles`,
  };

  await writeFile(join(targetDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  await mkdir(dirname(currentPath), { recursive: true });
  await writeFile(currentPath, `${JSON.stringify(current, null, 2)}\n`);

  console.log(`Staged pipeline export:
  ${targetDir}
  ${currentPath}

Upload these object paths into Supabase Storage bucket "pipeline-export":
  ${city}/current.json
  ${city}/${version}/...
`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
