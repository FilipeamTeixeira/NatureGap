import { open } from 'node:fs/promises';
import { resolve } from 'node:path';
import { PMTiles, TileType } from 'pmtiles';

class NodeFileSource {
  constructor(path) {
    this.path = resolve(path);
  }

  getKey() {
    return this.path;
  }

  async getBytes(offset, length) {
    const file = await open(this.path, 'r');
    try {
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await file.read(buffer, 0, length, offset);
      const data = buffer.subarray(0, bytesRead);
      return {
        data: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength),
      };
    } finally {
      await file.close();
    }
  }
}

function usage() {
  console.error('Usage: node validate_pmtiles.mjs <pmtiles-path> <source-layer> <required-field>...');
  process.exit(2);
}

const [, , pmtilesPath, sourceLayer, ...requiredFields] = process.argv;
if (!pmtilesPath || !sourceLayer || requiredFields.length === 0) usage();

const archive = new PMTiles(new NodeFileSource(pmtilesPath));
const header = await archive.getHeader();

if (header.tileType !== TileType.Mvt) {
  throw new Error(`Expected MVT PMTiles, found tileType=${header.tileType}`);
}

const metadata = await archive.getMetadata();
const vectorLayers = Array.isArray(metadata?.vector_layers) ? metadata.vector_layers : [];
const layer = vectorLayers.find((item) => item?.id === sourceLayer);

if (!layer) {
  throw new Error(`PMTiles source-layer "${sourceLayer}" not found`);
}

const fields = layer.fields && typeof layer.fields === 'object' ? layer.fields : {};
const missing = requiredFields.filter((field) => !(field in fields));

if (missing.length > 0) {
  throw new Error(`PMTiles source-layer "${sourceLayer}" missing fields: ${missing.join(', ')}`);
}

console.log(JSON.stringify({
  path: resolve(pmtilesPath),
  sourceLayer,
  minZoom: header.minZoom,
  maxZoom: header.maxZoom,
  bounds: [header.minLon, header.minLat, header.maxLon, header.maxLat],
  fields: requiredFields,
}));
