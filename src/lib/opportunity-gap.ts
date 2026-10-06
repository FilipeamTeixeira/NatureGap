/**
 * The opportunity gap — "Nature gap" on the map (docs/methodology.md §15).
 *
 * Expected native species each place's surroundings support now, and how many
 * more the city's species models expect in real places that are alike (same
 * land use; similar water, noise, traffic and light) but in the greener
 * quarter. Negative where those greener places hold fewer of the species
 * expected here — often open, rough or wet ground whose species would lose out
 * to trees. Every taxon group counts; each carries its city's label from its
 * own records test, so the map can say how much of a number has been checked.
 *
 * Sources (docs/data-contract.md): manifest `metricDefinitions.opportunityGap`,
 * tile fields expectedSpecies / opportunityGap / opportunityGapChecked /
 * opportunityOnly, the cell-details `opportunity` JSON string and park-stats
 * `opportunity`. Pure module, like residual-window.ts.
 */

export type OpportunityGroupId = 'bird' | 'mammal' | 'plant' | 'insect' | 'fungi' | 'other';
export type OpportunityGroupLabel = 'checked' | 'mismatch' | 'insufficient';
/** Which tile field the layer draws: every group, or only the checked ones. */
export type OpportunityMode = 'all' | 'checked';

export const OPPORTUNITY_GROUP_ORDER: readonly OpportunityGroupId[] = [
  'bird', 'mammal', 'plant', 'insect', 'fungi', 'other',
];

/** classify_taxon_group() names; "mammal" there is every vertebrate but birds. */
export const OPPORTUNITY_GROUP_NAMES: Record<OpportunityGroupId, string> = {
  bird: 'Birds',
  mammal: 'Mammals, amphibians, reptiles & fish',
  plant: 'Plants',
  insect: 'Insects & spiders',
  fungi: 'Fungi',
  other: 'Snails & other invertebrates',
};

export const OPPORTUNITY_LABEL_TEXT: Record<OpportunityGroupLabel, string> = {
  checked: 'Checked against records',
  mismatch: 'Didn’t match the records',
  insufficient: 'Too few records to check',
};

/** At or below: greener places like this one hold fewer of its species. */
export const OPPORTUNITY_LOSS_AT = -1;
/** At or above: a gain worth colouring; between the two reads as no clear gain. */
export const OPPORTUNITY_GAIN_AT = 0.5;

export type OpportunityBand = 'gain' | 'same' | 'loss' | 'none';

export function opportunityBand(gap: number | null | undefined): OpportunityBand {
  if (typeof gap !== 'number' || !Number.isFinite(gap)) return 'none';
  if (gap <= OPPORTUNITY_LOSS_AT) return 'loss';
  if (gap >= OPPORTUNITY_GAIN_AT) return 'gain';
  return 'same';
}

export interface OpportunityGroupInfo {
  label: OpportunityGroupLabel;
  species: number;
}

/** One city's opportunity gap, from its manifest. */
export interface OpportunityGapInfo {
  speciesCounted: number;
  groups: Partial<Record<OpportunityGroupId, OpportunityGroupInfo>>;
  /** 90th percentile of the per-cell gap, which the layer's ramp tops out at. */
  gapP90: number | null;
  /** The checked groups' part of all change, gains and losses alike (0–1). */
  checkedShare: number | null;
  rareSpecies: number | null;
}

export interface CellOpportunityGroup {
  group: OpportunityGroupId;
  label: OpportunityGroupLabel | null;
  expected: number | null;
  gap: number | null;
  top: string[];
}

/** One cell's (or one park's mean) opportunity gap. */
export interface CellOpportunity {
  expected: number | null;
  gap: number | null;
  gapChecked: number | null;
  /** Empty for parks and for the tile-only preview. */
  groups: CellOpportunityGroup[];
  top: string[];
  rare: { count: number; species: string[] } | null;
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

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];
}

function isGroupId(value: unknown): value is OpportunityGroupId {
  return typeof value === 'string' && (OPPORTUNITY_GROUP_ORDER as readonly string[]).includes(value);
}

function isLabel(value: unknown): value is OpportunityGroupLabel {
  return value === 'checked' || value === 'mismatch' || value === 'insufficient';
}

/** Null when the manifest predates the stage or the stage did not run. */
export function opportunityGapFromManifest(manifest: unknown): OpportunityGapInfo | null {
  const definitions = asObject(asObject(manifest)?.metricDefinitions);
  const block = asObject(definitions?.opportunityGap);
  if (!block || block.computed !== true) return null;

  const labels = asObject(block.labels) ?? {};
  const groups: OpportunityGapInfo['groups'] = {};
  for (const [group, entry] of Object.entries(labels)) {
    const value = asObject(entry);
    if (!isGroupId(group) || !value || !isLabel(value.label)) continue;
    groups[group] = { label: value.label, species: finite(value.species) ?? 0 };
  }

  const summary = asObject(block.summary);
  const checkedShare = finite(summary?.checkedGapShare);
  return {
    speciesCounted: finite(asObject(block.species)?.counted) ?? 0,
    groups,
    gapP90: finite(summary?.gapP90),
    // A share outside 0–1 is the net-gap definition from before 6c.9, which
    // breaks when groups pull in opposite directions; it is not shown.
    checkedShare: checkedShare != null && checkedShare >= 0 && checkedShare <= 1 ? checkedShare : null,
    rareSpecies: finite(asObject(block.rare)?.species),
  };
}

/**
 * The cell-details `opportunity` field (a JSON string, like `species`) or a
 * park's `opportunity` means. Null when absent.
 */
export function parseCellOpportunity(value: unknown): CellOpportunity | null {
  let parsed: unknown = value;
  if (typeof value === 'string') {
    try {
      parsed = JSON.parse(value);
    } catch {
      return null;
    }
  }
  const object = asObject(parsed);
  if (!object) return null;

  const groups = Array.isArray(object.groups)
    ? object.groups.flatMap((entry): CellOpportunityGroup[] => {
        const group = asObject(entry);
        if (!group || !isGroupId(group.group)) return [];
        return [{
          group: group.group,
          label: isLabel(group.label) ? group.label : null,
          expected: finite(group.expected),
          gap: finite(group.gap),
          top: strings(group.top),
        }];
      })
    : [];
  const rare = asObject(object.rare);

  return {
    expected: finite(object.expected),
    gap: finite(object.gap),
    gapChecked: finite(object.gapChecked),
    groups,
    top: strings(object.top),
    rare: rare ? { count: finite(rare.count) ?? 0, species: strings(rare.species) } : null,
  };
}

/** The click preview, from tile properties alone, until the full detail loads. */
export function opportunityFromRender(render: {
  expectedSpecies?: number | null;
  opportunityGap?: number | null;
  opportunityGapChecked?: number | null;
}): CellOpportunity | null {
  if (render.expectedSpecies == null && render.opportunityGap == null) return null;
  return {
    expected: render.expectedSpecies ?? null,
    gap: render.opportunityGap ?? null,
    gapChecked: render.opportunityGapChecked ?? null,
    groups: [],
    top: [],
    rare: null,
  };
}

/** "+3.2", "−1.4", "0" — species counts to one decimal with a real minus sign. */
export function formatSpeciesChange(value: number): string {
  const rounded = Math.round(value * 10) / 10;
  if (rounded === 0) return '0';
  const text = Math.abs(rounded).toFixed(1).replace(/\.0$/, '');
  return rounded > 0 ? `+${text}` : `−${text}`;
}
