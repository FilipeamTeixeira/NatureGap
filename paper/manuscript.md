# The gap is in the data: expected-minus-observed biodiversity maps reproduce sampling effort at fine grain, and a variance criterion that detects it

**Authors.** [Filipe A. M. Teixeira]¹, [co-authors]
**Affiliations.** ¹[affiliation]
**Corresponding author.** filipe@joinprisma.org

**Running title.** The residual window

**Keywords.** citizen science · sampling bias · effort correction · species richness ·
urban ecology · residual mapping · decision support · spatial cross-validation ·
open source

---

## Abstract

Maps of the difference between *expected* and *observed* biodiversity are widely used
to prioritise conservation and restoration. They are almost always validated by
reporting how well the expectation model fits — R², explained deviance, AUC — and
almost never by asking whether the difference itself carries information beyond its
two inputs. We show analytically that for a difference map R = Ŷ − Y the shared
variance between the residual and each of its inputs is fixed by a single quantity,
the variance ratio λ = Var(Ŷ)/Var(Y), and that the map is informative only in a narrow
window around λ ≈ 1. Outside it the map degenerates in one of two ways that look
entirely different on screen but are the same arithmetic: at λ ≫ 1 the residual
reproduces the model, at λ ≪ 1 it reproduces the data with the sign flipped.

We measure λ in a deployed, fully open urban-biodiversity pipeline covering four
cities — Porto (Portugal), Amsterdam (Netherlands), Gent (Belgium) and Yokohama
(Japan) — comprising 1.04 million 20 m hexagonal cells, 1.85 million occurrence
records from iNaturalist and GBIF, and an effort-corrected quasi-Poisson richness
model fitted per city. λ ranges from 0.00018 to 0.028 — 35× to 5,500× below λ = 1. The
published "ecological residual" shares 97.1–99.98% of its variance with the observation
it was meant to explain away and at most 0.01% with the fitted expectation; the analytic
prediction for corr(R, −Y) matches the measured value
to four decimal places in all four cities. The same pipeline's previous release
occupied the opposite failure mode (λ ≫ 1, residual–expectation correlation 0.9987–
0.9996), so both regimes are exhibited by one codebase within six months.

Three upstream mechanisms produce this. First, fine grain: 20 m cells leave 64.6–96.1%
of admitted cells with zero recorded species, and no richness model can fit a response
that is mostly zero — spatially blocked cross-validation gives explained deviance of
0.120 (Porto), 0.027 (Amsterdam), 0.008 (Yokohama) and 0.0009 (Gent), with individual
folds performing worse than a constant in three cities. Second, the effort correction
itself: admitting only cells with ≥ 50 m of pedestrian path nearby discards 46–77% of
all occurrence records, and the surviving expectation is largely a map of path density
(Spearman ρ up to 0.891). Third, coordinate precision: five hexagons — 1,730 m² in
total — hold 72.1% of Amsterdam's 789,554 records, and their centroids fall on the
0.05° graticule to within 10 m.

The consequences reach users unchanged. In the published product the top 1% of "nature
gap" cells are 80.3–100% cells with no species recorded at all, and 42.0–82.9% of parks
per city are labelled *as expected* solely because they contain no usable data. We
propose a five-number reporting standard — λ, out-of-sample explained deviance, a
coverage triple, a coordinate-artefact screen, and rank stability under uncalibrated
parameters — and argue that no expected-minus-observed map should be published without
it. All data, code, and per-run fitted parameters are open.

---

## 1. Introduction

A recurring move in applied ecology is to model what a place *should* hold, compare it
with what has been *recorded* there, and treat the difference as a measurable deficit.
The move appears under many names — biodiversity debt, extinction debt, conservation
shortfall, restoration priority, effort-corrected richness anomaly, "nature gap" — and
it is attractive for the same reason in each case. A raw observation map is obviously
confounded by where people looked. A raw habitat model is obviously not an observation.
Subtracting one from the other appears to give a quantity that is neither: a shortfall,
relative to a baseline, in units someone can act on.

The move is also increasingly consequential. Difference maps of this form are no longer
confined to journal figures; they run inside municipal dashboards, feed restoration
prioritisation, and are rendered to the public as neighbourhood-level scores. A cell or
a park now receives a colour, a band, and a rank, and someone may plant trees on the
strength of it.

What is rarely reported is whether the difference contains anything the two inputs did
not already contain. The standard validation is a fit statistic for the expectation
model — R², explained deviance, AUC — reported alone. That statistic answers a
different question. It tells you how well Ŷ tracks Y. It does not tell you what the
map of Ŷ − Y is *made of*, and those are not the same thing: a model can fit
respectably and still produce a difference map that is a re-rendering of one of its
inputs.

This paper makes that question precise and then answers it empirically. Section 2.7
derives the relationship between λ = Var(Ŷ)/Var(Y) and the correlation of the residual
with each input, and shows that it admits only a narrow window of λ in which the
residual is genuinely a third quantity. Sections 3.1–3.8 measure λ, and the mechanisms
that set it, in a production system covering four cities on three continents, built by
one codebase from openly licensed inputs, with every fitted parameter recorded per run.

We chose to audit our own system. This is deliberate. An audit of someone else's
pipeline can only measure what they published; here we can refit the model, reproduce
the published coefficients to four decimal places, cross-validate out of sample, trace
each pathology to the line of code that causes it, and release everything. The system
is also unusually instructive because it has occupied *both* failure modes within six
months, under two different specifications of the same subtraction, and documented the
first one in its own repository. The general point is not about this pipeline. It is
that the subtraction is fragile in a way that a fit statistic cannot see, and that a
one-line diagnostic makes visible.

Our contributions are:

1. **A criterion.** A closed-form expression for the residual's shared variance with
   its inputs as a function of λ and ρ = corr(Ŷ, Y), with two symmetric failure modes
   and a narrow informative window (§2.7, §4.1).
2. **A four-city measurement.** λ = 0.00018–0.028 across 1.04 million cells; the
   residual shares 97.1–99.98% of its variance with the observation (§3.5).
3. **The first out-of-sample evaluation** of this model class in this setting, by
   spatially blocked cross-validation, with a reconstruction validated against the
   published coefficients (§3.4).
4. **A mechanistic account** — zero-inflation at fine grain, effort-based cell
   exclusion that discards most of the data, and coordinate-precision artefacts —
   each quantified (§3.1–3.3).
5. **A reporting standard** of five numbers that would have caught all of it (§4.5).

---

## 2. Materials and methods

### 2.1 Study areas

Four urban areas of interest were analysed with an identical codebase and identical
parameters (Table 1). They were selected to span contrasting data-availability regimes
rather than to be representative of cities in general: Porto and Gent have national
colour-infrared orthophoto coverage and dense OpenStreetMap footpath data; Amsterdam
has both plus an exceptionally large GBIF stream; Yokohama has neither national NIR
coverage nor a comparable record volume.

