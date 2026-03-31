# 보안 감사 심각도 기준 및 Remediation 가이드

감사 발견 사항의 심각도를 일관되게 분류하고, 각 심각도에 맞는 remediation을 제시하기 위한 기준.

## 목차

1. [심각도 분류 기준](#1-심각도-분류-기준)
2. [영역별 심각도 매핑](#2-영역별-심각도-매핑)
3. [Remediation 패턴](#3-remediation-패턴)
4. [보고 형식](#4-보고-형식)
5. [교차 도메인 위험 패턴](#5-교차-도메인-위험-패턴)

---

## 1. 심각도 분류 기준

| 심각도 | 정의 | 조치 기한 | CVSS 대응 |
|--------|------|----------|-----------|
| **Critical** | 즉시 악용 가능, 클러스터 전체 영향. 데이터 유출, 권한 탈취, 서비스 파괴 가능 | 즉시 (24시간 내) | 9.0-10.0 |
| **High** | 조건부 악용 가능, 특정 워크로드 영향. 네트워크 접근 또는 인증 필요 | 1주 내 | 7.0-8.9 |
| **Medium** | 직접 악용 어렵지만 방어 심화 부재. 다른 취약점과 결합 시 위험 상승 | 1개월 내 | 4.0-6.9 |
| **Low** | 베스트 프랙티스 미준수. 보안 태세 개선 권고 | 다음 정기 점검 | 0.1-3.9 |

### 분류 판단 흐름

```
외부에서 직접 악용 가능한가?
├── Yes + 클러스터 전체 영향 → Critical
├── Yes + 특정 워크로드 영향 → High
└── No
    ├── 내부자/다른 취약점과 결합 시 악용 가능 → Medium
    └── 직접 위험 없고 개선 권고 → Low
```

---

## 2. 영역별 심각도 매핑

### 네트워크

| 발견 | 심각도 | 근거 |
|------|--------|------|
| default-deny 미적용 네임스페이스 | Critical | 모든 트래픽 허용 → 래터럴 무브먼트 |
| public 서비스에 rate-limit 누락 | High | DoS 공격 표면 |
| IngressRoute에 security-headers 누락 | High | 클릭재킹, XSS 보호 미비 |
| internal 서비스에 tailscale-only 누락 | Critical | 인증 없이 내부 서비스 접근 |
| Service가 NodePort 타입 | High | 노드 IP로 직접 접근 가능 |
| containerPort와 Service port 불일치 | Medium | 서비스 장애 (보안보다 가용성) |
| Tunnel ↔ IngressRoute hostname 불일치 | Medium | 라우팅 오류, 의도치 않은 노출 가능 |

### 시크릿

| 발견 | 심각도 | 근거 |
|------|--------|------|
| Git에 kind: Secret (평문) 커밋 | Critical | 시크릿 완전 노출 |
| ConfigMap에 API 키/토큰 포함 | Critical | 시크릿이 암호화 없이 저장 |
| SealedSecret이 아닌 Secret 참조 | High | SealedSecret 파이프라인 우회 |
| envFrom/env 참조가 존재하지 않는 Secret | High | 워크로드 기동 실패 + 보안 설정 누락 |
| SealedSecret 인증서 30일 내 만료 | Medium | 갱신 실패 시 시크릿 동기화 중단 |
| 시크릿 로테이션 정책 미문서화 | Low | 장기 사용 시크릿 침해 시 영향 확대 |

### 컨테이너

| 발견 | 심각도 | 근거 |
|------|--------|------|
| privileged: true | Critical | 호스트 커널 완전 접근 |
| allowPrivilegeEscalation: true (또는 미설정) | Critical | 컨테이너 탈출 가능 |
| hostNetwork/hostPID/hostIPC: true | Critical | 격리 우회 |
| runAsNonRoot 미설정 (예외 미해당) | High | root로 실행 시 탈출 영향 확대 |
| readOnlyRootFilesystem 미설정 | High | 악성 코드 기록 가능 |
| capabilities.drop: ["ALL"] 미설정 | High | 불필요한 커널 기능 보유 |
| seccompProfile 미설정 | Medium | 시스템 콜 필터링 미적용 |
| resources.limits 미설정 | Medium | DoS(리소스 고갈) 가능 |
| latest 태그 사용 | Medium | 이미지 추적 불가, 공급망 위험 |
| imagePullSecrets 누락 (private 이미지) | High | 이미지 풀 실패 + 잘못된 이미지 사용 가능 |

### 접근제어

| 발견 | 심각도 | 근거 |
|------|--------|------|
| ClusterRole에 verbs: ["*"] resources: ["*"] | Critical | 클러스터 완전 제어 |
| secrets 접근에 resourceNames 미제한 | High | 모든 시크릿 읽기 가능 |
| automountServiceAccountToken: true + 불필요 | High | API 서버 토큰 노출 |
| default ServiceAccount 사용 | Medium | 최소 권한 원칙 위반 |
| 미사용 ServiceAccount 존재 | Low | 공격 표면 불필요 확대 |
| ArgoCD project: default 사용 | Medium | 전체 레포/클러스터 접근 |

---

## 3. Remediation 패턴

각 발견 사항의 remediation은 3단계로 구성한다:

### 즉시 조치 (What)
구체적인 수정 내용. 코드/매니페스트 변경 사항을 명시한다.

```markdown
**즉시 조치**: `manifests/apps/myapp/deployment.yaml`에 다음 추가:
\`\`\`yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
\`\`\`
```

### 검증 방법 (Verify)
수정 후 확인 절차.

```markdown
**검증**: `kubectl get pod -n myapp -o jsonpath='{.spec.securityContext}'`로 설정 확인
```

### 재발 방지 (Prevent)
같은 문제가 재발하지 않도록 하는 장기 대책.

```markdown
**재발 방지**: setup-app 템플릿에 securityContext 기본값 포함 확인
```

---

## 4. 보고 형식

각 감사자는 아래 형식으로 `_workspace/audit_<domain>.md`에 결과를 저장한다:

```markdown
# [영역] 보안 감사 결과

**감사 일시**: YYYY-MM-DD
**감사 범위**: [범위]
**감사 모드**: 라이브 / 정적 분석

## 요약
| 심각도 | 건수 |
|--------|------|
| Critical | N |
| High | N |
| Medium | N |
| Low | N |

## 발견 사항

### [심각도] 제목
- **위치**: 파일:라인 또는 리소스 경로
- **현재 상태**: [현재 설정/값]
- **위험**: [왜 위험한지]
- **즉시 조치**: [구체적 수정]
- **검증**: [확인 방법]
- **재발 방지**: [장기 대책]

### [심각도] 제목
...

## 교차 검증 요청
[다른 감사자에게 SendMessage로 확인 요청한 내용과 결과]
```

---

## 5. 교차 도메인 위험 패턴

단일 영역에서는 Medium이지만 여러 영역이 결합하면 심각도가 상승하는 패턴:

| 패턴 | 관련 영역 | 개별 심각도 | 결합 심각도 |
|------|----------|-----------|-----------|
| 특권 컨테이너 + 네트워크 미격리 | container + network | High + Critical | **Critical** (래터럴 무브먼트) |
| 과다 RBAC + 시크릿 미암호화 | access + secret | High + Critical | **Critical** (권한 탈취 → 데이터 유출) |
| root 실행 + hostPath + 시크릿 마운트 | container + secret | High + High | **Critical** (호스트 시크릿 접근) |
| NodePort + rate-limit 미적용 | network + network | High + High | **Critical** (DoS 공격 표면) |
| SA 토큰 노출 + secrets 전체 접근 RBAC | access + secret | High + High | **Critical** (API 경유 시크릿 탈취) |
| readOnly 미설정 + 시크릿 환경변수 | container + secret | High + Medium | **High** (시크릿 디스크 기록 가능) |

오케스트레이터는 Phase 4에서 이 교차 패턴을 반드시 확인한다. 개별 감사자의 보고서에서 관련 발견 사항을 매칭하고, 결합 심각도를 적용한다.
