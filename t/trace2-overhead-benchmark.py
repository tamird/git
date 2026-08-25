#!/usr/bin/env python3
"""Opt-in, warm-cache Trace2 overhead measurement of one optimized Git binary.

Run through Bazel with -c opt --stamp --nocache_test_results. Fixtures live in
TEST_TMPDIR; raw samples and summaries go to TEST_UNDECLARED_OUTPUTS_DIR.
Only direct Git process wall/child CPU time is sampled, including startup and
output collection. Fixture preparation, validation, hashing, and trace parsing
are outside that interval. Trace parsing is not OG postprocessing measurement.
The 180-second budget is checked at Git launches and work boundaries, not by a
watchdog. Bazel's medium-test timeout supplies the hard outer limit.
"""

from __future__ import annotations

import hashlib
import itertools
import json
import os
import platform
import random
import signal
import statistics
import subprocess
import sys
import time
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

from python.runfiles import runfiles

try:
    import resource
except ImportError:
    resource = None


Mode = Literal["off", "event-null", "event-file"]
MODES: tuple[Mode, ...] = ("off", "event-null", "event-file")
# All six permutations balance position and each directed within-round pair.
ORDERS = tuple(itertools.permutations(MODES))
SMALL_FILES = 4000
STREAM_FILES = 8
STREAM_BYTES = 8 * 1024 * 1024
BUDGET_SECONDS = 180
CONFIG = (
    "core.fsmonitor=false",
    "core.untrackedCache=false",
    "core.autocrlf=false",
    "core.attributesFile=/dev/null",
    "core.hooksPath=/dev/null",
    "core.bigFileThreshold=1m",
    "checkout.workers=4",
    "checkout.thresholdForParallelism=0",
    "commit.gpgSign=false",
    "gc.auto=0",
    "maintenance.auto=false",
)


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def child_cpu() -> tuple[float, float] | None:
    if resource is None:
        return None
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime, usage.ru_stime


@dataclass(frozen=True)
class Measurement:
    wall_seconds: float
    child_user_seconds: float | None
    child_system_seconds: float | None
    stdout: bytes
    stderr: bytes


@dataclass
class Git:
    path: Path
    trace: Path
    environment: dict[str, str]
    deadline: float

    def remaining_seconds(self) -> float:
        remaining = self.deadline - time.perf_counter()
        if remaining <= 0:
            raise TimeoutError("benchmark exceeded its 180-second work-boundary budget")
        return remaining

    def command(self, args: tuple[str, ...]) -> list[str]:
        return [str(self.path), "--no-pager", *itertools.chain.from_iterable(
            ("-c", setting) for setting in CONFIG
        ), *args]

    def run(self, repo: Path, args: tuple[str, ...], mode: Mode = "off") -> Measurement:
        env = dict(self.environment)
        env["GIT_TRACE2_EVENT"] = {
            "off": "0", "event-null": os.devnull, "event-file": str(self.trace)
        }[mode]
        if mode == "event-file":
            self.trace.write_bytes(b"")
        command = self.command(args)
        remaining = self.remaining_seconds()
        before = child_cpu()
        start = time.perf_counter()
        with subprocess.Popen(
            command, cwd=repo, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        ) as process:
            try:
                stdout, stderr = process.communicate(timeout=min(30, remaining))
            except subprocess.TimeoutExpired as error:
                # This session belongs only to this invocation. Killing just
                # Git could leave checkout workers running with our pipes open.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                error.output, error.stderr = process.communicate()
                raise
        elapsed = time.perf_counter() - start
        after = child_cpu()
        if process.returncode:
            raise subprocess.CalledProcessError(
                process.returncode, command, output=stdout, stderr=stderr,
            )
        return Measurement(
            elapsed,
            after[0] - before[0] if after is not None and before is not None else None,
            after[1] - before[1] if after is not None and before is not None else None,
            stdout, stderr,
        )


@dataclass(frozen=True)
class Fixture:
    repo: Path
    files: dict[str, str]
    index: bytes
    object_counts: str

    def prepare_checkout(self) -> None:
        for name in self.files:
            (self.repo / name).unlink()
        # Restore identical index contents, including the original stat cache.
        (self.repo / ".git/index").write_bytes(self.index)

    def verify_checkout(self) -> None:
        for name, expected in self.files.items():
            if file_hash(self.repo / name) != expected:
                raise AssertionError(f"checkout content changed: {name}")


