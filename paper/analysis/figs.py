import json, numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.ticker import PercentFormatter
plt.rcParams.update({'font.size':8,'font.family':'DejaVu Sans','axes.spines.top':False,'axes.spines.right':False,
                     'figure.dpi':200,'savefig.dpi':200,'axes.labelsize':8,'axes.titlesize':9})
OUT='/Users/Fil/naturegap-freshclone/paper/figures/'
CITIES=['porto','amsterdam','gent','yokohama']
LAB={'porto':'Porto','amsterdam':'Amsterdam','gent':'Gent','yokohama':'Yokohama'}
COL={'porto':'#1b6ca8','amsterdam':'#c8102e','gent':'#2e8b57','yokohama':'#e08a00'}
S1=json.load(open('summary.json')); S2=json.load(open('summary2.json'))
CV=json.load(open('cv.json')); TH=json.load(open('theory.json'))

# ---- Fig 1: the residual window
fig,ax=plt.subplots(figsize=(6.6,2.9))
lam=np.logspace(-4.2,3,600); rho=0.0
corr=(1-rho*np.sqrt(lam))/np.sqrt(1+lam-2*rho*np.sqrt(lam))
corrE=(np.sqrt(lam)-rho)/np.sqrt(1+lam-2*rho*np.sqrt(lam))
ax.plot(lam,corr**2,color='#333',lw=1.6,label=r'shared variance with observation, $\rho^2(R,-Y)$')
ax.plot(lam,corrE**2,color='#999',lw=1.6,ls='--',label=r'shared variance with expectation, $\rho^2(R,\hat{Y})$')
ax.axvspan(0.25,4,color='#dff0d8',alpha=.8,zorder=0)
ax.text(1,0.55,'residual\nwindow',ha='center',va='center',fontsize=8,color='#2e6b2e',weight='bold')
ax.text(2.5e-4,0.9,'map reproduces\nthe DATA',fontsize=7.5,color='#c8102e',ha='left')
ax.text(2.5e2,0.9,'map reproduces\nthe MODEL',fontsize=7.5,color='#555',ha='right')
for c in CITIES:
    l=TH[c]['lam']; ax.plot([l],[TH[c]['meas']**2],'o',ms=5,color=COL[c],zorder=5)
    ax.annotate(LAB[c],(l,TH[c]['meas']**2),textcoords='offset points',xytext=(3,-9),fontsize=7,color=COL[c])
ax.plot([600],[0.9974],'s',ms=5,color='#777')
ax.annotate('NatureGap v1\n(2026-08-19)',(600,0.9974),textcoords='offset points',xytext=(-6,-24),fontsize=6.5,color='#777',ha='right')
ax.set_xscale('log'); ax.set_xlabel(r'variance ratio  $\lambda=\mathrm{Var}(\hat{Y})/\mathrm{Var}(Y)$')
ax.set_ylabel('shared variance'); ax.set_ylim(0,1.05); ax.legend(frameon=False,fontsize=7,loc='center left',bbox_to_anchor=(0.14,0.28))
ax.set_title(r'Fig. 1  A difference map is informative only when $\lambda\approx1$',loc='left')
fig.tight_layout(); fig.savefig(OUT+'fig1_residual_window.png',bbox_inches='tight'); plt.close(fig)

# ---- Fig 2: coverage and sparsity
fig,axes=plt.subplots(1,3,figsize=(6.9,2.4))
x=np.arange(4)
v1=[S1[c]['pct_sampled'] for c in CITIES]
v2=[S1[c]['sampled_zero_richness_pct'] for c in CITIES]
v3=[S2[c]['pct_obs_lost_to_effort_filter'] for c in CITIES]
for ax,v,t in zip(axes,[v1,v2,v3],
      ['a  Grid cells admitted\nto the analysis','b  Admitted cells with\nzero species recorded','c  Records falling in cells\nexcluded as unsampled']):
    ax.bar(x,v,color=[COL[c] for c in CITIES],width=.66)
    for i,val in enumerate(v): ax.text(i,val+1.5,f'{val:.0f}%',ha='center',fontsize=7)
    ax.set_xticks(x); ax.set_xticklabels([LAB[c] for c in CITIES],rotation=35,ha='right',fontsize=7)
    ax.set_ylim(0,105); ax.set_title(t,loc='left',fontsize=8); ax.yaxis.set_major_formatter(PercentFormatter())
fig.tight_layout(); fig.savefig(OUT+'fig2_coverage.png',bbox_inches='tight'); plt.close(fig)

# ---- Fig 3: record concentration (Lorenz)
fig,axes=plt.subplots(1,2,figsize=(6.6,2.7))
ax=axes[0]
for c in CITIES:
    z=np.load(f'{c}.npz'); n=np.nan_to_num(z['n_obs'],nan=0); n=np.sort(n)[::-1]
    cum=np.cumsum(n)/n.sum(); k=np.arange(1,len(n)+1)
    ax.plot(k,cum,color=COL[c],lw=1.4,label=f"{LAB[c]} (G={S2[c]['gini_obs']:.3f})")
