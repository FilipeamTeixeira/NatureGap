#!/usr/bin/env node
/**
 * Pull the active pipeline-export dataset from Supabase Storage and import it
 * into PostgreSQL (pipeline_datasets by default; cell_attributes only on opt-in).
 *
 * Bucket upload alone does NOT update the database — this script closes that gap.
 *
 * Usage:
 *   npm run sync:pipeline-from-storage
 *   npm run sync:pipeline-from-storage -- --city yokohama-honmoku
 *   npm run sync:pipeline-from-storage -- --with-cell-attributes
 *   npm run sync:pipeline-from-storage -- --dry-run
 */
import { mkdir, unlink, writeFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, '..');

const CITY_CONFIG = {
  'yokohama-honmoku': 'config_yokohama.R',
  'amsterdam-schimmelstraat': 'config_amsterdam.R',
  'porto-center': 'config_porto.R',
};

const IMPORT_FILES = [
  'manifest.json',
  'cell_attributes.geojson',
  'parks.geojson',
  'park-stats.json',
  'cell-details.manifest.json',
  'hexgrid.pmtiles',
  'connectivity-network-edges.geojson',
  'connectivity-network-nodes.geojson',
  'top_interventions.json',
];

function usage() {
  console.error(`Usage:
  npm run sync:pipeline-from-storage [-- --city <id>] [--with-cell-attributes] [--dry-run]

Options:
  --city <id>             Sync one city (default: all known cities with current.json in Storage)
  --with-cell-attributes  Also stage/import full cell_attributes into PostgreSQL
  --dry-run               Download and stage files only; skip PostgreSQL import
`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = new Map();
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === '--dry-run') {
      args.set('dry-run', true);
      continue;
    }
    if (key === '--with-cell-attributes') {
      args.set('with-cell-attributes', true);
      continue;
    }
    if (!key.startsWith('--')) usage();
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) usage();
    args.set(key.slice(2), value);
    i += 1;
  }
  return {
    city: args.get('city'),
    withCellAttributes: args.get('with-cell-attributes') === true,
    dryRun: args.get('dry-run') === true,
  };
}

function loadEnvFile(path) {
  if (!existsSync(path)) return;
  const lines = readFileSync(path, 'utf8').split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    value = value.replace(/^['"]|['"]$/g, '');
    if (!process.env[key]) process.env[key] = value;
  }
}

function supabasePublicUrl(supabaseUrl, objectPath) {
  return `${supabaseUrl.replace(/\/$/, '')}/storage/v1/object/public/pipeline-export/${objectPath}`;
}

async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`GET ${url} failed: ${res.status} ${res.statusText}`);
  }
  return res.json();
}

async function downloadFile(url, targetPath) {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`GET ${url} failed: ${res.status} ${res.statusText}`);
  }
  await mkdir(dirname(targetPath), { recursive: true });
  const buffer = Buffer.from(await res.arrayBuffer());
  await writeFile(targetPath, buffer);
}

async function listCitiesToSync(supabaseUrl, requestedCity) {
  const candidates = requestedCity
    ? [requestedCity]
    : Object.keys(CITY_CONFIG);

  const cities = [];
  for (const city of candidates) {
    const url = supabasePublicUrl(supabaseUrl, `${city}/current.json`);
    try {
      const current = await fetchJson(url);
      const datasetId = current.datasetId ?? current.dataVersion;
      if (!datasetId) {
        console.warn(`Skipping ${city}: current.json has no datasetId`);
        continue;
      }
      cities.push({ city, datasetId, current });
    } catch (error) {
      console.warn(`Skipping ${city}: ${error instanceof Error ? error.message : error}`);
    }
  }
  return cities;
}

