import {
  basename,
  dirname,
  fetchStorageJson,
  joinPath,
  listActivePipelineDatasets,
  resolveDatasetFile,
} from './pipeline-manifest';
import { supabase } from './supabase';

type ChunkManifest = { version?: number; chunks?: string[] };

function isManifest(value: unknown): value is ChunkManifest {
  return (
    typeof value === 'object' &&
    value !== null &&
    Array.isArray((value as ChunkManifest).chunks)
  );
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

/**
 * Load a JSON asset from the active pipeline dataset for each city.
 * Active datasets are discovered through pipeline-export/<city>/current.json,
 * then resolved through the versioned manifest.json.
 */
export async function fetchPipelineJson(
  fileName: string,
  manifestName: string | null,
  mergeChunks?: (parts: unknown[]) => unknown,
): Promise<unknown | null> {
  if (!supabase) return null;

  const datasets = await listActivePipelineDatasets();
  const parts: unknown[] = [];

  for (const dataset of datasets) {
    if (manifestName && mergeChunks && dataset.files[manifestName]) {
      const chunkManifestPath = resolveDatasetFile(dataset, manifestName);
      const chunkManifest = await fetchStorageJson(chunkManifestPath);
      if (isManifest(chunkManifest) && chunkManifest.chunks?.length) {
        const basePath = dirname(chunkManifestPath);
        const chunks = await Promise.all(
          chunkManifest.chunks.map((chunk) => fetchStorageJson(joinPath(basePath, basename(chunk)))),
        );
        if (!chunks.some((chunk) => chunk == null)) {
          parts.push(mergeChunks(chunks));
          continue;
        }
      }
    }

    const path = resolveDatasetFile(dataset, fileName);
    const data = await fetchStorageJson(path);
    if (data) parts.push(data);
  }

  return mergePipelineData(parts);
}

export function mergeCellChunks(parts: unknown[]): Record<string, unknown> {
  return Object.assign({}, ...parts.map((p) => p as Record<string, unknown>));
}
