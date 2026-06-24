import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'NatureGap — Yokohama',
  description:
    'See where nature is under pressure and what you can do about it. Open-source ecological health mapping for Yokohama.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="h-full">
      <body className="h-full">{children}</body>
    </html>
  );
}
