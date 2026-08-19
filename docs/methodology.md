# Methodology Notes

This document describes NatureGap's analytical methods, assumptions, and known
limitations. All ecological and spatial calculations originate in the R pipeline.
PostgreSQL/PostGIS stores R outputs and performs live record-to-cell assignment.
PMTiles and MapLibre are presentation layers.

## 1. Source Of Truth

The R pipeline is the only authoritative source for:

- habitat quality
- observer effort correction
- expected richness
- ecological residual
- Nature Gap score
- connectivity metrics
- intervention score and ranking
- pressure strings and detail-panel scientific summaries

Frontend fallbacks in `src/lib/cell-detail.ts` are local/demo safeguards only.
They must not be treated as scientific outputs.

## 2. Spatial Grid

Resolution:

```text
20 m hexagons
```

Generated with:

```r
sf::st_make_grid(area, cellsize = 20, square = FALSE)
```

CRS:

- Local processing uses each city's national projected CRS, set as `CRS_LOCAL`
  in `pipeline/cities/<city>.R`:
  - `yokohama-honmoku`: JGD2011 / Japan Plane Rectangular CS VI, `EPSG:6674`
  - `amsterdam-schimmelstraat`: Amersfoort / RD New, `EPSG:28992`
  - `porto-center`: ETRS89 / Portugal TM06, `EPSG:3763`
- Web/PostGIS export: WGS84, `EPSG:4326`

Contract:

- The 20 m hex grid is the only analytical grid.
- The same cell IDs connect R outputs, PMTiles features, PostgreSQL
  `cell_attributes`, quick sightings, structured surveys, and detail lookup.
- Do not introduce a secondary analytical grid.
- Unsampled cells are excluded from residual inference, not treated as zero.

## 3. Input Streams

External observations:

- iNaturalist
- GBIF

Application observations:

- `quick_sightings`: opportunistic, presence-only, zero weight in
  effort-corrected richness
- `structured_surveys` + `survey_records`: protocol-based, time-bounded,
  higher analytical weight, effort metadata, habitat indicators

Current implementation note:

- The R pipeline reads iNaturalist and GBIF raw files, plus approved app
  observations exported from Supabase.
- That export is implemented: `pipeline_observations_export` (PostgreSQL view)
  → `pipeline/01_ingest/export_supabase_observations.R` →
  `raw/supabase_observations.gpkg`, read by the tiled observation standardisation
  in `pipeline/02_habitat/process_tile.R`.
- It runs only when `SUPABASE_OBSERVATIONS_ENABLED="1"` (or
  `SUPABASE_OBSERVATIONS_REQUIRED="1"`) is set for the run. With the flag unset
  or `"0"`, app observations stay transactional records and map overlays and
  reach no model output. See docs/pipeline-runbook.md.
- Weights applied at import: `structured_survey` = 3, `quick_sighting` = 0,
  anything else = 1.

Eligibility rules for app observations before R import:

- Exclude rejected records.
- Exclude records with pending or confirmed quality flags.
- Preserve raw geometry.
- Preserve GPS accuracy.
- Preserve structured-survey effort and habitat indicators.
- Preserve the assigned 20 m `cell_id` when available.

## 4. Habitat Quality Index

Habitat quality is computed per tile in
`pipeline/02_habitat/process_tile.R` (`finish_citywide_metrics()`), which
`pipeline/02_habitat/habitat_model.R` drives and whose output it writes.

Current implementation:

```text
habitat_quality =
  0.50 * ndvi_idx
  + 0.286 * lst_idx
  + 0.214 * (1 - disturbance_idx)
```

Sub-indexes:

| Sub-index | Source | Transformation | Rationale |
| --- | --- | --- | --- |
| `ndvi_idx` | Sentinel-2 B4/B8 | NDVI rescaled from [-0.2, 1.0] | Photosynthetically active vegetation |
| `lst_idx` | Landsat ST_B10 | `1 - percentile_rank(lst_celsius)` | Cooler cells are less heat-stressed |
| `disturbance_idx` | OSM footways/paths/tracks and amenities | `rescale01(0.60 * path_density + 0.40 * amenity_proximity)` | Human presence and access proxy disturbance |

