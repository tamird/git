#!/usr/bin/env python3
"""Compare full status costs after ignore changes, including UC persistence.

Run with native Bazel, -c opt and --nocache_test_results. Both arms use the
same Git and filesystem; restored primed indexes isolate each observation.
This is a manual measurement, not a performance gate. Set
GIT_RAW_DIRECTORY_BENCH_FSMONITOR=1 to exercise daemon snapshot persistence.
It does not model cold physical storage. Traces and results are Bazel outputs.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from python.runfiles import runfiles


SETTINGS = (
    "core.fsmonitor=false", "core.untrackedCache=true", "core.autocrlf=false",
    "core.attributesFile=/dev/null", "core.hooksPath=/dev/null",
    "commit.gpgSign=false", "gc.auto=0", "maintenance.auto=false",
)


@dataclass(frozen=True)
class Measurement:
    wall_seconds: float
    native_seconds: float | None
    user_seconds: float
    system_seconds: float
    peak_rss_bytes: int
    counters: dict[str, float]
    phases_seconds: dict[str, float]
    outcomes: dict[str, str]


@dataclass(frozen=True)
class Sample:
    pair: int
    raw: bool
    measured: Measurement
    index_bytes: int


def main() -> None:
    match sys.argv:
        case [_, binary_name, "opt"]:
            pass
        case _:
            raise ValueError("run the Bazel target with -c opt")
    manifest = runfiles.Create()
    assert manifest is not None, "Bazel runfiles are unavailable"
    resolved = manifest.Rlocation(binary_name)
    assert resolved is not None, ("Git is absent from runfiles", binary_name)
    binary = Path(resolved).resolve()
    directories = int(os.environ.get("GIT_RAW_DIRECTORY_BENCH_DIRS", "32768"))
    assert 0 < directories <= 65536, (directories, "expected 1–65536 directories")
    fsmonitor = os.environ.get("GIT_RAW_DIRECTORY_BENCH_FSMONITOR", "0") == "1"
    compress_raw = os.environ.get("GIT_RAW_DIRECTORY_BENCH_COMPRESS_RAW", "0") == "1"
    monitor_started = False
    root = Path(os.environ.get(
        "GIT_RAW_DIRECTORY_BENCH_ROOT",
        str(Path(os.environ["TEST_TMPDIR"]) / "untracked-inventory-benchmark"),
    ))
    root.mkdir(mode=0o700)
    output = Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"])
    output.mkdir(parents=True, exist_ok=True)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("GIT_")}
    environment.update(
        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_SYSTEM=os.devnull,
        GIT_CONFIG_GLOBAL=os.devnull, GIT_ATTR_NOSYSTEM="1",
        GIT_EXEC_PATH=str(binary.parent),
        GIT_AUTHOR_NAME="Inventory benchmark",
        GIT_AUTHOR_EMAIL="benchmark@example.invalid",
        GIT_COMMITTER_NAME="Inventory benchmark",
        GIT_COMMITTER_EMAIL="benchmark@example.invalid",
        GIT_AUTHOR_DATE="2000-01-01T00:00:00+0000",
        GIT_COMMITTER_DATE="2000-01-01T00:00:00+0000", LC_ALL="C",
    )
    deadline = time.monotonic() + 240

    def check_deadline() -> None:
        if time.monotonic() >= deadline:
            raise TimeoutError("inventory benchmark exceeded 240 seconds")

    def run(args: tuple[str, ...], raw: bool, *, trace: str | None = None
            ) -> tuple[bytes, Measurement]:
        check_deadline()
        stdout_path = output / "command.stdout"
        stderr_path = output / "command.stderr"
        trace_path = output / f"{trace}.jsonl" if trace else None
        env = {**environment, "GIT_TEST_UNTRACKED_CACHE_RAW": str(int(raw)),
               "GIT_TRACE2_EVENT": str(trace_path) if trace_path else "0"}
        if raw and compress_raw:
            env["GIT_TEST_FSMONITOR_COMPRESS_UNTRACKED_CACHE"] = "1"
        command = [str(binary), "--no-pager"]
        for setting in SETTINGS:
            command.extend(("-c", setting))
        if monitor_started:
            command.extend(("-c", "core.fsmonitor=true"))
        command.extend(args)
        started = time.monotonic()
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            process = subprocess.Popen(command, cwd=root, env=env,
                                       stdin=subprocess.DEVNULL, stdout=stdout,
                                       stderr=stderr, start_new_session=True)
            try:
                while True:
                    pid, status, usage = os.wait4(process.pid, os.WNOHANG)
                    if pid:
                        process.returncode = os.waitstatus_to_exitcode(status)
                        break
                    check_deadline()
                    time.sleep(0.005)
            finally:
                if process.returncode is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)
        elapsed = time.monotonic() - started
        result = stdout_path.read_bytes()
        errors = stderr_path.read_bytes()
        assert (process.returncode, errors) == (0, b""), (args, process.returncode, errors)
        numbers: dict[str, float] = {}
        phases: dict[str, float] = {}
        outcomes: dict[str, str] = {}
        native_seconds: float | None = None
        if trace_path:
            for line in trace_path.read_text().splitlines():
                event = json.loads(line)
                match event:
                    case {"event": "region_leave", "category": str() as category,
                          "label": str() as label, "t_rel": int() | float() as seconds}:
                        key = f"{category}/{label}"
                        phases[key] = phases.get(key, 0) + seconds
                    case {"event": "timer", "category": str() as category,
                          "name": str() as name, "t_total": int() | float() as seconds}:
                        key = f"timer/{category}/{name}"
                        phases[key] = phases.get(key, 0) + seconds
                    case {"event": "counter", "category": str() as category,
                          "name": str() as name, "count": int() | float() as count}:
                        key = f"counter/{category}/{name}"
                        numbers[key] = numbers.get(key, 0) + count
                    case {"event": "exit", "t_abs": int() | float() as elapsed_native}:
                        native_seconds = elapsed_native
                    case {"event": "data", "category": str() as category,
                          "key": str() as key, "value": str() | int() | float() as value}:
                        if category in ("read_directory", "status", "untracked_cache", "fsmonitor"):
                            try:
                                numbers[f"{category}/{key}"] = float(value)
                            except ValueError:
                                outcomes[f"{category}/{key}"] = str(value)
        return result, Measurement(
            elapsed, native_seconds, usage.ru_utime, usage.ru_stime,
            usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024), numbers, phases, outcomes,
        )

    def stop_monitor() -> None:
        nonlocal monitor_started
        if monitor_started:
            subprocess.run([str(binary), "fsmonitor--daemon", "stop"], cwd=root,
                           env=environment, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=10, check=True)
            monitor_started = False

    def rule(contents: bytes) -> None:
        (root / ".gitignore").write_bytes(contents)

    samples: list[Sample] = []
    readers: dict[str, list[Sample]] = {}
    initial: dict[str, object] = {}
    try:
        run(("init", "--quiet", "--initial-branch=main", "--template=", "."), False)
        rule(b"*.a\n*.b\nstdout\nstderr\n")
        tracked: list[str] = [".gitignore"]
        expected_names: list[str] = []
        past = time.time() - 120
        for number in range(directories):
            check_deadline()
            directory = root / f"tree/{number // 512:04d}/{number % 512:04d}"
            directory.mkdir(parents=True)
            for item in range(4):
                path = directory / f"tracked-{item}"
                path.write_bytes(b"tracked\n")
                tracked.append(path.relative_to(root).as_posix())
            for suffix in ("a", "b"):
                (directory / f"new.{suffix}").write_bytes(b"untracked\n")
            expected_names.append(f"?? {directory.relative_to(root).as_posix()}/new.a\n")
            os.utime(directory, (past, past))
        for directory in (root / "tree").iterdir():
            os.utime(directory, (past, past))
        os.utime(root / "tree", (past, past))
        run(("add", "--all"), False)
        run(("commit", "--quiet", "-m", "benchmark fixture"), False)
        run(("-c", "core.untrackedCache=false", "update-index", "--no-untracked-cache"), False)
        if fsmonitor:
            for setting in (("core.fsmonitor", "true"), ("core.untrackedCache", "true"),
                            ("status.showUntrackedFiles", "all")):
                run(("config", *setting), False)
            run(("update-index", "--untracked-cache"), False)
        base_index = (root / ".git/index").read_bytes()
        primed: dict[bool, bytes] = {}
        status_args = ("status", "--porcelain=v1", "--untracked-files=normal")
        for raw in (() if fsmonitor else (False, True)):
            (root / ".git/index").write_bytes(base_index)
            data, measured = run(status_args, raw, trace=f"initial-{int(raw)}")
            assert data == b"", data[:200]
            initial[str(raw)] = asdict(measured)
            data, measured = run(status_args, raw, trace=f"unchanged-{int(raw)}")
            assert data == b"", data[:200]
            initial[f"unchanged-{raw}"] = asdict(measured)
            primed[raw] = (root / ".git/index").read_bytes()
            initial[f"index_bytes-{raw}"] = len(primed[raw])
        if not fsmonitor:
            path = "tree/0000/0000/tracked-0"
            for name, args, reader_expected in (
                ("ls-files", ("ls-files", "--error-unmatch", "--", path), f"{path}\n".encode()),
                ("grep", ("grep", "-F", "-n", "tracked", "--", path), f"{path}:1:tracked\n".encode()),
            ):
                readers[name] = []
                for pair, order in enumerate(((False, True), (True, False)) * 2):
                    for raw in order:
                        (root / ".git/index").write_bytes(primed[raw])
                        data, measured = run(args, raw, trace=f"{name}-{pair}-{int(raw)}")
                        assert data == reader_expected, (name, pair, raw, data, reader_expected)
                        readers[name].append(Sample(pair, raw, measured, len(primed[raw])))
        expected = (" M .gitignore\n" + "".join(sorted(expected_names))).encode()
        for pair, order in enumerate(((False, True), (True, False)) * 2):
            for raw in order:
                if fsmonitor:
                    stop_monitor()
                    (root / ".git/index").write_bytes(base_index)
                    rule(b"*.a\n*.b\nstdout\nstderr\n")
                    # Refresh the rewritten ignore file before disabling locks.
                    # Each arm starts with current stat data and no raw cache.
                    run(("update-index", "--refresh"), False)
                    comparison_index = (root / ".git/index").read_bytes()
                    monitor_started = True
                    run(("fsmonitor--daemon", "start"), raw)
                    status_args = ("--no-optional-locks", "status", "--porcelain=v1", "-uall")
                    data, measured = run(status_args, raw, trace=f"prime-{pair}-{int(raw)}")
                    assert data == b"", data[:200]
                    assert measured.counters.get("fsmonitor/untracked-cache/save-outcome") == 7, measured
                    initial[f"prime-{pair}-{raw}"] = asdict(measured)
                    data, measured = run(status_args, raw, trace=f"unchanged-{pair}-{int(raw)}")
                    assert data == b"", data[:200]
                    assert measured.outcomes.get("status/untracked-cache/restore") == "hit", measured
                    assert measured.counters.get("status/untracked/cache-opendir") == 0, measured
                    assert measured.counters.get("status/untracked/cache-directory-invalidated") == 0, measured
                    initial[f"unchanged-{pair}-{raw}"] = asdict(measured)
                else:
                    (root / ".git/index").write_bytes(primed[raw])
                rule(b"*.b\nstdout\nstderr\n")
                data, measured = run(status_args, raw, trace=f"change-{pair}-{int(raw)}")
                assert data == expected, (pair, raw, len(data), data[:200], expected[:200])
                assert measured.native_seconds is not None, (pair, raw, "missing native duration")
                if raw:
                    replayed = measured.counters.get("untracked_cache/raw/replayed-entries", 0)
                    assert replayed >= directories * 6, (pair, replayed, directories * 6)
                if fsmonitor:
                    assert measured.outcomes.get("status/untracked-cache/restore") == "hit", measured
                    assert (root / ".git/index").read_bytes() == comparison_index, "lock-free status changed the index"
                samples.append(Sample(pair, raw, measured, (root / ".git/index").stat().st_size))
        summary = {}
        for raw in (False, True):
            selected = [sample.measured for sample in samples if sample.raw == raw]
            summary[str(raw)] = {
                "wall_seconds": statistics.median(sample.wall_seconds for sample in selected),
                "user_seconds": statistics.median(sample.user_seconds for sample in selected),
                "system_seconds": statistics.median(sample.system_seconds for sample in selected),
                "peak_rss_bytes": statistics.median(sample.peak_rss_bytes for sample in selected),
            }
        result = {
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "version": run(("version",), False)[0].decode().strip(),
            "directories": directories, "files": directories * 6,
            "fsmonitor": fsmonitor,
            "compress_raw": compress_raw,
            "tracked_files": len(tracked), "output_sha256": hashlib.sha256(expected).hexdigest(),
            "output_bytes": len(expected), "initial": initial, "samples": [asdict(s) for s in samples],
            "readers": {name: [asdict(s) for s in observations] for name, observations in readers.items()},
            "median": summary, "limitations": "warm filesystem; one fixed fixture; client CPU/RSS excludes daemon",
        }
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, separators=(",", ":")), flush=True)
    finally:
        stop_monitor()
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
