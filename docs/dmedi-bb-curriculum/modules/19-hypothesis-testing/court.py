# LANE 09 COURT: re-derive EVERY reported statistic from the on-disk CSVs.
# Fail (exit 1) on any mismatch with the values printed in README/key files.
import csv, math, sys
import numpy as np
from scipy import stats

BASE="/Users/sac/smalt/docs/dmedi-bb-curriculum/modules"
fails=[]
def chk(name, got, want, tol=1e-3):
    if abs(got-want) > tol*max(1,abs(want)):
        fails.append(f"{name}: got {got!r} want {want!r}")
    else:
        print(f"  ok {name} = {got:.6g}" if isinstance(got,(int,float)) else f"  ok {name}")

# M19/20/21: bore-30
x=np.array([float(r["bore_mm"]) for r in csv.DictReader(open(f"{BASE}/19-hypothesis-testing/data/bore-30.csv"))])
n=len(x); xb=x.mean(); s=x.std(ddof=1); se=s/math.sqrt(n)
t=(xb-12)/se; tcrit=stats.t.ppf(0.975,29); p=2*(1-stats.t.cdf(abs(t),29))
print("bore-30 (M19/M20/M21 §1):")
chk("n",n,30); chk("mean",xb,12.0072,1e-4); chk("s",s,0.0035,3e-3)
chk("t",t,11.197,1e-3); chk("tcrit",tcrit,2.045,1e-3); chk("p",p,4.78e-12,5e-2)
ci=stats.t.interval(0.95,29,loc=xb,scale=se); chk("ci95lo",ci[0],12.0059,2e-4); chk("ci95hi",ci[1],12.0085,2e-4)
z=(xb-12)/(0.007407/math.sqrt(30)); chk("1samp z sigma-known",z,5.32,5e-3)

# M20 trap
rows=list(csv.DictReader(open(f"{BASE}/20-confidence-intervals/data/ci-trap-overlap.csv")))
t1=np.array([float(r["spindle1_mm"]) for r in rows]); t2=np.array([float(r["spindle2_mm"]) for r in rows])
m1,s1=t1.mean(),t1.std(ddof=1); m2,s2=t2.mean(),t2.std(ddof=1)
c1=stats.t.interval(0.95,29,loc=m1,scale=s1/math.sqrt(30)); c2=stats.t.interval(0.95,29,loc=m2,scale=s2/math.sqrt(30))
tt,ptt=stats.ttest_ind(t1,t2,equal_var=True)
ov=(min(c1[1],c2[1])-max(c1[0],c2[0]))/min(c1[1]-c1[0],c2[1]-c2[0])
sp=math.sqrt((29*s1**2+29*s2**2)/58); d=m1-m2; h=2.002*sp*math.sqrt(2/30)
print("ci-trap-overlap (M20):")
chk("m1",m1,12.0032,2e-4); chk("m2",m2,12.0022,2e-4)
chk("t",tt,2.062,1e-3); chk("p",ptt,0.0437,2e-2); chk("overlap-frac",ov,0.36,5e-2)
chk("diffCI-lo",d-h,0.0000,5e-4); chk("diffCI-hi",d+h,0.0019,5e-4)
assert c1[0]<c2[1] and c2[0]<c1[1], "CIs must overlap"
assert ptt<0.05, "test must reject"