**Table 1. Study areas.** AOI area derived as cell count × 346.4 m² (the area of a 20 m
hexagon). Parks are OpenStreetMap `leisure=park|nature_reserve|garden` polygons.

| City | Country | Local CRS | Hex cells | AOI (km²) | Parks | Cells admitted | Admitted (%) |
|---|---|---|---:|---:|---:|---:|---:|
| Porto | Portugal | EPSG:3763 | 119,771 | 41.5 | 5,254 | 30,947 | 25.8 |
| Amsterdam | Netherlands | EPSG:28992 | 192,087 | 66.5 | 767 | 67,147 | 35.0 |
| Gent | Belgium | EPSG:31370 | 349,034 | 120.9 | 5,648 | 64,875 | 18.6 |
| Yokohama | Japan | EPSG:6674 | 383,341 | 132.8 | 608 | 52,014 | 13.6 |
| **Total** | | | **1,044,233** | **361.7** | **12,277** | **214,983** | **20.6** |

### 2.2 Data sources

**Table 2. Inputs.**

| Source | Contribution | Licence |
|---|---|---|
| iNaturalist | Occurrence records, research and needs_id grade | CC-BY (research grade) |
| GBIF | Aggregated occurrence records | Varies; CC-BY / CC0 |
| OpenStreetMap | Footpaths, roads, rail, green space, amenities, lighting, water | ODbL |
| Sentinel-2 MSI | NDVI at 10 m | Copernicus |
| Landsat 8/9 | Land surface temperature, three seasonal composites | USGS/NASA |
| ESA WorldCover | Land-cover fractions | CC-BY 4.0 |
| Copernicus EMC-BUILT | Impervious fraction | Copernicus |
| Portugal DGT / NL PDOK / Flanders | 0.5 m CIR orthophoto → vegetation fraction, NDVI texture | National open data |

Occurrence records are filtered on ingest and again after the streams are combined:
records with stated positional accuracy > 30 m are dropped; records with unknown
accuracy are retained at half weight; iNaturalist records with obscured or
geoprivacy-restricted coordinates are dropped; records earlier than 2015 (the Sentinel-2
operational start) or without a date are dropped; and GBIF `PRESERVED_SPECIMEN` records
are dropped. The gates are severe on some streams: of the GBIF archives as fetched they
retain 91.1% for Porto, 22.4% for Gent, 27.4% for Yokohama and 18.5% for Amsterdam,
and of the survivors 44.0–95.6% state no positional accuracy at all. §3.3 shows what
that last figure permits.

After gating, the four cities contribute 1,850,703 records: Porto 227,110, Amsterdam
789,554, Gent 799,628, Yokohama 34,411.

### 2.3 Spatial unit

All analysis is on a 20 m hexagonal grid (`sf::st_make_grid(cellsize = 20,
square = FALSE)`; ≈ 346 m² per cell) generated in each city's national projected CRS.
The same cell identifiers connect the modelling outputs, the vector tiles, the database
and the public interface. There is no secondary analytical grid.

### 2.4 Observer effort correction

Occurrence records cluster where people walk, so raw richness confounds biodiversity
with observer effort. The pipeline corrects for this with a pedestrian-path proxy:

    survey_effort_units_i = log(1 + path_local_m_i)
    observed_richness_i   = species_richness_i / survey_effort_units_i

where `path_local_m_i` is OpenStreetMap footway, path and track length in metres within
40 m of cell *i*'s centroid. Cells with less than 50 m of path in that neighbourhood are
declared **unsampled**: they receive `NA` for effort, observed richness and residual,
and are excluded from model fitting rather than treated as zero-richness cells. This is
the correct treatment of an unobserved cell, and §3.2 shows what it costs.

### 2.5 Expected richness

Expected richness is the fitted conditional expectation of the same quantity that is
subtracted from it — not a separate index — so that the difference in §2.6 is a
residual in the statistical sense, with both sides in units of species per effort unit:

    species_richness_i ~ quasipoisson(log link)
      habitat_component + connectivity_component + accessibility_component
      + offset(log(survey_effort_units_i))

    expected_richness_i = exp(X_i · β)

`habitat_component` is a habitat quality index (0.50 · NDVI index + 0.286 · inverted LST
percentile + 0.214 · inverted disturbance index); `connectivity_component` is the
percentile rank of dispersal-limited betweenness on a habitat-resistance graph, clamped
to [0, 1]; `accessibility_component` is log1p(path_local_m) normalised by its city
maximum. The model is fitted per city, on admitted cells only, in-sample.

Note that effort enters twice: once as a fixed offset and once, in transformed form, as
a free covariate. We return to this in §3.6.

### 2.6 Published products

- **Ecological residual** `R = expected_richness − observed_richness`, signed so that
  positive means below expectation.
- **Nature Gap score**, a composite of the median-centred residual (0.50), habitat
  deficit (0.30) and connectivity deficit (0.20), scaled to [−100, +100] and binned into
  five bands (`much-better` < −15 ≤ `better` < −5 ≤ `as-expected` < 10 ≤ `worse` < 20 ≤
  `much-worse`).
- **Intervention score** `max(0, R − median(R)) × corridor_importance`, ranked
  descending, with the top 20 exported for action.
- A **rank-stability** ensemble: the whole residual chain is recomputed at six values of
  the uncalibrated dispersal-cost ceiling (R ∈ {5, 10, 20, 30, 50, 100}) and each cell
  records the share of runs placing it in the top 20.

### 2.7 Diagnostics introduced here

**The variance criterion.** Write the residual as R = Ŷ − Y, let λ = Var(Ŷ)/Var(Y) and
ρ = corr(Ŷ, Y). Then

    Var(R) = Var(Ŷ) + Var(Y) − 2·Cov(Ŷ, Y)

and the residual's correlation with each of its inputs follows in closed form:

    corr(R, −Y) = (1 − ρ√λ) / √(1 + λ − 2ρ√λ)                              (1)
    corr(R,  Ŷ) = (√λ − ρ) / √(1 + λ − 2ρ√λ)                               (2)

Equation (1) has two limits. As λ → 0, corr(R, −Y) → 1: the residual *is* the
observation, negated. As λ → ∞, corr(R, Ŷ) → 1: the residual *is* the model. Only in
between is R a quantity distinct from both. Setting ρ = 0 for the worst case, the
residual shares less than half its variance with the observation only once λ > 1, and
less than 20% only once λ > 4. We therefore treat **λ ∈ [0.25, 4] as the residual window**
(Fig. 1) — deliberately generous; a map at λ = 0.25 still shares 80% of its variance
with the observation.

λ is not a restatement of the model's fit statistic. Under a log link on overdispersed
counts, fitted values shrink toward the mean far more than the deviance measure
suggests: in Porto the model explains 14.05% of deviance but λ = 0.028, a fivefold
discrepancy. λ is a property of the two mapped quantities and must be measured on them.

