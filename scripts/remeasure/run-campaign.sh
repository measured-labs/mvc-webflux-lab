#!/usr/bin/env bash
# 재측정 캠페인(2026-11-18): 조건 3개(MVC 일반 스레드 · MVC 가상 스레드 · WebFlux) × 시나리오 3개(load · stress · pool) × 3회.
# 실행 위치: 작업 PC. 앱 서버 = APP_HOST(.164), 부하 발생 = K6_HOST(.158). 실행마다 앱 컨테이너를 새로 띄운다(CPU 2 · 메모리 1G — 원래 compose 제한과 같음).
# 사용: APP_HOST=jun@<앱 서버> K6_HOST=<k6 서버 ssh 별칭> APP_IP=<앱 서버 IP> OUT=<결과 폴더> scripts/remeasure/run-campaign.sh
set -euo pipefail
: "${APP_HOST:?}" "${K6_HOST:?}" "${APP_IP:?}" "${OUT:?}"
SHA=$(git rev-parse --short HEAD)
PORT=18080
REPS=${REPS:-3}
SCENARIOS=${SCENARIOS:-"load stress pool"}
mkdir -p "$OUT"
# 회차마다 조건 순서를 돌린다(시간대 · 열 상태 치우침을 나누려고)
ORDERS=("mvc-platform mvc-virtual webflux" "mvc-virtual webflux mvc-platform" "webflux mvc-platform mvc-virtual")

start_app() {
  local cond=$1
  ssh "$APP_HOST" "docker rm -f mvcwf-target >/dev/null 2>&1 || true"
  case $cond in
    mvc-platform) ssh "$APP_HOST" "docker run -d --name mvcwf-target --cpus 2 --memory 1g -p $PORT:8080 -e JAVA_OPTS='-Xms512m -Xmx1024m' -e VIRTUAL_THREADS=false mvcwf-mvc:$SHA" ;;
    mvc-virtual)  ssh "$APP_HOST" "docker run -d --name mvcwf-target --cpus 2 --memory 1g -p $PORT:8080 -e JAVA_OPTS='-Xms512m -Xmx1024m' -e VIRTUAL_THREADS=true mvcwf-mvc:$SHA" ;;
    webflux)      ssh "$APP_HOST" "docker run -d --name mvcwf-target --cpus 2 --memory 1g -p $PORT:8081 -e JAVA_OPTS='-Xms512m -Xmx1024m' mvcwf-webflux:$SHA" ;;
  esac >/dev/null
  for i in $(seq 1 90); do
    if curl -s -o /dev/null -w '%{http_code}' "http://$APP_IP:$PORT/api/simple" | grep -q 200; then break; fi
    sleep 1
  done
  # 조건이 실제로 적용됐는지 런타임 증거(요청을 처리한 스레드 이름)
  curl -s "http://$APP_IP:$PORT/api/delay/1" > "$OUT/$2.thread.json"
}

for rep in $(seq 1 "$REPS"); do
  for cond in ${ORDERS[$(( (rep - 1) % 3 ))]}; do
    for scen in $SCENARIOS; do
      tag="r${rep}-${cond}-${scen}"
      echo "$(date -Is) start $tag" | tee -a "$OUT/campaign.log"
      start_app "$cond" "$tag"
      app=$([ "$cond" = webflux ] && echo webflux || echo mvc)
      ssh "$K6_HOST" "cd ~/mvcwf-k6 && k6 run --quiet --env BASE_URL=http://$APP_IP:$PORT --env APP_TYPE=$app --summary-export /tmp/$tag.json scenarios/$scen-test.js > /tmp/$tag.log 2>&1; echo rc=\$?" | tee -a "$OUT/campaign.log"
      scp -q "$K6_HOST:/tmp/$tag.json" "$K6_HOST:/tmp/$tag.log" "$OUT/"
      ssh "$APP_HOST" "docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' mvcwf-target" > "$OUT/$tag.stats" || true
      echo "$(date -Is) end $tag" | tee -a "$OUT/campaign.log"
    done
  done
done
ssh "$APP_HOST" "docker rm -f mvcwf-target >/dev/null 2>&1 || true"
echo "$(date -Is) campaign done" | tee -a "$OUT/campaign.log"