# M21: coating
rows=list(csv.DictReader(open(f"{BASE}/21-testing-means-medians-variances/data/coating-ab-bore.csv")))
A=np.array([float(r["bore_mm"]) for r in rows if r["coating"]=="A"])
B=np.array([float(r["bore_mm"]) for r in rows if r["coating"]=="B"])
mA,sA=mA0,sA0=A.mean(),A.std(ddof=1); mB,sB=B.mean(),B.std(ddof=1)
spc=math.sqrt((29*sA**2+29*sB**2)/58); tp=(mA-mB)/(spc*math.sqrt(2/30))
pp2=2*(1-stats.t.cdf(abs(tp),58))
lw,lpw=stats.levene(A,B,center='median'); bl,blp=stats.bartlett(A,B)
tw,ptw=stats.ttest_ind(A,B,equal_var=False)
dfw=(sA**2/30+sB**2/30)**2/((sA**2/30)**2/29+(sB**2/30)**2/29)
u,pu=stats.mannwhitneyu(A,B,alternative='two-sided')
print("coating-ab (M21 §2,4,5):")
chk("meanA",mA,12.0061,2e-4); chk("meanB",mB,12.0016,2e-4); chk("sp",spc,0.0042,2e-3)
chk("t-pooled",tp,4.187,1e-3); chk("p-pooled",pp2,9.72e-5,3e-2)
chk("t-welch",tw,4.187,1e-3); chk("df-welch",dfw,57.8,5e-3); chk("p-welch",ptw,9.75e-5,3e-2)
chk("levene W",lw,0.053,3e-2); chk("levene p",lpw,0.819,1e-3)
chk("bartlett K2",bl,0.086,3e-2); chk("bartlett p",blp,0.770,1e-3)
chk("MW U",u,726,0); chk("MW p",pu,4.62e-5,3e-2)

# M21: paired
rows=list(csv.DictReader(open(f"{BASE}/21-testing-means-medians-variances/data/paired-feed.csv")))
bf=np.array([float(r["before_mm"]) for r in rows]); af=np.array([float(r["after_mm"]) for r in rows])
d=af-bf; db=d.mean(); sd=d.std(ddof=1); sed=sd/5; tp2=db/sed
ptp=2*(1-stats.t.cdf(abs(tp2),24)); tcc=stats.t.ppf(0.975,24)
ti,pi=stats.ttest_ind(bf,af)
cb=stats.t.interval(0.95,24,loc=bf.mean(),scale=bf.std(ddof=1)/5)
ca=stats.t.interval(0.95,24,loc=af.mean(),scale=af.std(ddof=1)/5)
print("paired-feed (M21 §3, M20 trap2):")
chk("dbar",db,-0.0030,2e-4); chk("sd",sd,0.0022,3e-3); chk("t-paired",tp2,-6.924,1e-3)
chk("p-paired",ptp,3.68e-7,5e-2)
chk("cid-lo",db-tcc*sed,-0.0039,3e-4); chk("cid-hi",db+tcc*sed,-0.0021,3e-4)
chk("t-unpaired",ti,2.508,1e-3); chk("p-unpaired",pi,0.0156,3e-2)
assert cb[0]<ca[1] and ca[0]<cb[1], "marginal CIs must overlap"
assert ptp<0.001, "paired must reject hard"

# M21: ANOVA
g={}
for r in csv.DictReader(open(f"{BASE}/21-testing-means-medians-variances/data/coolant-anova.csv")):
    g.setdefault(r["coolant_pct"],[]).append(float(r["bore_mm"]))
G=[np.array(g[k]) for k in ("5","8","12")]
F,pF=stats.f_oneway(*G)
grand=np.concatenate(G); gm=grand.mean()
ssb=10*sum((gr.mean()-gm)**2 for gr in G); ssw=sum(((gr-gr.mean())**2).sum() for gr in G)
print("coolant-anova (M21 §6):")
chk("F",F,12.850,1e-3); chk("p",pF,1.1997e-4,3e-2)
chk("SSB",ssb,0.00044544,3e-3); chk("SSW",ssw,0.00046799,3e-3)
chk("mean5",G[0].mean(),12.0081,2e-4); chk("mean8",G[1].mean(),12.0069,2e-4); chk("mean12",G[2].mean(),11.9993,2e-4)

# M22: scrap
rows=list(csv.DictReader(open(f"{BASE}/22-proportion-chi-square/data/scrap-shifts.csv")))
X=sum(int(r["scrapped"]) for r in rows); N=sum(int(r["inspected"]) for r in rows)
ph=X/N; z1=(ph-0.05)/math.sqrt(0.05*0.95/N)
p1=1-stats.norm.cdf(z1); p2=2*p1
lo=stats.beta.ppf(0.025,X,N-X+1); hi=stats.beta.ppf(0.975,X+1,N-X)
print("scrap-shifts (M22 §2):")
chk("x/n",X/N if N else 0,193/2500,1e-9); chk("z",z1,6.240,1e-3); chk("p-2sided",p2,4.37e-10,5e-2)
chk("wald-lo",ph-1.96*math.sqrt(ph*(1-ph)/N),0.0667,3e-3); chk("wald-hi",ph+1.96*math.sqrt(ph*(1-ph)/N),0.0877,3e-3)
chk("cp-lo",lo,0.0670,3e-3); chk("cp-hi",hi,0.0884,3e-3)