**Spatially blocked cross-validation.** The pipeline reports in-sample explained
deviance only. We tiled each city's admitted cells into a 25 × 25 lattice of spatial
blocks, assigned whole blocks at random to five folds (seed 42), refitted the model on
four folds and evaluated Poisson deviance on the held-out fold against a constant-rate
null fitted on the training folds. Blocking by contiguous area rather than by cell
prevents neighbouring cells of the same record cluster appearing in both training and
test sets.

**Reconstruction validation.** Before any of this, we refitted the published
specification from the exported per-cell components. The refitted coefficients match
the published ones to within 4 × 10⁻⁴ in all four cities, and the explained deviance and
dispersion match to the published precision (Table 5). All subsequent diagnostics are
therefore measuring the published model, not a reimplementation of it.

**Coordinate-artefact screen.** For each cell holding records we computed the distance
from its centroid to the nearest node of a regular geographic lattice at 0.1°, 0.05°,
0.01° and 0.001°, and summed records within 15 m of a node.

**Software.** Pipeline in R (`sf`, `terra`, `igraph`); diagnostics in Python
(`numpy`, `scipy`, `statsmodels` 0.12.2). All analysis scripts are released
(§ Data and code availability).

---

## 3. Results

### 3.1 Coverage and sparsity

Across the four cities, 214,983 of 1,044,233 cells (20.6%) are admitted to the analysis
(Table 1). Of those admitted, the great majority hold nothing: 64.6% of Gent's, 76.3%
of Porto's, 79.7% of Amsterdam's and 96.1% of Yokohama's admitted cells record zero
species (Table 3, Fig. 2b). Mean richness on an admitted cell is 0.16–1.22 species.

**Table 3. Coverage and sparsity.**

| | Porto | Amsterdam | Gent | Yokohama |
|---|---:|---:|---:|---:|
| Records after gating | 227,110 | 789,554 | 799,628 | 34,411 |
| Cells holding ≥ 1 record | 13,866 | 24,003 | 68,321 | 3,218 |
| Cells admitted | 30,947 | 67,147 | 64,875 | 52,014 |
| Admitted cells with zero species (%) | 76.3 | 79.7 | 64.6 | 96.1 |
| Mean species richness, admitted | 0.88 | 0.76 | 1.22 | 0.16 |
| 99th percentile richness | 14 | 11 | 12 | 2 |
| Maximum richness in one cell | 359 | 3,403 | 619 | 993 |
| Gini coefficient of records over cells | 0.986 | 0.994 | 0.977 | 0.999 |
| Records in the 10 largest cells (%) | 45.3 | 80.1 | 42.1 | 45.5 |

The distributional consequence is severe (Fig. 3a). Gini coefficients of 0.977–0.999
place these datasets close to the maximum possible concentration; ten cells out of tens
of thousands hold 42–80% of a city's records. A response this concentrated and this
sparse is a difficult target for any regression, and §3.4 shows that the difficulty is
realised.

### 3.2 The effort correction discards most of the data

The 50 m path-length admission rule is meant to distinguish cells that were plausibly
searched from cells that were not. Measured against the records themselves, it does
something more drastic: **46–77% of all occurrence records fall in cells the rule
excludes** (Fig. 2c).

| | Porto | Amsterdam | Gent | Yokohama |
|---|---:|---:|---:|---:|
| Records in excluded cells (%) | 47.2 | 62.9 | 77.2 | 45.8 |
| Excluded cells holding ≥ 1 record | 6,526 | 10,362 | 45,370 | 1,209 |

Gent loses 617,307 of 799,628 records this way. These are not marginal records; §3.3
shows that the single largest record concentration in three of the four cities sits in
an excluded cell. The rule is not wrong in principle — a cell with no nearby path
genuinely has an unknown search history — but it is being applied to a record set whose
positions are, in large part, not where the observer stood (§3.3), and the interaction
of the two removes most of the evidence before the model sees it.

### 3.3 Records pile up on the coordinate graticule

The artefact screen returns a clean signal in Amsterdam. Five cells — 1,730 m² of a
66.5 km² study area — hold **72.1%** of the city's 789,554 records, and four of them sit
within 10 m of an intersection of the 0.05° graticule at latitude 52.35 and longitudes
4.85, 4.90, 4.95 and 5.00 (Fig. 3b). Yokohama shows the same signature more weakly:
10.1% of records lie within 15 m of a 0.1° node, one of which is exactly (139.600,
35.400). Porto and Gent show no coarse-graticule concentration but do show fine-scale
rounding: 5.7% and 30.6% of their records respectively fall within 15 m of a 0.001°
node.

**Table 4. The largest record concentrations and what the pipeline did with them.**

| City | Cell | lon, lat | Records | Distinct species | Path (m) | Admitted? | Published value |
|---|---|---|---:|---:|---:|---|---|
| Gent | gent-226024 | 3.67803, 51.06701 | 183,567 | 0 | 0.0 | no | excluded |
| Amsterdam | amsterdam-61262 | 4.90008, 52.35003 | 166,475 | 0 | 15.3 | no | excluded |
| Amsterdam | amsterdam-59934 | 5.00003, 52.34994 | 149,677 | 0 | 25.1 | no | excluded |
| Amsterdam | amsterdam-60365 | 4.94998, 52.34992 | 133,933 | 3,403 | 141.5 | **yes** | richness 686.2, residual −686.0, score −66.1 |
| Amsterdam | amsterdam-61674 | 4.85003, 52.34997 | 119,147 | 0 | 0.0 | no | excluded |
| Porto | porto-84470 | −8.67987, 41.16890 | 34,107 | 159 | 205.2 | **yes** | richness 29.8, residual −29.2, score −100 (floor) |
| Yokohama | yokohama-124476 | 139.60006, 35.40000 | 3,449 | 0 | 2.1 | no | excluded |

The exact graticule positions are strong evidence that these are records whose
coordinates were rounded or gridded upstream, not 350 m² patches of extraordinary
biodiversity. We state that as an inference: the export does not carry per-record
provenance, so the specific upstream mechanism — coordinate truncation, atlas-grid
aggregation, or a provider-level centroid convention — is not identified here, and a
provider-level breakdown is the obvious next step.

Two properties of the pipeline let these records through. First, the positional-accuracy
gate drops records whose *stated* accuracy is worse than 30 m but only halves the weight
of records that state no accuracy — and 44.0–95.6% of surviving GBIF records state none.
A record rounded to 0.05° carries no accuracy field to fail on. Second, the gate acts on
metadata, not geometry: a screen on spatial concentration, which is what identifies
these cells, is not part of the pipeline.

