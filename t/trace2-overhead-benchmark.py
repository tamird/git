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
TREE_READ_REVISIONS = 256
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

    def run(self, repo: Path, args: tuple[str, ...], mode: Mode = "off",
            *, expected_returncode: int = 0) -> Measurement:
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
        if process.returncode != expected_returncode:
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


def make_fixture(git: Git, root: Path, streaming: bool, *, tree_reads_only: bool = False) -> Fixture:
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
            # Only the tree-read mode makes the first two directories differ
            # by one blob, so packing can delta one against the other.
            directory = f"{index // 10:04d}"
            if tree_reads_only and index < 20:
                # A shared suffix keeps the pair adjacent in name-hash order.
                directory += "-seed"
            name = index - 10 if tree_reads_only and 10 <= index < 20 else index
            content_index = index - 10 if tree_reads_only and 10 <= index < 19 else index
            content = f"trace2-overhead-needle {content_index:06d}\n" + "x" * 2000 + "\n"
            write(f"data/{directory}/{name:06d}.txt",
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
    tree_read_revisions: int = 0


def trace_coverage(path: Path, workload: Workload) -> dict[str, object]:
    timers: Counter[str] = Counter()
    events: Counter[str] = Counter()
    sessions: set[str] = set()
    tree_values: dict[str, int] = {}
    tree_counts = {
        "count/revisions": workload.tree_read_revisions,
        "content_index_tree_directories": (SMALL_FILES // 10 + 1) * workload.tree_read_revisions,
    }
    tree_times = ("content_index_tree_walk_us", "content_index_tree_object_read_us")
    with path.open() as source:
        for line in source:
            event = json.loads(line)
            events[event["event"]] += 1
            sessions.add(event["sid"])
            if event["event"] == "timer":
                timers[f"{event['category']}/{event['name']}"] += event["intervals"]
            if workload.tree_read_revisions:
                if event["event"] in ("exit", "atexit") and event["code"] != 1:
                    raise AssertionError("tree-only grep must exit with no matches")
                key = event.get("key")
                if (event["event"] == "data" and event.get("category") == "grep"
                        and (key in tree_counts or key in tree_times)):
                    if key in tree_values or event.get("thread") != "main":
                        raise AssertionError("tree DATA must occur once on the main thread")
                    tree_values[key] = int(event["value"])
    if not events["version"] or not events["exit"]:
        raise AssertionError("expected a complete Trace2 event stream")
    for name, minimum in workload.required_timers.items():
        if timers[name] < minimum:
            raise AssertionError(f"{name}: expected >= {minimum} intervals, got {timers[name]}")
        if not workload.checkout and timers[name] != minimum:
            raise AssertionError(f"{name}: expected exactly {minimum} intervals")
    workers = 0 if workload.tree_read_revisions else 4
    if not workload.checkout and (events["thread_start"] != workers or events["thread_exit"] != workers):
        raise AssertionError(f"{workload.name}: unexpected worker count")
    if workload.tree_read_revisions:
        if len(sessions) != 1 or any(events[name] != 1 for name in ("version", "start", "exit", "atexit")):
            raise AssertionError("tree-only grep must have one complete process")
        if any(tree_values.get(key) != expected for key, expected in tree_counts.items()):
            raise AssertionError(f"tree traversal count mismatch: {tree_values}")
        if not 0 <= tree_values[tree_times[1]] <= tree_values[tree_times[0]]:
            raise AssertionError("child-read time must be nonnegative and contained in tree-walk time")
    return {"bytes": path.stat().st_size, "events": dict(events),
            "processes": len(sessions), "timer_intervals": dict(timers),
            **({"tree_values": tree_values} if workload.tree_read_revisions else {})}


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
        off = {sample.round: sample for sample in samples if sample.mode == "off"}
        ratios = [sample.wall_seconds / off[sample.round].wall_seconds for sample in selected]
        deltas = [sample.wall_seconds - off[sample.round].wall_seconds for sample in selected]
        values["median_paired_wall_ratio_to_off"] = statistics.median(ratios)
        values["median_paired_wall_delta_seconds"] = statistics.median(deltas)
        summary[mode] = values
    return summary


def benchmark(git: Git, workloads: tuple[Workload] | tuple[Workload, Workload]) -> dict[str, object]:
    samples: dict[str, list[Sample]] = {workload.name: [] for workload in workloads}
    conditions = tuple((workload, mode) for workload in workloads for mode in MODES)
    if len(workloads) == 1:
        orders = tuple(tuple((workloads[0], mode) for mode in order) for order in ORDERS)
    else:
        # Balanced six-condition crossover: each (size, mode) occupies each
        # position once; every directed within-round predecessor occurs once.
        orders = tuple(
            tuple(conditions[(column + row) % 6] for column in (0, 1, 5, 2, 4, 3))
            for row in range(6)
        )
    # Two warmups per condition; no sample is a cold-cache measurement.
    for round_index, order in enumerate((conditions, tuple(reversed(conditions)), *orders), -2):
        for position, (workload, mode) in enumerate(order):
            git.remaining_seconds()
            if workload.checkout:
                workload.fixture.prepare_checkout()
            measured = git.run(workload.fixture.repo, workload.args, mode,
                               expected_returncode=1 if workload.tree_read_revisions else 0)
            if measured.stdout != workload.expected_stdout or measured.stderr:
                raise AssertionError(f"{workload.name}/{mode}: output parity failed")
            if workload.checkout:
                workload.fixture.verify_checkout()
            coverage = (trace_coverage(git.trace, workload)
                        if mode == "event-file" else None)
            git.remaining_seconds()
            if round_index >= 0:
                samples[workload.name].append(Sample(
                    mode, round_index, position, measured.wall_seconds,
                    measured.child_user_seconds, measured.child_system_seconds, coverage,
                ))
    results: dict[str, object] = {}
    for workload in workloads:
        selected = samples[workload.name]
        summary = summarize(selected)
        print(workload.name, json.dumps(summary, separators=(",", ":")), flush=True)
        results[workload.name] = {
            "argv": git.command(workload.args),
            "fixture_files": len(workload.fixture.files),
            "selected_files": (len(workload.fixture.files) if workload.checkout
                               else len(workload.expected_stdout.splitlines())),
            "packed_objects": workload.fixture.object_counts,
            "stdout_sha256": hashlib.sha256(workload.expected_stdout).hexdigest(),
            "orders": [[(item.name, mode) for item, mode in order] for order in orders],
            "samples": [asdict(sample) for sample in selected], "summary": summary,
        }
    return results


def packed_grep_workload(fixture: Fixture, name: str, path: str, count: int) -> Workload:
    selected = sorted(filename for filename in fixture.files if filename.startswith(path + "/"))
    if len(selected) != count:
        raise AssertionError(f"{name}: fixture selection changed")
    return Workload(name, fixture, (
        "grep", "--threads=4", "--fixed-strings", "--files-with-matches",
        "trace2-overhead-needle", "HEAD", "--", path,
    ), False, b"".join(f"HEAD:{filename}\n".encode() for filename in selected), {
        "grep/source/object-read": count, "grep/source/process": count,
        "grep/dispatch/producer-lock": count, "grep/dispatch/worker-drain": 1,
    })


def tree_read_workload(git: Git, fixture: Fixture) -> tuple[Workload, dict[str, object]]:
    # Verify outside the sample that repeated revisions retain initial misses:
    # unpack_entry caches delta bases, not every object it returns.
    listing = git.run(fixture.repo, ("ls-tree", "-r", "-d", "HEAD")).stdout
    children = [line.split() for line in listing.decode().splitlines()]
    child_oids = [fields[2] for fields in children]
    if [fields[3] for fields in children[:3]] != ["data", "data/0000-seed", "data/0001-seed"]:
        raise AssertionError("the delta/base pair must precede the bulk tree reads")
    child_count = SMALL_FILES // 10 + 1
    if len(child_oids) != child_count or len(set(child_oids)) != child_count:
        raise AssertionError("expected 401 distinct child trees")
    indexes = list((fixture.repo / ".git/objects/pack").glob("*.idx"))
    if len(indexes) != 1:
        raise AssertionError("expected one fixture pack")
    packed_trees: dict[str, int] = {}
    delta_bases: set[str] = set()
    tree_delta_bases: dict[str, str] = {}
    for line in git.run(fixture.repo, ("verify-pack", "-v", str(indexes[0]))).stdout.decode().splitlines():
        fields = line.split()
        if len(fields) not in (5, 7) or fields[1] not in ("blob", "tree", "commit", "tag"):
            continue
        if fields[1] == "tree":
            packed_trees[fields[0]] = int(fields[2])
        if len(fields) == 7:
            delta_bases.add(fields[6])
            if fields[1] == "tree":
                tree_delta_bases[fields[0]] = fields[6]
    if any(packed_trees.get(oid, 0) <= 0 for oid in child_oids):
        raise AssertionError("every child tree must be packed and nonempty")
    first, second = child_oids[1:3]
    if tree_delta_bases not in ({first: second}, {second: first}):
        raise AssertionError(
            f"expected one tree delta between {first} and {second}; got {tree_delta_bases}"
        )
    # A successful delta read inserts its base before returning, initializing
    # the cache by child read 3 regardless of which member was packed as delta.
    delta_oid, base_oid = next(iter(tree_delta_bases.items()))
    never_base = len(set(child_oids) - delta_bases)
    if not never_base:
        raise AssertionError("fixture does not prove repeated initial cache misses")
    geometry = {
        "pack_sha256": file_hash(indexes[0].with_suffix(".pack")),
        "child_trees_per_revision": child_count,
        "cache_initializing_tree_delta": delta_oid,
        "cache_initializing_tree_base": base_oid,
        "cache_initialized_by_child_read": 3,
        "child_trees_never_delta_bases": never_base,
        "known_initial_cache_misses_lower_bound": never_base * TREE_READ_REVISIONS,
        "child_cache_copy_upper_bound": (child_count - never_base) * TREE_READ_REVISIONS,
    }
    workload = Workload("grep-packed-tree-reads", fixture, (
        "grep", "--no-content-index", "--threads=1", "--fixed-strings",
        "trace2-overhead-needle", *("HEAD",) * TREE_READ_REVISIONS,
        "--", ":(glob)**/__trace2_absent__",
    ), False, b"", {
        "grep/source/object-read": 0, "grep/source/process": 0,
        "grep/dispatch/producer-lock": 0, "grep/dispatch/worker-drain": 0,
    }, tree_read_revisions=TREE_READ_REVISIONS)
    return workload, geometry


def main() -> None:
    if (len(sys.argv) not in (3, 4) or sys.argv[2] != "opt"
            or (len(sys.argv) == 4 and sys.argv[3] != "--tree-reads-only")):
        raise SystemExit("run //t:trace2-overhead-benchmark with -c opt --stamp "
                         "and optional --test_arg=--tree-reads-only")
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
        "warmups_per_mode": 2,
        "budget_seconds": BUDGET_SECONDS, "stream_bytes_per_file": STREAM_BYTES,
        "budget_enforcement": "Soft Git-launch/work-boundary budget; Bazel supplies the hard outer timeout.",
        "limitations": [
            "Same optimized binary on/off measures total enabled tracing, not a particular patch.",
            "No older-binary comparison or deployed-binary byte-identity claim.",
            "Warm OS caches; file tracing uses buffered filesystem writes, not durable fsync.",
            "Two grep sizes distinguish shared/fixed from workload-scaling cost, not per-object or recent-patch causality: directories, output, and scheduling also vary.",
            "No OG wrapper or postprocessing, daemon, content-index IPC, or cold-cache measurement.",
            "Packed-only fixtures and object-read timers prove packed reads; daemon-only tree provenance events are not emitted.",
            "Child CPU is RUSAGE_CHILDREN when available; parent fixture/parser CPU is excluded.",
        ],
    }
    try:
        report["git_sha256"] = file_hash(git_path)
        report["git_version_build_options"] = git.run(root, ("version", "--build-options")).stdout.decode()
        small = make_fixture(git, root, streaming=False, tree_reads_only=len(sys.argv) == 4)
        if len(sys.argv) == 4:
            workload, report["tree_read_geometry"] = tree_read_workload(git, small)
            report["limitations"] = [
                "Repeated revisions amplify packed child-tree reads, not unique OIDs or cold-cache I/O.",
                "The non-delta-base count proves an initial-miss lower bound, not the production cache mixture.",
                "A/B requires matched harness, pack, build options and trace mode; on/off ratios are not patch effects.",
                "No blobs, workers, daemon or OG processing; no performance threshold.",
            ]
            report.update(benchmark(git, (workload,)))
            git.remaining_seconds()
            report["status"] = "complete"
            return
        git.remaining_seconds()
        streaming = make_fixture(git, root, streaming=True)
        git.remaining_seconds()
        workload_groups = (
            (Workload("checkout-small", small, ("reset", "--hard", "--quiet", "HEAD"), True, b"", {
                "unpack_trees/queue-entries/prepare-entry": SMALL_FILES,
                **{f"pcheckout/item/{phase}": SMALL_FILES for phase in (
                    "prepare", "read-blob", "convert", "write-buffer", "finalize"
                )},
            }),),
            (Workload("checkout-streaming", streaming, ("reset", "--hard", "--quiet", "HEAD"), True, b"", {
                "unpack_trees/queue-entries/prepare-entry": STREAM_FILES,
                "pcheckout/item/prepare": STREAM_FILES,
                "pcheckout/item/finalize": STREAM_FILES,
                **{f"odb/stream-to-fd/{phase}": minimum for phase, minimum in (
                    ("open", STREAM_FILES), ("close", STREAM_FILES),
                    ("read-filter", STREAM_FILES * (STREAM_BYTES // 16384 + 1)),
                    ("write", STREAM_FILES * (STREAM_BYTES // 16384)),
                )},
            }),),
            (
                packed_grep_workload(small, "grep-packed-tree-10", "data/0000", 10),
                packed_grep_workload(small, "grep-packed-tree", "data", SMALL_FILES),
            ),
        )
        for workloads in workload_groups:
            names = ", ".join(workload.name for workload in workloads)
            print(f"Measuring {names}: 2 warmups + 6 samples per condition", flush=True)
            report.update(benchmark(git, workloads))
        git.remaining_seconds()
        report["status"] = "complete"
    finally:
        report["total_seconds_including_setup_and_validation"] = time.perf_counter() - start
        output.write_text(json.dumps(report, separators=(",", ":")) + "\n")
        print(f"Results: {output}", flush=True)


if __name__ == "__main__":
    main()
