# Methodology Notes

This document describes the analytical decisions behind NatureGap's indices, their inputs, assumptions, and limitations. Every index is documented here to support reproducibility and honest communication with users.

---

## 1. Spatial grid

**Resolution:** 20 m hexagons generated with `sf::st_make_grid(area, cellsize = 20, square = FALSE)`. This is the only analytical, storage, and display grid.  
**CRS:** JGD2011 / Japan Plane Rectangular CS VI (EPSG:6674) for local processing; reprojected to WGS84 (EPSG:4326) for web serving.  
**Coverage:** configured city analysis extent. Display and analysis use the same 20 m hex cells.

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
corrected_richness_i = raw_species_count_i / log(1 + path_km_i)
```

Where `path_km_i` is the total length of OSM footways, paths, and tracks within cell *i*.
If `path_km_i = 0`, the cell is marked unsampled and excluded from richness residual inference rather than treated as zero richness.

**Rationale for log:** `log(1 + path_km)` dampens very high accessibility while preserving the critical distinction between sampled and unsampled cells.

**Limitations:**  
- Effort proxy assumes observers walk on mapped paths. Unmarked paths and private land crossings are missed.  
- Does not account for observer skill (expert vs. casual recorder).  
- Temporal uneven sampling (more summer observations) is partially addressed by `n_survey_dates` but not fully corrected.

---

## 4. Expected richness

**Formula:**

```
expected_richness_i = MAX_EXPECTED × (0.65 × habitat_i + 0.20 × connectivity_i + 0.15 × accessibility_i)
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
ecological_residual_i = expected_richness_i − corrected_richness_i
```

- **Positive residual** → high habitat pressure. Priority for restoration.
- **Negative residual** → potential refuge worth protecting.
- **Near zero** → nature is performing as expected.

---

## 6. Connectivity analysis

**Graph construction:**  
- Nodes = all 20 m hex cells, including urban, green, water, and built-up cells.  
- Edges = neighbouring 20 m hex centroids.  
- Edge weight = mean resistance = mean(1 − habitat_quality) of both connected cells.

**Corridor importance:**  
Normalised betweenness centrality computed with `igraph::betweenness()`. A cell with high betweenness lies on many shortest paths between habitat patches — removing it would disconnect the network.

**Fragmentation index:**  
Proportion of neighbouring 20 m hexes that are NOT classified as habitat.

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
4. **Data sparsity:** Unsampled cells are excluded from residual inference rather than treated as zero biodiversity.
5. **Single-city calibration:** All parameters are tuned for Yokohama. Transferability to a second city requires re-validation.
