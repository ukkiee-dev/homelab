# Runbook 표준 템플릿

모든 Runbook은 이 템플릿을 따른다. 섹션을 빠뜨리지 말고, 해당 없는 섹션에는 "해당 없음"을 명시한다.

---

## 템플릿

```markdown
# [Runbook 제목]

| 항목 | 값 |
|------|-----|
| **심각도** | Critical / High / Medium / Low |
| **예상 소요** | N분 ~ N분 |
| **최종 수정** | YYYY-MM-DD |
| **관련 서비스** | service-a, service-b |
| **카테고리** | 장애 대응 / 일상 운영 / 백업·복원 / 인프라 관리 / 재해복구 |

## 증상

사용자 또는 시스템이 관찰하는 이상 현상을 구체적으로 기술한다.

- 관찰 가능한 증상 1
- 관찰 가능한 증상 2
- Grafana 알림 메시지 (해당 시)

## 진단

원인을 좁히는 단계별 절차. 각 단계 후 분기 판단을 포함한다.

### Step 1: [확인 사항]

\```bash
[진단 명령어]
\```

**예상 출력 (정상)**:
\```
[정상 출력 예시]
\```

**예상 출력 (비정상)**:
\```
[비정상 출력 예시]
\```

→ 정상이면 Step 2로, 비정상이면 [해결 섹션 N]으로 이동

### Step 2: [확인 사항]
...

## 해결

원인별 수정 절차. 진단 결과에 따라 해당 섹션으로 이동한다.

### 원인 A: [원인 설명]

1. [수정 절차 1]
   \```bash
   [명령어]
   \```
2. [수정 절차 2]
3. → [검증] 섹션으로 이동

### 원인 B: [원인 설명]
...

## 검증

해결 후 정상 복귀를 확인하는 절차.

\```bash
[검증 명령어]
\```

**정상 상태 기준**:
- [ ] 조건 1 충족
- [ ] 조건 2 충족
- [ ] 모니터링 알림 해소

## 롤백

해결 시도가 상황을 악화시켰을 때 원래 상태로 돌아가는 절차.

\```bash
[롤백 명령어]
\```

> ⚠️ 롤백이 불가능한 경우 명시하고 에스컬레이션으로 안내.

## 에스컬레이션

이 Runbook으로 해결되지 않을 때 다음 단계.

- **확인할 문서**: [관련 Runbook 링크]
- **확인할 시스템**: [Grafana 대시보드, ArgoCD UI 등]
- **수동 개입 필요 시**: [누구에게, 어떤 정보와 함께]

## 관련 문서

- [관련 Runbook 1](./related-runbook.md)
- [외부 문서](URL)
- [프로젝트 내 파일](../../path/to/file)
```

---

## 작성 규칙

### 명령어 블록
- 모든 명령어는 코드 블록으로 감싼다
- 변수는 `<placeholder>` 형식 + 바로 아래 예시:
  ```bash
  make logs POD=<pod-name> NS=<namespace>
  # 예: make logs POD=homepage-abc123 NS=apps
  ```

### 진단 트리
- 단순 목록이 아닌 분기 진단을 제공한다
- "→ 정상이면 Step N, 비정상이면 해결 섹션 M"
- 가능하면 원인을 확률 순(흔한 것부터)으로 나열

### Makefile 활용
프로젝트에 Makefile 타겟이 있으면 raw 명령 대신 make 사용:

| raw 명령 | Makefile 대체 |
|----------|--------------|
| `kubectl get pods -A` | `make pods` |
| `kubectl top nodes && kubectl top pods -A` | `make top` |
| `kubectl get events -A --sort-by=.lastTimestamp` | `make events` |
| `kubectl rollout restart ... -n ...` | `make restart NAME=<name> NS=<ns>` |
| `./backup.sh` | `make backup` |
| `argocd app list` | `make status` |
| `scripts/seal-secret.sh set ...` | `make seal-secret NS=<ns> NAME=<name> KEY=<key>` |

### 카테고리 분류

| 카테고리 | 파일명 패턴 | 예시 |
|---------|-----------|------|
| 장애 대응 | `incident-*.md` | incident-crashloop.md, incident-oom.md |
| 일상 운영 | `ops-*.md` | ops-deploy-app.md, ops-update-image.md |
| 백업·복원 | `backup-*.md` | backup-pvc.md, backup-postgres.md |
| 인프라 관리 | `infra-*.md` | infra-dns.md, infra-tunnel.md |
| 재해복구 | `dr-*.md` | dr-orbstack-restart.md, dr-mac-reinstall.md |

### 크로스레퍼런스
관련 Runbook을 링크할 때 상대 경로를 사용한다:
```markdown
→ 이 방법으로 해결되지 않으면 [OrbStack 재시작 Runbook](./dr-orbstack-restart.md) 참조
```
