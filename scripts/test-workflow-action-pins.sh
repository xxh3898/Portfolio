#!/bin/bash

set -Eeuo pipefail

PROJECT_ROOT="$(
  CDPATH= cd -- "$(dirname -- "$0")/.." && pwd
)"

/usr/bin/python3 - "${PROJECT_ROOT}/.github/workflows" <<'PY'
import pathlib
import re
import sys

workflows_dir = pathlib.Path(sys.argv[1])
expected_build_push_sha = "53b7df96c91f9c12dcc8a07bcb9ccacbed38856a"
uses_pattern = re.compile(
    r"""^\s*(?:-\s*)?(?:"uses"|'uses'|uses)\s*:\s*([^\s#]+)(?:\s+#.*)?\s*$"""
)
possible_uses_pattern = re.compile(
    r"""(?:^|[\s{,-])(?:"uses"|'uses'|uses)\s*:"""
)
sha_pattern = re.compile(r"^[0-9a-f]{40}$")
external_actions = []
errors = []

workflow_files = sorted(
    set(workflows_dir.glob("*.yml")) | set(workflows_dir.glob("*.yaml"))
)
for workflow_file in workflow_files:
    for line_number, line in enumerate(
        workflow_file.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        match = uses_pattern.match(line)
        if match is None:
            if not line.lstrip().startswith("#") and possible_uses_pattern.search(line):
                errors.append(
                    f"{workflow_file}:{line_number}: unsupported uses syntax"
                )
            continue
        reference = match.group(1).strip("\"'")
        if reference.startswith("./"):
            continue
        external_actions.append((workflow_file, line_number, reference))
        if "@" not in reference:
            errors.append(
                f"{workflow_file}:{line_number}: external action is not pinned"
            )
            continue
        action, revision = reference.rsplit("@", 1)
        if not sha_pattern.fullmatch(revision):
            errors.append(
                f"{workflow_file}:{line_number}: {reference} must use a full 40-character SHA"
            )
        if (
            action == "docker/build-push-action"
            and revision != expected_build_push_sha
        ):
            errors.append(
                f"{workflow_file}:{line_number}: docker/build-push-action must use "
                f"{expected_build_push_sha}"
            )

if not external_actions:
    errors.append("no external workflow actions were found")
if uses_pattern.match('  - "uses": actions/checkout@revision') is None:
    errors.append("quoted uses keys are not recognized")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)

print(f"Workflow action pin tests passed: {len(external_actions)} references")
PY
