# Sensitivity Analysis

How much does the published intervention ranking depend on parameters that were
never calibrated?

> **The tables below were run on the 2026-08-20 exports and are superseded.**
> The pipeline has changed since, and re-running `sweep_connectivity.R` on
> current data gives materially different figures — Porto retains 0.65 of its
> top-20 at R = 100, not the 0.45 reported here. Four cities are now configured,
> not three. Current per-run figures come from `rank_stability`, produced by
> `05_residuals/residuals.R` and summarised in
> [methodology.md](methodology.md) section 13. Regenerate this document before
> citing any number in it.
>
> Current baseline top-20 stability across R = {5, 10, 20, 30, 50, 100}:
> Yokohama 12/20, Porto 10/20, Amsterdam 4/20, **Gent 0/20**.

Scripts: `pipeline/sensitivity/sweep_habitat_effort.R` and
`pipeline/sensitivity/sweep_connectivity.R`.

```bash
cd pipeline && SENS_CITY=porto Rscript sensitivity/sweep_habitat_effort.R
cd pipeline && SENS_CITY=porto Rscript sensitivity/sweep_connectivity.R
```

## Method

The intervention chain is recomputed analytically from per-cell components stored
in `grid_residuals.gpkg` — `ndvi_idx`, `lst_idx`, `disturbance_idx`,
`path_local_m`, `species_richness` — rather than by re-running upstream stages:

```text
habitat_quality -> expected richness (GLM refit) -> ecological_residual
  -> underperformance -> intervention_score = underperformance x corridor_importance
```

`CONN_MAX_RESISTANCE` is the exception: `corridor_importance` is recomputed by
calling the pipeline's own `build_habitat_graph()` and `corridor_percentile()`,
so the graph, resistance formula, and dispersal cutoff are the real ones. Only
the routing graph and derived-network stages are skipped, and neither feeds the
intervention list.

**Validation.** At baseline parameters the reconstruction reproduces the
pipeline's `habitat_quality` and `intervention_score` with `max|difference| = 0`,
and self-comparison gives Spearman rho = 1.000 with top-20 overlap 1.00. Without
that check the sweep would measure reconstruction error rather than sensitivity.

**Metrics.** Spearman rho on `intervention_score` over cells positive in either
run, and the share of the baseline top-N retained. Top-20 is the decision-relevant
figure: `TOP_N = 20` in `05_residuals/residuals.R` is what gets exported and acted
on.

## Which parameters even reach the intervention list

Two of the four parameters originally proposed for this sweep are not in the
causal path, which is worth stating before any numbers:

| parameter | reaches `intervention_score`? | why |
| --- | --- | --- |
| habitat index weights | **yes** | `habitat_quality` -> expected richness -> residual |
| `CONN_MAX_RESISTANCE` | **yes** | resistance -> betweenness -> `corridor_importance` |
| `MIN_PATH_M` | **yes** | which cells are sampled at all, plus effort and accessibility |
| `SPECIES_AREA_Z` | no | used only at `05_patch/patch_aggregation.R:285` |
| `NET_CORE_IMPORTANCE` | no | used only in `04_connectivity/network_derive.R` |

## Results, ranked by influence

### 1. `CONN_MAX_RESISTANCE` — dominant, and not robust

Baseline 20. Swept 5 to 100.

| R | Porto rho / top-20 | Amsterdam rho / top-20 | Yokohama rho / top-20 |
| --- | --- | --- | --- |
| 5 | 0.753 / 0.75 | 0.849 / 0.85 | 0.962 / 1.00 |
| 10 | 0.824 / 0.90 | 0.919 / 0.85 | 0.984 / 1.00 |
| **20** | 1.000 / 1.00 | 1.000 / 1.00 | 1.000 / 1.00 |
| 30 | 0.831 / 0.80 | 0.928 / 0.65 | 0.991 / 0.95 |
| 50 | 0.648 / 0.60 | 0.822 / 0.30 | 0.976 / 0.90 |
| 100 | 0.495 / 0.45 | 0.683 / **0.05** | 0.951 / 0.90 |

**This is the finding that matters.** At R = 100 only **1 of Amsterdam's top 20
cells survives**, and fewer than half of Porto's. The count of cells with any
positive score moves by a factor of 5.7 in Porto (4,388 at R=5 to 764 at R=100).
The top-20 intervention list cannot be presented as robust without either
calibrating this constant or reporting the range.

Yokohama is the exception (rho >= 0.95 throughout) because its permeability falls
back to near-binary WorldCover fractions in the absence of NIR coverage, so the
resistance contrast is largely insensitive to the ceiling.

### 2. Habitat index weights — robust

Baseline `0.50 * ndvi_idx + 0.286 * lst_idx + 0.214 * (1 - disturbance_idx)`.
Swept over 15 points of the weight simplex, NDVI weight 0.20 to 0.80 and
disturbance weight 0.05 to 0.60.

| | Porto | Amsterdam | Yokohama |
| --- | --- | --- | --- |
| Spearman rho (min / median) | 0.980 / 0.990 | 0.963 / 0.989 | 0.899 / 0.990 |
| top-20 (min / median) | 0.80 / 0.90 | 0.70 / 0.80 | 0.55 / 0.85 |
| top-100 (min) | 0.87 | 0.77 | 0.57 |
| top-1000 (min) | 0.94 | 0.91 | 0.84 |
| explained deviance range | 0.175-0.203 | 0.028-0.037 | 0.055-0.104 |