There is no `green_idx` term: green cover enters through `ndvi_idx` rather than
through an OSM/landcover area fraction. Path density is not a standalone term
either — it enters only inside `disturbance_idx`, and separately (as a length,
not a density) in the effort correction of section 5.

Other stressor and context features are computed on the same grid and exported
but do **not** enter `habitat_quality`: `noise` (road/rail density and
proximity), `light_pollution` (street lamps, lit roads), `water_proximity`,
`heat_exposure` (the un-inverted LST rank), `built_fraction_wc`,
`impervious_fraction`, `tree_fraction`, and `canopy_height_idx`.

Limitations:

- Weights are expert-assigned and not yet empirically calibrated.
- NDVI does not distinguish native vegetation from ornamental or invasive cover.
- OSM completeness varies by city, and `disturbance_idx` inherits that.
- LST is date-sensitive; the pipeline composites three seasonal windows
  (`LST_SEASON_WINDOWS`), but a single growing season still anchors it.
- `habitat_quality` has a narrow dynamic range in dense cities (Amsterdam
  interquartile range 0.436–0.598), which is why connectivity resistance is
  built from permeability instead (section 9).

Where a national CIR orthophoto is available (Portugal DGT Ortos, Netherlands
PDOK luchtfoto CIR), ingest also writes `veg_fraction` (share of 0.5 m pixels
with DN-based NDVI ≥ 0.2) and `ndvi_texture` (within-hex SD of that NDVI).
These are supplementary hex attributes. They do **not** enter `habitat_quality`,
which continues to use Sentinel-2 `ndvi_idx` so cities stay comparable.

## 5. Observer Effort Correction

Effort correction is computed in `pipeline/02_habitat/process_tile.R`
(`finish_citywide_metrics()`), on the same tiled pass that builds habitat
quality. `pipeline/03_observations/observation_layer.R` is the contract gate for
it: it fails the run if a sampled cell lacks `survey_effort_units` or
`observed_richness`, or if an unsampled cell carries either, then writes
`grid_observations.gpkg` and the per-cell taxa JSON.

Problem:

Citizen-science observations cluster where people walk. Raw richness therefore
confounds biodiversity with observer effort.

Canonical formula:

```text
survey_effort_units_i = log(1 + path_local_m_i)

effort_corrected_richness_i =
  species_richness_i / survey_effort_units_i

observed_richness_i =
  effort_corrected_richness_i
```

Where:

- `species_richness_i` is the distinct species count in cell `i`.
- `path_local_m_i` is OSM pedestrian path length, in metres, within
  `PATH_RADIUS_M` (40 m) of cell `i`'s centroid. A 20 m hex is ~350 m², so a
  path centreline only clips a narrow ribbon of cells: measuring the cell
  alone marks a cell one hex off a footway as unsampled even though it is
  plainly observable from that footway.
- the denominator is a length in metres. `log1p` of a length in kilometres is
  inert at this cell size (`log1p(x) ≈ x` for `x` ≈ 0.02), which turned effort
  correction into division by a near-zero denominator.
- `path_km_i` is the per-cell intersected length. It is still exported for
  transparency but no longer drives effort correction.
- `survey_effort_units_i` is the explicit effort denominator used by every
  city pipeline run.
- `observed_richness_i` is the exported biodiversity metric used by hex,
  patch, and detail outputs. It is intentionally effort-normalised, not raw
  species count.

Unsampled rule:

```text
if path_local_m_i < MIN_PATH_M (50 m):
  is_unsampled_i = true
  survey_effort_units_i = NA
  observed_richness_i = NA
  effort_corrected_richness_i = NA
```

Unsampled cells are excluded from residual inference. They are not zero-richness
cells.

Missing-value rule:

- Sampled cells with no records keep `survey_effort_units_i > 0` and export
  `observed_richness_i = 0`.
