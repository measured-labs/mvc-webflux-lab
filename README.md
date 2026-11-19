# Spring MVC vs WebFlux Performance Benchmark

## 결과와 결론 (2026-11-19 재측정)

동시에 기다리는 요청이 Tomcat 스레드 풀(200개)보다 많아지면 Spring MVC(일반 스레드) · Spring MVC(가상 스레드) · Spring WebFlux의 처리량과 응답 시간이 어떻게 달라지는지 다시 쟀다. 100ms를 기다리는 엔드포인트에 동시 사용자(VU)를 100 · 400 · 800 · 1600으로 올리며 3회씩 잰 결과(중앙값), MVC 일반 스레드는 400 VU부터 1600 VU까지 약 2,000 req/s(이론 상한 200 ÷ 0.1초)에서 더 오르지 않았고, p99가 213 → 422 → 830ms로 VU에 비례해 늘었다. 같은 코드에 가상 스레드만 켜면 1600 VU에서 10,876 req/s(약 5.4배) · p99 581ms였고, WebFlux는 15,002 req/s · p99 146ms로 가장 좋았다. 요청 사이에 쉼이 있는 일반 부하(load · stress)에서는 세 방식의 처리량 · 전체 p95 차이가 1% 안쪽이었다. 결론: 동시성 모델의 차이는 동시에 기다리는 요청이 스레드 수를 넘을 때 드러나고, 이 측정 범위(최대 1600 VU · CPU 2개 · 인공 대기)에서 가상 스레드는 일반 스레드 풀의 약 2,000 req/s 정체를 넘었지만 WebFlux에는 못 미쳤다.

| 동시 사용자(VU) | MVC 일반 스레드 req/s | MVC 가상 스레드 req/s | WebFlux req/s |
|---:|---:|---:|---:|
| 400 | 1,987 | 3,868 | 3,960 |
| 800 | 1,992 | 7,217 | 7,926 |
| 1600 | 1,999 | 10,876 | 15,002 |

- 조건: 앱 컨테이너 CPU 2개 · 메모리 1G, 앱 서버와 부하 발생 서버(k6) 분리, 실행마다 컨테이너를 새로 띄움. MVC는 요청을 처리한 스레드 이름(`Thread` · `VirtualThread`), WebFlux는 응답의 서버 종류로 조건이 실제로 적용됐는지 확인. 모든 시나리오에서 실패 0%.
- 측정 중 서버 사이 연결이 약 37분마다 20초 안팎으로 끊겨, 처음 27회 중 7회를 무효 처리하고 다시 쟀다(무효 기준은 처음 측정 뒤 · 다시 재기 전에 정해 커밋으로 고정)(결과는 다시 잰 값 기준).
- 자세한 결과 · 가설 판정 · 한계: [ADR-001](docs/adr/ADR-001-remeasure-virtual-threads.md) · 원본 [results/remeasure-20261118/](results/remeasure-20261118/) · 측정 전 고정 계획 [docs/measurement/2026-11-18-remeasure-plan.md](docs/measurement/2026-11-18-remeasure-plan.md) · [보완](docs/measurement/2026-11-19-remeasure-addendum.md).
- **아래 "벤치마크 결과" 절(2025-12 첫 측정)은 결론으로 쓰지 않는다.** MVC의 100ms 대기가 실제로는 100µs만 자는 버그가 있었고(재측정 전에 고침), 가상 스레드를 켠 기록이 저장소에 없다. 이유는 [ADR-000](docs/adr/ADR-000-first-benchmark.md)에 있다.

## 📋 프로젝트 개요

이 프로젝트는 동일한 비즈니스 로직을 가진 두 개의 Spring 애플리케이션을 통해:
- **Spring MVC (Tomcat)**: 전통적인 Servlet 기반 동기 처리
- **Spring WebFlux (Netty)**: Reactive 기반 비동기 처리

대용량 트래픽 환경에서의 성능 차이를 측정하고 분석합니다.

