// load-test/k6/scenarios/pool-test.js
// 스레드 풀 포화 시나리오(2026-11-18 재측정): 100ms 대기 엔드포인트만, 쉬지 않고 동시 사용자를 단계별로 올린다.
// 일반 Tomcat 스레드 풀(200개)의 이론 상한은 200 / 0.1초 = 2,000 req/s다. 그 위 구간에서 가상 스레드 · WebFlux가 어떻게 다른지 본다.
import http from 'k6/http';
import { check } from 'k6';
import { getConfig } from '../lib/config.js';

const config = getConfig();
const LEVELS = [100, 400, 800, 1600];
const HOLD = '2m';
const GAP = 30; // 단계 사이 쉬는 초

function build() {
  const scenarios = {};
  const thresholds = {};
  let start = 0;
  for (const vus of LEVELS) {
    const name = `vu${vus}`;
    scenarios[name] = { executor: 'constant-vus', vus, duration: HOLD, startTime: `${start}s`, exec: 'delay', tags: { level: name } };
    // 단계별 요약 지표를 summary에 남기려고 거는 기준(판정용 아님 — 항상 통과)
    thresholds[`http_req_duration{level:${name}}`] = ['p(99)<600000'];
    thresholds[`http_reqs{level:${name}}`] = ['count>=0'];
    thresholds[`http_req_failed{level:${name}}`] = ['rate<=1'];
    start += 120 + GAP;
  }
  return { scenarios, thresholds, summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'] };
}

export const options = build();

export function delay() {
  const res = http.get(config.endpoints.delay(100));
  check(res, { 'delay: status 200': (r) => r.status === 200 });
}
