import json, numpy as np, matplotlib
matplotlib.use('Agg'); import matplotlib.pyplot as plt
plt.rcParams.update({'font.size':8,'font.family':'DejaVu Sans','axes.spines.top':False,'axes.spines.right':False,
                     'figure.dpi':200,'savefig.dpi':200})
TH=json.load(open('theory.json'))
CITIES=['porto','amsterdam','gent','yokohama']
LAB={'porto':'Porto','amsterdam':'Amsterdam','gent':'Gent','yokohama':'Yokohama'}
COL={'porto':'#1b6ca8','amsterdam':'#c8102e','gent':'#2e8b57','yokohama':'#e08a00'}
OFF={'yokohama':(-6,-14,'right'),'gent':(-2,-34,'right'),'amsterdam':(10,-24,'left'),'porto':(6,-10,'left')}
fig,ax=plt.subplots(figsize=(6.6,3.2))
lam=np.logspace(-4.4,3.2,700); rho=0.0
corr=(1-rho*np.sqrt(lam))/np.sqrt(1+lam-2*rho*np.sqrt(lam))
corrE=(np.sqrt(lam)-rho)/np.sqrt(1+lam-2*rho*np.sqrt(lam))
ax.axvspan(0.25,4,color='#e3f1de',zorder=0)
ax.plot(lam,corr**2,color='#222',lw=1.7,label=r'shared with the observation, $\rho^2(R,-Y)$',zorder=3)
ax.plot(lam,corrE**2,color='#999',lw=1.7,ls='--',label=r'shared with the expectation, $\rho^2(R,\hat{Y})$',zorder=3)
ax.text(1,0.5,'residual\nwindow',ha='center',va='center',fontsize=8.5,color='#2e6b2e',weight='bold')
ax.text(1.1e-4,0.60,'the map reproduces\nthe DATA',fontsize=8,color='#8a1020',ha='center',style='italic')
ax.text(2.0e2,0.60,'the map reproduces\nthe MODEL',fontsize=8,color='#555',ha='center',style='italic')
for c in CITIES:
    l=TH[c]['lam']; y=TH[c]['meas']**2
    dx,dy,ha=OFF[c]
    ax.plot([l],[y],'o',ms=6,color=COL[c],zorder=6,mec='white',mew=.8)
    ax.annotate(f"{LAB[c]}\n$\\lambda$={l:.4f}".replace('0.0000','<0.0001'),(l,y),textcoords='offset points',
                xytext=(dx,dy),fontsize=7,color=COL[c],ha=ha,zorder=6,
                arrowprops=dict(arrowstyle='-',lw=.6,color=COL[c],shrinkA=0,shrinkB=2))
ax.plot([600],[0.9974],'s',ms=6,color='#666',zorder=6,mec='white',mew=.8)
ax.annotate('NatureGap v1\n(2026-08-19 export)\n$\\lambda\\gg1$',(600,0.9974),textcoords='offset points',
            xytext=(-8,-30),fontsize=7,color='#666',ha='right',
            arrowprops=dict(arrowstyle='-',lw=.6,color='#666',shrinkA=0,shrinkB=2))
ax.set_xscale('log'); ax.set_xlim(4e-5,4e3); ax.set_ylim(0,1.06)
ax.set_xlabel(r'variance ratio  $\lambda=\mathrm{Var}(\hat{Y})\,/\,\mathrm{Var}(Y)$')
ax.set_ylabel('shared variance of the residual')
ax.legend(frameon=False,fontsize=7.2,loc='lower left',bbox_to_anchor=(0.015,0.02))
ax.set_title(r'Fig. 1   An expected$-$observed map carries information only inside the residual window',
             loc='left',fontsize=8.8)
fig.tight_layout(); fig.savefig('/Users/Fil/naturegap-freshclone/paper/figures/fig1_residual_window.png',bbox_inches='tight')
print('ok')
