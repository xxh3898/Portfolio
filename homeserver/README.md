# Portfolio homeserver deployment

이 디렉터리는 Portfolio Mac mini 운영 설정의 비밀값 없는 source copy를 관리한다.
실제 운영 파일을 바꾸기 전에는 live file과 이 copy의 diff를 확인하고 파일별 backup을 만든다.

## 파일 mapping

```text
homeserver/compose.yaml
  -> /Users/homeserver/Server/apps/portfolio/compose.yaml

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
```

배포 스크립트는 digest image를 pull하고 Compose health를 확인한다.
실패하면 직전 정상 digest로 돌아가며, 첫 digest 전환 중에는 기존 40자리 SHA tag도
직전 정상 image로 인정한다.

## 검증

저장소에서 다음 명령을 실행한다.

```bash
./scripts/verify-home-server-config.sh
```

운영 파일을 동기화한 뒤에는 Mac mini에서 `bash -n`, 현재 `.env`를 사용한
`docker compose config --quiet`, repository copy와 live file의 SHA-256 일치를
확인한다. 파일 동기화만으로 운영 container를 재시작하지 않는다.

## 롤백

운영 파일 동기화에 문제가 있으면 동기화 직전 만든 개별 backup으로 세 파일을
복원하고 구문, Compose 설정, 권한과 SHA-256을 다시 확인한다.