- Unsampled cells export `observed_richness_i = NA`; exporters may coalesce to
  `0` only for render-only PMTiles fields that cannot style nulls reliably.
- Patch-level `observed_richness` is aggregated from the same cell-level
  `observed_richness` field, weighted by cell/patch overlap, so patch and hex
  values use the same pipeline semantics.

Structured-survey rule:

- Structured surveys receive analytical weight; quick sightings remain
  presence-only and do not affect effort-corrected richness.
- Live Supabase survey import is wired through `pipeline_observations_export`
  and `raw/supabase_observations.gpkg`.
- Structured-survey effort metadata affects effort summaries and weighting in R,
  not SQL or frontend code.

Limitations:

- Path length is a proxy for observer effort, not direct effort.
- It does not fully account for observer skill, seasonal effort, private access,
  or unmapped paths.
- GPS accuracy is stored and should be used in weighting/quality decisions, but
  final weighting details should remain in R.

## 6. Expected Richness

Expected richness is modelled at two levels.

### 6.1 Per-hex expected index (`pipeline/05_residuals/residuals.R`)

A relative, index-like value per 20 m hex, used only for the hex-level map
layers and the per-hex ecological residual:

```text
expected_richness_i =
  SPECIES_AREA_C * (CELL_SIZE ^ 2) ^ SPECIES_AREA_Z * (
    0.65 * habitat_quality_i
    + 0.20 * corridor_importance_i
    + 0.15 * accessibility_component_i
  )
```

Where:

- `SPECIES_AREA_C = 12` and `SPECIES_AREA_Z = 0.25`, the same species-area
  parameters used at patch level (section 6.2), with the hex's own area
  (`CELL_SIZE^2 = 400 m²`) as the area input. One model, two area scales.
- the area term is therefore a constant `12 * 400^0.25 ≈ 53.7` for every hex,
  which is the ceiling of `expected_richness` at quality 1.
- `accessibility_component_i = log1p(path_local_m_i) / log1p(max_path_local_m)`
  clamped to `[0, 1]`, and `0` for unsampled cells

**This replaces an earlier `MAX_EXPECTED_RICHNESS * (...)` formulation**, which
put the hex ceiling at 350 species — an implausible per-20 m-hex figure, and
inconsistent with the patch-level species-area model. `MAX_EXPECTED_RICHNESS`
(350) is still exported as `max_expected_richness` for transparency and is read
by the frontend, but it no longer scales expected richness.

This is a within-city relative index for hex comparison, not a species count and
not calibrated per city.

### 6.2 Patch (park) expected richness (`pipeline/05_patch/patch_aggregation.R`)

Per-park expected richness must scale with total park area — larger areas
support more species (the species-area relationship), all else equal. It is
therefore computed **once per patch** from total patch area using a power law,
not by averaging the per-hex index (an area-weighted average does not scale with
size, so a small park and a large park of similar per-hex quality would
otherwise get nearly the same expected richness):

```text
expected_richness_patch =
  SPECIES_AREA_C * (patch_area_m2 ^ SPECIES_AREA_Z) * quality_modifier
```

Where:

- `patch_area_m2` is the park's total area.
- `quality_modifier` is the area-weighted mean of `habitat_quality_index`,
  `corridor_importance`, and accessibility across the park's hexes, clamped to
  `[0, 1]`. Averaging is appropriate here because these are intensive
  properties, not counts.
- `SPECIES_AREA_Z = 0.25` is the species-area exponent. **This value is an
  assumption informed by general species-area relationship literature, not
  calibrated to Yokohama or Amsterdam specifically, and not sourced to a
  specific citation.** It is set within the commonly cited 0.2–0.3 range pending
  a proper literature review / local calibration.
- `SPECIES_AREA_C = 12` is a scaling constant chosen so `expected_richness`
  lands in a plausible range across the actual park-area distribution in both
  cities (roughly 20 m² to 3.4×10⁵ m²). It is a tuning constant, not a
  measured quantity.

