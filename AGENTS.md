# Repository Guidelines

## 목적

이 파일은 `Projects/Portfolio`에만 적용되는 repo-specific 기준만 정의한다.
전역 하네스와 중복되는 일반 승인, 구현, 보고 절차는 전역 하네스를 따른다.

## AI 산출물 경로

- `Projects/Portfolio` 작업의 기본 AI 산출물은 `/Users/chiho/AI/portfolio/<yyyymmdd>/<NN-task-name>/`에 둔다.
- 상위 PKM 하네스의 일반 `pkm` 기본값보다 이 경로 규칙을 우선한다.
- 같은 작업의 `research-*`, `plan-*`, `review-*`, `handoff-*` 문서는 동일한 작업 폴더 아래에 함께 둔다.
- PKM 볼트 내부 `AI/**`는 기본 생성 위치가 아니라, 장기 참조 가치가 높을 때만 선별 이관한다.

## 편집 근거 조회 규칙

- 이 프로젝트에서 `index.html`, `resume.html`, `coverletter.html`을 수정할 때 근거가 더 필요하면 PKM 관련 노트를 좁게 조회하라.
- 우선 확인 경로는 아래와 같다.
  - `Projects/Portfolio/README.md`
  - `Projects/Portfolio/Portfolio.md`
  - `Areas/Career/Portfolio/포트폴리오.md`
  - `Areas/Career/Interview Prep/취업 기본 프로필.internal.md`
- PKM은 보조 근거일 뿐이며, 공개 제출 자산을 덮어쓰는 source of truth가 아니다.
- PKM과 공개 자산 사이에 오래된 정보, 공개 부적합 정보, 민감정보, 문서 간 불일치가 있으면 그대로 반영하지 말고 확인하라.
- 최종 보고에는 어떤 PKM 노트를 근거로 삼았는지 짧게 남겨라.
- `Projects/Portfolio` 작업에서 나온 설명 자산 중 장기 재사용 가치가 있으면 제한적으로 `PKM 후보`로 제안할 수 있다.
- 단순 문구 다듬기, 링크 수정, 디자인 수정, 상태 업데이트는 `PKM 후보`로 올리지 마라.

## 제출본 source of truth 규칙

- 실제 제출본 기준은 `index.html`, `resume.html`, `coverletter.html` 3개다.
- 이 프로젝트를 직접 수정할 때는 위 3개 HTML을 기준으로 편집한다.
- `README.md`와 `Portfolio.md`는 보조 공개 문서이며, 위 3개 HTML을 덮어쓰는 source of truth가 아니다.
- `resume.pdf`는 기본 확인 대상이 아니며, 이 하네스에서는 읽지 않는다.
- HTML 제출본과 PKM 노트가 충돌하면 추측하지 말고 차이와 필요한 인간 결정을 먼저 보고하라.

## 문서 작업 기준

- `README.md`, `index.html`, `resume.html`, `coverletter.html`, `api-spec.html`은 공개 포트폴리오 자산으로 본다.
- 공개 포트폴리오 자산에는 확인되지 않은 정보, 과장된 성과, 민감정보를 넣지 마라.
- 링크, 수치, 프로젝트 설명을 바꿀 때는 관련 PKM 노트와 실제 공개 문서가 서로 어긋나지 않는지 확인하라.

## 비강제 원칙

- 모든 작업에서 PKM 전체를 넓게 훑지 말고, 필요한 정보 유형이 분명할 때만 관련 노트를 좁혀서 읽는다.
