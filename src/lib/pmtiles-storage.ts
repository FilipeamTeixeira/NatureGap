import { STORAGE } from './config';
import { supabase } from './supabase';

export type HexPmtilesDataset = {
  datasetId: string;
  storagePath: string;
  publicUrl: string;
  sourceId: string;
  sourceLayer: typeof STORAGE.HEXGRID_SOURCE_LAYER;
};

function sourceId(datasetId: string): string {
  return `hexgrid-${datasetId.replace(/[^a-z0-9_-]/gi, '-')}`;
}

export function listHexPmtilesDatasets(): HexPmtilesDataset[] {
  if (!supabase) return [];

  const client = supabase;
  return STORAGE.DATASET_IDS.map((datasetId) => {
    const path = `${datasetId}/${STORAGE.HEXGRID_PMTILES_KEY}`;

    const { data } = client.storage
      .from(STORAGE.PIPELINE_BUCKET)
      .getPublicUrl(path);

    return {
      datasetId,
      storagePath: `${STORAGE.PIPELINE_BUCKET}/${path}`,
      publicUrl: data.publicUrl,
      sourceId: sourceId(datasetId),
      sourceLayer: STORAGE.HEXGRID_SOURCE_LAYER,
    };
  });
}
