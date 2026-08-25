import { isRegisteredCityId, STORAGE } from './config';
import { supabase } from './supabase';

export type ActivePipelineDataset = {
  cityId: string;
  dataVersion: string;
  sourceLayer: string;
  basePath: string;
  manifestPath: string;
  hexgridPath: string;
  /** Set when the city publishes its tileset as several archives (SHARD_TILES). */
  hexgridShardPaths: string[];
  files: Record<string, string>;
};

type CurrentPointer = {
  cityId?: unknown;
  datasetId?: unknown;
  dataVersion?: unknown;
  manifest?: unknown;
  hexgrid?: unknown;
  hexgridShards?: unknown;
  sourceLayer?: unknown;
};

type DatasetManifest = {
  cityId?: unknown;
  datasetId?: unknown;
  dataVersion?: unknown;
  sourceLayer?: unknown;
  pmtiles?: {
    path?: unknown;
    sourceLayer?: unknown;
    shards?: unknown;
  };
  files?: unknown;
};

type PipelineDatasetRow = {
  city_id: unknown;
  dataset_id: unknown;
  storage_prefix: unknown;
  manifest_path: unknown;
  source_layer: unknown;
};

function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

export function dirname(path: string): string {
  const index = path.lastIndexOf('/');
  return index === -1 ? '' : path.slice(0, index);
}

export function basename(path: string): string {
  const index = path.lastIndexOf('/');
  return index === -1 ? path : path.slice(index + 1);
}

export function joinPath(...parts: string[]): string {
  return parts
    .flatMap((part) => part.split('/'))
    .filter((part) => part.length > 0)
    .join('/');
}

function storageObjectPath(path: string): string {
  const prefix = `${STORAGE.PIPELINE_BUCKET}/`;
  return path.startsWith(prefix) ? path.slice(prefix.length) : path;
}

/**
 * Pipeline products are gzipped (see write_geojson in pipeline/06_export/export.R).
 * Supabase Storage serves stored bytes verbatim — there is no Content-Encoding
 * negotiation to rely on — so a ".gz" path is decompressed here explicitly.
 * Decompression is ~15ms for a cell-details shard and saves ~2.6MB of transfer,
 * so it is a large net win on every metered request.
 */
async function readStorageText(blob: Blob, path: string): Promise<string> {
  if (!path.endsWith('.gz')) return blob.text();

  const stream = blob.stream().pipeThrough(new DecompressionStream('gzip'));
  return new Response(stream).text();
}

export async function fetchStorageJson(path: string): Promise<unknown | null> {
  if (!supabase) return null;
  const { data, error } = await supabase.storage
    .from(STORAGE.PIPELINE_BUCKET)
    .download(path);

  if (error || !data) return null;

  try {
    return JSON.parse(await readStorageText(data, path));
  } catch {
    return null;
  }
}

function normalizeManifestFiles(value: unknown): Record<string, string> {
  const files = asObject(value);
  if (!files) return {};

  return Object.fromEntries(Object.entries(files).flatMap(([name, entry]) => {
    const path = asString(asObject(entry)?.path) ?? asString(entry);
    return path ? [[name, path]] : [];
  }));
}

function uniqueStrings(values: string[]): string[] {
  return Array.from(new Set(values.filter((value) => value.length > 0)));
}

function mergeDatasets(datasets: ActivePipelineDataset[]): ActivePipelineDataset[] {
  const byCity = new Map<string, ActivePipelineDataset>();
  for (const dataset of datasets) {
    if (!byCity.has(dataset.cityId)) byCity.set(dataset.cityId, dataset);
  }
  return Array.from(byCity.values());
}

/**
 * Archive paths for a sharded tileset, or [] when the city publishes one file.
 *
 * A sharded export writes no `pmtiles.path` / `hexgrid` at all — see the note in
 * export.R — so a reader that ignores shards fails loudly instead of rendering
 * one shard as if it were the whole city. Both publish routes are covered: the
 * manifest lists shards under `pmtiles.shards` (relative to the dataset folder)
 * and current.json under `hexgridShards` (relative to the city folder).
 */
function shardPathsFromPointers(
  cityFolder: string,
  basePath: string,
  current: CurrentPointer | null,
  manifest: DatasetManifest | null,
): string[] {
  const fromManifest = Array.isArray(manifest?.pmtiles?.shards)
    ? (manifest.pmtiles.shards as unknown[])
        .map((shard) => asString(asObject(shard)?.path))
        .filter((path): path is string => Boolean(path))
        .map((path) => joinPath(basePath, path))
    : [];
  if (fromManifest.length > 0) return fromManifest;

  return Array.isArray(current?.hexgridShards)
    ? (current.hexgridShards as unknown[])
        .map((shard) => asString(shard))
        .filter((path): path is string => Boolean(path))
        .map((path) => (path.includes('/') ? joinPath(cityFolder, path) : joinPath(basePath, path)))
    : [];
}

/** Every hexgrid archive for a dataset — one entry unless the city shards. */
export function resolveHexgridPaths(dataset: ActivePipelineDataset): string[] {
  if (dataset.hexgridShardPaths.length > 0) return dataset.hexgridShardPaths;
  return [resolveHexgridPath(dataset)];
}

