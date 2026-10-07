/**
 * Green focus — the "Nature gap" layer (docs/methodology.md §16).
 *
 * Green places (the cells the Tree cover and Vegetation layers draw) classed
 * by two tests: a connectivity role — a stepping-stone habitat patch,
 * a top corridor cell, a corridor bottleneck, or thin green such as street
 * trees carrying more corridor routes than most thin green — and at least one
 * native species recorded nearby. `protect` additionally needs calmer and
 * cooler conditions than most green places. Nothing here predicts species.
 *
 * Sources (docs/data-contract.md): manifest `metricDefinitions.greenFocus`,
 * tile fields focusClass / focusHint / speciesNearby, and the cell-details
 * `focus` JSON string. Pure module, like opportunity-gap.ts.
 */

export type FocusClass = 'focus' | 'link' | 'protect' | 'green';
export type FocusHint = 'low' | 'moderate' | 'high';

export const FOCUS_CLASS_ORDER: readonly FocusClass[] = ['focus', 'link', 'protect', 'green'];

export const FOCUS_COLORS: Record<FocusClass, string> = {
  focus: '#7B3294',
  link: '#E66101',
  protect: '#1B7837',
  green: '#D9F0D3',
};

/** Darker text colours for the same classes, readable on white. */
export const FOCUS_TEXT_COLORS: Record<FocusClass, string> = {
  focus: '#5A1F6E',
  link: '#A34400',
  protect: '#1B5E2E',
  green: '#4F6B4F',
};

export const FOCUS_CLASS_TEXT: Record<FocusClass, { label: string; headline: string }> = {
  focus: { label: 'Focus here', headline: 'Links nature and has species — worth protecting' },
  link: { label: 'Link worth keeping', headline: 'Links nature — no species recorded here yet' },
  protect: { label: 'Worth protecting', headline: 'Species recorded in calm, cool green' },
  green: { label: 'Green space', headline: 'Green space' },
};

export const FOCUS_HINT_TEXT: Record<FocusHint, string> = {
  low: 'Calm and cool: protect it as it is',
  moderate: 'Some heat, noise or traffic',
  high: 'Hot, noisy or busy: relieving the pressure would help',
};

export interface CellFocus {
  focusClass: FocusClass;
  roles: { stepping: boolean; corridor: boolean; bottleneck: boolean; thinCorridor: boolean } | null;
  steppingPct: number | null;
  corridorImportance: number | null;
  thinCorridorPct: number | null;
  speciesNearby: number | null;
  speciesInCell: number | null;
  /** Share of the city's green places hotter / more disturbed than this one is 1 − these. */
  heatPct: number | null;
  disturbancePct: number | null;
  hint: FocusHint | null;
  inPark: boolean | null;
}

export interface GreenFocusInfo {
  speciesRadiusM: number | null;
  classes: Partial<Record<FocusClass, number>>;
}

function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function finite(value: unknown): number | null {
  if (value == null || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

export function isFocusClass(value: unknown): value is FocusClass {
  return typeof value === 'string' && (FOCUS_CLASS_ORDER as readonly string[]).includes(value);
}

function isHint(value: unknown): value is FocusHint {
  return value === 'low' || value === 'moderate' || value === 'high';
}

/** Null when the manifest predates the stage or the stage did not run. */
export function greenFocusFromManifest(manifest: unknown): GreenFocusInfo | null {
  const block = asObject(asObject(asObject(manifest)?.metricDefinitions)?.greenFocus);
  if (!block || block.computed !== true) return null;
  const classes: GreenFocusInfo['classes'] = {};
  for (const [key, count] of Object.entries(asObject(block.classes) ?? {})) {
    if (isFocusClass(key)) classes[key] = finite(count) ?? 0;
  }
  return { speciesRadiusM: finite(asObject(block.settings)?.speciesRadiusM), classes };
}

/** The cell-details `focus` field (a JSON string). Null when absent. */
export function parseCellFocus(value: unknown): CellFocus | null {
  let parsed: unknown = value;
  if (typeof value === 'string') {
    try {
      parsed = JSON.parse(value);
    } catch {
      return null;
    }
  }
  const object = asObject(parsed);
  if (!object || !isFocusClass(object.class)) return null;
  const roles = asObject(object.roles);
  return {
    focusClass: object.class,
    roles: roles ? {
      stepping: roles.stepping === true,
      corridor: roles.corridor === true,
      bottleneck: roles.bottleneck === true,
      thinCorridor: roles.thinCorridor === true,
    } : null,
    steppingPct: finite(object.steppingPct),
    corridorImportance: finite(object.corridorImportance),
    thinCorridorPct: finite(object.thinCorridorPct),
    speciesNearby: finite(object.speciesNearby),
    speciesInCell: finite(object.speciesInCell),
    heatPct: finite(object.heatPct),
    disturbancePct: finite(object.disturbancePct),
    hint: isHint(object.hint) ? object.hint : null,
    inPark: typeof object.inPark === 'boolean' ? object.inPark : null,
  };
}

/** The click preview, from tile properties alone, until the full detail loads. */
export function focusFromRender(render: {
  focusClass?: string | null;
  focusHint?: string | null;
  speciesNearby?: number | null;
}): CellFocus | null {
  if (!isFocusClass(render.focusClass)) return null;
  return {
    focusClass: render.focusClass,
    roles: null,
    steppingPct: null,
    corridorImportance: null,
    thinCorridorPct: null,
    speciesNearby: render.speciesNearby ?? null,
    speciesInCell: null,
    heatPct: null,
    disturbancePct: null,
    hint: isHint(render.focusHint) ? render.focusHint : null,
    inPark: null,
  };
}

/** "more than 70%" style share of green places this one beats, from a 0–1 rank (low = good). */
function betterThan(pct: number | null): number | null {
  return pct == null ? null : Math.round((1 - pct) * 100);
}

/**
 * The plain-language reasons behind a cell's class, in the order a reader
 * needs them: what it does for movement, what lives there, its conditions.
 */
export function focusReasons(focus: CellFocus, speciesRadiusM: number | null = 50): string[] {
  const out: string[] = [];
  const r = focus.roles;
  if (r?.stepping) out.push('A stepping stone: other green places are better connected through this one');
  if (r?.corridor) out.push('Among the city’s busiest wildlife routes');
  if (r?.thinCorridor) out.push('Street trees or a green strip that carries wildlife routes between larger green areas');
  if (r?.bottleneck) out.push('On a weak stretch of a corridor, where little green is left');
  const n = focus.speciesNearby;
  const radius = speciesRadiusM ?? 50;
  if (n != null) {
    out.push(n > 0
      ? `${n} native species recorded within ${radius} m`
      : `No native species recorded within ${radius} m yet — worth a survey`);
  }
  const cooler = betterThan(focus.heatPct);
  const quieter = betterThan(focus.disturbancePct);
  if (cooler != null && quieter != null) {
    out.push(`Cooler than ${cooler}% and quieter than ${quieter}% of the city’s green places`);
  }
  if (focus.inPark) out.push('Inside a park');
  return out;
}
