# 앱 설계 체크리스트

app-architect가 설계 시 참조하는 상세 체크리스트.

## 1. 앱 분류 결정 트리

```
Docker 이미지가 HTTP 요청을 받는가?
├── YES → 포트가 몇 번인가?
│   ├── 8080 (nginx/caddy 등 정적 서버) → static
│   ├── 3000 (Node.js/Next.js 등) → web
│   ├── 기타 (커스텀 포트) → web (포트 명시)
│   └── 다중 컴포넌트 (DB + 앱 + 캐시) → complex
└── NO → worker
```

## 2. 네트워크 토폴로지 결정 트리

```
외부(인터넷)에서 접근이 필요한가?
├── YES → public
│   └── Tailscale에서도 접근이 필요한가?
│       ├── YES → both (entryPoints: [web, websecure])
│       └── NO → public only (entryPoints: [web])
└── NO → Tailscale(VPN) 내부에서만 접근?
    ├── YES → internal (entryPoints: [websecure])
    └── NO (클러스터 내부 통신만) → none (IngressRoute 불필요)
```

## 3. 네임스페이스 결정 트리

```
컴포넌트가 3개 이상인가? (예: app + db + cache + worker)
├── YES → 전용 네임스페이스 (앱 이름)
│   └── NetworkPolicy 추가 필요 (default-deny + allow)
└── NO → apps 네임스페이스 공유
    └── 기존 NetworkPolicy로 커버됨
```

## 4. 리소스 산정 가이드

### 이미지 특성별 기준

| 특성 | CPU req/limit | Memory req/limit | 근거 |
|------|-------------|-----------------|------|
| 정적 파일 서빙 | 50m / 100m | 64Mi / 128Mi | I/O 바운드, CPU 미미 |
| SSR 웹앱 (Next.js) | 100m / 300m | 128Mi / 384Mi | 렌더링 시 CPU 스파이크 |
| API 서버 (Express/Fastify) | 100m / 200m | 128Mi / 256Mi | 일반적 웹앱 |
| 백그라운드 워커 | 100m / 200m | 128Mi / 256Mi | I/O 대기 위주 |
| PostgreSQL | 100m / 500m | 256Mi / 512Mi | 쿼리 처리 시 메모리 사용 |
| Redis | 50m / 200m | 64Mi / 256Mi | 인메모리 데이터 |
| ML 추론 | 100m / 2000m | 512Mi / 4Gi | 모델 로딩 + 추론 |

### 클러스터 가용량 확인

```bash
# 노드 전체 리소스
kubectl top nodes

# 현재 할당량
kubectl describe node | grep -A5 "Allocated resources"

# 앱별 실사용량
kubectl top pods -A --sort-by=memory
```

가용 리소스 = 노드 총량 - 시스템 오버헤드(~2.3Gi) - 기존 할당량
새 앱 리소스가 가용량의 80%를 초과하면 경고한다.

## 5. 스토리지 결정 트리

```
앱이 파일시스템에 데이터를 쓰는가?
├── YES → 재시작 후에도 데이터가 유지되어야 하는가?
│   ├── YES → PVC 필요
│   │   ├── 데이터 크기 < 10Gi → local-path-provisioner PVC
│   │   └── 데이터 크기 >= 10Gi → 외장 SSD hostPath (/Volumes/ukkiee/)
│   └── NO → emptyDir 또는 tmp 볼륨
└── NO → readOnlyRootFilesystem: true, tmp emptyDir만
```

## 6. 시크릿 분석

```
앱이 환경변수로 시크릿을 필요로 하는가?
├── YES → SealedSecret 생성 필요
│   ├── 키 목록 정리
│   ├── seal 도구: scripts/seal-secret.sh set <ns> <secret> <key> [value]
│   └── SealedSecret YAML을 매니페스트에 포함
└── NO → 시크릿 불필요
```

## 7. 모니터링 분석

```
앱에 /metrics 엔드포인트가 있는가?
├── YES → prometheus.io/scrape: "true" annotation 추가
│   └── 커스텀 경로라면 prometheus.io/path 설정
└── NO → annotation 불필요 (기본 probe만 설정)

앱에 헬스체크 엔드포인트가 있는가?
├── YES → startup/liveness/readiness probe 설정
│   └── 경로 확인 (/health, /healthz, /api/health 등)
└── NO → / 경로로 대체 (static), 또는 TCP probe (DB 등)
```
