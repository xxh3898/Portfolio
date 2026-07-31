# Portfolio homeserver deployment

이 디렉터리는 Portfolio Mac mini 운영 설정의 비밀값 없는 source copy를
관리한다. 실제 운영 파일을 바꾸기 전에는 live file과 이 copy의 diff를
확인하고 파일별 backup과 rollback 경로를 준비한다.

## 역할과 파일 mapping

```text
homeserver/scripts/deploy-portfolio-ci.sh
  -> /Users/homeserver/Server/scripts/deploy/deploy-portfolio-ci.sh
  -> 서버에 고정 설치하는 최소 bootstrap/forced-command 진입점

homeserver/compose.yaml
  -> runtime-config artifact의 /runtime/compose.yaml

homeserver/scripts/deploy-portfolio.sh
  -> runtime-config artifact의 /runtime/scripts/deploy-portfolio.sh
  -> exact digest artifact에서 선택되는 실제 deploy/recovery worker

homeserver/runtime-config.Dockerfile
  -> ghcr.io/xxh3898/portfolio-runtime-config@sha256:<digest>
```

`/Users/homeserver/Server/apps/portfolio/.env`, registry token, SSH key와
known_hosts 원문은 저장소나 runtime-config artifact에 넣지 않는다.

## 자동 동기화 계약

마지막 성공 `Production` deployment 이후 다음 입력 중 하나가 변경되면
workflow가 runtime-config image를 발행하고 `update` mode를 선택한다.

```text
.dockerignore
homeserver/compose.yaml
homeserver/runtime-config.Dockerfile
homeserver/scripts/deploy-portfolio.sh
```

artifact의 허용 entry는 다음 세 개뿐이다.

```text
compose.yaml
scripts/
scripts/deploy-portfolio.sh (regular non-symlink, executable, mode 0700)
```

애플리케이션·정적 파일만 변경되면 새 runtime-config image를 만들지 않고
`keep` mode로 현재 검증된 config digest와 worker를 유지한다. 최초 배포,
이전 성공 deployment를 찾지 못한 경우, 또는 `workflow_dispatch`에서
`sync_runtime_config`를 선택한 경우에는 `update`를 강제한다.

stable bootstrap 자체는 artifact에 넣지 않는다. bootstrap은 artifact를
검증하고 worker를 선택하는 trust anchor이므로 그 파일이 변경될 때만 별도
승인 아래 서버에 먼저 atomic install해야 한다. 이후 Compose와 deploy worker
변경은 runtime-config artifact를 통해 자동 동기화된다.

## 배포 명령과 검증 순서

GitHub Actions의 forced-command SSH는 다음 형식만 허용한다.

```text
deploy-portfolio <sha256:image-digest> <registry-user>
deploy-portfolio-v2 <sha256:image-digest> <commit-sha> keep <registry-user>
deploy-portfolio-v2 <sha256:image-digest> <commit-sha> update <sha256:config-digest> <registry-user>
```

v2 `update`의 순서는 다음과 같다.

1. 공통 operation lock을 FD 9로 획득
2. pending transaction과 기존 state/current/marker 검증
3. exact runtime-config digest pull
4. OCI revision과 `portfolio` project label 검증
5. 임시 release에 artifact extract
6. exact entry allowlist, file type, worker mode와 Bash syntax 검증
7. 검증된 candidate worker로 `exec`
8. candidate Compose와 application exact digest/revision 검증
9. pending 기록 후 container recreate와 health 확인
10. 성공한 application/config 쌍의 state/current/marker atomic 반영

GHCR token은 argument나 environment로 worker에 전달하지 않는다. bootstrap이
mode `0600` 임시 파일을 FD 3으로 연 뒤 pathname을 제거하고, worker stdin에만
연결하면서 FD 3 자체는 닫는다. FD 9 lock은 worker 종료까지 상속되므로 deploy,
rollback, direct recovery가 서로 겹치지 않는다. lock 경합은 exit `75`다.

Compose contract는 `privileged`, host PID/cgroup, Docker API socket, host bind,
과도한 capability뿐 아니라 `devices`, `device_cgroup_rules`, `gpus`,
`deploy.resources.reservations.devices`를 통한 device grant도 거부한다.

