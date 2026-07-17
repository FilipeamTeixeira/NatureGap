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

export async function listHexPmtilesDatasets(): Promise<HexPmtilesDataset[]> {
  if (!supabase) return [];
  const client = supabase;

  const datasets = await listActivePipelineDatasets();
  if (datasets.length === 0) {
    console.warn('[pmtiles-storage] No active PMTiles datasets found in Supabase Storage.');
    return [];
  }

  return datasets.map((dataset) => {
    const objectPath = resolveHexgridPath(dataset);
    const { data } = client.storage
      .from(STORAGE.PIPELINE_BUCKET)
      .getPublicUrl(objectPath);

    const datasetId = `${dataset.cityId}-${dataset.dataVersion}`;

    return {
      datasetId,
      cityId: dataset.cityId,
      dataVersion: dataset.dataVersion,
      storagePath: `${STORAGE.PIPELINE_BUCKET}/${objectPath}`,
      publicUrl: data.publicUrl,
      sourceId: sourceId(datasetId),
      sourceLayer: dataset.sourceLayer,
    };
  });
}