The consequences differ by whether the artefact cell happens to sit near a footpath.
Where it does not, the record concentration is silently deleted (four of the seven rows
in Table 4). Where it does, it survives into the published product with an extreme
value: cell `amsterdam-60365` carries an effort-corrected richness of 686.2 species per
effort unit against a city median of 0, and `porto-84470` reaches the Nature Gap score
floor of −100. Both are strong influence points in a city-wide fit and in the
percentile scaling that sets every other cell's published score.

### 3.4 Model fit, in and out of sample

The refit reproduces the published model exactly (Table 5, columns 3–4), so the
cross-validation is a statement about the deployed model.

**Table 5. Expected-richness model: published fit, refit, and spatially blocked
5-fold cross-validation.** Coefficients are habitat / connectivity / accessibility.

| City | n | D² published | D² refit | CV D² (mean) | CV fold range | Dispersion | Coefficients |
|---|---:|---:|---:|---:|---|---:|---|
| Porto | 30,947 | 0.1405 | 0.1405 | **0.1204** | 0.057 – 0.213 | 16.7 | +3.543 / +0.023 / +6.268 |
| Amsterdam | 67,147 | 0.0298 | 0.0298 | **0.0266** | −0.030 – 0.072 | 246.3 | +0.662 / +0.580 / +3.143 |
| Yokohama | 52,014 | 0.0211 | 0.0211 | **0.0083** | −0.095 – 0.078 | 301.6 | +0.759 / +1.313 / +0.138 |
| Gent | 64,875 | 0.0088 | 0.0088 | **0.0009** | −0.013 – 0.012 | 102.7 | **−0.152** / +0.282 / +2.520 |

Three results (Fig. 4). **(i)** Only Porto survives held-out evaluation with a
meaningful fit, and even there D² = 0.12 leaves 88% of deviance unexplained. **(ii)**
In Amsterdam, Yokohama and Gent at least one fold performs *worse than a constant rate*
— in Yokohama, −0.095. A model that loses to an intercept on held-out ground is not
estimating a spatial pattern. **(iii)** Gent's mean CV D² of 0.0009 is not
distinguishable from zero, and its habitat coefficient is negative: better habitat
predicts fewer species. That is not an ecological finding; it means the term is not
identifying habitat.

Dispersion of 103–302 is not merely overdispersion. At that level the quasi-Poisson
variance assumption is itself misspecified, in every city, at this grain.

### 3.5 λ, and what the residual is actually made of

**Table 6. The variance decomposition of the published residual, hex scale, admitted
cells.** Predicted values from equation (1).

| City | Var(Ŷ) | Var(Y) | **λ** | ρ(Ŷ, Y) | corr(R, −Y) predicted | measured | R²(R ~ Y) | R²(R ~ Ŷ) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Porto | 0.0231 | 0.824 | **0.0280** | 0.177 | 0.9859 | 0.9859 | 0.971 | 0.0001 |
| Amsterdam | 0.00462 | 8.372 | **0.00055** | 0.023 | 0.9997 | 0.9997 | 0.9994 | 0.0000 |
| Gent | 0.00270 | 5.436 | **0.00050** | 0.023 | 0.9998 | 0.9998 | 0.9994 | 0.0000 |
| Yokohama | 0.000328 | 1.858 | **0.00018** | 0.013 | 0.9999 | 0.9999 | 0.9998 | 0.0000 |

Equation (1) predicts the measured correlation to four decimal places in every city.
λ is 0.00018–0.028, that is 9× to 1,400× below the lower edge of the residual window
and 35× to 5,500× below λ = 1.

The interpretation is direct. **The published ecological residual shares 97.1–99.98% of
its variance with the observation and essentially none with the fitted expectation.**
Regressing the residual on the observation returns R² = 0.971–0.9998; regressing it on
the expectation returns R² ≤ 0.0001. The "gap between expected and observed nature" is
the observation, negated, plus a rounding error.

The same holds out of sample: on held-out folds, λ = 0.0014–0.042 and corr(R, −Y) =
0.979–0.9993, so this is not an in-sample artefact of the fit.

**It also holds after aggregation to parks**, which is the standard remedy. Pooling
records and effort over each green space and refitting with an area term gives a better
model — the pipeline reports explained deviance of 0.277 at patch scale in Porto against
0.140 at hex scale — but leaves λ almost unchanged:

| Patch scale | Porto | Amsterdam | Gent | Yokohama |
|---|---:|---:|---:|---:|
| Parks scored | 1,814 | 445 | 968 | 344 |
| Parks with ≥ 1 species (%) | 31.3 | 45.6 | 56.2 | 29.7 |
| **λ** | 0.015 | 0.025 | 0.0004 | 0.047 |
| R²(R ~ Y) | 0.985 | 0.974 | 0.9997 | 0.961 |

A doubling of explained deviance moved λ from 0.028 to 0.015 — in the wrong direction. Fit and λ are not the same lever.

**The opposite failure, in the same codebase.** The release of this pipeline dated
2026-08-19 used a different construction of expected richness — a species–area power law
with expert weights — whose scale was three orders of magnitude larger than the
observation it was subtracted from. Its documented diagnostics were the mirror image of
Table 6: correlation between residual and *expected* richness of 0.9987 (Porto), 0.9996
(Amsterdam) and 0.9990 (Yokohama), with the observation contributing 0.08–0.26% of the
residual's variance, and 99.99% of cells positive. That is λ ≫ 1. Six months and one
respecification later, the same subtraction sits at λ ≪ 1. Both maps looked plausible;
both were re-renderings of one input (Fig. 1).

### 3.6 The expectation is largely a map of footpaths

Effort enters the expected-richness model twice — as the fixed offset log(effort), and
again as `accessibility_component`, which is the same path length rescaled by a constant
and fitted as a free covariate. The model can therefore re-estimate the effort
adjustment it was supposed to hold fixed, and it does: accessibility is the largest
coefficient in three of four cities.

**Table 7. Spearman correlation with log(1 + path_local_m), admitted cells.**

| | Porto | Amsterdam | Gent | Yokohama |
|---|---:|---:|---:|---:|
| Expected richness | **0.646** | **0.757** | **0.891** | 0.001 |
| Observed (effort-corrected) richness | 0.220 | 0.162 | 0.179 | 0.104 |
| Raw species richness | 0.226 | 0.166 | 0.192 | 0.105 |
| Ecological residual | 0.329 | 0.409 | 0.261 | −0.048 |
| Nature Gap score | 0.353 | 0.088 | 0.063 | 0.182 |

In Gent, expected richness and pedestrian path density share 79% of their rank variance.
Yokohama is the exception (ρ = 0.001) precisely because its fitted accessibility
coefficient is near zero (+0.138) — it is the one city where the term failed to take
over, and it is also the city with the fewest records.

So both sides of the subtraction carry the same confounder: the observation is divided
by path length, and the expectation is largely predicted by it. Part of what the
published Nature Gap maps is where people walk.