## 기존 one-file state migration

기존 운영의 `RUNTIME_CONFIG_COMPOSE_SHA256` state와 Compose 한 파일 release는
migration source와 rollback/recovery predecessor로만 허용한다. marker가 없는
legacy state/current가 서로 일치하면 첫 `update`가 이를 검증하고 marker를 만든
뒤 script-enabled artifact를 적용한다. 신규 성공 state는 Compose와 worker의
순서 고정 합성 hash를 `RUNTIME_CONFIG_CONTENT_SHA256`에 기록한다.

legacy one-file release에서는 `keep`을 거부한다. 따라서 첫 전환은 반드시 새
runtime-config digest를 포함한 `update`여야 한다. marker가 있는데 state/current가
없거나 release/hash가 손상된 경우에는 legacy Compose로 조용히 fallback하지 않고
배포를 중단한다.

## 최초 rollout

첫 merge 전에 별도 운영 승인 아래 다음 bootstrap 한 파일만 사전 설치한다.

```text
/Users/homeserver/Server/scripts/deploy/deploy-portfolio-ci.sh
```

기존 bootstrap을 timestamp backup으로 보존하고 repository 원본과 설치본의
SHA-256 일치, mode `0700`, `/bin/bash -n`, 잘못된 forced command의 exit `64`,
Docker/Compose/Python/lockf 실행 환경을 확인한다. 기존
`/Users/homeserver/Server/scripts/deploy/deploy-portfolio.sh`는 첫 artifact 전환과
legacy recovery용 fallback으로 보존한다. 이 사전 설치 단계에서는 Compose,
`.env`, runtime state와 container를 변경하거나 recreate하지 않는다.

## 검증

저장소에서는 focused 검증 진입점을 실행한다.

```bash
./scripts/verify-home-server-config.sh
```

이 검증은 detector, bootstrap/lock/token handoff, worker transaction·rollback,
workflow action pin과 Compose exact digest 계약을 포함한다. ARM64 image build와
실제 container runtime은 required GitHub Actions check를 source of truth로 삼는다.

runtime config는 candidate release에서 현재 `.env`를 사용해
`docker compose config --quiet`을 통과한 뒤에만 적용된다. healthcheck `test`는
운영 기준과 정확히 일치해야 하며 `tmpfs`는 image content를 가리지 않는 `/tmp`
target만 허용한다. `read_only: true`, `init: true`, `pids_limit: 100`,
`security_opt: [no-new-privileges:true]`는 core hardening 불변식이다.

## 실패와 rollback

- artifact pull/label/allowlist/mode/syntax 검증 실패: 기존 state/current,
  운영 Compose, 기존 worker와 container를 변경하지 않고 배포 중단
- candidate worker가 pending 기록 전에 실패: 기존 verified pair 유지
- recreate 또는 health 실패: previous application/runtime pair를
  `--pull never`로 복구하고 성공한 경우 pending 제거
- rollback도 실패: pending을 보존하고 자동 재배포 중단
- bootstrap 설치 실패: 설치 직전 개별 backup으로 bootstrap 복원

배포 중단이나 host 재시작으로
`/Users/homeserver/Server/apps/portfolio/runtime-config/pending`이 남으면 파일을
직접 수정·삭제하지 말고 stable bootstrap의 direct recovery를 실행한다.

```bash
/Users/homeserver/Server/scripts/deploy/deploy-portfolio-ci.sh recover
```

bootstrap은 state가 가리키는 script-enabled verified release이면 그 worker의
recovery를 실행하고, one-file legacy release이면 보존된 legacy worker를 사용한다.
이 handoff 단계는 중단된 transaction이 만든 `.env` 또는 current pointer drift를
허용하되 state의 exact content hash와 marker는 계속 검증한다. recovery는
pending, state, exact release content hash, `.env`, current pointer를 대조한다.
이미 적용이 끝난 target은 pointer와 marker를 원자 정리하고, 그렇지 않으면 이전
verified pair를 복구한다. 불일치나 변조가 있으면 상태를 임의 수정하지 않고
fail-closed한다. 복구 뒤 container health와 공개
`https://www.chochiho.cloud/health`는 별도로 확인한다.