ax.set_xscale('log'); ax.set_xlim(1,3e5); ax.set_ylim(0,1.02)
ax.set_xlabel('cells, ranked by record count'); ax.set_ylabel('cumulative share of records')
ax.axhline(.5,color='#bbb',lw=.6,ls=':'); ax.legend(frameon=False,fontsize=6.5,loc='lower right')
ax.set_title('a  Records are concentrated in a handful of cells',loc='left',fontsize=8)
ax=axes[1]
lat=json.load(open('lattice.json'))
cells=lat['amsterdam']['detail']
lons=[v['lon'] for v in cells.values()]; lats=[v['lat'] for v in cells.values()]
sz=[v['n_obs']/1500 for v in cells.values()]
ax.scatter(lons,lats,s=sz,color='#c8102e',alpha=.65,edgecolor='k',lw=.4,zorder=3)
for g in np.arange(4.80,5.06,0.05): ax.axvline(g,color='#888',lw=.5,ls='--',zorder=1)
for g in np.arange(52.30,52.41,0.05): ax.axhline(g,color='#888',lw=.5,ls='--',zorder=1)
for cid,v in cells.items():
    ax.annotate(f"{v['n_obs']:,}",(v['lon'],v['lat']),textcoords='offset points',xytext=(0,-13),fontsize=6,ha='center')
ax.set_xlim(4.815,5.04); ax.set_ylim(52.315,52.40)
ax.set_xlabel('longitude'); ax.set_ylabel('latitude')
ax.set_title("b  Amsterdam's four largest cells sit on the 0.05° graticule",loc='left',fontsize=8)
fig.tight_layout(); fig.savefig(OUT+'fig3_concentration.png',bbox_inches='tight'); plt.close(fig)

# ---- Fig 4: in-sample vs CV explained deviance
fig,ax=plt.subplots(figsize=(4.4,2.6))
w=.36
ins=[CV[c]['dev_explained_insample'] for c in CITIES]
cvm=[CV[c]['cv_dev_explained_mean'] for c in CITIES]
ax.bar(x-w/2,ins,w,color='#9ec5e8',label='in-sample $D^2$',edgecolor='none')
ax.bar(x+w/2,cvm,w,color='#1b6ca8',label='spatially blocked 5-fold CV',edgecolor='none')
for i,c in enumerate(CITIES):
    f=CV[c]['cv_dev_explained_folds']
    ax.plot([i+w/2]*len(f),f,'k.',ms=2.6,zorder=4)
ax.axhline(0,color='#333',lw=.7)
ax.set_xticks(x); ax.set_xticklabels([LAB[c] for c in CITIES],rotation=35,ha='right',fontsize=7)
ax.set_ylabel('explained deviance'); ax.legend(frameon=False,fontsize=7)
ax.set_title('Fig. 4  Out-of-sample performance of the expected-richness model',loc='left',fontsize=8.5)
fig.tight_layout(); fig.savefig(OUT+'fig4_crossval.png',bbox_inches='tight'); plt.close(fig)

# ---- Fig 5: what the gap map ranks
fig,axes=plt.subplots(1,2,figsize=(6.6,2.6))
ax=axes[0]
zr=[S2[c]['top1pct_resid_pct_zero_records'] for c in CITIES]
ax.bar(x,zr,color=[COL[c] for c in CITIES],width=.66)
for i,val in enumerate(zr): ax.text(i,val+1.2,f'{val:.0f}%',ha='center',fontsize=7)
ax.set_xticks(x); ax.set_xticklabels([LAB[c] for c in CITIES],rotation=35,ha='right',fontsize=7)
ax.set_ylim(0,110); ax.yaxis.set_major_formatter(PercentFormatter())
ax.set_title('a  Top 1% of "nature gap" cells\nwith zero species recorded',loc='left',fontsize=8)
ax=axes[1]
st=[S1[c]['top20_n_fully_stable'] for c in CITIES]
ax.bar(x,st,color=[COL[c] for c in CITIES],width=.66)
for i,val in enumerate(st): ax.text(i,val+.3,f'{val}/20',ha='center',fontsize=7)
ax.set_xticks(x); ax.set_xticklabels([LAB[c] for c in CITIES],rotation=35,ha='right',fontsize=7)
ax.set_ylim(0,20); ax.set_ylabel('cells')
ax.set_title('b  Top-20 intervention cells stable across\nall six dispersal-cost settings',loc='left',fontsize=8)
fig.tight_layout(); fig.savefig(OUT+'fig5_ranking.png',bbox_inches='tight'); plt.close(fig)
print('figures written')
