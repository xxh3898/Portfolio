# Repository Guidelines

## 목적

이 파일은 `Projects/Portfolio`에만 적용되는 repo-specific 기준만 정의한다.
전역 하네스와 중복되는 일반 승인, 구현, 보고 절차는 전역 하네스를 따른다.

## AI 산출물 경로

- `Projects/Portfolio` 작업의 기본 AI 산출물은 `/Users/chiho/AI/portfolio/<yyyymmdd>/<NN-task-name>/`에 둔다.
- 상위 PKM 하네스의 일반 `pkm` 기본값보다 이 경로 규칙을 우선한다.
- 같은 작업의 `research-*`, `plan-*`, `review-*`, `handoff-*` 문서는 동일한 작업 폴더 아래에 함께 둔다.
- PKM 볼트 내부 `AI/**`는 기본 생성 위치가 아니라, 장기 참조 가치가 높을 때만 선별 이관한다.

## PKM 조회 우선 규칙

- 포트폴리오 작업 중 사용자 소개, 경력, 프로젝트 설명, 성과, 링크, 기술 스택, 회고가 필요하면 먼저 PKM 관련 노트를 조회하라.
- 우선 확인 경로는 아래와 같다.
  - `Projects/Portfolio/README.md`
  - `Projects/Portfolio/Portfolio.md`
  - `Areas/Career/Portfolio/포트폴리오.md`
  - `Areas/Career/Interview Prep/취업 기본 프로필.internal.md`
- PKM에서 근거를 찾지 못한 항목만 사용자에게 질문하라.
- PKM에 정보가 있어도 오래됐을 가능성, 공개 부적합 가능성, 민감성, 문서 간 불일치가 있으면 그대로 단정하지 말고 확인하라.
- 최종 보고에는 어떤 PKM 노트를 근거로 삼았는지 짧게 남겨라.

## 문서 작업 기준

- `README.md`, `index.html`, `resume.html`, `coverletter.html`, `api-spec.html`은 공개 포트폴리오 자산으로 본다.
- 공개 포트폴리오 자산에는 확인되지 않은 정보, 과장된 성과, 민감정보를 넣지 마라.
- 링크, 수치, 프로젝트 설명을 바꿀 때는 관련 PKM 노트와 실제 공개 문서가 서로 어긋나지 않는지 확인하라.

## 비강제 원칙

- 모든 작업에서 PKM 전체를 넓게 훑지 말고, 필요한 정보 유형이 분명할 때만 관련 노트를 좁혀서 읽는다.