## 🏛️ 테스트 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Server PC (A) - Docker Compose                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         Nginx (Reverse Proxy)                         │  │
│  │                              Port: 80                                 │  │
│  │                    /mvc/* → mvc-app:8080                              │  │
│  │                    /webflux/* → webflux-app:8081                      │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│          │                              │                                   │
│          ▼                              ▼                                   │
│  ┌───────────────────┐        ┌───────────────────┐                        │
│  │     mvc-app       │        │   webflux-app     │                        │
│  │   (Container)     │        │   (Container)     │                        │
│  │                   │        │                   │                        │
│  │ CPU: 2 cores      │        │ CPU: 2 cores      │                        │
│  │ Memory: 1GB       │        │ Memory: 1GB       │                        │
│  │ Port: 8080        │        │ Port: 8081        │                        │
│  └───────────────────┘        └───────────────────┘                        │
│          │                              │                                   │
│          └──────────────┬───────────────┘                                   │
│                         ▼                                                   │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    Monitoring Stack                                   │  │
│  │  ┌─────────────┐              ┌─────────────┐                        │  │
│  │  │ Prometheus  │─────────────▶│  Grafana    │                        │  │
│  │  │ Port: 9090  │              │ Port: 3000  │                        │  │
│  │  └─────────────┘              └─────────────┘                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    ▲
                                    │ HTTP Requests
                                    │
┌─────────────────────────────────────────────────────────────────────────────┐
│  Client PC (B) - Load Test                                                  │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                              k6                                       │  │
│  │                                                                       │  │
│  │  k6 run --env TARGET_HOST=<SERVER_IP> scenarios/load-test.js         │  │
│  │                                                                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 테스트 환경 구성

| 구성 요소 | 위치 | 역할 |
|----------|------|------|
| Docker Compose | Server PC (A) | MVC/WebFlux 앱 + 모니터링 스택 |
| Nginx | Server PC (A) | 리버스 프록시, 단일 진입점 |
| k6 | Client PC (B) | 부하 생성 (서버와 분리) |

### 로컬 테스트 (1대 PC)
- k6에서 `TARGET_HOST=localhost` 또는 `TARGET_HOST=127.0.0.1` 지정
- Nginx 포트(80)로 요청

### 원격 테스트 (2대 PC - 권장)
- Server PC에서 Docker Compose 실행
- Client PC에서 `TARGET_HOST=<SERVER_IP>` 지정하여 k6 실행

## 🏗️ 프로젝트 구조

```
spring-performance-benchmark/
├── mvc-app/                       # Spring MVC + Tomcat
│   ├── src/
│   │   └── main/
│   │       ├── java/
│   │       │   └── com/benchmark/mvc/
│   │       │       ├── MvcApplication.java
│   │       │       ├── controller/
│   │       │       ├── service/
│   │       │       └── config/
│   │       └── resources/
│   │           └── application.yml
│   ├── Dockerfile
│   └── build.gradle
│
├── webflux-app/                   # Spring WebFlux + Netty
│   ├── src/
│   │   └── main/
│   │       ├── java/
│   │       │   └── com/benchmark/webflux/
│   │       │       ├── WebFluxApplication.java
│   │       │       ├── controller/
│   │       │       ├── service/
│   │       │       └── config/
│   │       └── resources/
│   │           └── application.yml
│   ├── Dockerfile
│   └── build.gradle
│
├── common/                        # 공통 모듈
│   ├── src/
│   │   └── main/java/
│   │       └── com/benchmark/common/
│   │           ├── dto/
│   │           └── util/
│   └── build.gradle
│
├── docker/                        # Docker 설정
│   ├── docker-compose.yml         # 전체 스택 (MVC + WebFlux + Monitoring)
│   ├── docker-compose.mvc.yml     # MVC만 테스트
│   ├── docker-compose.webflux.yml # WebFlux만 테스트
│   └── nginx/
│       └── nginx.conf
│
├── monitoring/                    # 모니터링 설정
│   ├── prometheus/
│   │   └── prometheus.yml
│   └── grafana/
│       ├── provisioning/
│       │   ├── dashboards/
│       │   └── datasources/
│       └── dashboards/
│
├── load-test/                     # 부하 테스트 (Client PC에서 실행)
│   ├── k6/
│   │   ├── scenarios/
│   │   │   ├── smoke-test.js
│   │   │   ├── load-test.js
│   │   │   ├── stress-test.js
│   │   │   └── spike-test.js
│   │   └── lib/
│   │       └── config.js
│   └── README.md                  # 부하 테스트 실행 가이드
│
├── scripts/                       # 실행 스크립트
│   ├── server/                    # Server PC용
│   │   ├── start-all.sh
│   │   ├── start-all.bat
│   │   ├── start-mvc.sh
│   │   ├── start-mvc.bat
│   │   ├── start-webflux.sh
│   │   ├── start-webflux.bat
│   │   ├── stop-all.sh
│   │   └── stop-all.bat
│   └── client/                    # Client PC용
│       ├── run-load-test.sh
│       ├── run-load-test.bat
│       └── README.md
│
├── results/                       # 테스트 결과 저장
│
├── settings.gradle
├── build.gradle
└── README.md
```

## 🎯 테스트 시나리오

### API 엔드포인트

| 엔드포인트 | 설명 | 테스트 목적 |
|-----------|------|------------|
| `GET /mvc/api/simple` | 간단한 JSON 응답 | 기본 처리량 |
| `GET /mvc/api/delay/{ms}` | 지연 응답 | I/O 바운드 성능 |
| `GET /mvc/api/cpu/{iterations}` | CPU 집약적 계산 | CPU 바운드 성능 |
| `GET /mvc/api/db/users` | DB 조회 | DB I/O 성능 |
| `POST /mvc/api/db/users` | DB 저장 | 쓰기 성능 |
| `GET /mvc/api/external` | 외부 API 호출 | 네트워크 I/O |
| `GET /mvc/api/stream` | 대용량 스트리밍 | 스트리밍 성능 |

> WebFlux는 `/webflux/api/*` 경로로 동일한 엔드포인트 제공

### 부하 테스트 유형

| 시나리오 | VUs | 시간 | 목적 |
|---------|-----|------|------|
| Smoke Test | 5 | 1분 | 기본 동작 확인 |
| Load Test | 100 | 10분 | 일반 부하 성능 |
| Stress Test | 300 | 10분 | 고부하 한계 확인 |
| Spike Test | 10→500→10 | 5분 | 급격한 트래픽 대응 |

## 📊 측정 지표

### Response Time Percentiles
- P50, P90, P95, P99, Max

### System Metrics
- CPU 사용률
- Memory 사용량 (Heap/Non-Heap)
- GC 횟수 및 시간
- 스레드 수

### Application Metrics
- Throughput (RPS)
- Error Rate
- Connection Pool 상태

## 🛠️ 기술 스택

| 구분 | MVC App | WebFlux App |
|------|---------|-------------|
| Framework | Spring Boot 4.0 | Spring Boot 4.0 |
| Java | 25 | 25 |
| Server | Tomcat 11 | Netty |
| DB Client | JDBC / HikariCP | R2DBC |
| HTTP Client | RestClient | WebClient |

### 인프라
- **Container**: Docker + Docker Compose
- **Reverse Proxy**: Nginx
- **Metrics**: Micrometer + Prometheus
- **Visualization**: Grafana
- **Load Testing**: k6

## 🚀 Quick Start

### 사전 요구사항

**Server PC (A):**
```bash
# Docker & Docker Compose
docker --version
docker compose version

# Java 25 (빌드용)
java -version
```

**Client PC (B):**
```bash
# k6 설치
# macOS
brew install k6

# Windows
choco install k6

# Linux
sudo apt install k6
```

### Step 1: 프로젝트 빌드 (Server PC)

```bash
# Windows
gradlew.bat clean build

# Linux/Mac
./gradlew clean build
```

### Step 2: Docker 이미지 빌드 및 실행 (Server PC)

```bash
# 전체 스택 실행 (MVC + WebFlux + Monitoring)
cd docker
docker compose up -d --build

# 또는 개별 실행
docker compose -f docker-compose.mvc.yml up -d --build
docker compose -f docker-compose.webflux.yml up -d --build
```

### Step 3: 서비스 확인

| 서비스 | URL | 설명 |
|--------|-----|------|
| MVC API | http://SERVER_IP/mvc/api/info | MVC 앱 |
| WebFlux API | http://SERVER_IP/webflux/api/info | WebFlux 앱 |
| Prometheus | http://SERVER_IP:9090 | 메트릭 수집 |
| Grafana | http://SERVER_IP:3000 | 대시보드 (admin/admin) |

### Step 4: 부하 테스트 실행 (Client PC)

```bash
# 프로젝트 클론 (Client PC에서)
git clone <repository>
cd spring-performance-benchmark/load-test

# MVC 테스트
k6 run --env TARGET_HOST=<SERVER_IP> --env APP_TYPE=mvc k6/scenarios/load-test.js

# WebFlux 테스트
k6 run --env TARGET_HOST=<SERVER_IP> --env APP_TYPE=webflux k6/scenarios/load-test.js
```

### Step 5: 결과 확인

- **실시간**: Grafana 대시보드 (http://SERVER_IP:3000)
- **k6 결과**: 터미널 출력 및 `results/` 디렉토리

## 🔧 Docker 리소스 제한 설정

`docker/docker-compose.yml`에서 리소스 조정:

```yaml
services:
  mvc-app:
    deploy:
      resources:
        limits:
          cpus: '2'        # CPU 코어 수
          memory: 1G       # 메모리 제한
        reservations:
          cpus: '1'
          memory: 512M
```

## 📈 예상 결과

### I/O 바운드 워크로드
```
WebFlux > MVC (동일 리소스 대비 높은 동시성)
```

### CPU 바운드 워크로드
```
MVC ≈ WebFlux (큰 차이 없음)
```

### 메모리 사용량
```
WebFlux < MVC (이벤트 루프 특성)
```

## 🤔 고려사항

1. **네트워크 분리**: Client PC와 Server PC 간 네트워크 지연 고려
2. **리소스 격리**: Docker로 CPU/Memory 제한하여 공정한 비교
3. **Warm-up**: 테스트 전 JIT 최적화를 위한 워밍업 필요
4. **GC 영향**: GC 설정이 결과에 영향을 미침

## 📊 벤치마크 결과

> 2025-12 첫 측정 기록이다. 결론으로 쓰지 않는다 — MVC 대기 엔드포인트 버그 · 가상 스레드 설정 기록 없음([ADR-000](docs/adr/ADR-000-first-benchmark.md)). 다시 잰 결과는 맨 위 '결과와 결론'과 [ADR-001](docs/adr/ADR-001-remeasure-virtual-threads.md).

### 테스트 환경

| 항목 | 사양 |
|------|------|
| Server PC | Windows, Docker (CPU 2코어, Memory 1GB 제한) |
| Client PC | Linux (Ubuntu) |
| Java | 25.0.1 |
| Spring Boot | 4.0.0 |
| 네트워크 | 동일 LAN (192.168.55.x) |

---

### Smoke Test 결과 (5 VUs, 1분)

#### 응답 시간 비교

| 지표 | MVC (Tomcat) | WebFlux (Netty) | 차이 |
|------|--------------|-----------------|------|
| **avg** | 17.77ms | 39.74ms | MVC 55% 빠름 |
| **min** | 3.26ms | 2.82ms | WebFlux 13% 빠름 |
| **med** | 9.25ms | 10.01ms | 비슷 |
| **p(90)** | 23.53ms | 108.16ms | MVC 78% 빠름 |
| **p(95)** | 51.29ms | 121.61ms | MVC 58% 빠름 |
| **p(99)** | 216.87ms | 168.38ms | WebFlux 22% 빠름 |
| **max** | 216.95ms | 173.12ms | WebFlux 20% 빠름 |

#### 처리량 비교

| 지표 | MVC (Tomcat) | WebFlux (Netty) |
|------|--------------|-----------------|
| **Total Requests** | 300 | 300 |
| **RPS** | 4.91/s | 4.80/s |
| **Error Rate** | 0.00% | 0.00% |
| **Iterations** | 75 | 75 |

#### 체크 결과

| 체크 항목 | MVC (Tomcat) | WebFlux (Netty) |
|----------|--------------|-----------------|
| simple: status 200 | ✅ 100% | ✅ 100% |
| simple: response time < 200ms | ⚠️ 93% (70/75) | ✅ 100% |
| delay: status 200 | ✅ 100% | ✅ 100% |
| cpu: status 200 | ✅ 100% | ✅ 100% |
| db read: status 200 | ✅ 100% | ✅ 100% |

#### 데이터 전송량

| 지표 | MVC (Tomcat) | WebFlux (Netty) |
|------|--------------|-----------------|
| **Data Received** | 844 KB (14 KB/s) | 80 KB (1.3 KB/s) |
| **Data Sent** | 26 KB (426 B/s) | 26 KB (417 B/s) |

---

### 분석

#### 낮은 동시성 (5 VUs) 결과 해석

1. **평균 응답시간**: MVC가 더 빠름 (17.77ms vs 39.74ms)
    - 낮은 동시성에서는 전통적인 스레드 기반 모델이 오버헤드가 적음
    - WebFlux의 리액티브 스택 초기화 비용이 영향

2. **최대/P99 응답시간**: WebFlux가 더 안정적 (173ms vs 217ms)
    - 극단적 상황에서 WebFlux가 더 예측 가능한 성능

3. **데이터 전송량**: MVC가 10배 더 많음 (844KB vs 80KB)
    - 응답 형식 차이로 인한 것으로 추정

#### 예상되는 고부하 시나리오

| 시나리오 | 예상 우위 | 이유 |
|---------|----------|------|
| Load Test (100 VUs) | WebFlux | 스레드 풀 한계 없음 |
| Stress Test (300 VUs) | WebFlux | 논블로킹 I/O 장점 |
| Spike Test (500 VUs) | WebFlux | 급격한 부하에 안정적 |

---

### 추가 테스트 예정

- [ ] Load Test (50→100 VUs, 10분)
- [ ] Stress Test (100→300 VUs, 10분)
- [ ] Spike Test (10↔500 VUs, 6분)
- [ ] CPU 집약적 엔드포인트 집중 테스트
- [ ] DB I/O 집중 테스트

---

### Load Test 결과 (100 VUs, 10분)

#### 전체 성능 비교

| 지표 | MVC (Tomcat) | WebFlux (Netty) | 앞선 쪽 |
|------|--------------|-----------------|------|
| **Total Requests** | 79,760 | 76,184 | MVC |
| **RPS** | **132.66/s** | 126.84/s | MVC (+4.6%) |
| **avg 응답시간** | **5.41ms** | 29.4ms | MVC (5.4배 빠름) |
| **med 응답시간** | 4.9ms | 4.74ms | 비슷 |
| **p(95)** | **10.37ms** | 105.51ms | MVC (10배 빠름) |
| **p(99)** | **15.31ms** | 108.69ms | MVC (7배 빠름) |
| **max** | 54.13ms | 183.1ms | MVC |
| **Error Rate** | 0% | 0% | 동일 |

#### 시스템 리소스 비교

| 지표 | MVC (Tomcat) | WebFlux (Netty) | 앞선 쪽 |
|------|--------------|-----------------|------|
| **CPU Max** | 19.5% | 33.6% | MVC (42% 적음) |
| **CPU Mean** | 4.93% | 3.53% | WebFlux |
| **Load Avg Max** | 0.976 | 1.15 | MVC |
| **GC Count** | 4회 | ~20회 | MVC |
| **GC Duration Max** | 4.20ms | 1.25ms | WebFlux |

#### 엔드포인트별 p(95) 비교

| 엔드포인트 | MVC | WebFlux | 앞선 쪽 | 비고 |
|-----------|-----|---------|------|------|
| `/api/simple` | 9.62ms | **7.72ms** | WebFlux | 단순 응답 |
| `/api/delay/100` | **9.90ms** | 108.20ms | MVC | ⚠️ 10배 차이 |
| `/api/cpu/5000` | 10.88ms | **9.12ms** | WebFlux | CPU 집약적 |
| `/api/db/users` | 10.87ms | **8.07ms** | WebFlux | DB 조회 |

#### 주요 발견

1. **delay 엔드포인트 이상 현상**
    - MVC: 9.90ms (100ms 대기인데 훨씬 빠름)
    - WebFlux: 108.20ms (예상대로 ~100ms)
    - **원인**: MVC의 `Thread.sleep()`이 실제로 100ms를 기다리지 않는 것으로 추정
    - 또는 k6 측정 방식 차이

2. **Virtual Threads 효과**
    - Java 21+ Virtual Threads 덕분에 MVC도 높은 동시성 처리 가능
    - 전통적인 스레드 풀 병목 현상 없음

3. **WebFlux 강점**
    - 단순 응답, CPU 작업, DB 조회에서 약간 우세
    - GC STW 시간이 짧음 (1.25ms vs 4.20ms)
    - 평균 CPU 사용률이 낮음

4. **MVC 강점**
    - 전체 처리량(RPS) 우세
    - 응답시간 일관성 (p95, p99 안정적)
    - 피크 CPU 사용률 낮음

## 📚 참고 자료

- [Spring Boot 4.0 Release Notes](https://github.com/spring-projects/spring-boot/wiki/Spring-Boot-4.0-Release-Notes)
- [Spring WebFlux Documentation](https://docs.spring.io/spring-framework/reference/web/webflux.html)
- [k6 Documentation](https://k6.io/docs/)
- [Docker Resource Constraints](https://docs.docker.com/config/containers/resource_constraints/)