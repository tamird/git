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
from typing import Literal, cast

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
REFS_COMMANDS_PER_SAMPLE = 128
FOLLOW_SOURCES = (4000, 100000)
FOLLOW_ADDITIONS = (0, 4096, 65536)
FOLLOW_READ_SUBTREES = 65536
FOLLOW_INPUT_LIMIT = 8 * 1024 * 1024
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
            *, expected_returncode: int = 0, input_data: bytes | None = None) -> Measurement:
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
            command, cwd=repo, env=env,
            stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        ) as process:
            try:
                stdout, stderr = process.communicate(input=input_data, timeout=min(30, remaining))
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
    allowed_tree_directories: tuple[int, ...] = ()
    status_scan: bool = False


def trace_coverage(
    path: Path, workload: Workload, observed_tree_counts: dict[str, int],
) -> dict[str, object]:
    timers: Counter[str] = Counter()
    events: Counter[str] = Counter()
    sessions: set[str] = set()
    tree_values: dict[str, int] = {}
    status_values: dict[str, int] = {}
    status_counts = {
        "untracked/directories-visited": SMALL_FILES // 10 + 2,
        "untracked/paths-visited": SMALL_FILES + SMALL_FILES // 10 + 3,
        "count/changed": 0, "count/untracked": 0, "count/ignored": 0,
    }
    tree_counts = {
        "count/revisions": workload.tree_read_revisions,
    }
    tree_times = ("content_index_tree_walk_us", "content_index_tree_object_read_us")
    with path.open() as source:
        for line in source:
            event = json.loads(line)
            events[event["event"]] += 1
            sessions.add(event["sid"])
            if event["event"] == "timer":
                timers[f"{event['category']}/{event['name']}"] += event["intervals"]
            if workload.status_scan:
                if event["event"] in ("exit", "atexit") and event["code"] != 0:
                    raise AssertionError("status must exit successfully")
                key = event.get("key")
                if (event["event"] == "data" and event.get("category") == "status"
                        and (key in status_counts or key == "untracked/fill-us")):
                    if key in status_values or event.get("thread") != "main":
                        raise AssertionError("status DATA must occur once on the main thread")
                    status_values[key] = int(event["value"])
            if workload.tree_read_revisions:
                if event["event"] in ("exit", "atexit") and event["code"] != 1:
                    raise AssertionError("tree-only grep must exit with no matches")
                key = event.get("key")
                if (event["event"] == "data" and event.get("category") == "grep"
                        and (key in tree_counts or key in tree_times
                             or key == "content_index_tree_directories")):
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
    workers = 0 if workload.tree_read_revisions or workload.status_scan else 4
    if not workload.checkout and (events["thread_start"] != workers or events["thread_exit"] != workers):
        raise AssertionError(f"{workload.name}: unexpected worker count")
    if workload.tree_read_revisions or workload.status_scan:
        if len(sessions) != 1 or any(events[name] != 1 for name in ("version", "start", "exit", "atexit")):
            raise AssertionError("workload must have one complete process")
    if workload.status_scan:
        if any(status_values.get(key) != expected for key, expected in status_counts.items()):
            raise AssertionError(f"status traversal count mismatch: {status_values}")
        if status_values.get("untracked/fill-us", -1) < 0:
            raise AssertionError("status must report nonnegative fill wall time")
    if workload.tree_read_revisions:
        if any(tree_values.get(key) != expected for key, expected in tree_counts.items()):
            raise AssertionError(f"tree traversal count mismatch: {tree_values}")
        directories = tree_values.get("content_index_tree_directories", -1)
        if directories not in workload.allowed_tree_directories:
            raise AssertionError(f"unexpected child-tree count: {tree_values}")
        previous = observed_tree_counts.setdefault(workload.name, directories)
        if directories != previous:
            raise AssertionError("child-tree count changed between identical commands")
        if not 0 <= tree_values[tree_times[1]] <= tree_values[tree_times[0]]:
            raise AssertionError("child-read time must be nonnegative and contained in tree-walk time")
    return {"bytes": path.stat().st_size, "events": dict(events),
            "processes": len(sessions), "timer_intervals": dict(timers),
            **({"tree_values": tree_values} if workload.tree_read_revisions else {}),
            **({"status_values": status_values} if workload.status_scan else {})}


@dataclass(frozen=True)
class Sample:
    mode: Mode
    round: int
    position: int
    wall_seconds: float
    child_user_seconds: float | None
    child_system_seconds: float | None
    trace: dict[str, object] | None


def summarize(samples: list[Sample]) -> dict[Mode, dict[str, object]]:
    summary: dict[Mode, dict[str, object]] = {}
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


def benchmark_startup(git: Git, root: Path, version_line: bytes) -> dict[str, object]:
    reference = git.run(root, ("version",))
    if reference.stdout != version_line or reference.stderr:
        raise AssertionError("plain version must match the build-options identity")
    samples: list[Sample] = []
    for round_index, order in enumerate((MODES, tuple(reversed(MODES)), *ORDERS), -2):
        for position, mode in enumerate(order):
            measured = git.run(root, ("version",), mode)
            if measured.stdout != reference.stdout or measured.stderr:
                raise AssertionError(f"version/{mode}: output parity failed")
            coverage = None
            if mode == "event-file":
                events = [json.loads(line) for line in git.trace.read_text().splitlines()]
                counts = Counter(event["event"] for event in events)
                lifecycle = ("version", "start", "exit", "atexit")
                if (len({event["sid"] for event in events}) != 1
                        or any(counts[name] != 1 for name in lifecycle)
                        or [event["event"] for event in events if event["event"] in lifecycle] != list(lifecycle)
                        or any(event.get("code") != 0 for event in events
                               if event["event"] in ("exit", "atexit"))
                        or any(counts[name] for name in (
                            "child_start", "child_exit", "thread_start", "thread_exit", "error", "signal"))):
                    raise AssertionError("version must have one successful process and no children or workers")
                coverage = {"bytes": git.trace.stat().st_size, "events": dict(counts), "processes": 1}
            git.remaining_seconds()
            if round_index >= 0:
                samples.append(Sample(
                    mode, round_index, position, measured.wall_seconds,
                    measured.child_user_seconds, measured.child_system_seconds, coverage,
                ))
    summary = summarize(samples)
    print("version-startup", json.dumps(summary, separators=(",", ":")), flush=True)
    return {"version-startup": {
        "argv": git.command(("version",)), "fixture_files": 0, "repository_initialized": False,
        "git_launches": 26, "stdout_sha256": hashlib.sha256(reference.stdout).hexdigest(),
        "orders": ORDERS, "samples": [asdict(sample) for sample in samples], "summary": summary,
    }}


