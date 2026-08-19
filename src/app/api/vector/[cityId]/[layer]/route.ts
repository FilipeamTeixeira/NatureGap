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

// 'hex-cells' is deliberately absent. Hex geometry renders from
// hexgrid.pmtiles, and per-cell attributes come from the sharded cell-details
// lookup in lib/cell-detail.ts — nothing needs this route to serve them.
// cell_attributes.geojson is the full ecological export (450 MB across 13
// chunks for yokohama-honmoku), so answering a request here would merge every
// chunk into a single function response: one unauthenticated GET would exhaust
// a large share of the Storage egress budget and almost certainly exceed
// function memory. Keep hex cells out of the chunk-merging path entirely.
const LAYER_FILES = {
  'green-spaces': { fileName: 'parks.geojson', manifestName: null },
  'connectivity-network-edges': {
    fileName: 'connectivity-network-edges.geojson',
    manifestName: 'connectivity-network-edges.manifest.json',
  },
  'connectivity-network-nodes': {
    fileName: 'connectivity-network-nodes.geojson',
    manifestName: 'connectivity-network-nodes.manifest.json',
  },
} as const satisfies Partial<Record<VectorLayer, { fileName: string; manifestName: string | null }>>;

type ServableLayer = keyof typeof LAYER_FILES;

function isServableLayer(value: VectorLayer): value is ServableLayer {
  return value in LAYER_FILES;
}

// Backstop for the same failure mode on any layer that does get served: a
// manifest is an untrusted input here, and loadStorageGeoJSON fans out over it
// with Promise.all. Chunking only kicks in above 45 MB per part, so a
// legitimate corridor-links export is a single file — anything past this cap
// means the export grew large enough that merging it in one response is no
// longer safe.
const MAX_MERGE_CHUNKS = 4;

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

async function loadStorageGeoJSON(cityId: string, layer: ServableLayer): Promise<GeoJSON.FeatureCollection | null> {
  const dataset = (await listActivePipelineDatasets()).find((item) => item.cityId === cityId);
  if (!dataset) return null;

  const { fileName, manifestName } = LAYER_FILES[layer];
  if (manifestName && dataset.files[manifestName]) {
    const chunkManifestPath = resolveDatasetFile(dataset, manifestName);
    const chunkManifest = await fetchStorageJson(chunkManifestPath);
    if (isChunkManifest(chunkManifest) && chunkManifest.chunks.length > 0) {
      const basePath = dirname(chunkManifestPath);
      const chunkPaths = chunkManifest.chunks
        .map((chunk) => asString(chunk))
        .filter((chunk): chunk is string => chunk !== null);

      if (chunkPaths.length > MAX_MERGE_CHUNKS) {
        // The unchunked file is removed once an export is split, so falling
        // through here normally ends in a 404 rather than a partial answer.
        console.error(
          `[api/vector] Refusing to merge ${chunkPaths.length} chunks for ${cityId}/${layer} `
          + `(cap ${MAX_MERGE_CHUNKS}); falling back to unchunked ${fileName}.`,
        );
      } else {
        const chunks = await Promise.all(chunkPaths
          .map((chunk) => fetchStorageJson(joinPath(basePath, basename(chunk)))));

        const merged = mergeFeatureCollections(chunks);
        if (merged) return merged;
      }
    }
  }

  const data = await fetchStorageJson(resolveDatasetFile(dataset, fileName));
  return isFeatureCollection(data) ? data : null;
}

async function loadGeoJSON(cityId: string, layer: ServableLayer): Promise<GeoJSON.FeatureCollection | null> {
  return loadStorageGeoJSON(cityId, layer);
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

  if (!isServableLayer(layer)) {
    return NextResponse.json(
      {
        error: 'Vector layer is not served by this endpoint',
        detail: 'Hex cells render from hexgrid.pmtiles; per-cell attributes come from the cell-details shards.',
      },
      { status: 404 },
    );
  }

  const geojson = await loadGeoJSON(cityId, layer);
  if (!geojson) {
    return NextResponse.json({ error: 'Vector layer not found' }, { status: 404 });
  }

  return NextResponse.json(normalizeVectorGeoJSON(geojson, layer, cityId));
}