def make_fixture(git: Git, root: Path, streaming: bool) -> Fixture:
    repo = root / ("streaming" if streaming else "small")
    repo.mkdir()
    git.run(repo, ("init", "--quiet", "--initial-branch=main", "--template=", "."))
    files: dict[str, str] = {}

    def write(name: str, content: bytes) -> None:
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        files[name] = hashlib.sha256(content).hexdigest()

    if streaming:
        # Repeated nonzero pseudorandom blocks avoid sparse-file shortcuts,
        # while keeping fixture creation and packing bounded and reproducible.
        generator = random.Random(0)
        for index in range(STREAM_FILES):
            block = generator.randbytes(64 * 1024)
            write(f"data/{index:04d}.bin", block * (STREAM_BYTES // len(block)))
    else:
        # Automatic CRLF conversion forces the buffered checkout phases without
        # external filters or platform-specific encodings. Trees are distinct.
        write(".gitattributes", b"*.txt text=auto eol=crlf\n")
        for index in range(SMALL_FILES):
            content = f"trace2-overhead-needle {index:06d}\n" + "x" * 2000 + "\n"
            write(f"data/{index // 10:04d}/{index:06d}.txt",
                  content.replace("\n", "\r\n").encode())
    git.run(repo, ("add", "--all"))
    git.run(repo, ("commit", "--quiet", "-m", "benchmark fixture"))
    git.run(repo, ("repack", "-a", "-d", "--window=10", "--depth=10", "--threads=1"))
    counts = git.run(repo, ("count-objects", "-v")).stdout.decode()
    parsed = dict(line.split(": ", 1) for line in counts.splitlines())
    if int(parsed["count"]) != 0 or int(parsed["in-pack"]) <= len(files):
        raise AssertionError("fixture must have packed blobs and trees, no loose objects")
    return Fixture(repo, files, (repo / ".git/index").read_bytes(), counts)


@dataclass(frozen=True)
class Workload:
    name: str
    fixture: Fixture
    args: tuple[str, ...]
    checkout: bool
    expected_stdout: bytes
    required_timers: dict[str, int]


def trace_coverage(path: Path, required: dict[str, int]) -> dict[str, object]:
    timers: Counter[str] = Counter()
    events: Counter[str] = Counter()
    sessions: set[str] = set()
    with path.open() as source:
        for line in source:
            event = json.loads(line)
            events[event["event"]] += 1
            sessions.add(event["sid"])
            if event["event"] == "timer":
                timers[f"{event['category']}/{event['name']}"] += event["intervals"]
    if not events["version"] or not events["exit"]:
        raise AssertionError("expected a complete Trace2 event stream")
    for name, minimum in required.items():
        if timers[name] < minimum:
            raise AssertionError(f"{name}: expected >= {minimum} intervals, got {timers[name]}")
    return {"bytes": path.stat().st_size, "events": dict(events),
            "processes": len(sessions), "timer_intervals": dict(timers)}


@dataclass(frozen=True)
class Sample:
    mode: Mode
    round: int
    position: int
    wall_seconds: float
    child_user_seconds: float | None
    child_system_seconds: float | None
    trace: dict[str, object] | None


def summarize(samples: list[Sample]) -> dict[str, object]:
    summary: dict[str, object] = {}
    for mode in MODES:
        selected = [sample for sample in samples if sample.mode == mode]
        values: dict[str, object] = {"samples": len(selected)}
        for metric, timings in (
            ("wall_seconds", [sample.wall_seconds for sample in selected]),
            ("child_user_seconds", [sample.child_user_seconds for sample in selected]),
            ("child_system_seconds", [sample.child_system_seconds for sample in selected]),
        ):
            available = [value for value in timings if value is not None]
            if len(available) == len(timings):
                values[metric] = {
                    "median": statistics.median(available),
                    "min": min(available), "max": max(available),
                }
        off = [sample for sample in samples if sample.mode == "off"]
        ratios = [sample.wall_seconds / baseline.wall_seconds
                  for sample, baseline in zip(selected, off)]
        values["median_paired_wall_ratio_to_off"] = statistics.median(ratios)
        summary[mode] = values
    return summary


def benchmark(git: Git, workload: Workload) -> dict[str, object]:
    samples: list[Sample] = []
    # Two warmups per mode; no sample is a cold-cache measurement.
    for round_index, order in enumerate((MODES, tuple(reversed(MODES)), *ORDERS), -2):
        for position, mode in enumerate(order):
            git.remaining_seconds()
            if workload.checkout:
                workload.fixture.prepare_checkout()
            measured = git.run(workload.fixture.repo, workload.args, mode)
            if measured.stdout != workload.expected_stdout or measured.stderr:
                raise AssertionError(f"{workload.name}/{mode}: output parity failed")
            if workload.checkout:
                workload.fixture.verify_checkout()
            coverage = (trace_coverage(git.trace, workload.required_timers)
                        if mode == "event-file" else None)
            git.remaining_seconds()
            if round_index >= 0:
                samples.append(Sample(
                    mode, round_index, position, measured.wall_seconds,
                    measured.child_user_seconds, measured.child_system_seconds, coverage,
                ))
    summary = summarize(samples)
    print(workload.name, json.dumps(summary, separators=(",", ":")), flush=True)
    return {
        "argv": git.command(workload.args),
        "files": len(workload.fixture.files),
        "packed_objects": workload.fixture.object_counts,
        "stdout_sha256": hashlib.sha256(workload.expected_stdout).hexdigest(),
        "samples": [asdict(sample) for sample in samples], "summary": summary,
    }


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[2] != "opt":
        raise SystemExit("run //t:trace2-overhead-benchmark with -c opt --stamp")
    resolver = runfiles.Create()
    if resolver is None:
        raise RuntimeError("Bazel runfiles are required")
    location = resolver.Rlocation(sys.argv[1])
    if location is None:
        raise RuntimeError("declared //:git runfile is missing")
    git_path = Path(location).resolve(strict=True)
    root = Path(os.environ["TEST_TMPDIR"]) / "trace2-overhead-benchmark"
    root.mkdir()
    output = Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"]) / "trace2-overhead.json"
    # Isolation is subprocess-only. Preserve HOME and PATH; never read or edit
    # the user's Git config, inherited repository selection, or trace sinks.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(
        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_SYSTEM=os.devnull,
        GIT_CONFIG_GLOBAL=os.devnull, GIT_ATTR_NOSYSTEM="1",
        GIT_EXEC_PATH=str(git_path.parent), GIT_TERMINAL_PROMPT="0",
        GIT_AUTHOR_NAME="Trace2 benchmark", GIT_AUTHOR_EMAIL="benchmark@example.invalid",
        GIT_COMMITTER_NAME="Trace2 benchmark", GIT_COMMITTER_EMAIL="benchmark@example.invalid",
        GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000",
        GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000",
        GIT_TRACE2_EVENT_BRIEF="1", GIT_TRACE2_EVENT_NESTING="2", LC_ALL="C",
    )
    start = time.perf_counter()
    git = Git(git_path, root / "trace.jsonl", env, start + BUDGET_SECONDS)
    report: dict[str, object] = {
        "status": "incomplete", "platform": platform.platform(),
        "cpu_count": os.cpu_count(), "compilation_mode": sys.argv[2],
        "git_path": str(git_path),
        "trace_settings": {"brief": 1, "nesting": 2, "modes": MODES},
        "orders": ORDERS, "warmups_per_mode": 2,
        "budget_seconds": BUDGET_SECONDS, "stream_bytes_per_file": STREAM_BYTES,
        "budget_enforcement": "Soft Git-launch/work-boundary budget; Bazel supplies the hard outer timeout.",
        "limitations": [
            "Same optimized binary on/off measures total enabled tracing, not a particular patch.",
            "No older-binary comparison or deployed-binary byte-identity claim.",
            "Warm OS caches; file tracing uses buffered filesystem writes, not durable fsync.",
            "No OG wrapper or postprocessing, daemon, content-index IPC, or cold-cache measurement.",
            "Packed-only fixtures and object-read timers prove packed reads; daemon-only tree provenance events are not emitted.",
            "Child CPU is RUSAGE_CHILDREN when available; parent fixture/parser CPU is excluded.",
        ],
    }
    try:
        report["git_sha256"] = file_hash(git_path)
        report["git_version_build_options"] = git.run(root, ("version", "--build-options")).stdout.decode()
        small = make_fixture(git, root, streaming=False)
        git.remaining_seconds()
        streaming = make_fixture(git, root, streaming=True)
        git.remaining_seconds()
        workloads = (
            Workload("checkout-small", small, ("reset", "--hard", "--quiet", "HEAD"), True, b"", {
                "unpack_trees/queue-entries/prepare-entry": SMALL_FILES,
                **{f"pcheckout/item/{phase}": SMALL_FILES for phase in (
                    "prepare", "read-blob", "convert", "write-buffer", "finalize"
                )},
            }),
            Workload("checkout-streaming", streaming, ("reset", "--hard", "--quiet", "HEAD"), True, b"", {
                "unpack_trees/queue-entries/prepare-entry": STREAM_FILES,
                "pcheckout/item/prepare": STREAM_FILES,
                "pcheckout/item/finalize": STREAM_FILES,
                **{f"odb/stream-to-fd/{phase}": minimum for phase, minimum in (
                    ("open", STREAM_FILES), ("close", STREAM_FILES),
                    ("read-filter", STREAM_FILES * (STREAM_BYTES // 16384 + 1)),
                    ("write", STREAM_FILES * (STREAM_BYTES // 16384)),
                )},
            }),
            Workload("grep-packed-tree", small, (
                "grep", "--threads=4", "--fixed-strings", "--files-with-matches",
                "trace2-overhead-needle", "HEAD", "--", "data",
            ), False, b"".join(
                f"HEAD:{name}\n".encode() for name in sorted(small.files) if name != ".gitattributes"
            ), {"grep/source/object-read": SMALL_FILES, "grep/source/process": SMALL_FILES}),
        )
        for workload in workloads:
            print(f"Measuring {workload.name}: 2 warmups + 6 samples per mode", flush=True)
            report[workload.name] = benchmark(git, workload)
        git.remaining_seconds()
        report["status"] = "complete"
    finally:
        report["total_seconds_including_setup_and_validation"] = time.perf_counter() - start
        output.write_text(json.dumps(report, separators=(",", ":")) + "\n")
        print(f"Results: {output}", flush=True)


if __name__ == "__main__":
    main()
