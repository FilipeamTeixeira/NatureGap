import { type ClassValue, clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';
import { SCORE_THRESHOLDS, SCORE_COLORS } from './config';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function formatScore(score: number): string {
  if (score === 0) return '0';
  return score > 0 ? `+${score}` : `${score}`;
}

export function getScoreColor(score: number): string {
  const t = SCORE_THRESHOLDS;
  if (score < t.MUCH_WORSE)  return SCORE_COLORS.MUCH_WORSE;
  if (score < t.WORSE)       return SCORE_COLORS.WORSE;
  if (score < t.AS_EXPECTED) return SCORE_COLORS.AS_EXPECTED;
  if (score < t.BETTER)      return SCORE_COLORS.BETTER;
  return SCORE_COLORS.MUCH_BETTER;
}

export function getScoreLabel(score: number): string {
  const t = SCORE_THRESHOLDS;
  if (score < t.MUCH_WORSE)  return 'Much worse than expected';
  if (score < t.WORSE)       return 'Worse than expected';
  if (score < t.AS_EXPECTED) return 'As expected';
  if (score < t.BETTER)      return 'Better than expected';
  return 'Much better than expected';
}

export function formatNumber(n: number): string {
  return n.toLocaleString('en-US');
}

/** Single source of truth for the 5-step nature impact colour scale. */
export const IMPACT_LEGEND = [
  { color: SCORE_COLORS.MUCH_BETTER, label: 'Much better than expected' },
  { color: SCORE_COLORS.BETTER,      label: 'Better than expected'      },
  { color: SCORE_COLORS.AS_EXPECTED, label: 'As expected'               },
  { color: SCORE_COLORS.WORSE,       label: 'Worse than expected'       },
  { color: SCORE_COLORS.MUCH_WORSE,  label: 'Much worse than expected'  },
] as const;
