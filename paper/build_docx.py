#!/usr/bin/env python3
"""Build Word versions of the manuscript and framework via pandoc.

Figures are inserted inline at first mention; the figure-legend list is kept at
the end, as journals require. Run from paper/.
"""
import re, subprocess, sys, os

FIGS = [
 ('## 3. Results',
  'figures/fig1_residual_window.png',
  'Figure 1. Shared variance of the residual R = Y-hat - Y with each of its inputs, as a '
  'function of lambda, from equations (1) and (2) at rho = 0. The shaded band marks the '
  'residual window. The four cities of this study and the pipeline’s previous release '
  'are plotted at their measured lambda.'),
 ('### 3.2 The effort correction discards most of the data',
  'figures/fig2_coverage.png',
  'Figure 2. (a) Share of grid cells admitted to the analysis. (b) Share of admitted cells '
  'with zero recorded species. (c) Share of all occurrence records falling in cells the '
  'admission rule excludes.'),
 ('### 3.4 Model fit, in and out of sample',
  'figures/fig3_concentration.png',
  'Figure 3. (a) Cumulative share of records against cells ranked by record count, with Gini '
  'coefficients. (b) The four largest Amsterdam cells, plotted against the 0.05° graticule.'),
 ('### 3.5 λ, and what the residual is actually made of',
  'figures/fig4_crossval.png',
  'Figure 4. In-sample versus spatially blocked 5-fold cross-validated explained deviance; '
  'dots are individual folds.'),
 ('### 3.8 Grain',
  'figures/fig5_ranking.png',
  'Figure 5. (a) Share of the top 1% of residual cells with zero recorded species. (b) Number '
  'of each city’s baseline top-20 intervention cells that remain in the top 20 at all six '
  'values of the dispersal-cost ceiling.'),
]

MANUSCRIPT_META = """---
title: "The gap is in the data: expected-minus-observed biodiversity maps reproduce sampling effort at fine grain, and a variance criterion that detects it"
author:
  - "[Filipe A. M. Teixeira]"
  - "[co-authors]"
date: "Manuscript draft"
---

"""

FRAMEWORK_META = """---
title: "Research paper framework — NatureGap"
subtitle: "Working document"
date: "Draft"
---

"""

def prepare_manuscript(src):
    # strip the H1 title block; the YAML metadata carries it
    body = src.split('\n', 1)[1]
    body = re.sub(r'^\*\*Authors\.\*\*.*?\n\n', '', body, flags=re.S)
    missing = []
    for anchor, img, cap in FIGS:
        if not os.path.exists(img):
            missing.append(img); continue
        block = f'![{cap}]({img})\n\n'
        if anchor in body:
            body = body.replace(anchor, block + anchor, 1)
        else:
            missing.append(f'anchor: {anchor}')
    if missing:
        print('WARNING, not inserted:', *missing, sep='\n  ', file=sys.stderr)
    return MANUSCRIPT_META + body

def pandoc(md_text, out, toc=True):
    tmp = f'/private/tmp/claude-501/-Users-Fil-naturegap-freshclone/e6fca359-c6e8-4097-8d25-cbd1604ad874/scratchpad/_{os.path.basename(out)}.md'
    open(tmp, 'w').write(md_text)
    cmd = ['pandoc', tmp, '-f', 'markdown+pipe_tables+yaml_metadata_block',
           '-o', out, '--standalone', '--resource-path=.']
    if toc:
        cmd += ['--toc', '--toc-depth=2']
    subprocess.run(cmd, check=True)
    print(f'{out}  ({os.path.getsize(out)//1024} KB)')

pandoc(prepare_manuscript(open('manuscript.md').read()), 'NatureGap-manuscript.docx')
pandoc(FRAMEWORK_META + open('FRAMEWORK.md').read().split('\n', 1)[1],
       'NatureGap-paper-framework.docx')
