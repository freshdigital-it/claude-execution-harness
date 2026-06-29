#!/usr/bin/env python3
"""
Build parallel execution groups from plan.dag.json.

Tasks in the same group can run simultaneously because:
  - Their files_touched sets are disjoint (no file conflict)
  - No explicit DAG dependency between them

Output: .harness/parallel-groups.json

Usage: parallel-group-plan.py <dag_path> [output_path]
"""
import json, sys
from pathlib import Path


def build_groups(tasks: list) -> list:
    """
    Greedy grouping: place each task into the first group where
    it has no file overlap AND no dep on any existing group member.
    """
    groups = []

    for task in tasks:
        task_files = set(task.get("files_touched", []))
        task_deps  = set(task.get("deps", []))

        placed = False
        for group in groups:
            group_ids   = {t["id"] for t in group}
            group_files = set()
            for t in group:
                group_files.update(t.get("files_touched", []))

            no_file_conflict = not (task_files & group_files)
            no_dep_conflict  = not (task_deps  & group_ids)

            if no_file_conflict and no_dep_conflict:
                group.append(task)
                placed = True
                break

        if not placed:
            groups.append([task])

    return groups


def main():
    dag_path    = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else str(Path(dag_path).parent / "parallel-groups.json")

    with open(dag_path) as f:
        dag = json.load(f)

    all_tasks = dag.get("tasks", [])
    pending   = [t for t in all_tasks if t.get("status", "pending") not in ("done", "skipped")]

    groups  = build_groups(pending)
    max_par = max((len(g) for g in groups), default=0)

    result = {
        "groups": [
            {
                "group_id":     f"group-{i+1:03d}",
                "can_parallel": len(g) > 1,
                "task_count":   len(g),
                "tasks": [
                    {
                        "id":            t["id"],
                        "class":         t.get("class"),
                        "files_touched": t.get("files_touched", []),
                    }
                    for t in g
                ],
            }
            for i, g in enumerate(groups)
        ],
        "stats": {
            "total_pending":   len(pending),
            "group_count":     len(groups),
            "max_parallelism": max_par,
            "parallel_groups": sum(1 for g in groups if len(g) > 1),
        },
    }

    with open(output_path, "w") as f:
        json.dump(result, f, indent=2)

    s = result["stats"]
    print(
        f"[parallel-group-plan] {s['total_pending']} tasks"
        f" -> {s['group_count']} groups"
        f" (max {s['max_parallelism']} parallel,"
        f" {s['parallel_groups']} mixed groups)"
    )
    print(f"Output: {output_path}")


if __name__ == "__main__":
    main()
