import greenSpacesData from '@/data/green-spaces.json';
import { parseGreenSpaces } from './data-validation';

export interface GreenSpace {
  /** Stable identifier — matches hexgrid `parkId` and park-stats `id`. */
  id: string;
  /** English display name. */
  name: string;
  /** Japanese display name. */
  nameJa: string;
  /** Yokohama ward slug — matches ALL_WARDS. */
  wardId: string;
  /** Closed polygon ring in [lng, lat] order (WGS-84). */
  ring: [number, number][];
}

export const GREEN_SPACES = parseGreenSpaces(greenSpacesData);
