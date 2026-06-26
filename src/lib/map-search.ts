export interface GeocodingSearchResult {
  id: string;
  label: string;
  sub: string;
  center: [number, number];
  bbox?: [number, number, number, number];
  sourceType: 'geocode';
}
