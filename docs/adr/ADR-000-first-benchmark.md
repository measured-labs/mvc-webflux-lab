# ADR-000: 첫 측정 — Spring MVC(Tomcat) vs Spring WebFlux(Netty)

- 상태: 대체됨 (Superseded) — 결론은 [ADR-001](ADR-001-remeasure-virtual-threads.md)로 대체
- 날짜: 2025-12(커밋 기록 기준 — 마지막 커밋 427ddab "부하테스트 완료 및 결과 확인")
- 원문: README의 "벤치마크 결과" 절(그대로 남겨 둠)

## 질문

같은 비즈니스 로직을 가진 Spring MVC(Tomcat) 앱과 Spring WebFlux(Netty) 앱의 성능은 대용량 트래픽에서 얼마나 다른가?

## 한 일

- Spring Boot 4.0 · Java 25. 서버 PC 한 대에 nginx · MVC 앱 · WebFlux 앱 · Prometheus · Grafana를 함께 띄우고(앱마다 CPU 2개 · 메모리 1G), 다른 PC의 k6로 smoke(5 VU 1분) · load(50→100 VU 10분)를 돌렸다.
- 엔드포인트: 단순 응답 · 100ms 대기 · CPU 계산 · H2 DB 조회.

## 결과를 쓸 수 없는 이유 (2026-11-18 확인)

1. MVC의 100ms 대기 엔드포인트가 실제로는 100µs만 잤다(`mvc-app/.../BenchmarkService.java`의 `TimeUnit.MICROSECONDS.sleep`). README "주요 발견" 1번의 "MVC 9.90ms vs WebFlux 108.20ms"와 그 원인 추정("`Thread.sleep()`이 실제로 100ms를 기다리지 않는 것으로 추정")은 이 버그 때문이다. 대기가 들어간 처리량 비교도 MVC에 유리하게 기울었다.
2. README "주요 발견" 2번 "Java 21+ Virtual Threads 덕분에 MVC도 높은 동시성 처리 가능"은 근거가 없다. 저장소의 앱 설정 · compose · 커밋 27개 어디에도 가상 스레드를 켠 기록이 없고, 저장소 설정 그대로 띄우면 Tomcat 일반 스레드에서 처리된다. 실행할 때 저장소 밖에서 켰을 수는 있지만 확인할 수 없다.
3. 측정한 부하(최대 100 VU · 요청 사이 0.5초 쉼)에서는 동시에 처리 중인 요청이 스레드 풀 200개를 채우지 못한다. 그래서 동시성 모델의 차이가 드러나기 어려운 조건이었다(ADR-001 load · stress 시나리오에서 세 조건 차이 1% 안쪽으로 확인).

## 결정

이 측정의 수치는 남겨 두되 결론으로 쓰지 않는다. 버그를 고치고 가상 스레드 조건을 나눠 다시 잰 [ADR-001](ADR-001-remeasure-virtual-threads.md)의 결과를 쓴다.