Limitations:

- `SPECIES_AREA_Z` and `SPECIES_AREA_C` are documented assumptions, not
  calibrated or cited values, and they now set the scale at both hex and patch
  level.
- Neither scale is calibrated per city.
- Regional species-pool constraints are not yet modelled.

## 7. Ecological Residual

Ecological residual is computed in `pipeline/05_residuals/residuals.R`.

Formula:

```text
ecological_residual_raw_i =
  expected_richness_i - observed_richness_i

ecological_residual_normalized_i =
  (ecological_residual_raw_i - city_mean(ecological_residual_raw)) /
  city_stddev(ecological_residual_raw)
```

**The residual is expected minus observed — a gap, not a surplus.** It is
signed so that the headline metric and the residual point the same way: bigger
means further below expectation. The patch-level residual in
`pipeline/05_patch/patch_aggregation.R` uses the same orientation.

Interpretation:

- `ecological_residual` stores the raw expected-minus-observed value for
  backend analytics.
- `ecological_residual_normalized` stores the city-wise standardized residual,
  exported for analytics and detail panels.
- **Positive** residual: fewer species recorded than expected — habitat
  pressure, restoration priority.
- **Negative** residual: more species recorded than expected — above
  expectation, potential refuge.
- Near zero: observed richness aligns with expectation
- Unsampled: `NA`

Rendering uses `residualNorm` (`norm_diverging(ecological_residual)` in
`06_export/export.R`: the raw residual divided by the larger of |p10| and |p90|,
clamped to `[-1, 1]`), not `ecological_residual_normalized`. Raw backend values
are not clamped. `src/lib/layer-styles.ts` colours `+1` red and `-1` green,
following the sign convention above.

## 8. Nature Gap Score

Nature Gap score is computed in `pipeline/05_residuals/residuals.R`.

Current implementation:

```text
bio_residual_norm_i =
  clamp(ecological_residual_i / max_abs(ecological_residual), -1, 1)

nature_gap_score_i =
  (
    0.50 * bio_residual_norm_i +
    0.30 * (1 - habitat_quality_i) +
    0.20 * (1 - corridor_importance_i)
  ) * 100
```

Where `max_abs(ecological_residual)` is the largest absolute finite residual in
the city. The biodiversity term is scaled by that maximum, not by the standard
deviation: `ecological_residual_normalized` is exported alongside it but does
not enter the score.

Interpretation (the residual is expected minus observed, so the score rises as
a cell underperforms):

- **Positive** Nature Gap score: ecosystem under pressure — the gap is real
- **Negative** Nature Gap score: ecological surplus
- Zero: near expected or no finite residual range
- Range: `[-50, +100]` — the biodiversity term spans `±50`, the two deficit
  terms add `0` to `+50`

This is intentionally separate from `ecological_residual`. PMTiles expose
`natureGapScore` (plus `natureGapScoreNorm` for styling), and
`ecologicalResidual` / `ecologicalResidualNormalized` / `residualNorm` for the
residual layer. `impactScore` is also exported — a legacy field holding
`round(bio_residual_norm * 50)`, i.e. the biodiversity term alone. Prefer
`natureGapScore`.

Current colour/status thresholds (`SCORE_THRESHOLDS` in `src/lib/config.ts`, the
single source of truth for `src/lib/utils.ts` and
`src/lib/cell-detail.ts`):

| Nature Gap score range | Status |
| --- | --- |
| `< -15` | `much-better` |
| `< -5` | `better` |
| `< 10` | `as-expected` |
| `< 20` | `worse` |
| `>= 20` | `much-worse` |

**Known calibration issue.** The two deficit terms can only add to the score:
`0.30 * (1 - habitat_quality)` and `0.20 * (1 - corridor_importance)` are
non-negative by construction, and `corridor_importance` is 0 for every cell
carrying no route at all — which is most of the grid. The score is therefore
strongly biased positive in practice. Measured on the current Porto export
(`city_layer_stats.json`): `nature_gap_score` spans 8.7 to 62.0 with
p05–p95 = 54.5–59.7, and `ecological_residual` spans -18.5 to 48.9 with
p05–p95 = 10.3–38.2. Two consequences:

- Every band above resolves to `much-worse`, so the five-band scale carries no
  information on that dataset.
- `natureGapScoreNorm` and `residualNorm` divide by `max(|p10|, |p90|)` without
  centring, so a distribution that never crosses zero maps almost entirely onto
  one arm of the diverging ramp and the map renders near-uniform.

Both are calibration problems, not sign problems: the direction is correct
(Porto's cells genuinely record fewer species than the habitat model predicts).
Fixing them means either re-centring the render normalisation on the city median,
or rescaling the score so the bands describe within-city variation. Neither is
done yet, and both change published numbers, so they are deliberately left as
documented behaviour.

## 9. Connectivity Analysis

Connectivity is computed in `pipeline/04_connectivity/connectivity.R`.

Graph construction:

- Nodes: 20 m hex centroids, restricted to cells above `CONN_MIN_PERMEABILITY`
- Edges: hexes that share a boundary (`sf::st_touches`)
- Edge weight: centroid distance scaled by the mean habitat resistance of the
  two cells it joins
- Graph engine: `igraph`

Permeability and resistance:

    permeability = vegetation * (1 - built_fraction_wc)
    resistance   = 1 + (CONN_MAX_RESISTANCE - 1) * (1 - permeability)

`vegetation` is `veg_fraction` where available, falling back to
`tree_fraction + shrub_fraction + grass_fraction` and then `green_fraction_wc`
(Yokohama has no `veg_fraction`; the fallbacks correlate 0.78 with it on
Amsterdam and are close to binary, so corridors are blockier there — see
section 4 on where `veg_fraction` comes from).

Resistance is floored at 1 rather than reaching 0, so ideal habitat still costs
its true length; zero-cost edges make shortest paths degenerate. Cells below
the permeability floor are dropped from the graph entirely rather than carried
at high cost — nothing disperses through a building — and they receive `NA`
corridor values, not zero.

**This replaces an earlier specification of `resistance = 1 - habitat_quality`,
which was documented but never implemented.** It does not work in practice:
`habitat_quality` is an NDVI-led blend with almost no dynamic range (Amsterdam
interquartile range 0.436–0.598) that scores a cell which is 87.5% built and
3.3% vegetated at 0.515. Resistance derived from it varies only between about
8.6 and 11.7 city-wide, producing a near-uniform lattice on which betweenness
degenerates into geometry. Measured on Amsterdam, that formulation left 205
isolated top-decile "corridor" cells; the formulation above leaves 5.

Until this change, corridors were computed on the **OSM pedestrian path
network** rather than on habitat at all — betweenness over footway junctions,
transferred to cells by nearest-node snap. That ranked busy streets as prime
habitat links, made green space with no footway invisible, and produced
scattered single-cell corridors with nothing adjacent to them. Paths now appear
only in observation-effort correction (section on effort), where they belong:
they model where observers walk, not where wildlife can move.

Metrics:

- `betweenness_centrality`: raw dispersal-limited betweenness on the graph
  above, capped at `CONN_DISPERSAL_M` effective metres (1 unit = 1 m through
  ideal habitat). The cap is both an ecological statement — dispersal is
  bounded, organisms do not route across an entire city — and what keeps the
  computation tractable.
- `corridor_importance`: `betweenness_centrality` expressed as a percentile
  rank among the cells that carry any route at all, so it spans 0–1. Cells with
  no route through them stay at 0 rather than being ranked up into the lower
  percentiles: they are not weak corridors, they are not corridors. This is the
  value used for intervention ranking.

The percentile step matters for more than presentation. Raw betweenness is a
tiny, heavily skewed number — on the old path graph Amsterdam's maximum was
0.0187 against a median of 0 — so every absolute threshold downstream
(`corridor_importance > 0.7` for the corridor intervention,
`> 0.25` for the corridor pressure note) was unreachable and had never once
fired. Ranking restores a scale those thresholds can express.

### 9a. Derived ecological network

The 20 m cells are the analytical surface, but they are not the map's primary
representation. `pipeline/04_connectivity/network_derive.R` reduces them to a
simplified network — habitat-core nodes joined by corridors — which is what the
connectivity layer draws at overview and transition zoom. The cells themselves
fade in only at analytical zoom (`NETWORK_REGIME.handover` in
`lib/layer-styles.ts`).

The order is nodes first, then routes between them. The reverse order — take the
high-importance cells, skeletonise, draw every branch — was the previous
implementation and is structurally incapable of producing a city-scale network:
cutting the graph at the importance threshold *before* deriving topology means no
corridor can cross degraded ground, so every high-importance blob becomes its own
island. Porto came out as 130 disconnected components and 420 segments with a
median length of 84 m.

**Routing surface.** Corridors are routed on a graph built from *every* grid cell,
walls included at `CONN_MAX_RESISTANCE` (`build_routing_graph()`). The betweenness
graph cannot serve: it drops cells below `CONN_MIN_PERMEABILITY`, which leaves it
in 520–1375 disconnected components with its largest holding 8–20% of cells, so
four candidate connections in five were unreachable. Whether a corridor should
cross weak ground is decided by the cost ceilings below, not by a missing edge.

Derivation, per city:

1. **Habitat cores.** Cells at or above `NET_CORE_IMPORTANCE` are grouped into
   connected areas. An area of at least `NET_CORE_MIN_AREA_HA` earns exactly one
   node, placed at the core's centre among its more permeable cells — not at its
   most important cell, since `corridor_importance` peaks at bottlenecks and would
   pull the node off the patch onto the pinch point leading out of it. Tier comes
   from area (`NET_MAJOR_AREA_HA` / `NET_SECONDARY_AREA_HA`).
2. **Node budget.** Cores are kept largest-area first, up to
   `NET_NODES_PER_KM2 × AOI km²`, clamped to `[NET_NODES_MIN, NET_NODES_MAX]`.
   Keyed to a cell-count threshold instead, Porto drew 160 secondary nodes against
   Amsterdam's 84 for no ecological reason and the two maps stopped being
   comparable.
3. **Candidate connections.** Delaunay neighbours of the node set, capped at
   `NET_MAX_LINK_M` straight-line separation (k-nearest as a fallback when
   triangulation is unavailable). All-pairs routing is affordable at this node
   count but yields a bundle of near-parallel routes that pruning then has to
   undo; Delaunay also guarantees the candidate set is connected before the
   distance cap is applied.
4. **Routing.** One least-cost path per candidate over the routing surface, one
   Dijkstra per source node. Cost is in effective metres, so `cost ÷ geometric
   length` is the route's mean resistance. A route is rejected above
   `NET_MAX_ROUTE_RESISTANCE` or `NET_MAX_ROUTE_COST_M`. Because every node pair
   has *some* least-cost path, these ceilings are what stop the map trading
   true-but-trivial fragments for clean-looking fictions.
5. **Pruning.** The backbone is a minimum spanning tree over route cost. A
   non-tree link survives only if it costs less than `NET_REDUNDANCY_RATIO` of the
   detour the tree forces *and* reuses no more than `NET_MAX_ROUTE_OVERLAP` of the
   cells already covered.
6. **Scoring.** Each corridor gets one class from its whole route's mean
   resistance: `strongest | strong | moderate | weak` (`NET_STRENGTH_BREAKS`).
   There is no `fragmented` class — step 4 rejects a route that bad, and a
   corridor that is broken rather than merely poor is described by its bottlenecks
   instead of by its average. Mean `corridor_importance` is *not* usable here: the
   route now crosses cells that carry no betweenness at all, where importance is 0
   by definition, and averaging those collapses every score to the floor.
7. **Bottlenecks.** A contiguous run of cells below
   `NET_BOTTLENECK_PERMEABILITY` covering at least `NET_BOTTLENECK_MIN_M` is
   carved out of the line as its own section, sharing the corridor's `corridorId`
   and quality class but marked `kind = "bottleneck"`. Every other section keeps
   the corridor's single dominant colour, so the line does not flicker between
   classes along its length. Sections below `NET_MIN_SECTION_M` are absorbed into
   their longer neighbour.
8. **Geometry.** Corner-cut (`NET_SMOOTH_PASSES`) to relax the 60° zigzag of a hex
   centroid path into a curve, then Douglas-Peucker at `NET_SIMPLIFY_M`. The
   tolerance has to stay well under the 20 m cell pitch — at 6 m it ate the
   curvature the smoother had just produced and left a 240 m corridor as four
   vertices.

**Hierarchy is styling, not generation.** One network is produced per city; each
corridor carries a `rank` (`primary | secondary | minor`) derived from the tiers
it connects, and `corridorLineOpacity()` reveals ranks progressively across zoom.
Generating three networks for three scales would mean three things that can
disagree. Rank gates by significance rather than by quality on purpose: a weak
corridor between two major cores is a finding worth seeing at city scale.

| | corridors | sections | nodes (major/secondary/stepping) | median route |
|---|---|---|---|---|
| amsterdam-schimmelstraat | 34 | 66 | 31 (6/8/17) | 720 m |
| porto-center | 49 | 85 | 40 (7/23/10) | 680 m |
| yokohama-honmoku | 8 | 10 | 9 (5/3/1) | 1060 m |

Amsterdam previously emitted 211 segments (median 92 m) and 404 nodes; Porto 420
segments and 822 nodes. The edge GeoJSON is now about 5 KB per city.

Yokohama is genuinely sparse rather than misconfigured: it has no NIR coverage, so
permeability falls back to the near-binary WorldCover fractions (see the
permeability paragraph above), which
concentrates `corridor_importance` in few cells and leaves only nine habitat cores
above `NET_CORE_MIN_AREA_HA`.

Barriers are reported as bottleneck sections on the corridors they interrupt,
which is what the legend's break symbol now refers to. A **named** barrier — this
specific road, this railway — still needs a roads/rail loader at the connectivity
stage, which does not exist yet; roads are currently only read per-tile in
`02_habitat`.

`fragmentation_index`, `node_importance`, `edge_density`, `patch_isolation`, and
`patch_size_distribution` exist as placeholder fields in the pipeline but are
**not yet computed** (they are always null). They are intentionally not surfaced
in any user-facing metric, layer, or score until they are actually implemented
(see the connectivity backlog). Do not treat them as real values.

Limitations:

- Habitat quality is a generic permeability proxy.
- Species-specific movement is not modelled.
- Betweenness favours shortest paths and may not capture all ecological corridors.
- Habitat thresholds should be sensitivity-tested.

## 10. Intervention Ranking

Intervention ranking is computed in `pipeline/05_residuals/residuals.R`.

Current implementation:

```text
underperformance_i = max(0, ecological_residual_i)

intervention_score_i =
  (underperformance_i * 0.5) * (corridor_importance_i * 0.5)
```

Cells are ranked descending by `intervention_score`.

Interpretation:

- `underperformance` is the residual floored at zero, so a cell that already
  over-performs contributes nothing rather than a negative score. Since the
  residual is expected minus observed, underperformance is its positive side.
- Higher score: stronger combination of underperformance and corridor relevance
- A cell needs both: no corridor importance means no intervention score, however
  large the gap
- Only positive-scoring cells are candidates for top intervention exports

This replaces the older weighted-sum formula:

```text
0.55 * normalised_underperformance + 0.45 * corridor_importance
```

Do not use the older formula unless the R implementation is intentionally
changed at the same time.

Counterfactual connectivity estimate:

- Computed for the top cells only.
- The target cell is locally upgraded to habitat quality `1.0`.
- A local connectivity graph is rerun.
- Reported as approximate percentage connectivity gain.

Limitations:

- The counterfactual is local and approximate.
- It is not a full restoration simulation.
- It is computationally expensive at large scale.

## 11. PMTiles And Presentation

PMTiles do not define methodology. They carry lightweight, precomputed values
from R for viewport-based rendering.

`hexgrid.pmtiles` carries the fields listed in `PMTILES_REQUIRED_FIELDS`
(`pipeline/06_export/export.R`), which is the authoritative list and is enforced
at export time. As of the current export that is:

- identity and attribution: `cellId`, `parkId`, `parkName`
- scores: `natureGapScore`, `impactScore` (legacy), `expectedRichness`,
  `ecologicalResidual`, `ecologicalResidualNormalized`, `interventionRank`
- habitat and context: `habitatQuality`, `observedRichness`,
  `corridorImportance`, `betweennessCentrality`, `treeCover`, `canopyHeightIdx`,
  `heatExposure`, `meanLst`, `lstIdx`, `landUseGreen`, `landUseClass`, `nObs`
- render-normalised companions (`[-1, 1]` diverging or `[0, 1]` unit, used
  directly by MapLibre expressions): `natureGapScoreNorm`, `residualNorm`,
  `expectedNorm`, `habitatQualityNorm`, `corridorImportanceNorm`,
  `betweennessNorm`, `treeCoverNorm`, `ndviNorm`, `lstNorm`,
  `disturbanceNorm`, `interventionRankNorm`

The derived ecological network ships separately as
`connectivity-network-edges.geojson` / `-nodes.geojson`, not in PMTiles.

PMTiles must not include:

- raw observations
- species arrays
- pressure arrays
- full intervention descriptions
- formulas
- recomputed metrics

MapLibre may style and filter PMTiles properties. It must not compute ecological
metrics.

## 12. Database Responsibilities

PostgreSQL/PostGIS may:

- store transactional records
- store R-computed cell outputs
- enforce relationships, roles, RLS, and auditability
- assign live observations to the nearest canonical 20 m hex cell
- expose detail rows to the frontend

PostgreSQL/PostGIS must not:

- compute expected richness
- compute effort correction
- compute ecological residual
- compute intervention ranking
- replace R as the scientific source of truth

## 13. Known Biases And Caveats

1. Urban bias: records cluster near dense residential areas and popular parks.
2. Taxonomic bias: iNaturalist and GBIF skew toward visible and charismatic taxa.
3. Temporal mismatch: satellite imagery and field records rarely align exactly.
4. Data sparsity: unsampled cells are excluded, not treated as zero biodiversity.
5. Uncalibrated defaults: index weights, `SPECIES_AREA_*`, connectivity and
   network constants are shared across all cities and calibrated against none of
   them. Three cities are configured (`yokohama-honmoku`,
   `amsterdam-schimmelstraat`, `porto-center`); NIR/CIR coverage exists for
   Amsterdam and Porto only, so Yokohama falls back to WorldCover fractions for
   permeability.
6. OSM dependency: path, green-space, lighting, and road completeness vary by region.
7. Structured-survey dependence: live app surveys enter through the
   `pipeline_observations_export` view and must be exported before Step 03 for
   the latest approved records to affect the run.

## 14. Reproducibility Requirements

Every pipeline run should record:

- `CITY_ID`
- processing date/time
- CRS
- bbox
- `CELL_SIZE`
- `SPECIES_AREA_Z` and `SPECIES_AREA_C` (expected-richness assumptions at both
  hex and patch scale)
- `MAX_EXPECTED_RICHNESS` (exported for transparency; no longer scales expected
  richness)
- `MIN_PATH_M` and `PATH_RADIUS_M` (effort-correction thresholds)
- `CONN_*` and `NET_*` (connectivity and derived-network constants)
- source data dates or versions
- PMTiles source-layer name
- exported `cell_id` count
- active `dataset_id`
- `generated_at`
- PostgreSQL import result counts

These values should be auditable alongside the imported `cell_attributes` and
the Storage artefacts used by the frontend.