### 3.7 What the ranking actually selects

Given §3.5, the top of the residual distribution is the set of cells with the fewest
records, and that is what it is (Fig. 5a):

| | Porto | Amsterdam | Gent | Yokohama |
|---|---:|---:|---:|---:|
| Top 1% of residual cells with **zero** species recorded (%) | 80.3 | 99.7 | 98.6 | 100.0 |
| Mean habitat quality of those cells | 0.775 | 0.776 | 0.718 | 0.765 |
| Cells with a positive intervention score | 5,142 | 16,461 | 15,697 | 7,314 |
| Mean species richness of the exported top-20 | 0.40 | 0.00 | 0.00 | 0.00 |
| Mean habitat quality of the exported top-20 | 0.852 | 0.809 | 0.843 | 0.792 |

The 20 cells exported for action in Amsterdam, Gent and Yokohama contain, between them,
zero recorded species. Their habitat quality (0.79–0.85) sits far above the city medians
(0.45–0.64). The ranking is selecting well-vegetated cells that nobody has surveyed —
which is a defensible list of *places to go and look*, and is being published as a list
of *places where nature is missing*.

**Stability.** Recomputing the whole chain across the six values of the uncalibrated
dispersal-cost ceiling, the share of each city's baseline top-20 that survives every
value is 10/20 (Porto), 12/20 (Yokohama), 4/20 (Amsterdam) and **0/20 (Gent)**
(Fig. 5b). Not one cell on Gent's published action list is robust to a parameter for
which no calibrated value exists.

**How this reaches users.** The five-band Nature Gap scale partitions the four cities
completely differently despite fixed thresholds — Yokohama places 77.2% of cells in
`as-expected` against Gent's 17.1% — so the bands are not comparable between cities even
though they are drawn with the same colours on the same legend. More consequentially, at
park level **every unscored park is published as `as-expected`**: 3,440 of Porto's 5,254
parks (65.5%), 4,680 of Gent's 5,648 (82.9%), 322 of Amsterdam's 767 (42.0%) and 264 of
Yokohama's 608 (43.4%). Absence of data is rendered to the public as absence of a
problem, in the same colour as a park that was measured and found typical.

### 3.8 Grain

The pipeline's own grain sweep refits the specification on square blocks from 20 m to
1,000 m, recomputing richness from the observation points at each grain. Explained
deviance rises with aggregation, but the habitat coefficient — the diagnostic that
matters — does not become interpretable everywhere:

**Table 8. Explained deviance / habitat coefficient by grain** (source: pipeline
sensitivity run, `sweep_grain_scale.R`).

| Grain | Porto | Amsterdam | Gent | Yokohama |
|---|---|---|---|---|
| 20 m | 0.069 / +2.85 | 0.029 / +1.31 | 0.008 / −0.15 | 0.079 / +3.88 |
| 100 m | 0.219 / +2.70 | 0.043 / +0.23 | 0.020 / −1.86 | 0.082 / +4.59 |
| 200 m | 0.244 / +2.03 | 0.013 / +1.33 | 0.045 / −2.73 | 0.128 / +4.09 |
| 500 m | 0.244 / +1.50 | 0.008 / +0.27 | 0.077 / −2.50 | 0.203 / +3.26 |
| 1000 m | 0.321 / +1.60 | 0.054 / −0.06 | 0.198 / −2.59 | 0.482 / +4.74 |

Aggregation removes the zero-inflation (from 54–94% of units at 20 m to near zero by
500 m) and, in Porto and Yokohama, recovers a stable positive habitat effect. In Gent it
buys a better fit to a model whose habitat term runs backwards at every grain, and in
Amsterdam the sign changes four times. Dispersion does not improve with grain in any
city. Coarser reporting is therefore defensible in Porto, provisional in Yokohama, and
not defensible in Gent or Amsterdam at any grain tested — the validity of the metric is
city-dependent, and cannot be claimed as one uniform methodology across four cities.

---

## 4. Discussion

### 4.1 The variance condition, and why fit statistics miss it

The result in §2.7 is elementary and that is the point. Any difference between a fitted
value and an observation is governed by equation (1), and equation (1) has no
informative regime except λ ≈ 1. The two failure modes are worth naming because they
present so differently to a reader:

- **λ ≫ 1 — the map reproduces the model.** Every high-quality cell shows a large gap;
  the map looks ecologically sensible, because it *is* the habitat model. The published
  ranking selects the best habitat and calls it the biggest shortfall. This is what the
  2026-08-19 release did, with residual–expectation correlations of 0.9987–0.9996.
- **λ ≪ 1 — the map reproduces the data.** Every unrecorded cell shows a large gap; the
  map looks like a plausible patchwork of pressure, because it *is* the inverse sampling
  map. This is what the current release does, at λ = 0.00018–0.028.

Neither is detectable from a fit statistic. Porto's model explains 14.05% of deviance in
sample and 12.04% out of sample — an unremarkable but real fit, the kind that appears in
published maps without comment — and its residual still shares 97.1% of its variance with
the observation. Reporting D² alone tells the reader how well Ŷ tracks Y; λ tells them
what Ŷ − Y is made of. They are different questions and the second is the one a map
answers.

Practically: **compute λ, report it, and if λ < 0.25 do not publish the difference.**
Publish the observation and the model separately, which is what the difference contains
anyway, and say so.

### 4.2 Why fine grain makes λ ≪ 1 almost inevitable

The mechanism is a chain, and each link is measured above. At 20 m, cells are small
enough that 64.6–96.1% of admitted cells hold no species at all (§3.1). A response that
is mostly zero cannot be fitted: dispersion reaches 103–302 and out-of-sample deviance
falls to 0.0009–0.12 (§3.4). A model that explains little produces fitted values that
shrink hard toward the mean, so Var(Ŷ) collapses relative to Var(Y) — in Amsterdam by a
factor of 1,800 — and λ → 0. Equation (1) then forces the residual onto the observation.
The chain runs from grain to zero-inflation to shrinkage to λ, and none of its links is
specific to this pipeline.

The consequence for practice is uncomfortable: **the resolution at which citizen-science
biodiversity data is most attractive to map is the resolution at which the difference
map is guaranteed to be uninformative.** A 20 m hexagon is exactly the unit a resident
can act on — this verge, this courtyard, this row of trees — and it is exactly the unit
at which the underlying counts cannot support an expectation.

Aggregation is the obvious remedy and is only a partial one. It fixes the zero-inflation
and, in two of our four cities, recovers a coherent habitat effect (§3.8) — but it did
not restore λ at park scale (§3.5), because a better-fitting model on a more variable
response can still have a fitted variance far below the response's. Aggregation is
necessary, not sufficient. The sufficient test is λ itself.

### 4.3 Effort correction is not neutral

Two findings here generalise beyond this pipeline.

