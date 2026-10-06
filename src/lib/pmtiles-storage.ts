import { PMTiles } from 'pmtiles';
import { STORAGE } from './config';
import { LOCAL_PIPELINE_EXPORT, localPipelineUrl } from './local-pipeline';
import type { OpportunityGapInfo } from './opportunity-gap';
import { listActivePipelineDatasets, resolveHexgridPaths } from './pipeline-manifest';
import type { ResidualWindow } from './residual-window';
import { supabase } from './supabase';

export type HexPmtilesDataset = {
  datasetId: string;
  cityId: string;
  dataVersion: string;
  storagePath: string;
  publicUrl: string;
  sourceId: string;
  sourceLayer: string;
  bounds: [number, number, number, number];
  maxZoom: number;
  /** The city's residual window, repeated on every shard of a sharded city. */
  residualWindow: ResidualWindow | null;
  /** The city's Nature gap, likewise repeated on every shard. */
  opportunity: OpportunityGapInfo | null;
};

function sourceId(datasetId: string): string {
  return `hexgrid-${datasetId.replace(/[^a-z0-9_-]/gi, '-')}`;
}

/**
 * Every hex source/layer id is namespaced per dataset (see sourceId() below,
 * hexFillLayerIdForDataset, cityIdFromHexLayerId), and refreshHexLayers()
 * already toggles visibility across every dataset returned here — so there
 * is no reason to filter down to one city. Doing so used to silently drop
 * every non-default city's hex layer the moment a viewer zoomed in past
 * DETAIL_ZOOM, even though the aggregated overview layer (which is not
 * filtered) showed that city fine. PMTiles sources declare `bounds`, so a
 * city's source simply returns no tiles while panned elsewhere — there's no
 * real cost to keeping all of them registered.
 */
export function hexDatasetsForMapView(datasets: HexPmtilesDataset[]): HexPmtilesDataset[] {
  if (datasets.length === 0) {
    console.warn('[pmtiles-storage] No readable hexgrid datasets.');
  }
  return datasets;
}

export async function listHexPmtilesDatasets(): Promise<HexPmtilesDataset[]> {
  return (await listHexPmtilesDatasetsWithWindows()).datasets;
}

/**
 * The readable hex archives, plus every active city's residual window. The
 * windows come from the manifests, not from the archives, so a city whose
 * tiles fail to load still has its verdict applied to its parks and panels
 * rather than silently falling back to the full gap map.
 */
export async function listHexPmtilesDatasetsWithWindows(): Promise<{
  datasets: HexPmtilesDataset[];
  residualWindows: Record<string, ResidualWindow | null>;
  opportunity: Record<string, OpportunityGapInfo | null>;
}> {
  if (!supabase && !LOCAL_PIPELINE_EXPORT) return { datasets: [], residualWindows: {}, opportunity: {} };
  const client = supabase;
  const publicUrl = (objectPath: string): string | null => {
    if (LOCAL_PIPELINE_EXPORT) return localPipelineUrl(objectPath);
    return client?.storage.from(STORAGE.PIPELINE_BUCKET).getPublicUrl(objectPath).data.publicUrl ?? null;
  };

  const datasets = await listActivePipelineDatasets();
  const residualWindows = Object.fromEntries(
    datasets.map((dataset) => [dataset.cityId, dataset.residualWindow] as const),
  );
  const opportunity = Object.fromEntries(
    datasets.map((dataset) => [dataset.cityId, dataset.opportunity] as const),
  );
  if (datasets.length === 0) {
    console.warn('[pmtiles-storage] No active PMTiles datasets found in Supabase Storage.');
    return { datasets: [], residualWindows, opportunity };
  }

  // A city that sets SHARD_TILES publishes its tileset as several archives, so
  // one pipeline dataset can yield several map sources. Each keeps the city's
  // own cityId — cityIdFromHexLayerId() resolves a clicked layer back through
  // it — and each carries its own bounds, which is what stops MapLibre asking
  // the wrong shard for a tile. Shards are contiguous blocks cut on cell
  // centroids, so no cell is in two of them.
  const shardedDatasets = datasets.flatMap((dataset) => {
    const paths = resolveHexgridPaths(dataset);
    return paths.map((objectPath, index) => ({
      dataset,
      objectPath,
      datasetId: paths.length > 1
        ? `${dataset.cityId}-${dataset.dataVersion}-s${index + 1}`
        : `${dataset.cityId}-${dataset.dataVersion}`,
    }));
  });

  const readable = await Promise.all(shardedDatasets.map(async ({ dataset, objectPath, datasetId }) => {
    const url = publicUrl(objectPath);
    if (!url) return null;

    try {
      const header = await new PMTiles(url).getHeader();
      if (![header.minLon, header.minLat, header.maxLon, header.maxLat].every(Number.isFinite)
        || header.minLon >= header.maxLon
        || header.minLat >= header.maxLat) {
        console.warn('[pmtiles-storage] Invalid PMTiles bounds for', objectPath);
        return null;
      }

      return {
        datasetId,
        cityId: dataset.cityId,
        dataVersion: dataset.dataVersion,
        storagePath: `${STORAGE.PIPELINE_BUCKET}/${objectPath}`,
        publicUrl: url,
        sourceId: sourceId(datasetId),
        sourceLayer: dataset.sourceLayer,
        bounds: [header.minLon, header.minLat, header.maxLon, header.maxLat] as [number, number, number, number],
        maxZoom: header.maxZoom,
        residualWindow: dataset.residualWindow,
        opportunity: dataset.opportunity,
      };
    } catch (error) {
      console.warn('[pmtiles-storage] Skipping unreadable PMTiles archive for', objectPath, error);
      return null;
    }
  }));

  return {
    datasets: readable.filter((dataset): dataset is HexPmtilesDataset => dataset !== null),
    residualWindows,
    opportunity,
  };
}