async function stageCityExport(supabaseUrl, city, datasetId, current, withCellAttributes) {
  const exportRoot = join(REPO_ROOT, 'pipeline-export', city);
  const versionDir = join(exportRoot, datasetId);
  await mkdir(versionDir, { recursive: true });

  const manifestPath = `${city}/${datasetId}/manifest.json`;
  const manifestUrl = supabasePublicUrl(supabaseUrl, manifestPath);
  let manifest = await fetchJson(manifestUrl);

  const files = new Set(IMPORT_FILES);
  if (manifest.files && typeof manifest.files === 'object') {
    for (const entry of Object.values(manifest.files)) {
      const path = typeof entry === 'string' ? entry : entry?.path;
      if (typeof path === 'string' && path.length > 0) files.add(path);
    }
  }

  for (const file of files) {
    if (file === 'cell_attributes.geojson') continue;
    if (!withCellAttributes && /^cell_attributes-part-[0-9]+\.(json|geojson)$/.test(file)) continue;
    const objectPath = `${city}/${datasetId}/${file}`;
    const targetPath = join(versionDir, file);
    const url = supabasePublicUrl(supabaseUrl, objectPath);
    try {
      await downloadFile(url, targetPath);
      console.log(`  downloaded ${objectPath}`);
    } catch (error) {
      const OPTIONAL_FILES = new Set([
        'parks.geojson',
        // The derived connectivity network is absent from exports produced
        // before 04_connectivity started emitting it.
        'connectivity-network-edges.geojson',
        'connectivity-network-nodes.geojson',
        'top_interventions.json',
      ]);
      if (OPTIONAL_FILES.has(file)) {
        console.warn(`  optional file missing: ${objectPath}`);
        continue;
      }
      if (/^cell_attributes-part-|^connectivity-network-(edges|nodes)-part-/.test(file)) {
        await downloadFile(url, targetPath);
        console.log(`  downloaded ${objectPath}`);
        continue;
      }
      throw error;
    }
  }

  if (withCellAttributes) {
    const chunkManifestPath = join(versionDir, 'cell_attributes.manifest.json');
    if (existsSync(chunkManifestPath)) {
      const staleMergedPath = join(versionDir, 'cell_attributes.geojson');
      await unlink(staleMergedPath).catch((error) => {
        if (error?.code !== 'ENOENT') throw error;
      });
      const chunkManifest = JSON.parse(readFileSync(chunkManifestPath, 'utf8'));
      console.log(`  staged chunked cell_attributes (${chunkManifest.chunks?.length ?? 0} chunks)`);
    } else {
      const objectPath = `${city}/${datasetId}/cell_attributes.geojson`;
      await downloadFile(
        supabasePublicUrl(supabaseUrl, objectPath),
        join(versionDir, 'cell_attributes.geojson'),
      );
      console.log('  staged cell_attributes.geojson (single file)');
    }
  } else {
    console.log('  skipped cell_attributes staging (metadata-only sync)');
  }

  const currentPath = join(exportRoot, 'current.json');
  await writeFile(currentPath, `${JSON.stringify(current, null, 2)}\n`);

  if (!existsSync(join(versionDir, 'manifest.json'))) {
    await writeFile(join(versionDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  }

  return { exportRoot, versionDir, currentPath };
}

async function importCityToPostgres(city, withCellAttributes) {
  const configFile = CITY_CONFIG[city];
  if (!configFile) {
    throw new Error(`No R config mapping for city "${city}". Add it to CITY_CONFIG in sync-pipeline-from-storage.mjs`);
  }

  const pipelineDir = join(REPO_ROOT, 'pipeline');
  const rScript = `
    source("${configFile}")
    Sys.setenv(POSTGRES_IMPORT_ENABLED = "1")
    source("07_import/import_to_postgres.R")
  `.trim();

  const { stdout, stderr } = await execFileAsync('Rscript', ['-e', rScript], {
    cwd: pipelineDir,
    env: {
      ...process.env,
      POSTGRES_IMPORT_ENABLED: '1',
      POSTGRES_IMPORT_REQUIRED: process.env.POSTGRES_IMPORT_REQUIRED ?? '1',
      POSTGRES_IMPORT_CELL_ATTRIBUTES: withCellAttributes ? '1' : '0',
    },
    maxBuffer: 20 * 1024 * 1024,
  });

  const output = `${stdout}\n${stderr}`;
  if (/Could not run public\.import_pipeline_dataset|Could not connect to PostgreSQL|PostgreSQL pipeline import is disabled|Required import product is missing/i.test(output)) {
    throw new Error(`PostgreSQL import failed for ${city}:\n${output.trim()}`);
  }
  if (!/PostgreSQL import complete:/i.test(output)) {
    throw new Error(`PostgreSQL import did not complete for ${city}:\n${output.trim()}`);
  }

  if (stdout.trim()) console.log(stdout.trim());
  if (stderr.trim()) console.error(stderr.trim());
}

async function main() {
  const { city, withCellAttributes, dryRun } = parseArgs(process.argv.slice(2));

  for (const envFile of ['.env.local', '.env', 'pipeline/.env.local', 'pipeline/.env']) {
    loadEnvFile(join(REPO_ROOT, envFile));
  }

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!supabaseUrl) {
    throw new Error('NEXT_PUBLIC_SUPABASE_URL is not set in .env.local');
  }

  if (!dryRun && !process.env.DATABASE_URL) {
    throw new Error('DATABASE_URL is not set in .env.local (required for PostgreSQL import)');
  }

  const cities = await listCitiesToSync(supabaseUrl, city);
  if (cities.length === 0) {
    throw new Error('No cities with current.json found in Storage');
  }

  console.log(`Found ${cities.length} cit${cities.length === 1 ? 'y' : 'ies'} to sync:`);
  for (const entry of cities) {
    console.log(`  ${entry.city} -> ${entry.datasetId}`);
  }

  for (const entry of cities) {
    console.log(`\nStaging ${entry.city} (${entry.datasetId}) from Storage...`);
    await stageCityExport(supabaseUrl, entry.city, entry.datasetId, entry.current, withCellAttributes);

    if (dryRun) {
      console.log(`  dry-run: skipped PostgreSQL import for ${entry.city}`);
      continue;
    }

    console.log(`Importing ${entry.city} into PostgreSQL...`);
    await importCityToPostgres(entry.city, withCellAttributes);
    console.log(`  done: ${entry.city}`);
  }

  console.log('\nSync complete.');
  if (!dryRun) {
    console.log('Verify in Supabase SQL editor:');
    console.log('  select city_id, dataset_id, is_active, generated_at');
    console.log('  from public.pipeline_datasets');
    console.log('  order by generated_at desc;');
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
