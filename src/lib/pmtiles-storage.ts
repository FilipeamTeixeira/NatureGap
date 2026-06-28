import { STORAGE } from './config';
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
};

function sourceId(datasetId: string): string {
  return `hexgrid-${datasetId.replace(/[^a-z0-9_-]/gi, '-')}`;
}

function hexgridPmtilesApiUrl(cityId: string): string {
  return `${window.location.origin}/api/hexgrid-pmtiles/${encodeURIComponent(cityId)}`;
}

export async function listHexPmtilesDatasets(): Promise<HexPmtilesDataset[]> {
  if (!supabase || typeof window === 'undefined') return [];

  const datasets = await listActivePipelineDatasets();
  if (datasets.length === 0) {
    console.warn('[pmtiles-storage] No active PMTiles datasets found in Supabase Storage.');
    return [];
  }

  return datasets.map((dataset) => {
    const objectPath = resolveHexgridPath(dataset);
    const datasetId = `${dataset.cityId}-${dataset.dataVersion}`;

    return {
      datasetId,
      cityId: dataset.cityId,
      dataVersion: dataset.dataVersion,
      storagePath: `${STORAGE.PIPELINE_BUCKET}/${objectPath}`,
      publicUrl: hexgridPmtilesApiUrl(dataset.cityId),
      sourceId: sourceId(datasetId),
      sourceLayer: dataset.sourceLayer,
    };
  });
}
