import { STORAGE } from './config';
import { supabase } from './supabase';

export type HexPmtilesDataset = {
  datasetId: string;
  storagePath: string;
  publicUrl: string;
  sourceId: string;
  sourceLayer: typeof STORAGE.HEXGRID_SOURCE_LAYER;
};

type StorageFile = {
  name: string;
  path: string;
  updatedAt: string;
};

function logicalFilePattern(fileName: string): RegExp {
  const escaped = fileName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const [stem, ext] = fileName.split(/\.(?=[^.]+$)/);
  const escapedStem = stem.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const escapedExt = ext.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`^(?:${escaped}|${escapedStem}[-_.][0-9T:Z-]+\\.${escapedExt})$`);
}

function fileTimestamp(file: StorageFile): number {
  const parsed = Date.parse(file.updatedAt);
  if (!Number.isNaN(parsed)) return parsed;
  const pathMatch = file.path.match(/(?:^|[/_-])(\d{8,14})(?:[/_.-]|$)/);
  return pathMatch ? Number(pathMatch[1]) : 0;
}

async function listFolder(folder: string): Promise<StorageFile[]> {
  if (!supabase) return [];

  const { data, error } = await supabase.storage
    .from(STORAGE.PIPELINE_BUCKET)
    .list(folder, { limit: 1000, sortBy: { column: 'name', order: 'asc' } });

  if (error || !data) return [];

  const files: StorageFile[] = [];
  for (const entry of data) {
    const path = `${folder}/${entry.name}`;
    if (entry.name.includes('.')) {
      files.push({
        name: entry.name,
        path,
        updatedAt: entry.updated_at ?? entry.created_at ?? '',
      });
    } else {
      files.push(...await listFolder(path));
    }
  }
  return files;
}

function sourceId(datasetId: string): string {
  return `hexgrid-${datasetId.replace(/[^a-z0-9_-]/gi, '-')}`;
}

export async function listHexPmtilesDatasets(): Promise<HexPmtilesDataset[]> {
  if (!supabase) return [];

  const client = supabase;
  const pattern = logicalFilePattern(STORAGE.HEXGRID_PMTILES_KEY);
  const datasets: Array<HexPmtilesDataset | null> = await Promise.all(STORAGE.DATASET_IDS.map(async (datasetId) => {
    const files = (await listFolder(datasetId))
      .filter((file) => pattern.test(file.name))
      .sort((a, b) => fileTimestamp(b) - fileTimestamp(a) || b.path.localeCompare(a.path));

    const selected = files[0];
    if (!selected) return null;

    const { data } = client.storage
      .from(STORAGE.PIPELINE_BUCKET)
      .getPublicUrl(selected.path);

    return {
      datasetId,
      storagePath: `${STORAGE.PIPELINE_BUCKET}/${selected.path}`,
      publicUrl: data.publicUrl,
      sourceId: sourceId(datasetId),
      sourceLayer: STORAGE.HEXGRID_SOURCE_LAYER,
    } satisfies HexPmtilesDataset;
  }));

  return datasets.filter((dataset): dataset is HexPmtilesDataset => dataset !== null);
}
