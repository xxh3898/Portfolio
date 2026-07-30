# Portfolio homeserver deployment

이 디렉터리는 Portfolio Mac mini 운영 설정의 비밀값 없는 source copy를 관리한다.
실제 운영 파일을 바꾸기 전에는 live file과 이 copy의 diff를 확인하고 파일별 backup을 만든다.

## 파일 mapping

```text
homeserver/compose.yaml
  -> runtime-config image의 /runtime/compose.yaml

homeserver/runtime-config.Dockerfile
  -> ghcr.io/xxh3898/portfolio-runtime-config:<commit-sha>

homeserver/scripts/deploy-portfolio.sh
  -> /Users/homeserver/Server/scripts/deploy/deploy-portfolio.sh

homeserver/scripts/deploy-portfolio-ci.sh
  -> /Users/homeserver/Server/scripts/deploy/deploy-portfolio-ci.sh
```

`/Users/homeserver/Server/apps/portfolio/.env`, registry token, SSH key와
known_hosts 원문은 저장소에 넣지 않는다.

## 배포 계약

GitHub Actions의 forced-command SSH는 다음 형식만 허용한다.

```text
deploy-portfolio <sha256:image-digest> <registry-user>
deploy-portfolio-v2 <sha256:image-digest> <commit-sha> keep <registry-user>
deploy-portfolio-v2 <sha256:image-digest> <commit-sha> update <sha256:config-digest> <registry-user>
```

`homeserver/compose.yaml` 또는 `homeserver/runtime-config.Dockerfile`이 변경된
배포만 새 runtime-config image를 게시하고 `update`를 사용한다. 애플리케이션만
변경된 배포는 `keep`으로 현재 검증된 config digest를 유지한다. 첫 전환 또는
drift 복구는 `workflow_dispatch`의 `sync_runtime_config`를 사용한다.

배포 스크립트는 application/config exact digest와 revision을 검증하고 Compose
health를 확인한다. 실패하면 직전 정상 application/config 쌍으로 돌아간다.
기존 v1 명령은 v2 전환 기간에만 유지한다.

v2 workflow를 `main`에 병합하기 전에 두 deploy script를 위 mapping의 Mac
mini 경로에 사전 설치해야 한다. 기존 파일을 timestamp backup으로 보존하고,
설치본 SHA-256과 repository 원본의 일치, mode `700`, `/bin/bash -n`, 잘못된
forced command 거부를 확인한 뒤에만 merge한다. 완료하지 않으면 기존
wrapper가 v2 명령을 거부한다. deploy script 자체는 runtime config artifact의
자동 동기화 대상이 아니다.

## 검증

저장소에서 다음 명령을 실행한다.

```bash
./scripts/verify-home-server-config.sh
```

v2 스크립트를 설치한 뒤에는 Mac mini에서 `bash -n`과 wrapper 입력 거부를
확인한다. runtime config는 배포 중 candidate release에서 현재 `.env`를 사용해
`docker compose config --quiet`를 통과한 뒤에만 current state가 된다.

## 롤백

운영 script 설치에 문제가 있으면 설치 직전 만든 개별 backup으로 script를
복원한다. v2 배포 실패 시 state에 기록된 직전 application image와 runtime
config release를 함께 적용한다.

배포 중단이나 host 재시작으로
`/Users/homeserver/Server/apps/portfolio/runtime-config/pending`이 남으면
pending 파일을 직접 수정·삭제하지 말고 다음 명령을 Mac mini에서 실행한다.

```bash
/Users/homeserver/Server/scripts/deploy/deploy-portfolio.sh recover
```

recovery는 pending과 마지막 검증 state, release allowlist·Compose hash,
`.env`, `current` pointer를 대조한다. target pair 적용이 이미 끝났으면 marker만
정리하고, 그렇지 않으면 이전 image/config pair를 `--pull never`로 재적용한다.
runtime config 도입 전 설치는 legacy Compose로 복구한다. 첫 image도 없던
bootstrap 중단은 app을 제거하고 image 환경을 빈 값으로 되돌린다. 불일치나
변조가 있으면 marker를 유지한 채 실패한다. 복구 후 container health와
`https://www.chochiho.cloud/health`를 확인한다.
