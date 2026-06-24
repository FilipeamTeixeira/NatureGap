# Methodology Notes

This document describes the analytical decisions behind NatureGap's indices, their inputs, assumptions, and limitations. Every index is documented here to support reproducibility and honest communication with users.

---

## 1. Spatial grid

**Resolution:** 250m × 250m square grid (configurable; 100m tested but computationally heavier for connectivity step).  
**CRS:** JGD2011 / Japan Plane Rectangular CS VI (EPSG:6674) for local processing; reprojected to WGS84 (EPSG:4326) for web serving.  
**Coverage:** Yokohama city boundary with a 500m buffer to avoid edge effects in the connectivity graph.

---

## 2. Habitat quality index

**Formula:**

```
habitat_quality = 0.35 × ndvi_idx + 0.30 × green_idx + 0.20 × lst_idx + 0.15 × (1 − path_idx)
```

| Sub-index | Source | Transformation | Weight | Rationale |
|---|---|---|---|---|
| `ndvi_idx` | Sentinel-2 B4/B8 | Rescaled from [−0.2, 1.0] to [0, 1] | 0.35 | Proxy for photosynthetically active vegetation |
| `green_idx` | OSM leisure polygons | Fraction of cell area covered | 0.30 | Direct measure of accessible green space |
| `lst_idx` | Landsat ST_B10 | Inverted percentile rank | 0.20 | Cooler = less heat stress = more hospitable |
| `path_idx` | OSM highway paths | km of path per cell, capped at 2 km | 0.15 | High path density proxies for disturbance/urbanisation |

**Limitations:**  
- Weights are expert-assigned, not empirically calibrated.  
- NDVI does not distinguish native vegetation from ornamental or invasive cover.  
- OSM green space completeness varies; unmapped parks are treated as non-green.  
- LST is a single-date snapshot; multi-date composites would be more robust.

---

## 3. Observer effort correction

**Problem:** iNaturalist and GBIF records concentrate where people walk, not where biodiversity is highest. A cell near a popular trail will appear to have more species simply because more people visited it.

**Approach:** We normalise observed richness by a proxy for observer effort:

```
effort_i = n_obs_i / max(path_km_i, 0.1)
corrected_richness_i = raw_richness_i / sqrt(effort_i + 1)
```

Where `path_km_i` is the total length of OSM footways, paths, and tracks within cell *i*.

**Rationale for sqrt:** The square root dampens the correction for very high-effort cells, preventing over-correction where richness is genuinely high and well-sampled.

**Limitations:**  
- Effort proxy assumes observers walk on mapped paths. Unmarked paths and private land crossings are missed.  
- Does not account for observer skill (expert vs. casual recorder).  
- Temporal uneven sampling (more summer observations) is partially addressed by `n_survey_dates` but not fully corrected.

---

## 4. Expected richness

**Formula:**

```
expected_richness_i = habitat_quality_i × MAX_EXPECTED
```

Where `MAX_EXPECTED = 350` (provisional upper bound based on literature values for temperate urban biodiversity in Japan).

**This is an index, not a prediction.** It provides a relative ranking of cells by expected biodiversity, not an absolute species count.

**Limitations:**  
- Linear relationship between habitat quality and expected richness is a simplification. Real species-area relationships are typically power-law.  
- `MAX_EXPECTED` is not calibrated to Yokohama specifically. Future work should fit this parameter against independent plot-level surveys.  
- Does not account for species pool limitations (e.g., a cell cannot have species that don't exist in the regional pool).

---

## 5. Ecological residual

```
ecological_residual_i = corrected_richness_i − expected_richness_i
```

- **Negative residual** → nature is underperforming relative to habitat quality. Priority for restoration.
- **Positive residual** → biodiversity surplus. Potentially an unrecognised refuge worth protecting.
- **Near zero** → nature is performing as expected.

---

## 6. Connectivity analysis

**Graph construction:**  
- Nodes = habitat cells (habitat_quality ≥ 0.40).  
- Edges = queen's-case adjacency (8-neighbours within √2 × 250m).  
- Edge weight = mean resistance = mean(1 − habitat_quality) of both connected cells.

**Corridor importance:**  
Normalised betweenness centrality computed with `igraph::betweenness()`. A cell with high betweenness lies on many shortest paths between habitat patches — removing it would disconnect the network.

**Fragmentation index:**  
Proportion of the 8 possible queen's-case neighbours that are NOT classified as habitat.

**Limitations:**  
- The resistance surface uses habitat quality as a proxy for permeability. Species-specific permeability (e.g., for a focal species like a butterfly or small mammal) would require species distribution models.  
- Betweenness centrality favours cells on the shortest paths, not necessarily the most ecologically important corridors for all species.  
- The 0.40 habitat threshold is arbitrary; sensitivity analysis across thresholds is recommended.

---

## 7. Intervention ranking

```
composite_score_i = 0.55 × normalised_underperformance_i + 0.45 × corridor_importance_i
```

Cells are ranked by composite score. Higher score = higher restoration priority.

**Counterfactual connectivity estimate** (top 20 cells only):  
Each top cell is reclassified as habitat (quality = 1.0) and the connectivity graph is rerun. The change in mean betweenness of adjacent cells is reported as the estimated connectivity gain. This is computationally expensive and approximate.

---

## Known biases and caveats

1. **Urban bias in citizen science:** Records cluster near dense residential areas and popular parks. The effort correction partially addresses this but cannot fully compensate.
2. **Taxonomic bias:** iNaturalist records skew toward charismatic fauna (birds, butterflies, large plants). Soil fauna, fungi, and aquatic invertebrates are severely underrepresented.
3. **Temporal mismatch:** Satellite imagery and field records rarely coincide in time. Seasonal variation in NDVI and phenology creates noise.
4. **Data sparsity:** Many cells have zero observations. The residual for these cells reflects habitat quality only, not confirmed absence of biodiversity.
5. **Single-city calibration:** All parameters are tuned for Yokohama. Transferability to a second city requires re-validation.