The ranking is largely insensitive to weights that were set by expert judgement:
even at the extremes of the simplex, 80% of Porto's top 20 and 94% of its top
1,000 survive. Stability degrades with data sparsity — Yokohama, with the fewest
records, is the least stable at 0.55.

**Incidental finding: the current weights are not deviance-optimal.** In all three
cities explained deviance is highest with an LST-heavier blend (Porto 0.203 at
`w_lst = 0.6` against 0.195 at baseline; Amsterdam 0.037 against 0.032; Yokohama
0.104 against 0.076). The differences are small and this is in-sample, so it is
not grounds to re-weight, but it does mean the NDVI-dominant blend is not what the
data would pick.

### 3. `MIN_PATH_M` — matters more than the habitat weights

Baseline 50 m. This threshold decides which cells are analysed at all.

| min_path_m | Porto rho / top-20 | Amsterdam rho / top-20 | Yokohama rho / top-20 | sampled cells (Porto) |
| --- | --- | --- | --- | --- |
| 25 | 0.946 / 1.00 | 0.993 / 0.95 | 0.993 / 1.00 | 41,386 |
| 40 | 0.972 / 1.00 | 0.996 / 1.00 | 0.996 / 1.00 | 35,063 |
| **50** | 1.000 / 1.00 | 1.000 / 1.00 | 1.000 / 1.00 | 31,562 |
| 75 | 0.877 / 0.90 | 0.970 / 0.90 | 0.941 / 0.95 | 23,960 |
| 100 | 0.754 / 0.85 | 0.921 / 0.90 | 0.859 / 0.95 | 17,924 |
| 150 | 0.631 / 0.85 | 0.750 / 0.85 | 0.676 / 0.95 | 11,215 |

The head of the list is stable (top-20 >= 0.85 everywhere) but the body reorders
substantially: Porto's rho falls to 0.63 and top-1000 overlap to 0.70 at 150 m.
Relaxing the threshold is safer than tightening it, and the analysed cell count
moves by 3.7x across the range — which matters for any statement about coverage.

### 4. `SPECIES_AREA_Z` — negligible

Not in the hex intervention path at all. Swept 0.20 to 0.30 against the **patch**
residual ranking (Porto, 1,058 scored patches):

| z | Spearman rho | top-20 | top-100 | explained deviance |
| --- | --- | --- | --- | --- |
| 0.20 | 0.9995 | 0.95 | 0.94 | 0.2795 |
| 0.22 | 0.9998 | 0.95 | 0.96 | 0.2785 |
| **0.25** | 1.0000 | 1.00 | 1.00 | 0.2771 |
| 0.28 | 0.9999 | 1.00 | 0.98 | 0.2757 |
| 0.30 | 0.9996 | 1.00 | 0.97 | 0.2747 |

Across the whole commonly cited 0.2-0.3 range the patch ranking is effectively
unchanged. **The deferred question of a citation or local calibration for this
exponent does not affect any published ranking.** Fitting the coefficient on the
area term rather than asserting `SPECIES_AREA_C` (§6.2) is what absorbed the
uncertainty.

### 5. `NET_CORE_IMPORTANCE` — no effect on the list

It sets habitat-core membership in the derived network only. Its effect there is
large — core cells in Porto range from 8,187 at a 0.3 threshold to 3,498 at 0.7,
a 2.3x span — so it should be reported as a network-map parameter, but it cannot
change an intervention ranking.

## What this supports, and what it does not

Supported:

- The habitat index weights, the single most obviously arbitrary set of numbers in
  the model, do not drive the ranking. That converts "uncalibrated weights" from a
  fatal objection into a characterised one.
- `SPECIES_AREA_Z` can stay an assumption without qualifying any result.
- Rank stability degrades with observation density (Yokohama < Amsterdam < Porto),
  which is consistent with §6.1: the sparser the records, the more the ranking is
  a property of the model rather than of the data.

Not supported:

- Any claim that the top-20 intervention list is robust. `CONN_MAX_RESISTANCE` is
  uncalibrated and the list is highly sensitive to it in three of four cities.
  The ensemble this section called for is now implemented — `rank_stability`
  (`05_residuals/residuals.R`) reports the share of R values placing a cell in
  the top N, validated against the pipeline baseline at `max|diff| = 0` and
  against this sweep at every R for Porto. Present the ranking filtered by
  stability, never `intervention_rank` alone.

## Limitations of this analysis

- One-at-a-time sweeps except within the habitat simplex, so interactions between
  parameters are not characterised. `CONN_MAX_RESISTANCE` x habitat weights is the
  pair most likely to interact, since both feed expected richness.
- The GLM is refit at every point, so the fit adapts to each parameter set. That
  is the right comparison for "would the published list change", but it understates
  sensitivity of the coefficients themselves.
- Explained deviance is in-sample. No held-out or cross-validated estimate is
  reported anywhere here.
- `PATH_RADIUS_M` (40 m) is not swept: it needs the geometry re-scan in
  `02_habitat`, not just stored per-cell values.
- Baseline explained deviance from the reconstruction (0.1953 for Porto) differs
  slightly from the pipeline's own run (0.1987) because effort and accessibility
  are recomputed from `path_local_m` rather than read. Relative comparisons within
  the sweep are unaffected; the absolute figure to quote is the pipeline's.
