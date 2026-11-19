#!/usr/bin/env python3
"""재측정 결과 요약(2026-11-18 계획의 '읽는 법' 그대로): 조건 × 시나리오마다 3회의 중앙값과 범위."""
import json, glob, os, statistics, sys

D = sys.argv[1] if len(sys.argv) > 1 else 'results/remeasure-20261118'
CONDS = ['mvc-platform', 'mvc-virtual', 'webflux']
LEVELS = [100, 400, 800, 1600]

INVALID = set(open(f'{D}/INVALID.txt').read().split()) if os.path.exists(f'{D}/INVALID.txt') else set()
RERUN_OK = set()
for logf in sorted(glob.glob(f'{D}/rerun/rerun*.log')):
    for line in open(logf):
        if ' valid ' in line:
            RERUN_OK.add(line.split()[-1])
USED = []

def load(cond, scen):
    """회차 1~3을 모두 찾는다. 무효 실행은 다시 잰 유효 실행으로 바꾼다. 3회가 안 되면 멈춘다(2026-11-19 보완 계획)."""
    out = []
    for rep in (1, 2, 3):
        tag = f'r{rep}-{cond}-{scen}'
        if tag in INVALID:
            if tag not in RERUN_OK:
                sys.exit(f'다시 잰 유효 실행 없음: {tag}')
            f = f'{D}/rerun/{tag}.json'
            USED.append((tag, '다시 잼(rerun/)'))
        else:
            f = f'{D}/{tag}.json'
            USED.append((tag, '처음 측정'))
        out.append(json.load(open(f))['metrics'])
    return out

def fmt(vals, nd=0):
    vals = [v for v in vals if v is not None]
    if not vals: return '해당 없음'
    med = statistics.median(vals)
    return f"{med:,.{nd}f} ({min(vals):,.{nd}f}~{max(vals):,.{nd}f})"

def failrate(m, key='http_req_failed'):
    x = m.get(key, {})
    return x.get('value', x.get('rate'))

print('## load (50→100 VU 10분)\n')
print('| 조건 | 처리량 req/s | p95 ms | 대기 100ms p95 ms | CPU 5000 p95 ms | 실패율 % |')
print('|---|---|---|---|---|---|')
for c in CONDS:
    ms = load(c, 'load')
    print(f"| {c} | {fmt([m['http_reqs']['rate'] for m in ms],1)} | {fmt([m['http_req_duration']['p(95)'] for m in ms],1)} | {fmt([m['delay_latency']['p(95)'] for m in ms],1)} | {fmt([m['cpu_latency']['p(95)'] for m in ms],1)} | {fmt([100*failrate(m) for m in ms],2)} |")

print('\n## stress (100→300 VU 10분)\n')
print('| 조건 | 처리량 req/s | p95 ms | 실패율 % |')
print('|---|---|---|---|')
for c in CONDS:
    ms = load(c, 'stress')
    print(f"| {c} | {fmt([m['http_reqs']['rate'] for m in ms],1)} | {fmt([m['http_req_duration']['p(95)'] for m in ms],1)} | {fmt([100*failrate(m) for m in ms],2)} |")

print('\n## pool (100ms 대기만 · 쉼 없음 · 단계마다 2분)\n')
print('| 조건 | VU | 처리량 req/s | p50 ms | p99 ms | 실패율 % |')
print('|---|---|---|---|---|---|')
for c in CONDS:
    ms = load(c, 'pool')
    for lv in LEVELS:
        k = f'level:vu{lv}'
        print(f"| {c} | {lv} | {fmt([m[f'http_reqs{{{k}}}']['count']/120 for m in ms],0)} | {fmt([m[f'http_req_duration{{{k}}}']['med'] for m in ms],1)} | {fmt([m[f'http_req_duration{{{k}}}']['p(99)'] for m in ms],1)} | {fmt([100*failrate(m, f'http_req_failed{{{k}}}') for m in ms],2)} |")

print('\n## 쓴 실행\n')
print('| 실행 | 출처 |')
print('|---|---|')
for tag, src in sorted(set(USED)):
    print(f'| {tag} | {src} |')