First, **an effort correction that gates on a covariate deletes data at a rate that
should be reported.** The 50 m path rule discards 46–77% of all records (§3.2), and the
pipeline's documentation — thorough on the rule's ecological rationale — does not state
the fraction. Any admission rule of this form (minimum effort, minimum visits, minimum
list length) has such a fraction, and it belongs in the methods section next to the rule.

Second, **dividing the observation by an effort proxy while also predicting the
expectation from that proxy re-imports the confounder on both sides.** Here the offset
and the free accessibility covariate are the same path length, and the free term
dominates in three cities (§3.6), leaving expected richness correlated with path density
at ρ up to 0.891. The residual then differences two effort-laden quantities and retains
effort. Occupancy-detection models, list-length methods and effort-as-offset approaches
without a duplicate free term all avoid this specific error; the general rule is that an
effort variable should appear in the model once, with a fixed role.

### 4.4 Consequences for decision-support products

The failure does not stay in the model. It arrives in a public interface as a colour, a
band and a ranked list, and at that point it is indistinguishable from a result.

- The exported action list contains cells with **zero recorded species** and
  above-average habitat (§3.7). Read as "go and survey here" it is useful. Read as
  "restore here", which is how it is labelled, it directs effort by data absence.
- Between 42.0% and 82.9% of parks per city are shown as **`as-expected`** because they
  have no data, in the same band as parks that were measured (§3.7). This is the single
  most consequential presentation choice in the system: it converts ignorance into
  reassurance. A distinct "not assessed" state is a one-line fix and is the first thing
  we would change.
- The five-band scale is **not comparable between cities** (77.2% vs 17.1% in the middle
  band), nor between dataset versions of the same city, because the centring parameters
  are recomputed per run. A cell whose own data did not change can change band because
  its neighbours' did.
- The published ranking is **not robust** to an uncalibrated parameter: 0/20 of Gent's
  top-20 survives the dispersal-cost ensemble (§3.7).

None of these are exotic failures. They are what happens when a difference map with
λ ≪ 1 is given a legend.

### 4.5 Recommendations

**R1 — Report λ.** One line of code, alongside every expected-minus-observed map. If
λ < 0.25, publish the two inputs separately instead.

**R2 — Report out-of-sample fit, spatially blocked.** In-sample deviance overstated
held-out performance by 11% (Amsterdam) to 90% (Gent) here, and hid the fact that individual
held-out folds lose to a constant.

**R3 — Report the coverage triple.** Cells admitted / cells with data / records
discarded by the admission rule. All three, as percentages, in the methods.

**R4 — Screen for coordinate artefacts geometrically.** Metadata gates cannot catch
records that carry no accuracy field. A concentration screen — records per unit area
against a graticule at 0.1°, 0.05°, 0.01°, 0.001° — takes minutes and would have flagged
72% of Amsterdam's stream.

**R5 — Choose grain from the response, not the interface.** Report at the coarsest grain
the decision tolerates and the finest grain at which zero-inflation is below, say, 50%,
and if those two do not overlap, say so rather than splitting the difference.

**R6 — Let an effort variable appear once.** Offset or covariate, not both.

**R7 — Distinguish "no data" from "no problem" in every user-facing surface.** A
separate state, a separate colour, a separate count in the legend.

### 4.6 A reporting standard

We propose that any published expected-minus-observed ecological map carry five numbers,
in the methods or a standard table:

| # | Number | Why |
|---|---|---|
| 1 | λ = Var(Ŷ)/Var(Y) on the mapped cells | Says what the map is made of |
| 2 | Out-of-sample explained deviance/R², spatially blocked, with fold range | Says whether the expectation generalises |
| 3 | Coverage triple: % units admitted, % with data, % records discarded | Says how much of the study area and the data the map speaks for |
| 4 | Concentration: Gini of records over units, and share in the 10 largest | Flags artefacts before they become findings |
| 5 | Rank stability of the published ranking under uncalibrated parameters | Says whether the action list is a result or a parameter choice |

We report all five for four cities in §3 and would not have found any of the pathologies
without them. None requires new data.

---

## 5. Limitations

- **One pipeline.** All four cities share a codebase, so shared implementation choices
  cannot be separated from general properties of the method. The λ criterion is
  analytic and does not depend on the pipeline; the empirical magnitudes do.
- **No independent ground truth.** No systematic field survey exists for these AOIs, so
  we cannot say what the true richness surface is — only what the published one is made
  of. Validation against structured surveys is the most valuable next step and is
  currently impossible for want of data, not method.
- **The artefact mechanism is inferred.** §3.3 establishes the concentrations and their
  graticule positions; it does not identify the upstream provider or transformation,
  because the exports carry no per-record provenance. A provider-level breakdown would
  settle it.
- **Cross-validation blocks are square, not ecological.** A 25 × 25 lattice controls for
  short-range spatial autocorrelation but not for gradients at the scale of the whole
  AOI.
- **In-sample influence points remain.** The extreme cells of Table 4 were left in, to
  measure the published product as published. Refitting without them would change the
  coefficients, not the sign of any conclusion — λ moves by less than its own order of
  magnitude when they are removed.
- **Grain results are partly the pipeline's own.** Table 8 comes from the repository's
  sensitivity run rather than from our reanalysis, and is reported as such.
- **App-collected structured surveys are not in these numbers.** The live-import flag
  was unset for every run analysed here, so citizen-submitted survey data has never
  entered a published score. The observation streams are iNaturalist and GBIF only.

---

## 6. Conclusion

Subtracting an observation from a model of that observation feels like a way to isolate
what the model does not explain. It is, but only when the two sides vary comparably.
Outside a narrow window around λ = 1, the difference is one of its inputs wearing the
other's name — and which input depends on a scaling choice that no fit statistic reveals.

In four cities, on a million cells and 1.85 million records, we measured λ between
0.00018 and 0.028. The resulting maps of the "gap between expected and observed nature"
share 97.1–99.98% of their variance with the observation. Their highest-priority cells
are, in three cities out of four, cells with no recorded species at all. Their parks are
labelled *as expected* when nobody has looked. The same pipeline, one release earlier,
failed in the opposite direction with the same subtraction.

The gap these maps show is real. It is a gap in the data. Reporting λ is enough to tell
the two apart, and we can see no reason not to require it.

---

## Data and code availability

**Pipeline and application.** The full R pipeline, Next.js application, database
migrations and methodology documentation are open source at [repository URL]. Code is
MIT-licensed; documentation and derived data products are CC BY-SA 4.0.

**Exported datasets.** The four per-city exports analysed here are versioned by
`datasetId` (Porto `20260826T223825Z`, Amsterdam `20260826T214326Z`, Yokohama
`20260826T215132Z`, Gent `20260826T220614Z`). Each carries a `manifest.json` recording
the fitted model family, link, formula, coefficients, dispersion, explained deviance,
training row count, the score-centring parameters, and every threshold constant, so that
every number in §3 is traceable to a specific run. [Deposit to Zenodo before submission
and record the DOI here.]

