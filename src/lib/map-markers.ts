/**
 * Popup content helper extracted from MapView.tsx
 * (step 3 of the MapView split — the final extraction, after
 * lib/map-utils.ts (step 1) and lib/map-layers.ts (step 2)).
 * No logic changes from the original functions.
 */

import { safeColor, scoreColor } from '@/lib/map-utils';
import { OPPORTUNITY_COLORS } from '@/lib/layer-styles';
import { FOCUS_CLASS_TEXT, FOCUS_TEXT_COLORS, type FocusClass } from '@/lib/green-focus';
import { formatSpeciesChange, opportunityBand } from '@/lib/opportunity-gap';

/** The hovered cell's Room to grow, as the layer currently draws it. */
function opportunityLines(gap: number | null, checkedOnly: boolean): { label: string; value: string; color: string } {
  const label = checkedOnly ? 'Room to grow · checked groups' : 'Room to grow';
  switch (opportunityBand(gap)) {
    case 'gain':
      return { label, value: `${formatSpeciesChange(gap as number)} native species`, color: OPPORTUNITY_COLORS.gain[4] };
    case 'loss':
      // The map's yellow is unreadable as text on white; same hue, darker.
      return { label, value: 'Already richer than greener places like it', color: '#5C5300' };
    case 'same':
      return { label, value: 'No clear gain', color: '#667066' };
    default:
      return { label, value: 'Not computed', color: '#667066' };
  }
}

export function createPopupContent({
  parkName,
  score,
  showScore,
  opportunity,
  focus,
}: {
  parkName?: string;
  score?: number;
  showScore: boolean;
  opportunity?: { gap: number | null; checkedOnly: boolean };
  /** The hovered green cell's Nature gap class (lib/green-focus.ts). */
  focus?: { focusClass: FocusClass; speciesNearby: number | null };
}) {
  const root = document.createElement('div');
  root.style.fontFamily = "'Inter', system-ui, -apple-system, sans-serif";
  root.style.padding = '10px 14px';
  root.style.minWidth = '140px';

  if (parkName) {
    const title = document.createElement('div');
    title.textContent = parkName;
    title.style.fontSize = '12px';
    title.style.fontWeight = '600';
    title.style.color = '#1F2A1F';
    title.style.marginBottom = showScore ? '6px' : '4px';
    title.style.lineHeight = '1.4';
    root.append(title);
  }

  if (showScore && typeof score === 'number') {
    const labelEl = document.createElement('div');
    labelEl.textContent = 'Nature Gap score';
    labelEl.style.fontSize = '10px';
    labelEl.style.fontWeight = '500';
    labelEl.style.color = '#667066';
    labelEl.style.letterSpacing = '0.03em';
    labelEl.style.marginBottom = '2px';
    root.append(labelEl);

    const value = document.createElement('div');
    value.textContent = score > 0 ? `+${score}` : String(score);
    value.style.fontSize = '18px';
    value.style.fontWeight = '700';
    value.style.color = safeColor(scoreColor(score));
    value.style.lineHeight = '1.2';
    root.append(value);
  }

  const figures: { label: string; value: string; color: string }[] = [];
  if (focus) {
    const n = focus.speciesNearby;
    figures.push({
      label: 'Nature gap',
      value: n != null && n > 0
        ? `${FOCUS_CLASS_TEXT[focus.focusClass].label} · ${n} native species nearby`
        : FOCUS_CLASS_TEXT[focus.focusClass].label,
      color: FOCUS_TEXT_COLORS[focus.focusClass],
    });
  }
  if (opportunity) figures.push(opportunityLines(opportunity.gap, opportunity.checkedOnly));

  for (const lines of figures) {
    const labelEl = document.createElement('div');
    labelEl.textContent = lines.label;
    labelEl.style.fontSize = '10px';
    labelEl.style.fontWeight = '500';
    labelEl.style.color = '#667066';
    labelEl.style.letterSpacing = '0.03em';
    labelEl.style.marginBottom = '2px';
    root.append(labelEl);

    const value = document.createElement('div');
    value.textContent = lines.value;
    value.style.fontSize = '14px';
    value.style.fontWeight = '700';
    value.style.color = safeColor(lines.color);
    value.style.lineHeight = '1.3';
    value.style.maxWidth = '200px';
    root.append(value);
  }

  const hasFigure = showScore || figures.length > 0;
  const divider = document.createElement('div');
  divider.style.height = '1px';
  divider.style.background = '#E4E7E1';
  divider.style.margin = hasFigure ? '8px -14px 6px' : '6px -14px 4px';
  root.append(divider);

  const hint = document.createElement('div');
  hint.textContent = 'Click to explore →';
  hint.style.fontSize = '10px';
  hint.style.fontWeight = '500';
  hint.style.color = '#2E6F40';
  root.append(hint);

  return root;
}
