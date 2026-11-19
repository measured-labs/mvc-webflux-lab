#!/usr/bin/env bash
# 무효 실행 다시 재기(2026-11-19 보완 계획): 지정한 실행만 같은 회차 · 조건 · 시나리오로 다시 잰다.
# 실행마다 조건 확인 응답 · k6 종료 코드 · 끊김(unreachable 로그 · 최대 응답 10초 초과)을 검사하고, 무효면 최대 2번 더 잰다.
# 사용: APP_HOST=jun@<앱 서버> K6_HOST=<k6 서버> K6_BIN=<k6 경로> APP_IP=<앱 서버 IP> IMAGE_TAG=cea1db5 OUT=<결과 폴더> RUNS="r1-mvc-platform-pool ..." scripts/remeasure/rerun.sh
set -euo pipefail
: "${APP_HOST:?}" "${K6_HOST:?}" "${K6_BIN:?}" "${APP_IP:?}" "${IMAGE_TAG:?}" "${OUT:?}" "${RUNS:?}"
PORT=18080
mkdir -p "$OUT"

start_app() {
  local cond=$1
  ssh "$APP_HOST" "docker rm -f mvcwf-target >/dev/null 2>&1 || true"
  case $cond in
    mvc-platform) ssh "$APP_HOST" "docker run -d --name mvcwf-target --cpus 2 --memory 1g -p $PORT:8080 -e JAVA_OPTS='-Xms512m -Xmx1024m' -e VIRTUAL_THREADS=false mvcwf-mvc:$IMAGE_TAG" ;;
    mvc-virtual)  ssh "$APP_HOST" "docker run -d --name mvcwf-target --cpus 2 --memory 1g -p $PORT:8080 -e JAVA_OPTS='-Xms512m -Xmx1024m' -e VIRTUAL_THREADS=true mvcwf-mvc:$IMAGE_TAG" ;;
    webflux)      ssh "$APP_HOST" "docker run -d --name mvcwf-target --cpus 2 --memory 1g -p $PORT:8081 -e JAVA_OPTS='-Xms512m -Xmx1024m' mvcwf-webflux:$IMAGE_TAG" ;;
  esac >/dev/null
  for i in $(seq 1 90); do
    curl -s -o /dev/null -w '%{http_code}' "http://$APP_IP:$PORT/api/simple" | grep -q 200 && return 0
    sleep 1
  done
  return 1
}

# 조건 확인: MVC는 요청을 처리한 스레드 이름, WebFlux는 응답의 서버 종류
check_condition() {
  local cond=$1 f=$2
  case $cond in
    mvc-platform) grep -q '"thread":"Thread\[' "$f" ;;
    mvc-virtual)  grep -q '"thread":"VirtualThread\[' "$f" ;;
    webflux)      grep -q '"serverType":"[^"]*WebFlux' "$f" ;;
  esac
}

# 끊김 검사: unreachable 로그 또는 최대 응답 10초 초과면 무효
outage() {
  local tag=$1
  grep -q 'network is unreachable' "$OUT/$tag.log" && return 0
  python3 -c "import json,sys; m=json.load(open('$OUT/$tag.json'))['metrics']; sys.exit(0 if m['http_req_duration']['max']>10000 else 1)"
}

for tag in $RUNS; do
  cond=$(echo "$tag" | cut -d- -f2-3); scen=$(echo "$tag" | cut -d- -f4)
  app=$([ "$cond" = webflux ] && echo webflux || echo mvc)
  for try in 1 2 3; do
    echo "$(date -Is) start $tag try=$try" | tee -a "$OUT/rerun.log"
    start_app "$cond" || { echo "$(date -Is) app not ready $tag" | tee -a "$OUT/rerun.log"; continue; }
    curl -s "http://$APP_IP:$PORT/api/delay/1" > "$OUT/$tag.thread.json"
    if ! check_condition "$cond" "$OUT/$tag.thread.json"; then echo "$(date -Is) condition mismatch $tag" | tee -a "$OUT/rerun.log"; continue; fi
    rc=0; ssh "$K6_HOST" "cd ~/mvcwf-k6 && $K6_BIN run --quiet --env BASE_URL=http://$APP_IP:$PORT --env APP_TYPE=$app --summary-export /tmp/$tag.json scenarios/$scen-test.js > /tmp/$tag.log 2>&1" || rc=$?
    scp -q "$K6_HOST:/tmp/$tag.json" "$K6_HOST:/tmp/$tag.log" "$OUT/"
    if [ "$rc" -ne 0 ]; then echo "$(date -Is) k6 rc=$rc $tag" | tee -a "$OUT/rerun.log"; continue; fi
    if outage "$tag"; then echo "$(date -Is) outage detected $tag" | tee -a "$OUT/rerun.log"; continue; fi
    echo "$(date -Is) valid $tag" | tee -a "$OUT/rerun.log"
    break
  done
done
ssh "$APP_HOST" "docker rm -f mvcwf-target >/dev/null 2>&1 || true"
echo "$(date -Is) rerun done" | tee -a "$OUT/rerun.log"