function datasetFromPointers(
  cityFolder: string,
  current: CurrentPointer,
  manifest: DatasetManifest | null,
): ActivePipelineDataset | null {
  const cityId = asString(manifest?.cityId) ?? asString(current.cityId) ?? cityFolder;
  const dataVersion = asString(manifest?.datasetId)
    ?? asString(manifest?.dataVersion)
    ?? asString(current.datasetId)
    ?? asString(current.dataVersion);
  const currentManifestPath = asString(current.manifest);
  if (!dataVersion || !currentManifestPath) return null;

  const sourceLayer = asString(manifest?.pmtiles?.sourceLayer)
    ?? asString(manifest?.sourceLayer)
    ?? asString(current.sourceLayer)
    ?? STORAGE.HEXGRID_SOURCE_LAYER;

  const basePath = joinPath(cityFolder, dirname(currentManifestPath));
  const files = normalizeManifestFiles(manifest?.files);
  const manifestPmtilesPath = asString(manifest?.pmtiles?.path);
  const currentHexgridPath = asString(current.hexgrid);
  const hexgridPath = currentHexgridPath?.includes('/')
    ? joinPath(cityFolder, currentHexgridPath)
    : joinPath(basePath, manifestPmtilesPath ?? currentHexgridPath ?? STORAGE.HEXGRID_PMTILES_KEY);

  return {
    cityId,
    dataVersion,
    sourceLayer,
    basePath,
    manifestPath: joinPath(cityFolder, currentManifestPath),
    hexgridPath,
    hexgridShardPaths: shardPathsFromPointers(cityFolder, basePath, current, manifest),
    files,
  };
}

async function listDatabaseActiveDatasets(): Promise<ActivePipelineDataset[]> {
  if (!supabase) return [];

  const { data, error } = await supabase
    .from('pipeline_datasets')
    .select('city_id,dataset_id,storage_prefix,manifest_path,source_layer')
    .eq('is_active', true)
    .order('city_id', { ascending: true });

  if (error || !data) return [];

  const datasets = await Promise.all((data as PipelineDatasetRow[]).map(async (row) => {
    const cityId = asString(row.city_id);
    const dataVersion = asString(row.dataset_id);
    const storagePrefix = asString(row.storage_prefix);
    const manifestPath = asString(row.manifest_path);
    // Retired slugs stay is_active until deactivated in SQL; skip them here
    // so we never fetch yokohama-honmoku / porto-center / etc. archives.
    if (!cityId || !isRegisteredCityId(cityId) || !dataVersion || !storagePrefix || !manifestPath) {
      return null;
    }

    const basePath = storageObjectPath(storagePrefix);
    const normalizedManifestPath = storageObjectPath(manifestPath);
    const manifestValue = await fetchStorageJson(normalizedManifestPath);
    const manifest = asObject(manifestValue) as DatasetManifest | null;
    const files = normalizeManifestFiles(manifest?.files);
    const manifestPmtilesPath = asString(manifest?.pmtiles?.path);

    return {
      cityId,
      dataVersion,
      sourceLayer: asString(manifest?.pmtiles?.sourceLayer)
        ?? asString(manifest?.sourceLayer)
        ?? asString(row.source_layer)
        ?? STORAGE.HEXGRID_SOURCE_LAYER,
      basePath,
      manifestPath: normalizedManifestPath,
      hexgridPath: joinPath(basePath, manifestPmtilesPath ?? STORAGE.HEXGRID_PMTILES_KEY),
      hexgridShardPaths: shardPathsFromPointers(basePath, basePath, null, manifest),
      files,
    };
  }));

  return datasets.filter((dataset): dataset is ActivePipelineDataset => dataset !== null);
}

async function listStoragePointerDatasets(): Promise<ActivePipelineDataset[]> {
  const cityFolders = uniqueStrings([...STORAGE.PIPELINE_CITY_IDS]);
  const datasets = await Promise.all(cityFolders.map(async (cityFolder) => {
    const currentValue = await fetchStorageJson(`${cityFolder}/current.json`);
    const current = asObject(currentValue) as CurrentPointer | null;
    if (!current) return null;

    const manifestPath = asString(current.manifest);
    const manifestValue = manifestPath
      ? await fetchStorageJson(joinPath(cityFolder, manifestPath))
      : null;
    const manifest = asObject(manifestValue) as DatasetManifest | null;

    return datasetFromPointers(cityFolder, current, manifest);
  }));

  return datasets.filter((dataset): dataset is ActivePipelineDataset => dataset !== null);
}

async function loadActivePipelineDatasets(): Promise<ActivePipelineDataset[]> {
  // pipeline_datasets is the dynamic source of truth: import_to_postgres.R
  // promotes a row here on every export, and the "public_pipeline_dataset_
  // discovery" migration grants anon SELECT specifically so the frontend can
  // list every active city without a hardcoded id list. Storage pointers
  // (STORAGE.PIPELINE_CITY_IDS) are checked too, but only to fill in a city
  // that predates DB promotion — they never take priority over the registry.
  const [databaseDatasets, storageDatasets] = await Promise.all([
    listDatabaseActiveDatasets(),
    listStoragePointerDatasets(),
  ]);

  return mergeDatasets([...databaseDatasets, ...storageDatasets])
    .filter((dataset) => isRegisteredCityId(dataset.cityId));
}

export async function listActivePipelineDatasets(): Promise<ActivePipelineDataset[]> {
  if (!supabase) return [];
  return loadActivePipelineDatasets();
}

export function resolveHexgridPath(dataset: ActivePipelineDataset): string {
  if (dataset.files['hexgrid.pmtiles']) {
    return resolveDatasetFile(dataset, 'hexgrid.pmtiles');
  }
  return dataset.hexgridPath;
}

export function resolveDatasetFile(dataset: ActivePipelineDataset, fileName: string): string {
  // Callers ask for the logical name ('parks.geojson'). Current exports publish
  // it gzipped and list the real name in the manifest, while datasets published
  // before compression list the plain one — so prefer .gz and fall back. This
  // keeps every call site unchanged and both dataset generations readable.
  const manifestPath = dataset.files[`${fileName}.gz`] ?? dataset.files[fileName];
  if (manifestPath) return joinPath(dataset.basePath, manifestPath);
  return joinPath(dataset.basePath, fileName);
}