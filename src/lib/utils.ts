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
  if (score <= -20) return '#C95B4B';
  if (score <= -10) return '#E8A44C';
  if (score < 5)    return '#B8C9AE';
  if (score < 15)   return '#73A56D';
  return '#2E6F40';
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
