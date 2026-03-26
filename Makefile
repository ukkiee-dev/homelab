.PHONY: help install-tools apply diff sync status argocd-password pods logs events seal-secret bootstrap-secrets migrate backup restart port-forward top health validate pvc

help: ## 명령어 목록
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- 설치 ---

install-tools: ## macOS CLI 도구 설치 (kubectl, helm, k9s 등)
	./scripts/setup.sh tools

# --- 배포 ---

apply: ## 모든 매니페스트 적용 (kustomize)
	kubectl apply -k k8s/overlays/production

diff: ## 현재 클러스터와 매니페스트 차이 확인
	kubectl diff -k k8s/overlays/production || true

validate: ## 매니페스트 서버 사이드 검증 (dry-run)
	kubectl apply -k k8s/overlays/production --dry-run=server

# --- ArgoCD ---

sync: ## ArgoCD 전체 앱 동기화
	argocd app sync app-of-apps --prune

status: ## ArgoCD 앱 상태 확인
	argocd app list

argocd-password: ## ArgoCD 초기 admin 비밀번호 확인
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# --- 모니터링 ---

pods: ## 전체 pod 상태
	kubectl get pods -A

top: ## 노드 및 pod 리소스 사용량
	@echo "=== Nodes ===" && kubectl top nodes && echo "" && echo "=== Pods (by CPU) ===" && kubectl top pods -A --sort-by=cpu | head -20

health: ## 클러스터 상태 종합 확인 (ArgoCD 앱 + 비정상 pod)
	@echo "=== ArgoCD Apps ===" && argocd app list 2>/dev/null || echo "(argocd CLI 미연결)" && echo "" && echo "=== Non-Running Pods ===" && kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || echo "모든 pod 정상"

pvc: ## PVC 스토리지 현황
	kubectl get pvc -A

logs: ## 특정 pod 로그 (사용: make logs POD=<name> NS=apps)
	kubectl logs -n $(NS) $(POD) -f

events: ## 최근 이벤트 확인
	kubectl get events -A --sort-by='.lastTimestamp' | tail -30

restart: ## 특정 워크로드 재시작 (사용: make restart NAME=<deploy/name> NS=apps)
	kubectl rollout restart -n $(NS) $(NAME)

# --- 시크릿 ---

seal-secret: ## Sealed Secret 생성 (사용: make seal-secret ARGS="traefik traefik-system kv-api-token=xxx")
	./scripts/seal-secret.sh $(ARGS)

bootstrap-secrets: ## 부트스트랩 시크릿 생성 (클러스터 초기 구성 시 필수)
	./scripts/bootstrap-secrets.sh

# --- 데이터 ---

migrate: ## 서비스 데이터 마이그레이션 (사용: make migrate SVC=uptime-kuma)
	./scripts/migrate-data.sh $(SVC)

backup: ## PVC 데이터 백업
	./backup.sh

# --- 포트포워딩 ---

port-forward: ## ArgoCD UI 접근 (localhost:8080)
	kubectl port-forward svc/argocd-server -n argocd 8080:443
