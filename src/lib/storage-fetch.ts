import { supabase } from './supabase';
import { STORAGE } from './config';

type ChunkManifest = { version?: number; chunks?: string[] };

function isManifest(value: unknown): value is ChunkManifest {
  return (
    typeof value === 'object' &&
    value !== null &&
    Array.isArray((value as ChunkManifest).chunks)
  );
}

async function fetchFromStorage(path: string): Promise<unknown | null> {
  if (!supabase) return null;
  const { data, error } = await supabase.storage
    .from(STORAGE.PIPELINE_BUCKET)
    .download(`${STORAGE.CITY_ID}/${path}`);
  if (error || !data) return null;
  return JSON.parse(await data.text());
}

async function fetchFromPublic(path: string): Promise<unknown | null> {
  try {
    const res = await fetch(path);
    if (!res.ok) return null;
    return res.json();
  } catch {
    return null;
  }
}

/**
 * Load a JSON asset from Supabase Storage, with optional public fallback.
 * When a manifest exists (e.g. cells.manifest.json), fetches all chunks and merges them.
 */
export async function fetchPipelineJson(
  fileName: string,
  manifestName: string,
  mergeChunks: (parts: unknown[]) => unknown,
  publicBase = `/pipeline/${STORAGE.CITY_ID}`,
): Promise<unknown | null> {
  const manifest =
    (await fetchFromStorage(manifestName)) ??
    (await fetchFromPublic(`${publicBase}/${manifestName}`));

  if (isManifest(manifest) && manifest.chunks?.length) {
    const parts = await Promise.all(
      manifest.chunks.map(async (chunk) =>
        (await fetchFromStorage(chunk)) ??
        (await fetchFromPublic(`${publicBase}/${chunk}`)),
      ),
    );
    if (parts.some((p) => p == null)) return null;
    return mergeChunks(parts);
  }

  return (
    (await fetchFromStorage(fileName)) ??
    (await fetchFromPublic(`${publicBase}/${fileName}`))
  );
}

export function mergeCellChunks(parts: unknown[]): Record<string, unknown> {
  return Object.assign({}, ...parts.map((p) => p as Record<string, unknown>));
}

export function mergeGeoJsonChunks(parts: unknown[]): GeoJSON.FeatureCollection {
  const features = parts.flatMap((part) => {
    const fc = part as GeoJSON.FeatureCollection;
    return fc.features ?? [];
  });
  return { type: 'FeatureCollection', features };
}
