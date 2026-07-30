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
