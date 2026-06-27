import { STORAGE } from './config';
import { supabase } from './supabase';

export type ActivePipelineDataset = {
  cityId: string;
  dataVersion: string;
  sourceLayer: string;
  basePath: string;
  manifestPath: string;
  hexgridPath: string;
  files: Record<string, string>;
};

type CurrentPointer = {
  cityId?: unknown;
  datasetId?: unknown;
  dataVersion?: unknown;
  manifest?: unknown;
  hexgrid?: unknown;
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

export async function fetchStorageJson(path: string): Promise<unknown | null> {
  if (!supabase) return null;
  const { data, error } = await supabase.storage
    .from(STORAGE.PIPELINE_BUCKET)
    .download(path);

  if (error || !data) return null;

  try {
    return JSON.parse(await data.text());
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
    files,
  };
}

function legacyDataset(cityFolder: string): ActivePipelineDataset {
  return {
    cityId: cityFolder,
    dataVersion: 'legacy',
    sourceLayer: STORAGE.HEXGRID_SOURCE_LAYER,
    basePath: cityFolder,
    manifestPath: '',
    hexgridPath: joinPath(cityFolder, STORAGE.HEXGRID_PMTILES_KEY),
    files: {},
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
    if (!cityId || !dataVersion || !storagePrefix || !manifestPath) return null;

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

let activeDatasetsPromise: Promise<ActivePipelineDataset[]> | null = null;

export async function listActivePipelineDatasets(): Promise<ActivePipelineDataset[]> {
  if (!supabase) return [];

  activeDatasetsPromise ??= (async () => {
    const storageDatasets = await listStoragePointerDatasets();
    if (storageDatasets.length > 0) return storageDatasets;

    const databaseDatasets = await listDatabaseActiveDatasets();
    const activeDatasets = mergeDatasets([
      ...storageDatasets,
      ...databaseDatasets,
    ]);
    if (activeDatasets.length > 0) return activeDatasets;

    const cityFolders = uniqueStrings([...STORAGE.PIPELINE_CITY_IDS]);
    return cityFolders.map(legacyDataset);
  })();

  return activeDatasetsPromise;
}

export function resolveDatasetFile(dataset: ActivePipelineDataset, fileName: string): string {
  const manifestPath = dataset.files[fileName];
  if (manifestPath) return joinPath(dataset.basePath, manifestPath);
  return joinPath(dataset.basePath, fileName);
}