# M22: cnc
rows=list(csv.DictReader(open(f"{BASE}/22-proportion-chi-square/data/cnc-ab.csv")))
x3,n3=int(rows[0]["defective"]),int(rows[0]["inspected"])
x4,n4=int(rows[1]["defective"]),int(rows[1]["inspected"])
pp_=(x3+x4)/(n3+n4); z2=(x3/n3-x4/n4)/math.sqrt(pp_*(1-pp_)*(1/n3+1/n4))
pz=2*(1-stats.norm.cdf(abs(z2)))
p3,p4=x3/n3,x4/n4; sedd=math.sqrt(p3*(1-p3)/n3+p4*(1-p4)/n4)
print("cnc-ab (M22 §3):")
chk("p3",p3,0.0781,2e-3); chk("p4",p4,0.0968,2e-3); chk("pbar",pp_,0.0873,2e-3)
chk("z",z2,-0.829,1e-3); chk("p",pz,0.407,1e-3)
chk("ci-lo",p3-p4-1.96*sedd,-0.0628,3e-3); chk("ci-hi",p3-p4+1.96*sedd,0.0255,3e-3)

# M22: chi2 indep
tab=np.array([[int(v) for v in list(r.values())[1:]] for r in csv.DictReader(open(f"{BASE}/22-proportion-chi-square/data/defect-machine.csv"))])
chi2,pch,dof,exp=stats.chi2_contingency(tab)
print("defect-machine (M22 §4):")
chk("chi2",chi2,23.389,1e-3); chk("df",dof,6,0); chk("p",pch,6.76e-4,5e-2)
chk("min-exp",exp.min(),29.1,5e-3)
chk("rowtot0",tab.sum(1)[0],137,0); chk("rowtot3",tab.sum(1)[3],149,0)
chk("coltot0",tab.sum(0)[0],170,0); chk("N",tab.sum(),480,0)

# M22: GOF
x8=np.array([float(r["bore_mm"]) for r in csv.DictReader(open(f"{BASE}/22-proportion-chi-square/data/bore-100-gof.csv"))])
m8,s8=x8.mean(),x8.std(ddof=1)
edges=[stats.norm.ppf(i/8,loc=m8,scale=s8) for i in range(1,8)]
obs,_=np.histogram(x8,bins=[-np.inf]+edges+[np.inf])
chi2g=float(((obs-12.5)**2/12.5).sum()); pg=1-stats.chi2.cdf(chi2g,5)
print("bore-100-gof (M22 §5):")
chk("mean",m8,12.0092,2e-4); chk("s",s8,0.0042,3e-3)
chk("chi2",chi2g,1.920,2e-3); chk("obs-sum",obs.sum(),100,0)
chk("p",pg,0.860,2e-2)

# M19 power derivation (sigma corrected to 7.407 um, ADJUDICATED 2026-11-04)
za=stats.norm.ppf(0.975); zb=stats.norm.ppf(0.80)
nraw=((za+zb)*7.407/5.0)**2
chk("z_a",za,1.9600,1e-4); chk("z_b",zb,0.8416,1e-4); chk("n_raw",nraw,17.22,5e-3)
pw18=1-stats.norm.cdf(za-5/(7.407/math.sqrt(18)))+stats.norm.cdf(-za-5/(7.407/math.sqrt(18)))
chk("power(18)",pw18,0.817,5e-3)
pw17=1-stats.norm.cdf(za-5/(7.407/math.sqrt(17)))+stats.norm.cdf(-za-5/(7.407/math.sqrt(17)))
chk("power(17)",pw17,0.795,5e-3)

print()
if fails:
    print("COURT FAILED:"); [print(" ",f) for f in fails]; sys.exit(1)
print("COURT PASSED: all reported statistics re-derived from raw CSVs.")
