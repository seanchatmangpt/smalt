"""`smalt-migrate all` — scan -> generate -> inject pipeline (PRD §4.2).

Chains the three migrate stages over one IaC directory, producing per-stage
typed results and a final summary. NFR-2 budget: <=30s for 50 resources
(measured on the 50-resource cosmos fixture in tests/test_migrate_pipeline.py).

NFR-1: no network anywhere — the only I/O is file reads (IaC dir) and the two
artifact writes (smalt.manifest.json, .env.smalt).
"""

from __future__ import annotations

import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import typer

from .arm_template import scan_dir as scan_arm_dir
from .bicep import scan_dir as scan_bicep_dir
from .inject import build_env, discovered_services
from .manifest import MANIFEST_NAME, build_manifest, render_manifest
from .scan import build_topology
from .terraform import ScanResult, scan_dir as scan_tf_dir

pipeline_app = typer.Typer(name="pipeline", help="scan -> generate -> inject pipeline.")
STAGE_NAMES = ("scan", "generate", "inject")


@dataclass
class StageResult:
    name: str
    status: str  # "ok" | "ok_with_errors" | "failed"
    detail: dict[str, Any] = field(default_factory=dict)
    error: str | None = None


@dataclass
class PipelineResult:
    stages: list[StageResult]
    summary: dict[str, Any]
    elapsed_ms: float


def scan_all(directory: Path) -> ScanResult:
    """Scan a directory for .tf, .bicep AND .arm.json files, merged into one
    ScanResult (build_topology consumes every language uniformly)."""
    tf = scan_tf_dir(directory)
    bi = scan_bicep_dir(directory)
    arm = scan_arm_dir(directory)
    unsupported = dict(tf.unsupported_types)
    for res in (bi, arm):
        for t, c in res.unsupported_types.items():
            unsupported[t] = unsupported.get(t, 0) + c
    return ScanResult(
        blocks=[*tf.blocks, *bi.blocks, *arm.blocks],
        errors=[*tf.errors, *bi.errors, *arm.errors],
        files_scanned=tf.files_scanned + bi.files_scanned + arm.files_scanned,
        unsupported_types=unsupported,
    )


def run_all(
    iac_dir: Path,
    output_dir: Path = Path("out"),
    target_env: Path = Path(".env.smalt"),
    host: str = "127.0.0.1",
) -> PipelineResult:
    """Run scan -> generate -> inject with per-stage typed results."""
    iac_dir = Path(iac_dir)
    output_dir = Path(output_dir)
    target_env = Path(target_env)
    stages: list[StageResult] = []
    t0 = time.perf_counter()

    # ---- stage 1: scan ----
    scan_result = scan_all(iac_dir)
    topo = build_topology(scan_result)
    stages.append(
        StageResult(
            name="scan",
            status="ok" if not topo["errors"] else "ok_with_errors",
            detail={
                "files_scanned": topo["files_scanned"],
                "resource_blocks": len(scan_result.blocks),
                "unsupported_types": dict(topo["unsupported_resource_types"]),
                "scan_errors": len(topo["errors"]),
            },
        )
    )

    # ---- stage 2: generate ----
    manifest = build_manifest(topo)
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / MANIFEST_NAME
    manifest_path.write_text(render_manifest(manifest), encoding="utf-8")
    stages.append(
        StageResult(
            name="generate",
            status="ok",
            detail={
                "manifest_path": str(manifest_path),
                "seed_fixtures": len(manifest["seed_fixtures"]),
                "bytes": manifest_path.stat().st_size,
            },
        )
    )

    # ---- stage 3: inject ----
    env_body = build_env(topo)
    backup = Path(str(target_env) + ".bak")
    wrote_backup = False
    if target_env.exists():
        shutil.copy2(target_env, backup)
        wrote_backup = True
    target_env.write_text(env_body, encoding="utf-8")
    stages.append(
        StageResult(
            name="inject",
            status="ok",
            detail={
                "env_path": str(target_env),
                "backup_written": wrote_backup,
                "services": sorted(discovered_services(topo)),
                "lines": len(env_body.splitlines()),
            },
        )
    )

    elapsed = (time.perf_counter() - t0) * 1000
    return PipelineResult(
        stages=stages,
        summary={
            "files_scanned": topo["files_scanned"],
            "resource_blocks": len(scan_result.blocks),
            "manifest_path": str(manifest_path),
            "env_path": str(target_env),
            "seed_fixtures": len(manifest["seed_fixtures"]),
            "scan_errors": len(topo["errors"]),
            "elapsed_ms": round(elapsed, 1),
        },
        elapsed_ms=round(elapsed, 1),
    )


@pipeline_app.command("all")
def pipeline_all_command(
    iac_dir: Path = typer.Option(..., "--iac-dir", exists=True, file_okay=False),
    output_dir: Path = typer.Option(Path("out"), "--output-dir", file_okay=False),
    target_env: Path = typer.Option(Path(".env.smalt"), "--target"),
    quiet: bool = typer.Option(False, "--quiet", help="Suppress per-stage lines."),
) -> None:
    """Run scan -> generate -> inject, printing one typed line per stage."""
    result = run_all(iac_dir, output_dir, target_env)
    if not quiet:
        for s in result.stages:
            typer.echo(f"[{s.name}] {s.status}: {s.detail}")
    typer.echo(
        f"[summary] files={result.summary['files_scanned']} "
        f"resources={result.summary['resource_blocks']} "
        f"manifest={result.summary['manifest_path']} "
        f"env={result.summary['env_path']} "
        f"scan_errors={result.summary['scan_errors']} "
        f"elapsed_ms={result.summary['elapsed_ms']}"
    )
