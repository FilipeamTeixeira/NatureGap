import re, base64, html, os

FIGS = {
 'figures/fig1_residual_window.png':'fig1',
 'figures/fig2_coverage.png':'fig2',
 'figures/fig3_concentration.png':'fig3',
 'figures/fig4_crossval.png':'fig4',
 'figures/fig5_ranking.png':'fig5',
}
def datauri(p):
    return 'data:image/png;base64,'+base64.b64encode(open(p,'rb').read()).decode()
URIS={v:datauri(k) for k,v in FIGS.items()}

def inline(t):
    t = html.escape(t)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'(?<![\*\w])\*([^*\n]+)\*(?!\*)', r'<em>\1</em>', t)
    t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', t)
    return t

def md(src):
    lines = src.split('\n'); out=[]; i=0
    while i < len(lines):
        L = lines[i]
        if L.startswith('```'):
            i+=1; buf=[]
            while i<len(lines) and not lines[i].startswith('```'): buf.append(lines[i]); i+=1
            i+=1; out.append('<pre><code>'+html.escape('\n'.join(buf))+'</code></pre>'); continue
        if re.match(r'^---+\s*$', L):
            out.append('<hr>'); i+=1; continue
        m = re.match(r'^(#{1,4})\s+(.*)$', L)
        if m:
            lvl=len(m.group(1)); txt=m.group(2)
            num=re.match(r'^((?:Appendix [A-Z]|\d+(?:\.\d+)*)\.?)\s+(.*)$', txt)
            if num and lvl>1:
                out.append(f'<h{lvl}><span class="secno">{inline(num.group(1).rstrip("."))}</span>{inline(num.group(2))}</h{lvl}>')
            else:
                out.append(f'<h{lvl}>{inline(txt)}</h{lvl}>')
            i+=1; continue
        if L.strip().startswith('|'):
            tbl=[]
            while i<len(lines) and lines[i].strip().startswith('|'): tbl.append(lines[i].strip()); i+=1
            rows=[[c.strip() for c in r.strip('|').split('|')] for r in tbl]
            align=[]
            if len(rows)>1 and all(set(c)<=set('-: ') and '-' in c for c in rows[1]):
                for c in rows[1]:
                    align.append('right' if c.endswith(':') and not c.startswith(':') else ('center' if c.startswith(':') and c.endswith(':') else 'left'))
                head, body = rows[0], rows[2:]
            else:
                head, body = rows[0], rows[1:]; align=['left']*len(head)
            h='<thead><tr>'+''.join(f'<th style="text-align:{align[j] if j<len(align) else "left"}">{inline(c)}</th>' for j,c in enumerate(head))+'</tr></thead>'
            b='<tbody>'+''.join('<tr>'+''.join(f'<td style="text-align:{align[j] if j<len(align) else "left"}">{inline(c)}</td>' for j,c in enumerate(r))+'</tr>' for r in body)+'</tbody>'
            out.append(f'<div class="tw"><table>{h}{b}</table></div>'); continue
        if re.match(r'^\s*[-*]\s+', L):
            items=[]
            while i<len(lines) and (re.match(r'^\s*[-*]\s+', lines[i]) or (lines[i].startswith('  ') and lines[i].strip() and items)):
                if re.match(r'^\s*[-*]\s+', lines[i]): items.append(re.sub(r'^\s*[-*]\s+','',lines[i]))
                else: items[-1]+=' '+lines[i].strip()
                i+=1
            out.append('<ul>'+''.join(f'<li>{inline(x)}</li>' for x in items)+'</ul>'); continue
        if re.match(r'^\s*\d+\.\s+', L):
            items=[]
            while i<len(lines) and (re.match(r'^\s*\d+\.\s+', lines[i]) or (lines[i].startswith('   ') and lines[i].strip() and items)):
                if re.match(r'^\s*\d+\.\s+', lines[i]): items.append(re.sub(r'^\s*\d+\.\s+','',lines[i]))
                else: items[-1]+=' '+lines[i].strip()
                i+=1
            out.append('<ol>'+''.join(f'<li>{inline(x)}</li>' for x in items)+'</ol>'); continue
        if not L.strip(): i+=1; continue
        para=[]
        while i<len(lines) and lines[i].strip() and not lines[i].startswith(('#','|','```','---')) and not re.match(r'^\s*([-*]|\d+\.)\s+',lines[i]):
            para.append(lines[i].strip()); i+=1
        out.append('<p>'+inline(' '.join(para))+'</p>')
    return '\n'.join(out)

