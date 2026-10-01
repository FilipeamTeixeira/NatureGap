# Research paper framework — NatureGap

*Working document. Defines what the paper argues, why it is publishable, how it is
structured, what evidence supports each claim, and what still needs doing.*

---

## 1. The one-sentence thesis

**An expected-minus-observed biodiversity map carries information about ecology only
when the fitted expectation varies about as much as the observation it is subtracted
from; in four cities built on a production citizen-science pipeline this condition
fails by two to four orders of magnitude, so the "nature gap" is a map of where
nobody has been looking.**

Everything else in the paper is either the derivation of that condition, the
measurement of it, the diagnosis of why it fails, or what to do instead.

## 2. Why this is publishable

The literature is full of *expected vs. observed* maps — biodiversity debt, extinction
debt, restoration priority, "nature gap", conservation shortfall, effort-corrected
richness. Almost all of them:

- fit a model of expected richness,
- subtract the observation,
- map the difference,
- rank interventions on it,

and **report the fit of the model (R², D², AUC) but never the variance ratio between
the two sides of the subtraction.** Fit quality does not tell you whether the
difference is informative. That gap in practice is the paper's opening.

The contribution is not "here is another urban biodiversity index". It is:

1. **A closed-form criterion** for when a difference map is worth drawing, with two
   symmetric failure modes that look completely different on a map but are the same
   arithmetic error.
2. **A four-city audit** of a real, deployed, fully open pipeline in which both failure
   modes actually occurred, in sequence, and were measured.
3. **The first out-of-sample evaluation** of this model class in this setting.
4. **A short reporting standard** that would have caught it.

Reviewers will find claim 1 obvious *once stated*. That is a feature: it is obvious,
unreported, and the field is publishing maps that violate it.

## 3. Positioning against the likely objections

| Objection | Answer in the paper |
|---|---|
| "This is just a negative result about one tool." | The criterion is analytic and general; NatureGap is the demonstration, not the subject. Two opposite failure modes in the same codebase make the point sharper than a survey would. |
| "You are criticising your own system." | Yes — deliberately. The system is open source, the failure is documented in its own repository, and self-audit with full data release is the strongest available evidence. Frame as *audit*, not confession. |
| "Everyone knows citizen science is spatially biased." | Known: the bias. New: that effort *correction* does not remove it, that the correction discards 46–77% of records, and that the residual construction re-imports the bias in a form that looks like a result. |
| "λ is just 1−(unexplained variance)." | No. λ is measured between the *two mapped quantities*, is not a function of D² alone under a log link on overdispersed counts, and is what the map is actually made of. Porto: D²=0.14, λ=0.028 — a fivefold discrepancy. |
| "Why not just fix the model?" | The paper does propose fixes (§ recommendations) and tests one class of them (grain). But λ is a property of the *published product*, not of the modeller's intent, so it should be reported regardless. |
| "Four cities is not many." | They span three biogeographic and three data-availability regimes, are analysed by one identical codebase, and disagree strongly with each other — which is itself the finding. Positioned as an audit, not a survey. |

## 4. Target venues, in order

1. **Methods in Ecology and Evolution** — primary. Methodological diagnostic with a
   general result, an empirical demonstration, and released code. Fits "Practical
   Tools" or a standard Research Article.
2. **Ecography** — if the framing leans toward sampling bias and macroecological
   inference from opportunistic records.
3. **Ecological Indicators** — if the framing leans toward index construction and
   reporting standards.
4. **Landscape and Urban Planning** / **Urban Forestry & Urban Greening** — if the
   framing leans toward the policy risk of decision-support dashboards.
5. **Environmental Modelling & Software** — if the framing leans toward the pipeline
   as released software.

Recommendation: write for MEE. The policy angle survives as a Discussion subsection;
the reverse is not true, because a planning journal will not want the derivation.

## 5. Section architecture

