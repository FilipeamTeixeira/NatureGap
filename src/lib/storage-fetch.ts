import { supabase } from './supabase';
import { STORAGE } from './config';

type ChunkManifest = { version?: number; chunks?: string[] };
type PipelineFile = {
  name: string;
  path: string;
  updatedAt: string;
};

function isManifest(value: unknown): value is ChunkManifest {
  return (
    typeof value === 'object' &&
    value !== null &&
    Array.isArray((value as ChunkManifest).chunks)
  );
}

function dirname(path: string): string {
  const index = path.lastIndexOf('/');
  return index === -1 ? '' : path.slice(0, index);
}

function basename(path: string): string {
  const index = path.lastIndexOf('/');
  return index === -1 ? path : path.slice(index + 1);
}

function logicalFilePattern(fileName: string): RegExp {
  const escaped = fileName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const [stem, ext] = fileName.split(/\.(?=[^.]+$)/);
  const escapedStem = stem.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const escapedExt = ext.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`^(?:${escaped}|${escapedStem}[-_.][0-9T:Z-]+\\.${escapedExt})$`);
}

function fileTimestamp(file: PipelineFile): number {
  const parsed = Date.parse(file.updatedAt);
  if (!Number.isNaN(parsed)) return parsed;
  const pathMatch = file.path.match(/(?:^|[/_-])(\d{8,14})(?:[/_.-]|$)/);
  return pathMatch ? Number(pathMatch[1]) : 0;
}

async function listFolder(folder: string): Promise<PipelineFile[]> {
  if (!supabase) return [];
  const { data, error } = await supabase.storage
    .from(STORAGE.PIPELINE_BUCKET)
    .list(folder, { limit: 1000, sortBy: { column: 'name', order: 'asc' } });

  if (error || !data) return [];

  const files: PipelineFile[] = [];
  for (const entry of data) {
    const path = `${folder}/${entry.name}`;
    if (entry.name.includes('.')) {
      files.push({
        name: entry.name,
        path,
        updatedAt: entry.updated_at ?? entry.created_at ?? '',
      });
      continue;
    }
    files.push(...await listFolder(path));
  }
  return files;
}

let pipelineFilesPromise: Promise<PipelineFile[]> | null = null;

async function listPipelineFiles(): Promise<PipelineFile[]> {
  if (!supabase) return [];
  pipelineFilesPromise ??= Promise.all(STORAGE.DATASET_IDS.map(listFolder)).then((parts) => parts.flat());
  return pipelineFilesPromise;
}

function selectLatestFile(files: PipelineFile[], fileName: string): PipelineFile | null {
  const pattern = logicalFilePattern(fileName);
  const candidates = files
    .filter((file) => pattern.test(file.name))
    .sort((a, b) => fileTimestamp(b) - fileTimestamp(a) || b.path.localeCompare(a.path));

  return candidates[0] ?? null;
}

function selectLatestFilesByDataset(files: PipelineFile[], fileName: string): PipelineFile[] {
  const pattern = logicalFilePattern(fileName);
  return STORAGE.DATASET_IDS
    .map((datasetId) => selectLatestFile(files.filter((file) => file.path.startsWith(`${datasetId}/`)), fileName))
    .filter((file): file is PipelineFile => file !== null && pattern.test(file.name));
}

function mergePipelineData(parts: unknown[]): unknown {
  const validParts = parts.filter((part) => part != null);
  if (validParts.length === 0) return null;
  if (validParts.length === 1) return validParts[0];

  if (validParts.every((part) => typeof part === 'object' && part !== null && !Array.isArray(part))) {
    return Object.assign({}, ...validParts.map((part) => part as Record<string, unknown>));
  }

  return validParts[0];
}

async function fetchFromStorage(path: string): Promise<unknown | null> {
  if (!supabase) return null;
  const { data, error } = await supabase.storage
    .from(STORAGE.PIPELINE_BUCKET)
    .download(path);
  if (error || !data) return null;
  return JSON.parse(await data.text());
}

/**
 * Load a JSON asset from Supabase Storage.
 * Dynamically lists the city folder and picks the newest file matching the
 * logical name, e.g. park-stats.json or park-stats-20260626T120000Z.json.
 * When a manifest exists, fetches all chunks and merges them.
 */
export async function fetchPipelineJson(
  fileName: string,
  manifestName: string | null,
  mergeChunks?: (parts: unknown[]) => unknown,
): Promise<unknown | null> {
  const files = await listPipelineFiles();

  if (files.length === 0) {
    const parts: unknown[] = [];
    for (const basePath of STORAGE.DATASET_IDS) {
      const manifest = manifestName ? await fetchFromStorage(`${basePath}/${manifestName}`) : null;
      if (isManifest(manifest) && manifest.chunks?.length && mergeChunks) {
        const chunkParts = await Promise.all(
          manifest.chunks.map((chunk) => fetchFromStorage(`${basePath}/${basename(chunk)}`)),
        );
        if (!chunkParts.some((p) => p == null)) {
          parts.push(mergeChunks(chunkParts));
          continue;
        }
      }

      const data = await fetchFromStorage(`${basePath}/${fileName}`);
      if (data) parts.push(data);
    }
    return mergePipelineData(parts);
  }

  const manifestFiles = manifestName ? selectLatestFilesByDataset(files, manifestName) : [];
  const manifestParts = await Promise.all(manifestFiles.map(async (manifestFile) => {
    const manifest = await fetchFromStorage(manifestFile.path);
    if (!isManifest(manifest) || !manifest.chunks?.length || !mergeChunks) return null;

    const basePath = dirname(manifestFile.path);
    const parts = await Promise.all(
      manifest.chunks.map((chunk) => fetchFromStorage(`${basePath}/${basename(chunk)}`)),
    );
    if (parts.some((p) => p == null)) return null;
    return mergeChunks(parts);
  }));
  if (manifestParts.some((part) => part != null)) return mergePipelineData(manifestParts);

  const selectedFiles = selectLatestFilesByDataset(files, fileName);
  return mergePipelineData(await Promise.all(selectedFiles.map((file) => fetchFromStorage(file.path))));
}

export function mergeCellChunks(parts: unknown[]): Record<string, unknown> {
  return Object.assign({}, ...parts.map((p) => p as Record<string, unknown>));
}