src = open('manuscript.md').read()
# strip the title block + the trailing figure-list section (rendered separately)
src = src.split('\n', 1)[1]
src = src.split('## Figures')[0]
body = md(src)

# insert figures at their first reference
FIGDEF = [
 ('fig1','Figure 1','Shared variance of the residual <em>R</em>&nbsp;=&nbsp;Ŷ&nbsp;−&nbsp;Y with each of its inputs, as a function of λ, from equations (1) and (2) at ρ&nbsp;=&nbsp;0. The shaded band marks the residual window. The four cities and the pipeline&rsquo;s previous release are plotted at their measured λ.'),
 ('fig2','Figure 2','(a) Share of grid cells admitted to the analysis. (b) Share of admitted cells with zero recorded species. (c) Share of all occurrence records falling in cells the admission rule excludes.'),
 ('fig3','Figure 3','(a) Cumulative share of records against cells ranked by record count, with Gini coefficients. (b) The four largest Amsterdam cells, plotted against the 0.05° graticule.'),
 ('fig4','Figure 4','In-sample versus spatially blocked 5-fold cross-validated explained deviance; dots are individual folds.'),
 ('fig5','Figure 5','(a) Share of the top 1% of residual cells with zero recorded species. (b) Number of each city&rsquo;s baseline top-20 intervention cells that remain in the top 20 at all six values of the dispersal-cost ceiling.'),
]
ANCHOR = {
 'fig1':'<h2><span class="secno">3</span>Results</h2>',
 'fig2':'<h3><span class="secno">3.2</span>The effort correction discards most of the data</h3>',
 'fig3':'<h3><span class="secno">3.4</span>Model fit, in and out of sample</h3>',
 'fig4':'<h3><span class="secno">3.5</span>λ, and what the residual is actually made of</h3>',
 'fig5':'<h3><span class="secno">3.8</span>Grain</h3>',
}
for key, label, cap in FIGDEF:
    fig = (f'<figure class="fig"><img src="{URIS[key]}" alt="{label}">'
           f'<figcaption><span class="figlab">{label}</span> {cap}</figcaption></figure>')
    a = ANCHOR[key]
    if a in body: body = body.replace(a, fig + '\n' + a, 1)
    else: print('anchor missing for', key)

LAMBDA = """
<section class="lam" aria-label="Measured variance ratio by city">
  <p class="lam-eyebrow">Measured variance ratio &lambda; = Var(<span class="hat">Y</span>) / Var(Y)</p>
  <div class="lam-grid">
    <div class="lam-cell"><span class="lam-city">Porto</span><span class="lam-val">0.0280</span><span class="lam-note">36&times; below 1</span></div>
    <div class="lam-cell"><span class="lam-city">Amsterdam</span><span class="lam-val">0.00055</span><span class="lam-note">1,800&times; below 1</span></div>
    <div class="lam-cell"><span class="lam-city">Gent</span><span class="lam-val">0.00050</span><span class="lam-note">2,000&times; below 1</span></div>
    <div class="lam-cell"><span class="lam-city">Yokohama</span><span class="lam-val">0.00018</span><span class="lam-note">5,600&times; below 1</span></div>
  </div>
  <p class="lam-foot">A difference map carries information only near &lambda;&nbsp;&asymp;&nbsp;1. Below it, the map is the observation with the sign flipped.</p>
</section>
"""
body = body.replace('<hr>\n<h2>1. Introduction</h2>', LAMBDA + '<hr>\n<h2>1. Introduction</h2>',1)
body = body.replace('<hr>\n<h2><span class="secno">1</span>. Introduction</h2>', LAMBDA + '<hr>\n<h2><span class="secno">1</span>. Introduction</h2>',1)

TPL = open('artifact_template.html').read()
open('naturegap-paper.html','w').write(TPL.replace('<!--BODY-->', body))
print('written', os.path.getsize('naturegap-paper.html')//1024, 'KB')
