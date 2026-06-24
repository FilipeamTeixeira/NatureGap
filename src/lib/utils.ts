import { type ClassValue, clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function formatScore(score: number): string {
  if (score === 0) return '0';
  return score > 0 ? `+${score}` : `${score}`;
}

export function getScoreColor(score: number): string {
  if (score <= -20) return '#dc2626';
  if (score <= -10) return '#f59e0b';
  if (score < 5) return '#fbbf24';
  if (score < 15) return '#22c55e';
  return '#16a34a';
}

export function getScoreLabel(score: number): string {
  if (score <= -20) return 'Much worse than expected';
  if (score <= -10) return 'Worse than expected';
  if (score < 5) return 'As expected';
  if (score < 15) return 'Better than expected';
  return 'Much better than expected';
}

export function formatNumber(n: number): string {
  return n.toLocaleString('en-US');
}