def benchmark(git: Git, workloads: tuple[Workload] | tuple[Workload, Workload]) -> dict[str, object]:
    samples: dict[str, list[Sample]] = {workload.name: [] for workload in workloads}
    observed_tree_counts: dict[str, int] = {}
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
            coverage = (trace_coverage(git.trace, workload, observed_tree_counts)
                        if mode == "event-file" else None)
            if (workload.status_scan and
                    (workload.fixture.repo / ".git/index").read_bytes() != workload.fixture.index):
                raise AssertionError("read-only status changed the index")
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
            "selected_files": (len(workload.fixture.files) if workload.checkout or workload.status_scan
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


def tree_read_workload(
    git: Git, fixture: Fixture, *, exclude_trees: bool = False,
) -> tuple[Workload, dict[str, object]]:
    # Verify the unchanged packed fixture outside the sample. Without exclusions,
    # repeated revisions retain initial misses: unpack_entry caches delta bases,
    # not every object it returns.
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
    # Without exclusions, a successful delta read initializes the cache by child
    # read 3 regardless of which member was packed as delta.
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
    allowed_counts = (child_count * TREE_READ_REVISIONS,)
    if exclude_trees:
        allowed_counts += (TREE_READ_REVISIONS,)
        # The skipped seed trees do not initialize the delta-base cache. Keep
        # only fixture facts and explicit baseline/pruned work expectations.
        geometry = {
            "pack_sha256": geometry["pack_sha256"],
            "child_trees_per_revision": child_count,
            "exclusion": ":(exclude)data/**",
            "expected_tree_directories": {
                "baseline": allowed_counts[0], "pruned": allowed_counts[1],
            },
        }
    name = "grep-packed-tree-excludes" if exclude_trees else "grep-packed-tree-reads"
    workload = Workload(name, fixture, (
        "grep", "--no-content-index", "--threads=1", "--fixed-strings",
        "trace2-overhead-needle", *("HEAD",) * TREE_READ_REVISIONS,
        "--", ":(glob)**/__trace2_absent__",
        *((":(exclude)data/**",) if exclude_trees else ()),
    ), False, b"", {
        "grep/source/object-read": 0, "grep/source/process": 0,
        "grep/dispatch/producer-lock": 0, "grep/dispatch/worker-drain": 0,
    }, tree_read_revisions=TREE_READ_REVISIONS, allowed_tree_directories=allowed_counts)
    return workload, geometry


def refs_trace_intervals(path: Path) -> int:
    events = [json.loads(line) for line in path.read_text().splitlines()]
    counts = Counter(event["event"] for event in events)
    if (len({event["sid"] for event in events}) != 1
            or any(counts[name] != 1 for name in ("version", "start", "exit", "atexit"))
            or any(event.get("code") != 0 for event in events
                   if event["event"] in ("exit", "atexit"))
            or counts["child_start"] or counts["thread_start"] or counts["thread_exit"]):
        raise AssertionError("ref listing must have one successful, complete main process")
    summaries = 0
    for event in events:
        if event.get("category") != "ref-filter":
            continue
        name = event.get("name", event.get("label", ""))
        if name.startswith("materialized/"):
            raise AssertionError("ref listing unexpectedly used materialized formatting")
        if name == "iterative/filter-format":
            if (event["event"] != "timer" or event.get("thread") != "main"
                    or event.get("intervals") != 1):
                raise AssertionError("iterative timing must be one completed main-thread summary")
            summaries += 1
    if summaries > 1:
        raise AssertionError("ref listing must have at most one iterative summary")
    return summaries


def benchmark_refs(git: Git, fixture: Fixture) -> dict[str, object]:
    args = ("for-each-ref", "--format=%(refname)", "refs/heads/main")
    expected = b"refs/heads/main\n"
    refs_before = git.run(fixture.repo, ("show-ref",))
    if (refs_before.stderr or len(refs_before.stdout.splitlines()) != 1
            or not refs_before.stdout.endswith(b" refs/heads/main\n")):
        raise AssertionError("ref fixture must contain only its original main ref")
    samples: list[Sample] = []
    records: list[dict[str, object]] = []
    observed_intervals: int | None = None
    for round_index, order in enumerate((MODES, tuple(reversed(MODES)), *ORDERS), -2):
        for position, mode in enumerate(order):
            measurements: list[Measurement] = []
            for _ in range(REFS_COMMANDS_PER_SAMPLE):
                measured = git.run(fixture.repo, args, mode)
                if measured.stdout != expected or measured.stderr:
                    raise AssertionError(f"ref listing/{mode}: output parity failed")
                if mode == "event-file":
                    intervals = refs_trace_intervals(git.trace)
                    if observed_intervals is not None and intervals != observed_intervals:
                        raise AssertionError("iterative timer changed between identical commands")
                    observed_intervals = intervals
                measurements.append(measured)
            if (fixture.repo / ".git/index").read_bytes() != fixture.index:
                raise AssertionError("read-only ref listing changed the index")
            git.remaining_seconds()
            user = [item.child_user_seconds for item in measurements]
            system = [item.child_system_seconds for item in measurements]
            sample = Sample(
                mode, round_index, position,
                sum(item.wall_seconds for item in measurements),
                sum(value for value in user if value is not None)
                if all(value is not None for value in user) else None,
                sum(value for value in system if value is not None)
                if all(value is not None for value in system) else None,
                {"processes": REFS_COMMANDS_PER_SAMPLE,
                 "iterative_intervals_per_command": observed_intervals}
                if mode == "event-file" else None,
            )
            if round_index >= 0:
                samples.append(sample)
                records.append({
                    **asdict(sample),
                    "commands": [[item.wall_seconds, item.child_user_seconds,
                                  item.child_system_seconds] for item in measurements],
                })
    refs_after = git.run(fixture.repo, ("show-ref",))
    if refs_after.stderr or refs_after.stdout != refs_before.stdout:
        raise AssertionError("read-only ref listing changed refs")
    summary = summarize(samples)
    print("refs-iterative", json.dumps(summary, separators=(",", ":")), flush=True)
    return {"refs-iterative": {
        "argv": git.command(args), "fixture_files": len(fixture.files),
        "packed_objects": fixture.object_counts,
        "refs_sha256": hashlib.sha256(refs_before.stdout).hexdigest(),
        "stdout_sha256": hashlib.sha256(expected).hexdigest(),
        "commands_per_sample": REFS_COMMANDS_PER_SAMPLE,
        "sample_unit": "Sum of 128 separately timed direct Git processes.",
        "command_columns": ["wall_seconds", "child_user_seconds", "child_system_seconds"],
        "orders": ORDERS, "iterative_intervals_per_command": observed_intervals,
        "samples": records, "summary": summary,
    }}


FollowKind = Literal["exact", "edited"]
FOLLOW_KINDS: tuple[FollowKind, ...] = ("exact", "edited")


@dataclass(frozen=True)
class FollowFixture:
    repo: Path
    sources: int
    revisions: dict[str, str]
    trees: dict[str, str]
    pack_sha256: str
    import_sha256: str
    refs: bytes
    object_counts: str
    additions: int = 0
    tree_input_sha256: dict[str, str] | None = None
    subtrees: int = 0


def make_follow_fixture(git: Git, root: Path, sources: int, *, additions: int = 0,
                        bulk_trees: bool = False, subtrees: int = 0) -> FollowFixture:
    if subtrees and (not bulk_trees or additions or sources != subtrees + 1):
        raise AssertionError("tree-read fixture needs one source per subtree and one selected source")
    repo = root / (f"follow-{sources}" + (f"-additions-{additions}" if additions else "")
                   + (f"-tree-reads-{subtrees}" if subtrees else ""))
    repo.mkdir()
    git.run(repo, ("init", "--bare", "--quiet", "--initial-branch=base", "--template=", "."))
    # Each 64-byte line is one similarity span. Replacing one of 100 equally
    # sized lines leaves 99% copied bytes, independently specifying C099.
    line = b"follow source line".ljust(63, b"s") + b"\n"
    replacement = b"edited source line".ljust(63, b"e") + b"\n"
    source = line * 100
    edited = line * 49 + replacement + line * 50
    noise = b"unrelated small source\n"
    tree_oids: dict[str, str] = {}
    tree_input_sha256: dict[str, str] | None = None
    if bulk_trees:
        # fast-import scans existing siblings for each M path. Installing
        # prebuilt trees avoids quadratic setup without changing geometry.
        def write_setup_objects(args: tuple[str, ...], data: bytes, count: int = 1) -> tuple[str, ...]:
            if len(data) > FOLLOW_INPUT_LIMIT:
                raise AssertionError(f"follow setup input exceeded its fixed bound: {args}")
            written = git.run(repo, args, input_data=data)
            oids = written.stdout.splitlines(keepends=True)
            if (written.stderr or len(oids) != count
                    or any(len(oid) not in (41, 65) or oid[-1:] != b"\n"
                           or any(byte not in b"0123456789abcdef" for byte in oid[:-1])
                           for oid in oids)):
                raise AssertionError(f"expected {count} full object IDs from {args}: {written}")
            return tuple(oid[:-1].decode("ascii") for oid in oids)

        noise_oid, = write_setup_objects(("hash-object", "-w", "--stdin"), noise)
        source_oid, = write_setup_objects(("hash-object", "-w", "--stdin"), source)
        tree_input_sha256 = {}
        if subtrees:
            # Unique entry names make every unchanged subtree a distinct
            # object without adding blobs or one subprocess per tree.
            subtree_input = b"".join(f"100644 blob {noise_oid}\t{number:08d}\n\n".encode()
                                     for number in range(subtrees))
            if subtrees != 65536 or len(subtree_input) > FOLLOW_INPUT_LIMIT:
                raise AssertionError("tree-read setup requires the fixed bounded 65536-tree input")
            # Four fixed batches avoid putting all loose-object creation in
            # one 30-second launch. Equal-width records preserve boundaries.
            batch_bytes = len(subtree_input) // 4
            subtree_oids: list[str] = []
            for offset in range(0, len(subtree_input), batch_bytes):
                subtree_oids.extend(write_setup_objects(
                    ("mktree", "--batch"), subtree_input[offset:offset + batch_bytes], 16384,
                ))
            if len(set(subtree_oids)) != subtrees:
                raise AssertionError("tree-read fixture requires unique subtree objects")
            tree_input_sha256["subtrees"] = hashlib.sha256(subtree_input).hexdigest()
            source_entries = b"".join(f"040000 tree {oid}\t{number:08d}\n".encode()
                                      for number, oid in enumerate(subtree_oids))
        else:
            source_entries = b"".join(f"100644 blob {noise_oid}\t{number:08d}\n".encode()
                                      for number in range(sources - 1))
        tree_inputs = {
            "sources": source_entries + f"100644 blob {source_oid}\tsource\n".encode(),
        }
        if additions:
            tree_inputs["added"] = b"".join(f"100644 blob {noise_oid}\t{number:08d}\n".encode()
                                            for number in range(additions))
        for name, data in tree_inputs.items():
            tree_oids[name], = write_setup_objects(("mktree",), data)
            tree_input_sha256[name] = hashlib.sha256(data).hexdigest()
    stream = bytearray()

    def append_data(content: bytes) -> None:
        stream.extend(f"data {len(content)}\n".encode())
        stream.extend(content)
        stream.extend(b"\n")

    for mark, content in ((1, noise), (2, source), (3, edited)):
        stream.extend(f"blob\nmark :{mark}\n".encode())
        append_data(content)
    identity = b"Trace2 benchmark <benchmark@example.invalid> 946684800 +0000\n"
    for kind, mark, parent in (("base", 4, None), ("exact", 5, 4), ("edited", 6, 4)):
        stream.extend(f"commit refs/heads/{kind}\nmark :{mark}\n".encode())
        stream.extend(b"author " + identity + b"committer " + identity)
        append_data(f"{kind} copy\n".encode())
        if parent is not None:
            stream.extend(f"from :{parent}\n".encode())
        if kind == "base":
            if bulk_trees:
                stream.extend(f"M 040000 {tree_oids['sources']} sources\n".encode())
            else:
                for number in range(sources - 1):
                    stream.extend(f"M 100644 :1 sources/{number:08d}\n".encode())
                stream.extend(b"M 100644 :2 sources/source\n")
        else:
            stream.extend(f"M 100644 :{2 if kind == 'exact' else 3} destination\n".encode())
            if bulk_trees and additions:
                stream.extend(f"M 040000 {tree_oids['added']} added\n".encode())
            else:
                for number in range(additions):
                    stream.extend(f"M 100644 :1 added/{number:08d}\n".encode())
        stream.extend(b"\n")
    stream.extend(b"done\n")
    if len(stream) > FOLLOW_INPUT_LIMIT:
        raise AssertionError("follow fixture import exceeded its fixed input bound")
    imported = git.run(repo, ("fast-import", "--quiet", "--done"), input_data=bytes(stream))
    if imported.stdout or imported.stderr:
        raise AssertionError("follow fixture import produced unexpected output")
    git.run(repo, ("repack", "-a", "-d", "-f", "--window=0", "--depth=0", "--threads=1"))
    revisions: dict[str, str] = {}
    trees: dict[str, str] = {}
    for kind in ("base", *FOLLOW_KINDS):
        revisions[kind] = git.run(repo, ("rev-parse", f"refs/heads/{kind}")).stdout.decode().strip()
        trees[kind] = git.run(repo, ("rev-parse", f"{revisions[kind]}^{{tree}}")).stdout.decode().strip()
    source_trees = {
        git.run(repo, ("rev-parse", f"{revision}:sources")).stdout
        for revision in revisions.values()
    }
    if len(source_trees) != 1:
        raise AssertionError("copy commits must preserve the complete source subtree")
    expected_sources = b"".join(
        (f"sources/{number:08d}/{number:08d}\n" if subtrees else f"sources/{number:08d}\n").encode()
        for number in range(sources - 1)
    )
    expected_sources += b"sources/source\n"
    listing = git.run(repo, ("ls-tree", "-r", "--name-only", revisions["base"]))
    if listing.stdout != expected_sources or listing.stderr:
        raise AssertionError("follow fixture source geometry changed")
    expected_additions = b"".join(f"A\tadded/{number:08d}\n".encode() for number in range(additions))
    expected_additions += b"A\tdestination\n"
    for kind in FOLLOW_KINDS:
        added = git.run(repo, ("diff-tree", "--no-commit-id", "--name-status", "-r",
                               revisions["base"], revisions[kind]))
        if added.stdout != expected_additions or added.stderr:
            raise AssertionError("copy commit additions differ from the specified destination and noise")
    counts = git.run(repo, ("count-objects", "-v")).stdout.decode()
    parsed = dict(value.split(": ", 1) for value in counts.splitlines())
    # Both child commits share the added subtree and reuse the source noise blob.
    packed_objects = (11 if additions else 10) + subtrees
    if int(parsed["count"]) != 0 or int(parsed["in-pack"]) != packed_objects:
        raise AssertionError(f"expected {packed_objects} packed objects and no loose objects: {counts}")
    pack, = (repo / "objects/pack").glob("*.pack")
    refs = git.run(repo, ("show-ref",)).stdout
    return FollowFixture(repo, sources, revisions, trees, file_hash(pack),
                         hashlib.sha256(stream).hexdigest(), refs, counts, additions, tree_input_sha256,
                         subtrees)


def follow_trace_coverage(path: Path, fixture: FollowFixture, kind: FollowKind) -> dict[str, object]:
    events = [json.loads(line) for line in path.read_text().splitlines()]
    counts = Counter(event["event"] for event in events)
    if (len({event["sid"] for event in events}) != 1
            or any(counts[name] != 1 for name in ("version", "start", "exit", "atexit"))
            or any(event.get("code") != 0 for event in events
                   if event["event"] in ("exit", "atexit"))
            or counts["child_start"] or counts["thread_start"] or counts["thread_exit"]):
        raise AssertionError("follow must have one complete successful main process")
    values: dict[str, int] = {}
    timers: list[dict[str, object]] = []
    completed: list[int] = []
    for event in events:
        if event.get("category") != "diff":
            continue
        key = event.get("key", "")
        if event["event"] == "data" and (key.startswith("follow-full-tree")
                                          or key.startswith("rename/inexact/")):
            if key in values or event.get("thread") != "main":
                raise AssertionError("follow DATA must occur once on the main thread")
            values[key] = int(event["value"])
        if event.get("name") == "follow-full-tree" and event["event"] in ("timer", "th_timer"):
            if event["event"] != "timer" or event.get("thread") != "main" or event["intervals"] != 1:
                raise AssertionError("follow must have one completed full-tree interval")
            timers.append(event)
        if event.get("name") == "follow-full-tree/completed" and event["event"] == "counter":
            completed.append(event["count"])
    if (len(timers) != 1 or completed != [1]
            or values.get("follow-full-tree/count") != 1
            or values.get("follow-full-tree/tree-read/count") != 3 + fixture.subtrees + bool(fixture.additions)
            or values.get("follow-full-tree/eligible-additions") != fixture.additions):
        raise AssertionError(f"follow full-tree geometry changed: {values}")
    full_tree_us = values.get("follow-full-tree-us", -1)
    timer_seconds = float(timers[0]["t_total"])
    if (full_tree_us < 0 or values.get("follow-full-tree-max-us") != full_tree_us
            or not full_tree_us <= round(timer_seconds * 1000000) <= full_tree_us + 1):
        raise AssertionError("native full-tree wall timer disagrees with its DATA summary")
    inexact = {key: value for key, value in values.items() if key.startswith("rename/inexact/")}
    expected = {
        "rename/inexact/sources": fixture.sources,
        "rename/inexact/destinations": 1,
        "rename/inexact/rename_limit": 0,
        "rename/inexact/limit_result": 0,
        "rename/inexact/similarity_calls": fixture.sources,
        "rename/inexact/size_rejected": fixture.sources - 1,
        "rename/inexact/content_compared": 1,
    }
    if ((kind == "exact" and inexact)
            or (kind == "edited" and any(inexact.get(key) != value for key, value in expected.items()))):
        raise AssertionError(f"unexpected {kind} copy candidate geometry: {inexact}")
    return {"bytes": path.stat().st_size, "events": dict(counts), "values": values,
            "full_tree_wall_seconds": timer_seconds}


def follow_args(fixture: FollowFixture, kind: FollowKind) -> tuple[str, ...]:
    return ("-c", "diff.renameLimit=0", "log", "--follow", "--name-status",
            "--format=%s", "-n1", fixture.revisions[kind], "--", "destination")


def benchmark_follow(git: Git, fixtures: tuple[FollowFixture, ...], *,
                     additions_only: bool = False, tree_reads_only: bool = False) -> dict[str, object]:
    results: dict[str, object] = {}
    kinds: tuple[FollowKind, ...] = ("exact",) if tree_reads_only else FOLLOW_KINDS
    for kind in kinds:
        conditions = tuple((fixture, mode) for fixture in fixtures for mode in MODES)
        if tree_reads_only:
            fixture, = fixtures
            orders = tuple(tuple((fixture, mode) for mode in order) for order in ORDERS)
        elif additions_only:
            # Six mode permutations and rotating fixture blocks balance each
            # marginal position, not every carryover pair of nine conditions.
            orders_list = []
            for row, mode_order in enumerate(ORDERS):
                offset = row % len(fixtures)
                rotated = fixtures[offset:] + fixtures[:offset]
                orders_list.append(tuple((fixture, mode) for fixture in rotated for mode in mode_order))
            orders = tuple(orders_list)
        else:
            orders = tuple(
                tuple(conditions[(column + row) % 6] for column in (0, 1, 5, 2, 4, 3))
                for row in range(6)
            )
        samples: dict[tuple[int, int], list[Sample]] = {
            (fixture.sources, fixture.additions): [] for fixture in fixtures
        }
        expected = (f"{kind} copy\n\nC{'100' if kind == 'exact' else '099'}\t"
                    "sources/source\tdestination\n").encode()
        for round_index, order in enumerate((conditions, tuple(reversed(conditions)), *orders), -2):
            for position, (fixture, mode) in enumerate(order):
                measured = git.run(fixture.repo, follow_args(fixture, kind), mode)
                if measured.stdout != expected or measured.stderr:
                    raise AssertionError(
                        f"{fixture.repo.name}-{kind}/{mode}: expected {expected!r}; "
                        f"stdout={measured.stdout!r}, stderr={measured.stderr!r}"
                    )
                coverage = follow_trace_coverage(git.trace, fixture, kind) if mode == "event-file" else None
                git.remaining_seconds()
                if round_index >= 0:
                    samples[fixture.sources, fixture.additions].append(Sample(
                        mode, round_index, position, measured.wall_seconds,
                        measured.child_user_seconds, measured.child_system_seconds, coverage,
                    ))
        for fixture in fixtures:
            name = f"{fixture.repo.name}-{kind}"
            selected = samples[fixture.sources, fixture.additions]
            summary = summarize(selected)
            for mode in MODES:
                cpu = [sample.child_user_seconds + sample.child_system_seconds
                       for sample in selected if sample.mode == mode
                       and sample.child_user_seconds is not None and sample.child_system_seconds is not None]
                if len(cpu) == 6:
                    summary[mode]["child_cpu_seconds"] = {
                        "median": statistics.median(cpu), "min": min(cpu), "max": max(cpu),
                    }
            native = [cast(float, sample.trace["full_tree_wall_seconds"]) for sample in selected
                      if sample.mode == "event-file" and sample.trace is not None]
            results[name] = {
                "argv": git.command(follow_args(fixture, kind)),
                "revision": fixture.revisions[kind], "unchanged_sources": fixture.sources,
                **({"additions": fixture.additions} if additions_only else {}),
                "expected_stdout": expected.decode(), "stdout_sha256": hashlib.sha256(expected).hexdigest(),
                "orders": [[(item.sources, item.additions, mode) if additions_only else (item.sources, mode)
                            for item, mode in order] for order in orders],
                "samples": [asdict(sample) for sample in selected], "summary": summary,
                "full_tree_wall_seconds": {"median": statistics.median(native),
                                           "min": min(native), "max": max(native)},
            }
            print(name, json.dumps(summary, separators=(",", ":")), flush=True)
    for fixture in fixtures:
        if git.run(fixture.repo, ("show-ref",)).stdout != fixture.refs:
            raise AssertionError("read-only follow changed fixture refs")
        pack, = (fixture.repo / "objects/pack").glob("*.pack")
        if file_hash(pack) != fixture.pack_sha256:
            raise AssertionError("read-only follow changed the fixture pack")
        if additions_only or tree_reads_only:
            counts = git.run(fixture.repo, ("count-objects", "-v"))
            if counts.stdout.decode() != fixture.object_counts or counts.stderr:
                raise AssertionError("read-only follow changed the fixture object counts")
    return results


@dataclass(frozen=True)
class ReflogFixture:
    repo: Path
    refs: tuple[str, ...]
    objects: tuple[str, ...]
    # Oldest to newest, as stored by each reflog.
    entries: tuple[tuple[tuple[int, str], ...], ...]
    manifest: dict[str, object]

    def expected(self, *, since: int = 0, limit: int | None = None) -> bytes:
        ordered = sorted([
            (timestamp, ordinal, len(entries) - index - 1, message)
            for ordinal, entries in enumerate(self.entries)
            for index, (timestamp, message) in enumerate(entries)
            if timestamp >= since
        ], key=lambda item: (-item[0], item[1], item[2]))
        if limit is not None:
            ordered = ordered[:limit]
        return "".join(f"{self.refs[ordinal]}@{{{index}}} {message}\n"
                       for _, ordinal, index, message in ordered).encode()


def reflog_manifest(git: Git, repo: Path, refs: tuple[str, ...],
                    objects: tuple[str, ...]) -> dict[str, object]:
    return {
        "refs": git.run(repo, ("show-ref",)).stdout.decode(),
        "head": (repo / "HEAD").read_text(),
        "repository_config": (repo / "config").read_text(),
        "command_config": CONFIG,
        "environment": {key: value for key, value in git.environment.items()
                        if key.startswith(("GIT_AUTHOR_", "GIT_COMMITTER_", "GIT_CONFIG_"))
                        or key in ("GIT_ATTR_NOSYSTEM", "LC_ALL")},
        "objects": {oid: file_hash(repo / "objects" / oid[:2] / oid[2:]) for oid in objects},
        "reflogs": {ref: (repo / "logs" / ref).read_text() for ref in refs},
    }


def make_reflog_fixture(git: Git, root: Path, logs: int, *, recent: bool = False) -> ReflogFixture:
    repo = root / f"reflog-{logs}{'-since' if recent else ''}"
    repo.mkdir()
    git.run(repo, ("init", "--bare", "--quiet", "--initial-branch=main", "--template=",
                   "--object-format=sha1", "--ref-format=files", "."))
    tree = git.run(repo, ("hash-object", "-w", "-t", "tree", "--stdin"), input_data=b"").stdout.strip()
    commits = tuple(git.run(repo, ("commit-tree", tree.decode()), input_data=message).stdout.strip().decode()
                    for message in (b"one\n", b"two\n"))
    refs = tuple(f"refs/heads/reflog-{index:03d}" for index in range(logs))
    entries: list[list[tuple[int, str]]] = [[] for _ in refs]
    for index in range(64 + int(recent)):
        selected = refs[:6] if index == 64 else refs
        timestamp = 946684800 + (1000 if index == 64 else index)
        message = f"entry-{index:03d}"
        dated = Git(git.path, git.trace, {
            **git.environment, "GIT_COMMITTER_DATE": f"{timestamp} +0000",
        }, git.deadline)
        commands = "".join(f"update {ref} {commits[index % 2]}\n" for ref in selected)
        dated.run(repo, ("update-ref", "--create-reflog", "-m", message, "--stdin"),
                  input_data=commands.encode())
        for ordinal in range(len(selected)):
            entries[ordinal].append((timestamp, message))
    objects = (tree.decode(), *commits)
    manifest = reflog_manifest(git, repo, refs, objects)
    for ref, expected_entries in zip(refs, entries):
        lines = (repo / "logs" / ref).read_text().splitlines()
        if len(lines) != len(expected_entries):
            raise AssertionError(f"wrong reflog length: {ref}")
        for index, (line, (timestamp, message)) in enumerate(zip(lines, expected_entries)):
            previous = commits[(index - 1) % 2] if index else "0" * 40
            expected = (f"{previous} {commits[index % 2]} Trace2 benchmark "
                        f"<benchmark@example.invalid> {timestamp} +0000\t{message}")
            if line != expected:
                raise AssertionError(f"unexpected reflog entry: {ref}@{{{index}}}")
    return ReflogFixture(repo, refs, objects, tuple(tuple(log) for log in entries), manifest)


def reflog_trace_coverage(path: Path, expected_count: int) -> dict[str, int]:
    events = [json.loads(line) for line in path.read_text().splitlines()]
    counts = Counter(event["event"] for event in events)
    if (len({event["sid"] for event in events}) != 1
            or any(counts[name] != 1 for name in ("version", "start", "exit", "atexit"))
            or any(event["code"] != 0 for event in events if event["event"] in ("exit", "atexit"))):
        raise AssertionError("expected one successful, complete reflog command trace")
    values = {event["key"]: int(event["value"]) for event in events
              if event["event"] == "data" and event.get("category") == "reflog"}
    required = ("setup-us", "prepare-us", "history-us", "output-us", "finalize-us", "execution-us")
    if (any(values.get(key, -1) < 0 for key in required)
            or values.get("count/returned") != expected_count
            or values.get("count/shown") != expected_count):
        raise AssertionError(f"unexpected reflog DATA: {values}")
    return values


def benchmark_reflogs(git: Git, root: Path) -> dict[str, object]:
    small = make_reflog_fixture(git, root, 1)
    many = make_reflog_fixture(git, root, 128)
    recent = make_reflog_fixture(git, root, 128, recent=True)
    cutoff = 946685300
    conditions = (
        ("one-log-full", small, (), small.expected()),
        ("many-logs-full", many, (), many.expected()),
        ("many-logs-since", recent, (f"--since={cutoff}", "--max-count=15"),
         recent.expected(since=cutoff)),
        ("many-logs-max1", many, ("--max-count=1",), many.expected(limit=1)),
        ("many-logs-max0", many, ("--max-count=0",), many.expected(limit=0)),
    )
    results: dict[str, object] = {}
    for name, fixture, options, expected in conditions:
        args = ("reflog", "show", "--format=%gD %gs", *options, *fixture.refs, "--")
        samples: list[dict[str, object]] = []
        for sample in range(-1, 5):
            measured = git.run(fixture.repo, args, "event-file")
            if measured.stdout != expected or measured.stderr:
                raise AssertionError(f"{name}: unexpected stdout or stderr: {measured.stderr!r}")
            native = reflog_trace_coverage(git.trace, len(expected.splitlines()))
            git.remaining_seconds()
            if sample >= 0:
                cpu = (measured.child_user_seconds + measured.child_system_seconds
                       if measured.child_user_seconds is not None and measured.child_system_seconds is not None
                       else None)
                samples.append({
                    "sample": sample, "mode": "event-file", "wall_seconds": measured.wall_seconds,
                    "child_user_seconds": measured.child_user_seconds,
                    "child_system_seconds": measured.child_system_seconds, "child_cpu_seconds": cpu,
                    "history_seconds": native["history-us"] / 1000000,
                    "execution_seconds": native["execution-us"] / 1000000, "native": native,
                })
        summary: dict[str, object] = {}
        for field in ("wall_seconds", "child_cpu_seconds", "history_seconds", "execution_seconds"):
            values = [cast(float, sample[field]) for sample in samples if sample[field] is not None]
            if values:
                summary[field] = {"median": statistics.median(values), "min": min(values), "max": max(values)}
        results[name] = {
            "argv": git.command(args), "fixture": fixture.repo.name,
            "stdout_sha256": hashlib.sha256(expected).hexdigest(), "stdout_bytes": len(expected),
            "output_entries": len(expected.splitlines()), "stderr": "", "returncode": 0,
            "samples": samples, "summary": summary,
        }
        print(name, json.dumps(summary, separators=(",", ":")), flush=True)
    # A separate --all integration check has an explicit HEAD/ref/log manifest;
    # it is not used to infer log counts from revision pending-object counts.
    all_refs = git.run(recent.repo, ("reflog", "show", "--all", f"--since={cutoff}",
                                    "--max-count=15", "--format=%gD %gs"))
    if all_refs.stdout != recent.expected(since=cutoff) or all_refs.stderr:
        raise AssertionError("--all disagrees with the explicit reflog cursor manifest")
    fixtures: dict[str, object] = {}
    for fixture in (small, many, recent):
        after = reflog_manifest(git, fixture.repo, fixture.refs, fixture.objects)
        if after != fixture.manifest:
            raise AssertionError("read-only reflog command changed its fixture")
        fixtures[fixture.repo.name] = {
            "manifest": fixture.manifest,
            "manifest_sha256": hashlib.sha256(json.dumps(fixture.manifest, sort_keys=True).encode()).hexdigest(),
            "logs": len(fixture.refs), "entries": sum(map(len, fixture.entries)),
        }
    return {"reflog_fixtures": fixtures, "reflog_cases": results,
            "case_order": [name for name, _, _, _ in conditions],
            "all_refs_stdout_sha256": hashlib.sha256(all_refs.stdout).hexdigest()}


def main() -> None:
    if (len(sys.argv) not in (3, 4) or sys.argv[2] != "opt"
            or (len(sys.argv) == 4 and sys.argv[3] not in (
                "--tree-reads-only", "--tree-excludes-only", "--status-only", "--refs-only",
                "--follow-only", "--follow-additions-only", "--follow-tree-reads-only",
                "--startup-only", "--reflog-only"))):
        raise SystemExit("run //t:trace2-overhead-benchmark with -c opt --stamp "
                         "and optional --test_arg=--tree-reads-only, --tree-excludes-only, "
                         "--status-only, --refs-only, --follow-only, --follow-additions-only, "
                         "--follow-tree-reads-only, --startup-only or --reflog-only")
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
        build_options = git.run(root, ("version", "--build-options"))
        report["git_version_build_options"] = build_options.stdout.decode()
        if len(sys.argv) == 4 and sys.argv[3] == "--reflog-only":
            report["benchmark_sha256"] = file_hash(Path(__file__))
            report.pop("stream_bytes_per_file")
            report["trace_settings"] = {"brief": 1, "nesting": 2, "modes": ("event-file",)}
            report["warmups_per_mode"] = 1
            report["retained_samples_per_case"] = 5
            report["limitations"] = [
                "Compare baseline/candidate binaries only with identical harness, configuration, fixture manifests, outputs, mode and order; no deployed-binary identity claim.",
                "One discarded warmup and five sequential retained samples per case, in the reported fixed order; event-file tracing only, no adaptive repeats or timing assertion.",
                "Two deterministic loose commits are reused across reflogs to isolate cursor selection and parsed-object lookup; this is not a cold-object or natural-workload measurement.",
                "Native history/execution DATA are existing elapsed scopes, not CPU or isolated object-read timers. Primary CPU sums child user+system within each sample before summarizing.",
                "Fixture preparation, trace parsing and hashing are outside Git timing. Warm caches, buffered tracing, no OG wrapper, daemon, production replay or historical-cause claim.",
            ]
            report.update(benchmark_reflogs(git, root))
            git.remaining_seconds()
            report["status"] = "complete"
            return
        if len(sys.argv) == 4 and sys.argv[3] == "--startup-only":
            if build_options.stderr or not build_options.stdout.startswith(b"git version "):
                raise AssertionError("expected a successful, unambiguous build identity")
            report["benchmark_sha256"] = file_hash(Path(__file__))
            report.pop("stream_bytes_per_file")
            report["limitations"] = [
                "End-to-end harnessed version startup includes process launch, fixed configuration arguments, pipes and output collection; this is not isolated loader time.",
                "Compare off-mode across matched A1/B/A2 binaries with identical harness, metadata, flags and sample order; within-leg tracing ratios are not a patch effect.",
                "Two identity/reference calls, two discarded warmups and six retained samples per mode: 26 launches, no adaptive repeats or performance threshold.",
                "Empty test directory; no repository, file scan, OG, daemon, cold-cache or natural-workload savings claim.",
                "Trace reset/parsing and validation are outside timing; file tracing is buffered, not durable fsync. Child CPU excludes parent harness work.",
            ]
            report.update(benchmark_startup(git, root, build_options.stdout.splitlines(keepends=True)[0]))
            git.remaining_seconds()
            report["status"] = "complete"
            return
        if len(sys.argv) == 4 and sys.argv[3] in (
                "--follow-only", "--follow-additions-only", "--follow-tree-reads-only"):
            additions_only = sys.argv[3] == "--follow-additions-only"
            tree_reads_only = sys.argv[3] == "--follow-tree-reads-only"
            small_sources, large_sources = FOLLOW_SOURCES
            if tree_reads_only:
                fixtures = (make_follow_fixture(git, root, FOLLOW_READ_SUBTREES + 1,
                                               bulk_trees=True, subtrees=FOLLOW_READ_SUBTREES),)
            elif additions_only:
                fixtures = tuple(make_follow_fixture(git, root, large_sources, additions=additions,
                                                     bulk_trees=True)
                                 for additions in FOLLOW_ADDITIONS)
            else:
                fixtures = (make_follow_fixture(git, root, small_sources),
                            make_follow_fixture(git, root, large_sources))
            report["follow_geometry"] = [{
                "unchanged_sources": fixture.sources, "revisions": fixture.revisions,
                **({"additions": fixture.additions, "tree_input_sha256": fixture.tree_input_sha256}
                   if additions_only else {}),
                **({"unique_unchanged_subtrees": fixture.subtrees,
                    "completed_descriptor_loads": fixture.subtrees + 3,
                    "tree_input_sha256": fixture.tree_input_sha256} if tree_reads_only else {}),
                "trees": fixture.trees, "pack_sha256": fixture.pack_sha256,
                "import_sha256": fixture.import_sha256, "refs_sha256": hashlib.sha256(fixture.refs).hexdigest(),
                "packed_objects": fixture.object_counts,
            } for fixture in fixtures]
            report["benchmark_sha256"] = file_hash(Path(__file__))
            report.pop("stream_bytes_per_file")
            report["limitations"] = [
                "Compare fixed A1/B/A2 binaries with identical harness, import, trees, revisions, pack, build flags, modes and sample order; on/off is not a patch effect.",
                ("Each of six additions/copy conditions has six samples per tracing mode, with two unretained warmups per mode; fixture-block and mode positions are balanced, not all carryover pairs; no adaptive sizes, repeats or threshold."
                 if additions_only else
                 "Each of four size/copy conditions has six samples per tracing mode, with two unretained warmups per mode; no adaptive sizes, repeats or threshold."),
                "Primary CPU is user+system summed within each sample before summarizing; wall includes startup/output collection, and native full-tree wall scopes only traced commands.",
                ("Fixed unchanged sources and added noise isolate additions; N0 is the unchanged-heavy control, and unlimited edited-copy candidates are not the production mixture."
                 if additions_only else
                 "One destination and many identical small unrelated sources isolate unchanged-pair scaling; edited copies use unlimited rename candidates and are not the production candidate mixture."),
                "Bare packed fixtures, warm caches, no checkout, daemon, OG, cold-cache, per-child RSS or natural-workload savings claim.",
            ]
            if tree_reads_only:
                report["limitations"] = [
                    "Compare baseline/candidate binaries only with identical harness, fixture manifests, outputs, modes and order; within-binary on/off is not a patch effect.",
                    "One fixed geometry, two discarded warmups and six retained samples per tracing mode; all six mode permutations, no adaptive repeats, sizes or timing assertion.",
                    "65536 unique unchanged one-leaf trees plus one selected source yield 65537 sources and 65539 descriptor loads; one exact C100 destination, no inexact comparisons or added noise.",
                    "Small nondelta packed trees and warm caches isolate repeated descriptor overhead, not natural tree sizes, packed deltas, cold I/O or reusable-tree locality. Source-pair and rename bookkeeping remain in command timing.",
                    "Primary CPU sums child user+system within each sample; wall includes startup/output collection. Setup, hashing and trace parsing are outside Git timing. No OG wrapper, daemon, production replay or historical-cause claim.",
                ]
            report.update(benchmark_follow(git, fixtures, additions_only=additions_only,
                                           tree_reads_only=tree_reads_only))
            git.remaining_seconds()
            report["status"] = "complete"
            return
        small = make_fixture(
            git, root, streaming=False,
            tree_reads_only=len(sys.argv) == 4 and sys.argv[3] not in ("--status-only", "--refs-only"),
        )
        if len(sys.argv) == 4 and sys.argv[3] == "--refs-only":
            pack, = (small.repo / ".git/objects/pack").glob("*.pack")
            report["refs_geometry"] = {
                "pack_sha256": file_hash(pack), "tracked_files": len(small.files),
                "benchmark_sha256": file_hash(Path(__file__)),
            }
            report["limitations"] = [
                "Each mode has six retained 128-command aggregate samples, not 768 independent samples; divide grouped timings by 128 for per-command contrasts.",
                "Startup and output collection remain included; aggregation cannot remove drift or guarantee timer-cost resolution.",
                "Incremental cost requires matched A1/B/A2 source, binary, harness, pack, refs and modes; same-binary on/off measures all enabled tracing.",
                "Match the consistently absent/present iterative timer to pinned baseline/candidate identity; every file-traced command is validated outside timing.",
                "The new timer also enlarges per-thread arrays and summary scans; this command cannot establish cumulative overhead for other workloads.",
                "No natural-workload, OG, cold-cache, timer-only CPU or negligible-cost claim; no performance threshold or adaptive rerun.",
                "Fixture, trace reset/parsing and validation are excluded; sum user+system per sample before computing CPU medians.",
            ]
            report.update(benchmark_refs(git, small))
            small.verify_checkout()
            git.remaining_seconds()
            report["status"] = "complete"
            return
        if len(sys.argv) == 4 and sys.argv[3] == "--status-only":
            args = ("--no-optional-locks", "status", "--porcelain")
            disabled = git.run(small.repo, (*args, "--untracked-files=no"), "event-file")
            disabled_events = [json.loads(line) for line in git.trace.read_text().splitlines()]
            disabled_counts = Counter(event["event"] for event in disabled_events)
            if (disabled.stdout or disabled.stderr
                    or len({event["sid"] for event in disabled_events}) != 1
                    or any(disabled_counts[name] != 1 for name in ("version", "start", "exit", "atexit"))
                    or any(event["code"] != 0 for event in disabled_events
                           if event["event"] in ("exit", "atexit"))
                    or any(event.get("category") == "status" and event.get("key") == "untracked/fill-us"
                           for event in disabled_events)):
                raise AssertionError("status -uno must complete without untracked fill measurements")
            workload = Workload("status-untracked-scan", small, (
                *args, "--untracked-files=normal",
            ), False, b"", {}, status_scan=True)
            pack, = (small.repo / ".git/objects/pack").glob("*.pack")
            report["status_geometry"] = {
                "pack_sha256": file_hash(pack), "tracked_files": len(small.files),
                "directories_visited": SMALL_FILES // 10 + 2,
                "paths_visited": SMALL_FILES + SMALL_FILES // 10 + 3,
                "untracked_disabled_fill_events": 0,
            }
            report["limitations"] = [
                "Read-only clean status re-enumerates the fixture with fsmonitor and untracked cache disabled.",
                "A/B requires matched harness, fixture, build options and trace mode; same-binary on/off ratios measure all enabled tracing.",
                "When available, per-sample user/system CPU covers the whole command, not just directory fill; fixture and trace parsing are excluded.",
                "No daemon, OG processing, cold-cache or natural-workload claim; no performance threshold.",
            ]
            report.update(benchmark(git, (workload,)))
            small.verify_checkout()
            git.remaining_seconds()
            report["status"] = "complete"
            return
        if len(sys.argv) == 4:
            exclude_trees = sys.argv[3] == "--tree-excludes-only"
            workload, report["tree_read_geometry"] = tree_read_workload(
                git, small, exclude_trees=exclude_trees,
            )
            report["limitations"] = [
                "Repeated revisions amplify packed child-tree reads, not unique OIDs or cold-cache I/O.",
                "The non-delta-base count proves an initial-miss lower bound, not the production cache mixture.",
                "A/B requires matched harness, pack, build options and trace mode; on/off ratios are not patch effects.",
                "No blobs, workers, daemon or OG processing; no performance threshold.",
            ]
            if exclude_trees:
                report["limitations"] = [
                    "The existing packed fixture is unchanged; only the exclusion pathspec is added.",
                    "The candidate can skip covered child-tree reads; both versions still read and parse the boundary tree.",
                    "Each binary must consistently produce the exact baseline or pruned count; compare those counts with the pinned binary identity.",
                    "A/B requires matched harness, pack, build options and trace mode; work reduction is not a latency measurement.",
                    "No blobs, workers, daemon or OG processing; no cold-cache or natural-workload savings claim, and no performance threshold.",
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
