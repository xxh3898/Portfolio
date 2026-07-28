#!/bin/sh

set -eu

PROJECT_ROOT=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}

python3 - "$PROJECT_ROOT" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

project_root = Path(sys.argv[1]).resolve()

public_files = (
    "index.html",
    "resume.html",
    "coverletter.html",
    "api-spec.html",
    "resume.pdf",
)
public_directories = ("assets/images",)
excluded_public_files = (
    "report-before.html",
    "report-after.html",
    "AGENTS.md",
    "README.md",
    "Portfolio.md",
)

errors: list[str] = []

for relative_path in public_files:
    path = project_root / relative_path
    if not path.is_file():
        errors.append(f"필수 공개 파일이 없습니다: {relative_path}")

for relative_path in public_directories:
    path = project_root / relative_path
    if not path.is_dir():
        errors.append(f"필수 공개 디렉터리가 없습니다: {relative_path}")

attribute_pattern = re.compile(
    r"""(?:href|src)\s*=\s*["']([^"']+)["']""",
    re.IGNORECASE,
)
css_url_pattern = re.compile(
    r"""url\(\s*["']?([^"')]+)["']?\s*\)""",
    re.IGNORECASE,
)
external_schemes = {
    "data",
    "http",
    "https",
    "javascript",
    "mailto",
    "tel",
}


def is_public_path(path: Path) -> bool:
    relative_path = path.relative_to(project_root)
    if relative_path.as_posix() in public_files:
        return True
    return any(
        relative_path == Path(directory)
        or Path(directory) in relative_path.parents
        for directory in public_directories
    )


for html_name in public_files:
    if not html_name.endswith(".html"):
        continue

    html_path = project_root / html_name
    if not html_path.is_file():
        continue

    content = html_path.read_text(encoding="utf-8")
    references = attribute_pattern.findall(content)
    references.extend(css_url_pattern.findall(content))

    for raw_reference in references:
        reference = raw_reference.strip()
        if not reference or reference.startswith(("#", "//")):
            continue

        parsed = urlsplit(reference)
        if parsed.scheme.lower() in external_schemes or parsed.netloc:
            continue

        decoded_path = unquote(parsed.path)
        if not decoded_path:
            continue

        if decoded_path.startswith("/"):
            target = project_root / decoded_path.lstrip("/")
        else:
            target = html_path.parent / decoded_path

        resolved_target = target.resolve()
        try:
            resolved_target.relative_to(project_root)
        except ValueError:
            errors.append(
                f"프로젝트 외부를 참조합니다: {html_name} -> {reference}"
            )
            continue

        if not resolved_target.exists():
            errors.append(
                f"로컬 참조 대상이 없습니다: {html_name} -> {reference}"
            )
            continue

        if not is_public_path(resolved_target):
            errors.append(
                f"운영 이미지 제외 대상을 참조합니다: {html_name} -> {reference}"
            )

for relative_path in excluded_public_files:
    if relative_path in public_files:
        errors.append(f"제외 파일이 공개 파일 목록에 포함됐습니다: {relative_path}")

if errors:
    print("정적 사이트 검증 실패:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print("정적 사이트 검증 통과")
print(f"- 공개 파일: {', '.join(public_files)}")
print(f"- 공개 디렉터리: {', '.join(public_directories)}")
print(f"- 운영 제외 파일: {', '.join(excluded_public_files)}")
PY
