import { PMTiles } from 'pmtiles';
import { CITY, STORAGE } from './config';
import { listActivePipelineDatasets, resolveHexgridPath } from './pipeline-manifest';
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
};

function sourceId(datasetId: string): string {
  return `hexgrid-${datasetId.replace(/[^a-z0-9_-]/gi, '-')}`;
}

/** One hexgrid source per session — avoids cross-city empty tile requests while panning. */
export function hexDatasetsForMapView(
  datasets: HexPmtilesDataset[],
  preferredCityId: string = CITY.id,
): HexPmtilesDataset[] {
  const preferred = datasets.filter((dataset) => dataset.cityId === preferredCityId);
  if (preferred.length > 0) return preferred;
  if (datasets.length === 0) return [];
  console.warn(
    `[pmtiles-storage] No readable hexgrid for ${preferredCityId}; using ${datasets[0].cityId}.`,
  );
  return [datasets[0]];
}

export async function listHexPmtilesDatasets(): Promise<HexPmtilesDataset[]> {
  if (!supabase) return [];
  const client = supabase;

  const datasets = await listActivePipelineDatasets();
  if (datasets.length === 0) {
    console.warn('[pmtiles-storage] No active PMTiles datasets found in Supabase Storage.');
    return [];
  }

  const readable = await Promise.all(datasets.map(async (dataset) => {
    const objectPath = resolveHexgridPath(dataset);
    const { data } = client.storage
      .from(STORAGE.PIPELINE_BUCKET)
      .getPublicUrl(objectPath);

    const datasetId = `${dataset.cityId}-${dataset.dataVersion}`;

    try {
      const header = await new PMTiles(data.publicUrl).getHeader();
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
        publicUrl: data.publicUrl,
        sourceId: sourceId(datasetId),
        sourceLayer: dataset.sourceLayer,
        bounds: [header.minLon, header.minLat, header.maxLon, header.maxLat] as [number, number, number, number],
        maxZoom: header.maxZoom,
      };
    } catch (error) {
      console.warn('[pmtiles-storage] Skipping unreadable PMTiles archive for', objectPath, error);
      return null;
    }
  }));

  return readable.filter((dataset): dataset is HexPmtilesDataset => dataset !== null);
}