**Analysis code.** All diagnostics in this paper are in `paper/analysis/`:
`stats.py` and `centroids.py` (extraction), `analyse.py` and `analyse2.py`
(Tables 3, 4, 6, 7), `cv.py` (Table 5 and the cross-validation), `theory.py` (equation 1
verification), `lattice.py` (§3.3), `figs.py` and `fig1.py` (Figures 1–5). Results are
cached as JSON alongside. Python 3, `numpy` / `scipy` / `statsmodels` 0.12.2 /
`matplotlib` 3.4.3.

**Input data.** iNaturalist and GBIF records are publicly available under their own
terms; OpenStreetMap is ODbL; Sentinel-2, Landsat and WorldCover are open under their
providers' terms. GBIF download DOIs: [record per city before submission].

## Author contributions

[CRediT statement.]

## Acknowledgements

[iNaturalist and GBIF observers; OpenStreetMap contributors; funders.]

## Competing interests

The authors developed the pipeline audited here.

---

## References

*Starter list — every entry must be verified against the source before submission. One
prior version of this project cited Aronson et al. (2014) as the source of a species–area
exponent it does not contain; that error is the reason for this warning.*

**Urban biodiversity**

1. Aronson, M.F.J. et al. (2014) A global analysis of the impacts of urbanization on
   bird and plant diversity reveals key anthropogenic drivers. *Proc. R. Soc. B*
   281: 20133330.
2. Beninde, J., Veith, M. & Hochkirch, A. (2015) Biodiversity in cities needs space: a
   meta-analysis of factors determining intra-urban biodiversity variation.
   *Ecology Letters* 18: 581–592.
3. Grimm, N.B. et al. (2008) Global change and the ecology of cities. *Science* 319:
   756–760.
4. Lepczyk, C.A. et al. (2017) Biodiversity in the city: fundamental questions for
   understanding the ecology of urban green spaces. *BioScience* 67: 799–807.

**Citizen science: value and bias**

5. Dickinson, J.L., Zuckerberg, B. & Bonter, D.N. (2010) Citizen science as an ecological
   research tool. *Annu. Rev. Ecol. Evol. Syst.* 41: 149–172.
6. Isaac, N.J.B. & Pocock, M.J.O. (2015) Bias and information in biological records.
   *Biol. J. Linn. Soc.* 115: 522–531.
7. Bird, T.J. et al. (2014) Statistical solutions for error and bias in global citizen
   science datasets. *Biological Conservation* 173: 144–154.
8. Chandler, M. et al. (2017) Contribution of citizen science towards international
   biodiversity monitoring. *Biological Conservation* 213: 280–294.

**Spatial bias and data quality in occurrence records**

9. Boakes, E.H. et al. (2010) Distorted views of biodiversity: spatial and temporal bias
   in species occurrence data. *PLoS Biology* 8: e1000385.
10. Zizka, A. et al. (2019) CoordinateCleaner: standardized cleaning of occurrence
    records from biological collection databases. *Methods Ecol. Evol.* 10: 744–751.
    *(Directly relevant to §3.3.)*
11. Hughes, A.C. et al. (2021) Sampling biases shape our view of the natural world.
    *Ecography* 44: 1259–1269.
12. Geldmann, J. et al. (2016) What determines spatial bias in citizen science?
    *Diversity and Distributions* 22: 1139–1149.
13. Maldonado, C. et al. (2015) Estimating species diversity and distribution in the era
    of Big Data. *Global Ecology and Biogeography* 24: 973–984.

**Effort correction and detection**

14. Isaac, N.J.B. et al. (2014) Statistics for citizen science: extracting signals of
    change from noisy ecological data. *Methods Ecol. Evol.* 5: 1052–1060.
15. Kéry, M., Royle, J.A., Schmid, H. et al. (2010) Site-occupancy distribution modeling
    to correct population-trend estimates derived from opportunistic observations.
    *Conservation Biology* 24: 1388–1397.
16. van Strien, A.J., van Swaay, C.A.M. & Termaat, T. (2013) Opportunistic citizen
    science data of animal species produce reliable estimates of distribution trends.
    *J. Applied Ecology* 50: 1450–1458.
17. Outhwaite, C.L. et al. (2019) Annual estimates of occupancy for bryophytes, lichens
    and invertebrates in the UK, 1970–2015. *Scientific Data* 6: 259.

**Presence-only and richness modelling**

18. Phillips, S.J. et al. (2009) Sample selection bias and presence-only distribution
    models. *Ecological Applications* 19: 181–197.
19. Warton, D.I., Renner, I.W. & Ramp, D. (2013) Model-based control of observer bias for
    the analysis of presence-only data in ecology. *PLoS ONE* 8: e79168.
20. Fithian, W. et al. (2015) Bias correction in species distribution models: pooling
    survey and collection data. *Methods Ecol. Evol.* 6: 424–438.
21. Renner, I.W. et al. (2015) Point process models for presence-only analysis.
    *Methods Ecol. Evol.* 6: 366–379.

**Model evaluation**

22. Roberts, D.R. et al. (2017) Cross-validation strategies for data with temporal,
    spatial, hierarchical, or phylogenetic structure. *Ecography* 40: 913–929.
23. Ploton, P. et al. (2020) Spatial validation reveals poor predictive performance of
    large-scale ecological mapping models. *Nature Communications* 11: 4540.
24. Valavi, R. et al. (2019) blockCV: an R package for generating spatially or
    environmentally separated folds. *Methods Ecol. Evol.* 10: 225–232.
25. Wenger, S.J. & Olden, J.D. (2012) Assessing transferability of ecological models.
    *Methods Ecol. Evol.* 3: 260–267.

**Counts, overdispersion, zero-inflation**

26. Ver Hoef, J.M. & Boveng, P.L. (2007) Quasi-Poisson vs. negative binomial regression:
    how should we model overdispersed count data? *Ecology* 88: 2766–2772.
27. Warton, D.I. (2005) Many zeros does not mean zero inflation. *Environmetrics* 16:
    275–289.
28. Zuur, A.F. et al. (2009) *Mixed Effects Models and Extensions in Ecology with R.*
    Springer.

**Residual, gap and debt mapping**

29. Kuussaari, M. et al. (2009) Extinction debt: a challenge for biodiversity
    conservation. *TREE* 24: 564–571.
30. Newbold, T. et al. (2015) Global effects of land use on local terrestrial
    biodiversity. *Nature* 520: 45–50.
31. Watson, J.E.M. et al. (2016) Catastrophic declines in wilderness areas undermine
    global environment targets. *Current Biology* 26: 2929–2934.

**Connectivity**