| § | Title | Job | Evidence |
|---|---|---|---|
| 1 | Introduction | Establish that gap maps are widespread, decision-relevant, and unaudited. End on the thesis. | Literature |
| 2.1 | Study cities | Four AOIs, one codebase, contrasting data regimes. | Table 1 |
| 2.2 | Data sources | iNaturalist, GBIF, OSM, Sentinel-2, Landsat, WorldCover, national CIR. | Table 2 |
| 2.3 | Grid & quality gates | 20 m hex, accuracy/recency/obscuring gates. | Repo config |
| 2.4 | Effort correction | `log1p(path_local_m)` denominator, 50 m admission rule. | Repo |
| 2.5 | Expected richness | Quasi-Poisson GLM with effort offset. | Repo + refit |
| 2.6 | Residual, score, ranking | The published products. | Repo |
| 2.7 | **Diagnostics (new)** | λ, spatially blocked CV, artefact screen, rank ensemble. | This paper |
| 3.1 | Coverage and sparsity | 14–35% of cells admitted; 65–96% of those hold zero species. | Table 3, Fig 2 |
| 3.2 | The correction discards the data | 46–77% of records fall in excluded cells. | Fig 2c |
| 3.3 | Coordinate artefacts | 5 cells = 72% of Amsterdam's records, on the 0.05° graticule. | Fig 3, Table 4 |
| 3.4 | Model fit, in and out of sample | D² 0.009–0.14 in-sample; 0.001–0.12 CV; folds go negative. | Fig 4, Table 5 |
| 3.5 | **λ and the residual window** | λ = 0.0002–0.028; ρ(R,−Y) = 0.986–0.9999; analytic prediction matches to 4 d.p. | Fig 1, Table 6 |
| 3.6 | Effort entanglement | ρ_s(expected, log path) up to 0.89. | Table 7 |
| 3.7 | What the ranking selects | Top 1% of gap cells are 80–100% zero-record; top-20 stability 0–12/20. | Fig 5 |
| 3.8 | Grain | Aggregation improves fit in 2 of 4 cities; does not restore λ. | Table 8 |
| 4.1 | The variance condition | Derivation, the two failure modes, the window. | Analytic |
| 4.2 | Why fine grain guarantees failure | Zero-inflation → shrinkage → λ→0. | Analytic + data |
| 4.3 | Consequences for practice | Dashboards, policy, restoration lists. | — |
| 4.4 | Recommendations R1–R7 | What to do instead. | — |
| 4.5 | A reporting standard | The five numbers to publish with any gap map. | — |
| 5 | Limitations | In-sample artefacts, single pipeline, no ground truth. | — |
| 6 | Conclusion | — | — |
| — | Data & code availability | Repo, exports, analysis scripts. | — |

## 6. Figure and table plan

**Figures (all generated; `paper/figures/`)**

- **Fig 1** `fig1_residual_window.png` — the residual window. Shared variance of the
  residual with each side as a function of λ, with the four cities and the pipeline's
  own previous version plotted. *This is the paper's signature figure.*
- **Fig 2** `fig2_coverage.png` — coverage, sparsity, and records discarded.
- **Fig 3** `fig3_concentration.png` — Lorenz curves of record concentration + the
  Amsterdam graticule.
- **Fig 4** `fig4_crossval.png` — in-sample vs spatially blocked CV explained deviance.
- **Fig 5** `fig5_ranking.png` — what the gap ranking selects, and its stability.

**Still to make (optional, strengthens submission)**

- **Fig 6** — side-by-side maps of one city: observed richness, expected richness,
  residual. Visual proof that panel 3 is panel 1 inverted. Highest-impact addition.
- **Fig 7** — schematic of the pipeline (may be supplementary).

**Tables**

