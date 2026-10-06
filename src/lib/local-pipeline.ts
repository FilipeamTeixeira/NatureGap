/**
 * Dev-only preview of an export that has not been published.
 *
 * With NEXT_PUBLIC_PIPELINE_LOCAL_EXPORT=1 under `next dev` (`npm run
 * dev:local-export`), every pipeline file — pointers, manifests, tiles, cell
 * details, park stats — is read from the repo's pipeline-export/ folder through
 * /api/local-pipeline instead of Supabase Storage, and each city opens on its
 * newest local dataset rather than the published current.json. A production
 * build ignores the variable: NODE_ENV is fixed to 'production' there, and the
 * route answers 404.
 */
export const LOCAL_PIPELINE_EXPORT = process.env.NODE_ENV === 'development'
  && process.env.NEXT_PUBLIC_PIPELINE_LOCAL_EXPORT === '1';

/**
 * Absolute URL of a pipeline-export path. Absolute because PMTiles archives are
 * opened through the pmtiles:// protocol, and because server code (the vector
 * route) has no page origin to resolve a relative one against.
 */
export function localPipelineUrl(objectPath: string): string {
  const origin = typeof window === 'undefined'
    ? `http://127.0.0.1:${process.env.PORT ?? 3000}`
    : window.location.origin;
  const encoded = objectPath.split('/').filter(Boolean).map(encodeURIComponent).join('/');
  return `${origin}/api/local-pipeline/${encoded}`;
}