32. Adriaensen, F. et al. (2003) The application of "least-cost" modelling as a
    functional landscape model. *Landscape and Urban Planning* 64: 233–247.
33. McRae, B.H. et al. (2008) Using circuit theory to model connectivity in ecology,
    evolution, and conservation. *Ecology* 89: 2712–2724.
34. Zeller, K.A., McGarigal, K. & Whiteley, A.R. (2012) Estimating landscape resistance
    to movement: a review. *Landscape Ecology* 27: 777–797.
35. Saura, S. & Pascual-Hortal, L. (2007) A new habitat availability index to integrate
    connectivity in landscape conservation planning. *Landscape and Urban Planning* 83:
    91–103.

**Indicators, sensitivity and decision support**

36. Saltelli, A. et al. (2008) *Global Sensitivity Analysis: The Primer.* Wiley.
37. OECD/JRC (2008) *Handbook on Constructing Composite Indicators.* OECD Publishing.
38. Burgman, M.A. (2005) *Risks and Decisions for Conservation and Environmental
    Management.* Cambridge University Press.
39. Rocchini, D. et al. (2011) Accounting for uncertainty when mapping species
    distributions: the need for maps of ignorance. *Progress in Physical Geography* 35:
    211–226. *(Closest existing statement of §4.4's "no data ≠ no problem".)*

**Software and data infrastructure**

40. Pebesma, E. (2018) Simple Features for R: standardized support for spatial vector
    data. *The R Journal* 10: 439–446.
41. Csárdi, G. & Nepusz, T. (2006) The igraph software package for complex network
    research. *InterJournal, Complex Systems* 1695.
42. GBIF.org — occurrence downloads, DOIs per city [to be recorded].

---

## Appendix A. Parameter table

Every constant is shared across all four cities and calibrated against none of them.

| Parameter | Value | Role | Calibrated? |
|---|---|---|---|
| `CELL_SIZE` | 20 m | Hex grid resolution | no |
| `PATH_RADIUS_M` | 40 m | Neighbourhood for path length | no |
| `MIN_PATH_M` | 50 m | Admission threshold | no |
| `OBS_MAX_ACCURACY_M` | 30 m | Positional accuracy gate | no |
| `OBS_UNKNOWN_ACCURACY_WEIGHT` | 0.5 | Weight for unstated accuracy | no |
| `OBS_YEAR_MIN` | 2015 | Recency gate | tied to Sentinel-2 start |
| habitat weights | 0.500 / 0.286 / 0.214 | NDVI / LST / disturbance | no (expert) |
| `CONN_MAX_RESISTANCE` | 20 | Dispersal cost at zero permeability | **no — dominant** |
| `CONN_MIN_PERMEABILITY` | 0.05 | Graph membership floor | no |
| `CONN_DISPERSAL_M` | 500 m | Betweenness cutoff | no |
| `SPECIES_AREA_Z` | 0.25 | Patch-scale area exponent | no (assumption) |
| `EXPECTED_MODEL_MIN_CELLS` | 30 | Fit refusal threshold | no |
| score weights | 0.50 / 0.30 / 0.20 | Residual / habitat / connectivity | no |
| `SCORE_BREAKS` | −15, −5, 10, 20 | Band thresholds | no |
| `RANK_STABILITY_TOP_N` | 20 | Ensemble top-N | no |
| `CONN_ENSEMBLE_R` | 5, 10, 20, 30, 50, 100 | Stability ensemble | — |

A parameter sweep run by the pipeline finds the habitat weights and `SPECIES_AREA_Z`
barely move the published ranking (Spearman ρ ≥ 0.90 across the weight simplex;
ρ ≥ 0.9995 across z ∈ [0.20, 0.30]), while `CONN_MAX_RESISTANCE` moves it substantially
— which is why it, and not the more obviously arbitrary habitat weights, is the
parameter reported in §3.7.

## Appendix B. Nature Gap band distributions

Share of scored cells per band, showing that a fixed five-band scale partitions the four
cities incomparably.

| City | much-better | better | as-expected | worse | much-worse | p05 | p50 | p95 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Porto | 25.8 | 10.5 | 29.0 | 19.2 | 15.4 | −65.1 | +2.2 | +31.0 |
| Amsterdam | 33.7 | 12.2 | 26.3 | 15.0 | 12.8 | −72.5 | −2.3 | +27.4 |
| Gent | 45.5 | 11.8 | 17.1 | 8.9 | 16.6 | −67.1 | −11.3 | +33.1 |
| Yokohama | 4.7 | 13.6 | **77.2** | 4.4 | 0.06 | −14.5 | +0.9 | +9.7 |

## Appendix C. Taxonomic composition

Weighted distinct-taxon counts by iconic group, summed over cells.

| City | Plants | Birds | Insects | Mammals | Fungi |
|---|---:|---:|---:|---:|---:|
| Porto | 10,486 | 21,553 | 9,130 | 1,849 | 1,967 |
| Amsterdam | 33,085 | 35,203 | 13,308 | 1,121 | 1,338 |
| Gent | 128,120 | 35,999 | 46,290 | 5,961 | 1,694 |
| Yokohama | 5,505 | 2,603 | 2,564 | 326 | 591 |

Birds outnumber plants in Porto (2.1:1) and Amsterdam (1.1:1); plants outnumber birds in
Gent (3.6:1) and Yokohama (2.1:1). These are differences in observer community and
national recording scheme, not in flora. They are one more reason cross-city comparison of these outputs is not
supported.

---

## Figures

**Figure 1.** `figures/fig1_residual_window.png` — Shared variance of the residual
R = Ŷ − Y with each of its inputs, as a function of λ = Var(Ŷ)/Var(Y), from equations
(1) and (2) at ρ = 0. The shaded band marks the residual window (λ ∈ [0.25, 4]). The four
cities of this study and the pipeline's previous release are plotted at their measured λ.

**Figure 2.** `figures/fig2_coverage.png` — (a) Share of grid cells admitted to the
analysis. (b) Share of admitted cells with zero recorded species. (c) Share of all
occurrence records falling in cells the admission rule excludes.

**Figure 3.** `figures/fig3_concentration.png` — (a) Cumulative share of records against
cells ranked by record count, with Gini coefficients. (b) The four largest Amsterdam
cells, plotted against the 0.05° graticule.

**Figure 4.** `figures/fig4_crossval.png` — In-sample versus spatially blocked 5-fold
cross-validated explained deviance; dots are individual folds.

**Figure 5.** `figures/fig5_ranking.png` — (a) Share of the top 1% of residual cells with
zero recorded species. (b) Number of each city's baseline top-20 intervention cells that
remain in the top 20 at all six values of the dispersal-cost ceiling.

**Figure 6 (to make).** Three panels for one city — observed richness, expected richness,
ecological residual — on the same layout. The visual demonstration that panel 3 is panel 1
inverted.
