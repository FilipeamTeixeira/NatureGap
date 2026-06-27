import { STORAGE } from './config';
import { listActivePipelineDatasets } from './pipeline-manifest';
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
    console.warn('[pmtiles-storage] No active or legacy PMTiles datasets found.');
  }
  return datasets.map((dataset) => {
    const { data } = client.storage
      .from(STORAGE.PIPELINE_BUCKET)
      .getPublicUrl(dataset.hexgridPath);

    const datasetId = `${dataset.cityId}-${dataset.dataVersion}`;

    return {
      datasetId,
      cityId: dataset.cityId,
      dataVersion: dataset.dataVersion,
      storagePath: `${STORAGE.PIPELINE_BUCKET}/${dataset.hexgridPath}`,
      publicUrl: data.publicUrl,
      sourceId: sourceId(datasetId),
      sourceLayer: dataset.sourceLayer,
    };
  });
}