1. Study areas and data regimes
2. Data sources and licences
3. Coverage and sparsity per city
4. The ten most-recorded cells (artefact table)
5. Model fit in and out of sample
6. λ, ρ, and the residual decomposition
7. Effort entanglement correlations
8. Grain sweep (from the repo's own sensitivity run)
9. Full parameter table (appendix)

## 7. Claims ladder — what is supported by what

| # | Claim | Strength | Source |
|---|---|---|---|
| C1 | corr(R,−Y) = (1−ρ√λ)/√(1+λ−2ρ√λ) | Proved; verified numerically to 4 d.p. in 4 cities | Derivation + `theory.py` |
| C2 | λ = 0.0002–0.028 in all four cities | Measured directly on published exports | `theory.py` |
| C3 | The residual shares 97–99.98% of its variance with the observation | Measured | `analyse2.py` |
| C4 | CV D² = 0.0009–0.120; folds negative in 3 cities | Measured; reconstruction validated against published coefficients to <5×10⁻⁴ | `cv.py` |
| C5 | 46–77% of records fall in cells excluded as unsampled | Measured | `analyse2.py` |
| C6 | 5 cells hold 72.1% of Amsterdam's records, on the 0.05° graticule | Measured | `lattice.py` |
| C7 | Coordinate rounding is the mechanism behind C6 | **Inferred**, strongly consistent with exact graticule positions. State as inference. | — |
| C8 | Top 1% of gap cells are 80–100% zero-record cells | Measured | `analyse2.py` |
| C9 | Top-20 intervention stability 0–12/20 across dispersal cost | From repo's `rank_stability` ensemble | Repo |
| C10 | Aggregation raises D² in Porto/Yokohama only | From repo's grain sweep | Repo docs |
| C11 | The previous pipeline version had λ≫1 | From repo's documented measurement (ρ = 0.9987–0.9996) | Repo docs |

**Rule for the manuscript:** anything at C7's level is written as "consistent with",
never as "caused by". Anything from the repository's own runs is attributed to the
repository, not re-presented as this paper's measurement.

## 8. What the paper deliberately does not do

- No new index, no replacement metric, no "NatureGap 2.0". The paper's value is the
  criterion, not a product.
- No claim about which city is ecologically better. λ makes such claims unsupportable
  from this data, and saying so is the point.
- No implementation of `fragmentation_index` or a calibrated species–area exponent —
  both are out of scope and documented as deferred in the repository.
- No validation against independent field surveys — none exist for these AOIs. Named
  as the single most valuable next step.

## 9. Reference strategy

Nine clusters, roughly 45–60 references at submission:

1. **Urban biodiversity and its drivers** — Aronson et al. 2014; Beninde et al. 2015;
   Grimm et al. 2008; Lepczyk et al. 2017.
2. **Citizen science: value and bias** — Dickinson et al. 2010; Isaac & Pocock 2015;
   Bird et al. 2014; Chandler et al. 2017.
3. **Spatial and detection bias in opportunistic records** — Boakes et al. 2010;
   Geldmann et al. 2016; Hughes et al. 2021; Zizka et al. 2020 (CoordinateCleaner —
   directly relevant to §3.3).
4. **Effort correction and occupancy alternatives** — Isaac et al. 2014; Kéry et al.
   2010; van Strien et al. 2013; Outhwaite et al. 2019.
5. **Species distribution / richness modelling with presence-only data** — Phillips et
   al. 2009; Warton et al. 2013; Fithian et al. 2015; Renner et al. 2015.
6. **Model evaluation and spatial cross-validation** — Roberts et al. 2017;
   Ploton et al. 2020; Wenger & Olden 2012; Valavi et al. 2019 (blockCV).
7. **Zero-inflation and overdispersion in counts** — Ver Hoef & Boveng 2007;
   Warton 2005; Zuur et al. 2009.
8. **Residual / gap / debt mapping in ecology** — Kuussaari et al. 2009 (extinction
   debt); Newbold et al. 2015; Watson et al. 2016; conservation-shortfall literature.
9. **Landscape connectivity and least-cost modelling** — McRae et al. 2008;
   Adriaensen et al. 2003; Zeller et al. 2012; Saura & Pascual-Hortal 2007.
10. **Indicator construction, uncertainty and decision support** — Saltelli et al. 2008
    (sensitivity analysis); OECD/JRC composite-indicator handbook; Burgman 2005.

**Verify before submission.** Aronson et al. 2014 was previously mis-cited in this
project as the source of the species–area exponent; it is not. Every citation in the
final manuscript needs checking against the actual paper, not against a remembered
claim. Do not let a plausible-looking citation stand unread.

## 10. Reproducibility package

Everything in `paper/analysis/`:

| File | Produces |
|---|---|
| `stats.py` | Streams the four exports, caches per-cell arrays |
| `centroids.py` | Cell centroids for spatial blocking |
| `analyse.py` | Table 3, Table 7, band distributions → `summary.json` |
| `analyse2.py` | Tables 4, 6; discard fractions; concentration → `summary2.json` |
| `cv.py` | Table 5; refit validation; spatially blocked CV → `cv.json` |
| `theory.py` | Table 6; analytic verification of C1 → `theory.json` |
| `lattice.py` | §3.3 artefact screen → `lattice.json` |
| `figs.py`, `fig1.py` | Figures 1–5 |

The exports themselves are versioned (`datasetId`), and every fitted parameter is
recorded in each city's `manifest.json`. Archive the four export directories with a
DOI (Zenodo) at submission; they are the paper's raw data.

## 11. Open questions for the author

1. **Authorship and affiliation** — not filled in.
2. **Which framing wins**: methodological (MEE) or applied-urban (LUP)? The manuscript
   as drafted is the methodological one.
3. **Fig 6 (three-panel maps)** — worth making? It is the single most persuasive
   figure available and needs a rendering pass over one city's PMTiles.
4. **Does Gent's negative habitat coefficient have a local explanation?** Belgian
   waarnemingen.be flows into GBIF at very high volume; if that stream is gridded
   differently the sign may be an artefact of a single data provider. Worth one
   provider-level breakdown before submission — it would either strengthen §3.3
   considerably or remove a puzzle.
5. **Ethics/consent statement** — citizen-science records are public and aggregated;
   confirm the app's own structured-survey data is either excluded or consented.
   Current runs have `SUPABASE_OBSERVATIONS_ENABLED` unset, so app data has never
   entered a published score — state that explicitly and it resolves itself.
6. **Preprint** — EcoEvoRxiv is the norm for this community and is worth doing at
   submission.

## 12. Suggested next milestone

Before touching prose again: decide 11.2 and 11.3, then run the provider breakdown in
11.4. Those three change the manuscript; nothing else in the current draft is blocked.
