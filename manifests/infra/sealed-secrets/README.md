# sealed-secrets controller public cert

GitHub-hosted runner (`ubuntu-latest`) 에서 동작하는 composite action 이 **오프라인 모드**로 kubeseal 을 호출하기 위한 공개 인증서.

## 왜 커밋하는가

- `kubeseal` 의 온라인 모드(`--controller-namespace ... --controller-name ...`) 는 kubeconfig 를 요구하지만 GitHub-hosted runner 는 클러스터 kubeconfig 가 없다.
- 오프라인 모드(`--cert <path>`) 는 controller 공개 인증서만 있으면 **암호학적으로 클라이언트 사이드에서 seal** 가능.
- 이 `.pem` 은 **공개키**이므로 공개 레포에 커밋해도 안전하다 (secret 복호화 불가).

## cert 갱신 (rotate) 가이드

sealed-secrets controller 는 주기적으로 key 를 rotate 하며, 현재 cert 만료일은 **2036-03-25** 까지 유효 (10년).

만료 전 또는 수동 rotate 후 재발급이 필요하면:

```bash
kubeseal --controller-namespace kube-system \
  --controller-name sealed-secrets \
  --fetch-cert \
  > manifests/infra/sealed-secrets/controller-cert.pem

# 검증
openssl x509 -in manifests/infra/sealed-secrets/controller-cert.pem -noout -dates
```

변경 후 커밋하면 composite action 이 다음 실행부터 새 cert 로 seal.

> **주의**: 기존 SealedSecret 은 이전 private key 로 해독되므로 cert 갱신이 기존 secret 을 무효화하진 않는다. controller 가 active + deprecated key 를 동시에 보관하는 한 기존 암호문은 계속 유효.

## 참고

- `.github/actions/setup-app/database/action.yml` — `kubeseal --cert` 로 이 파일 참조
- 2026-04-22 `fix(database): kubeseal offline 모드 전환` PR — 이 전략 도입 배경
