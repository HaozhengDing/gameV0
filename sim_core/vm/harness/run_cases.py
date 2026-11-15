#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""T3 用例 harness 驱动：tests/vm_cases/*.yaml（T1 冻结契约） -> JSON -> C++ runner。

ctest 的 vm_cases 测试直接调用本脚本；也可以手工调试：

    python3 sim_core/vm/harness/run_cases.py \
        --runner sim_core/build-vm/vm/vm_cases_runner \
        --repo-root /tmp/gameV0 \
        --work-dir sim_core/build-vm/vm

约束：本脚本**只读** tests/vm_cases/ 与 data/，不修改任何契约文件；
JSON 是临时产物（写进构建目录），不提交。
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


def load_yaml(path):
    with path.open("r", encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def build_payload(repo_root):
    """按 manifest.yaml 索引读卡表与 4 个用例文件，合成一份 JSON。"""
    case_dir = repo_root / "tests" / "vm_cases"
    manifest = load_yaml(case_dir / "manifest.yaml")
    cards = load_yaml(case_dir / "cards.yaml")
    cases = []
    for entry in manifest.get("files", []):
        document = load_yaml(repo_root / entry["path"])
        cases.extend(document.get("cases", []))
    expected_total = manifest.get("total_cases")
    if expected_total is not None and len(cases) != expected_total:
        raise SystemExit(
            "vm_cases: 用例数 %d != manifest.total_cases %d" % (len(cases), expected_total)
        )
    for case in cases:
        if "id" not in case or "expect" not in case:
            raise SystemExit("vm_cases: 用例缺 id/expect 字段: %r" % (case.get("id"),))
    return {
        "schema": manifest.get("schema", ""),
        "spec": manifest.get("spec", ""),
        "cards": cards,
        "cases": cases,
    }


def main():
    parser = argparse.ArgumentParser(description="把 tests/vm_cases/*.yaml 转成 JSON 并驱动 C++ runner")
    parser.add_argument("--runner", required=True, help="vm_cases_runner 可执行文件路径")
    parser.add_argument("--repo-root", default=".", help="gameV0 仓库根目录")
    parser.add_argument("--work-dir", default=None, help="JSON 产物目录（默认临时目录）")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    payload = build_payload(repo_root)

    temporary = None
    if args.work_dir:
        work_dir = Path(args.work_dir).resolve()
        work_dir.mkdir(parents=True, exist_ok=True)
        json_path = work_dir / "vm_cases.json"
    else:
        temporary = tempfile.TemporaryDirectory(prefix="vm_cases_")
        json_path = Path(temporary.name) / "vm_cases.json"
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")

    print("harness: %d cases -> %s" % (len(payload["cases"]), json_path))
    completed = subprocess.run([args.runner, str(json_path)], check=False)
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
