/**
 * The residual window (docs/methodology.md §7.1): whether a city's ecological
 * residual carries information beyond its two inputs. pipeline/
 * residual_diagnostics.R writes it per run and per scale into each dataset's
 * manifest at metricDefinitions.ecologicalResidual.window.
 *
 * Outside the window the residual is one of its inputs re-rendered — on every
 * dataset so far, the observation with its sign flipped — so the map withholds
 * the layers built on it (methodology §8.4). Pure module: no Storage or
 * Supabase access, so paint and panel code can import it freely.
 */

export type ResidualRegime =
  | 'observation-dominated'
  | 'informative'
  | 'model-dominated'
  | 'undetermined';

export type ResidualWindowScale = {
  regime: ResidualRegime;
  n: number | null;
  lambda: number | null;
  sharedVarianceWithObserved: number | null;
  lower: number | null;
  upper: number | null;
};

export type ResidualWindow = {
  hex: ResidualWindowScale | null;
  patch: ResidualWindowScale | null;
};

const REGIMES: ReadonlySet<string> = new Set<ResidualRegime>([
  'observation-dominated',
  'informative',
  'model-dominated',
  'undetermined',
]);

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

// The manifest writes NA as null, and any of these can be NA in any regime
// (rho when the expectation is constant, the correlations when the residual
// has no spread), so every number is optional.
function finiteOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function parseScale(value: unknown): ResidualWindowScale | null {
  const scale = asRecord(value);
  const regime = scale?.regime;
  if (!scale || typeof regime !== 'string' || !REGIMES.has(regime)) return null;
  const bounds = asRecord(scale.window);
  return {
    regime: regime as ResidualRegime,
    n: finiteOrNull(scale.n),
    lambda: finiteOrNull(scale.lambda),
    sharedVarianceWithObserved: finiteOrNull(scale.sharedVarianceWithObserved),
    lower: finiteOrNull(bounds?.lower),
    upper: finiteOrNull(bounds?.upper),
  };
}

/**
 * Null when the manifest predates the window block (or is unreadable), which
 * keeps today's behaviour. Never throws: the server vector route shares the
 * module that calls this.
 */
export function residualWindowFromManifest(manifest: unknown): ResidualWindow | null {
  const block = asRecord(
    asRecord(asRecord(asRecord(manifest)?.metricDefinitions)?.ecologicalResidual)?.window,
  );
  if (!block) return null;
  const hex = parseScale(block.hex);
  const patch = parseScale(block.patch);
  return hex || patch ? { hex, patch } : null;
}

/** Whether to withhold the residual-based layers at this scale. Unknown keeps them. */
export function gapMapUnsupported(scale: ResidualWindowScale | null | undefined): boolean {
  return scale != null && scale.regime !== 'informative';
}

/**
 * Two significant digits, with more only when two would round onto the bound:
 * a λ of 0.2496 must not read "0.25; needs 0.25 or more".
 */
function formatLambda(value: number, bound: number): string {
  for (const digits of [2, 3, 4]) {
    const shown = Number(value.toPrecision(digits));
    if (shown !== bound) return String(shown);
  }
  return String(value);
}

function formatShare(share: number): string {
  // Rounding 99.94% up to "100%" would claim the difference *is* the
  // observation; three of four cities sit in that range.
  return share >= 0.995 ? 'more than 99%' : `${Math.round(share * 100)}%`;
}

/** One plain sentence on why the gap map is withheld, with the city's own numbers. */
export function residualWindowReason(cityName: string, scale: ResidualWindowScale): string {
  const lower = scale.lower ?? 0.25;
  const upper = scale.upper ?? 4;

  switch (scale.regime) {
    case 'observation-dominated': {
      const what = scale.sharedVarianceWithObserved != null
        ? `the difference is ${formatShare(scale.sharedVarianceWithObserved)} the observations themselves`
        : 'the difference mostly repeats the observations';
      const numbers = scale.lambda != null
        ? ` (λ ${formatLambda(scale.lambda, lower)}; needs ${lower} or more)`
        : '';
      return `${cityName}’s wildlife records can’t support a gap map yet: ${what}${numbers}.`;
    }
    case 'model-dominated': {
      const numbers = scale.lambda != null
        ? ` (λ ${formatLambda(scale.lambda, upper)}; needs ${upper} or less)`
        : '';
      return `In ${cityName} the difference mostly repeats the habitat model rather than the records${numbers}.`;
    }
    case 'undetermined':
      // residual_window() reports 'undetermined' both for too few units (e.g.
      // no parks scored) and for an observation with no spread.
      return scale.n == null || scale.n < 2
        ? `${cityName} has too few assessed places at this scale to test whether a gap map would hold.`
        : `${cityName}’s records vary too little to test whether a gap map would hold.`;
    default:
      return '';
  }
}
