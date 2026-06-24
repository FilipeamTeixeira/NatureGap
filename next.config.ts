import type { NextConfig } from 'next';

// OpenFreeMap serves the style JSON, tiles, glyphs, and sprites all from
// tiles.openfreemap.org (primary) plus Cloudflare CDN subdomains.
const OPENFREEMAP_HOSTS = [
  'https://tiles.openfreemap.org',
  'https://*.openfreemap.org',
].join(' ');

const CSP = [
  "default-src 'self'",
  // Scripts: self + inline (Next.js/Turbopack bootstraps via inline scripts) + eval (MapLibre WebGL)
  "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
  // Styles: self + inline (Tailwind, MapLibre)
  "style-src 'self' 'unsafe-inline'",
  // Workers: blob: for MapLibre's web worker
  "worker-src blob:",
  // Images: self + data URIs (MapLibre sprites/icons) + OpenFreeMap CDN
  `img-src 'self' data: blob: ${OPENFREEMAP_HOSTS}`,
  // Tile, glyph, sprite fetches and Supabase REST/Storage
  `connect-src 'self' ${OPENFREEMAP_HOSTS} https://*.supabase.co wss://*.supabase.co`,
  // Fonts: self + data URIs (MapLibre inlines some font data)
  "font-src 'self' data: https://fonts.gstatic.com",
  // Frames: none
  "frame-ancestors 'none'",
].join('; ');

const nextConfig: NextConfig = {
  async headers() {
    return [
      {
        source: '/(.*)',
        headers: [
          { key: 'Content-Security-Policy',   value: CSP },
          { key: 'X-Frame-Options',            value: 'DENY' },
          { key: 'X-Content-Type-Options',     value: 'nosniff' },
          { key: 'Referrer-Policy',            value: 'strict-origin-when-cross-origin' },
          { key: 'Permissions-Policy',         value: 'camera=(), microphone=(), geolocation=()' },
        ],
      },
    ];
  },
};

export default nextConfig;
