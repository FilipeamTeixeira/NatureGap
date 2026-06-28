import { NextResponse } from 'next/server';
import {
  basename,
  dirname,
  fetchStorageJson,
  joinPath,
  listActivePipelineDatasets,
  resolveDatasetFile,
} from '@/lib/pipeline-manifest';
import {
  isVectorLayer,
  normalizeVectorGeoJSON,
  type VectorLayer,
} from '@/lib/vector-normalization';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

type RouteParams = {
  cityId: string;
  layer: string;
};

type ChunkManifest = {
  chunks: unknown[];
};

const LAYER_FILES = {
  'green-spaces': { fileName: 'parks.geojson', manifestName: null },
  'hex-cells': { fileName: 'cell_attributes.geojson', manifestName: 'cell_attributes.manifest.json' },
  'corridor-links': { fileName: 'corridor-links.geojson', manifestName: 'corridor-links.manifest.json' },
} as const satisfies Record<VectorLayer, { fileName: string; manifestName: string | null }>;

function isSafeCityId(value: string): boolean {
  return /^[a-z0-9][a-z0-9-]*$/i.test(value);
}

function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function isFeatureCollection(value: unknown): value is GeoJSON.FeatureCollection {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as GeoJSON.FeatureCollection).type === 'FeatureCollection' &&
    Array.isArray((value as GeoJSON.FeatureCollection).features)
  );
}

function isChunkManifest(value: unknown): value is ChunkManifest {
  return Array.isArray(asObject(value)?.chunks);
}

function mergeFeatureCollections(parts: unknown[]): GeoJSON.FeatureCollection | null {
  const features = parts.flatMap((part) => (
    isFeatureCollection(part) ? part.features : []
  ));

  return features.length > 0 ? { type: 'FeatureCollection', features } : null;
}

async function readJsonFile(filePath: string): Promise<unknown | null> {
  try {
    const { readFile } = await import('node:fs/promises');
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch {
    return null;
  }
}

async function loadStorageGeoJSON(cityId: string, layer: VectorLayer): Promise<GeoJSON.FeatureCollection | null> {
  const dataset = (await listActivePipelineDatasets()).find((item) => item.cityId === cityId);
  if (!dataset) return null;

  const { fileName, manifestName } = LAYER_FILES[layer];
  if (manifestName && dataset.files[manifestName]) {
    const chunkManifestPath = resolveDatasetFile(dataset, manifestName);
    const chunkManifest = await fetchStorageJson(chunkManifestPath);
    if (isChunkManifest(chunkManifest) && chunkManifest.chunks.length > 0) {
      const basePath = dirname(chunkManifestPath);
      const chunks = await Promise.all(chunkManifest.chunks
        .map((chunk) => asString(chunk))
        .filter((chunk): chunk is string => chunk !== null)
        .map((chunk) => fetchStorageJson(joinPath(basePath, basename(chunk)))));

      const merged = mergeFeatureCollections(chunks);
      if (merged) return merged;
    }
  }

  const data = await fetchStorageJson(resolveDatasetFile(dataset, fileName));
  return isFeatureCollection(data) ? data : null;
}

async function loadLocalGeoJSON(cityId: string, layer: VectorLayer): Promise<GeoJSON.FeatureCollection | null> {
  if (process.env.NODE_ENV !== 'development') return null;

  const path = await import('node:path');
  const exportRoot = path.join(process.cwd(), 'pipeline-export', cityId);
  const current = asObject(await readJsonFile(path.join(exportRoot, 'current.json')));
  const manifestRel = asString(current?.manifest);
  if (!manifestRel) return null;

  const manifestPath = path.join(exportRoot, manifestRel);
  const manifestDir = path.dirname(manifestPath);
  const manifest = asObject(await readJsonFile(manifestPath));
  const { fileName } = LAYER_FILES[layer];
  const manifestFilePath = asString(asObject(asObject(manifest?.files)?.[fileName])?.path);
  const dataPath = path.join(manifestDir, manifestFilePath ?? fileName);
  const data = await readJsonFile(dataPath);

  return isFeatureCollection(data) ? data : null;
}

async function loadGeoJSON(cityId: string, layer: VectorLayer): Promise<GeoJSON.FeatureCollection | null> {
  return await loadStorageGeoJSON(cityId, layer) ?? await loadLocalGeoJSON(cityId, layer);
}

export async function GET(
  _request: Request,
  context: { params: Promise<RouteParams> },
) {
  const { cityId, layer } = await context.params;

  if (!isSafeCityId(cityId)) {
    return NextResponse.json({ error: 'Invalid cityId' }, { status: 400 });
  }

  if (!isVectorLayer(layer)) {
    return NextResponse.json({ error: 'Unknown vector layer' }, { status: 404 });
  }

  const geojson = await loadGeoJSON(cityId, layer);
  if (!geojson) {
    return NextResponse.json({ error: 'Vector layer not found' }, { status: 404 });
  }

  return NextResponse.json(normalizeVectorGeoJSON(geojson, layer, cityId));
}
