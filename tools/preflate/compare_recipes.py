#!/usr/bin/env python3
"""Per group: our recipes (test_preflate -tsv) against preflate 0.3.4 (M0 baseline)."""
import sys, csv, collections, glob
BENCH='/mnt/IA_LAB/agentes/ppa/preflate/m0/bench'
def load_base(subset):
    rows=collections.defaultdict(list)
    for r in csv.DictReader(open(f'{BENCH}/{subset}.streams.tsv'), delimiter='\t'):
        rows[r['file']].append(r)
    return rows
def main(subset, tsvs, md=False):
    base=load_base(subset)
    mine=collections.defaultdict(list)
    for t in tsvs:
        for line in open(t):
            f=line.rstrip('\n').split('\t')
            name=f[0].split(' #')[0]
            mine[name].append(dict(a=int(f[1]),plain=int(f[2]),kind=int(f[3]),rec=int(f[4]),msA=int(f[5]),msR=int(f[6])))
    G=collections.OrderedDict()
    tot=collections.Counter()
    for fn,brs in sorted(base.items()):
        grp=brs[0]['group']
        if fn not in mine: continue
        g=G.setdefault(grp,collections.Counter())
        ms=mine[fn]
        for m in ms:
            g['n']+=1; g['k%d'%m['kind']]+=1; g['rec']+=m['rec']; g['plain']+=m['plain']; g['msA']+=m['msA']; g['msR']+=m['msR']
            if m['kind']==3: g['rec3']+=m['rec']
        for b in brs:
            if b['deflate_bytes'] not in ('','-'):
                g['defl']+=int(b['deflate_bytes'])
                if any(m['kind']==3 for m in ms): g['defl3']+=int(b['deflate_bytes']); g['pf3']+=int(b['pf_diff'] or 0)
            if b['pf_ok']=='ok': g['pf']+=int(b['pf_diff'])
    hdr='| group | streams | k0 | k1 | k3 | deflate B | recipes B | % deflate | preflate B | preflate % | k3 deflate B | k3 recipes % | preflate on them % | analyse MB/s | rebuild MB/s |'
    print(hdr); print('|'+'---|'*15)
    def row(name,g):
        pct=lambda a,b: '%.2f'%(100*a/b) if b else '-'
        mbs=lambda ms: '%.1f'%(g['plain']/1e6/(ms/1e3)) if ms else '-'
        print(f"| {name} | {g['n']} | {g['k0']} | {g['k1']} | {g['k3']} | {g['defl']:,} | {g['rec']:,} | {pct(g['rec'],g['defl'])} | {g['pf']:,} | {pct(g['pf'],g['defl'])} | {g['defl3']:,} | {pct(g['rec3'],g['defl3'])} | {pct(g['pf3'],g['defl3'])} | {mbs(g['msA'])} | {mbs(g['msR'])} |")
    for k,g in G.items():
        row(k,g); tot.update(g)
    row('**total**',tot)
if __name__=='__main__':
    main(sys.argv[1], sys.argv[2:])
