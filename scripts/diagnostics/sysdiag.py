#!/usr/bin/env python3
"""sysdiag: pre-deploy process, socket and resource-limit diagnostics.

Stdlib only and built directly on Linux /proc, so it runs anywhere Python
does: inside the app container in CI (`docker exec app python
/opt/diag/sysdiag.py`) and on EC2 hosts over SSM for live troubleshooting.

Checks
  limits    RLIMIT_NOFILE / RLIMIT_NPROC of the *target* process (read from
            /proc/<pid>/limits, not our own) meet a floor
  process   expected worker count under the master, no zombies, per-process
            RSS within budget, fd usage well under the soft limit
  sockets   the service port is in LISTEN, its accept queue is not backing up,
            and CLOSE_WAIT stays low (peer closed, app never did: an fd leak)
  baseline  compared with an earlier snapshot (e.g. before a load test):
            fd growth, RSS growth, and workers that were replaced mid-run
            (crash, timeout, or OOM kill)

Exit status is 0 when nothing FAILs (WARN is allowed unless --strict).
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import socket
import sys
import time
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path

PASS, WARN, FAIL = "PASS", "WARN", "FAIL"

# include/net/tcp_states.h
TCP_STATES = {
    "01": "ESTABLISHED",
    "02": "SYN_SENT",
    "03": "SYN_RECV",
    "04": "FIN_WAIT1",
    "05": "FIN_WAIT2",
    "06": "TIME_WAIT",
    "07": "CLOSE",
    "08": "CLOSE_WAIT",
    "09": "LAST_ACK",
    "0A": "LISTEN",
    "0B": "CLOSING",
    "0C": "NEW_SYN_RECV",
}

LIMIT_RE = re.compile(r"^(?P<name>\S.*?)\s{2,}(?P<soft>\S+)\s+(?P<hard>\S+)")


# --------------------------------------------------------------------------- data


@dataclass
class Limit:
    soft: int | None  # None means unlimited
    hard: int | None


@dataclass
class ProcInfo:
    pid: int
    ppid: int
    name: str
    state: str
    cmdline: str
    rss_kb: int
    threads: int
    fds: int | None  # None when /proc/<pid>/fd is not readable by us
    sockets: int | None


@dataclass
class TcpSocket:
    local_ip: str
    local_port: int
    remote_ip: str
    remote_port: int
    state: str
    tx_queue: int
    rx_queue: int
    inode: int


@dataclass
class Target:
    master: ProcInfo | None
    workers: list[ProcInfo]

    @property
    def processes(self) -> list[ProcInfo]:
        return ([self.master] if self.master else []) + self.workers


@dataclass
class Check:
    name: str
    status: str
    detail: str


# ----------------------------------------------------------------- /proc parsing


def _limit_value(raw: str) -> int | None:
    return None if raw == "unlimited" else int(raw)


def parse_limits(text: str) -> dict[str, Limit]:
    """Parse /proc/<pid>/limits into {"Max open files": Limit(...), ...}."""
    limits: dict[str, Limit] = {}
    for line in text.splitlines()[1:]:  # first line is the header
        match = LIMIT_RE.match(line)
        if not match:
            continue
        try:
            limits[match["name"]] = Limit(_limit_value(match["soft"]), _limit_value(match["hard"]))
        except ValueError:
            continue
    return limits


def parse_status(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        key, _, value = line.partition(":")
        out[key.strip()] = value.strip()
    return out


def _kb(raw: str) -> int:
    try:
        return int(raw.split()[0])
    except (IndexError, ValueError):
        return 0


def read_proc(pid: int, proc_root: Path) -> ProcInfo | None:
    base = proc_root / str(pid)
    try:
        status = parse_status((base / "status").read_text())
        raw_cmdline = (base / "cmdline").read_bytes()
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return None  # process exited while we were looking, or is not ours to read

    cmdline = raw_cmdline.replace(b"\0", b" ").decode(errors="replace").strip()
    fds = sockets = None
    try:
        targets = []
        for entry in os.scandir(base / "fd"):
            try:
                targets.append(os.readlink(entry.path))
            except OSError:
                continue  # fd closed between scandir() and readlink()
        fds = len(targets)
        sockets = sum(1 for t in targets if t.startswith("socket:"))
    except (PermissionError, FileNotFoundError):
        pass

    return ProcInfo(
        pid=pid,
        ppid=int(status.get("PPid") or 0),
        name=status.get("Name", "?"),
        state=(status.get("State") or "?")[0],
        cmdline=cmdline or f"[{status.get('Name', '?')}]",
        rss_kb=_kb(status.get("VmRSS", "0 kB")),
        threads=int(status.get("Threads") or 1),
        fds=fds,
        sockets=sockets,
    )


def list_processes(proc_root: Path) -> list[ProcInfo]:
    procs = []
    for entry in proc_root.iterdir():
        if entry.name.isdigit():
            info = read_proc(int(entry.name), proc_root)
            if info is not None:
                procs.append(info)
    return sorted(procs, key=lambda p: p.pid)


def _decode_address(hex_addr: str) -> tuple[str, int]:
    ip_hex, port_hex = hex_addr.split(":")
    raw = bytes.fromhex(ip_hex)
    if len(raw) == 4:
        ip = socket.inet_ntop(socket.AF_INET, raw[::-1])
    else:
        # IPv6 is printed as four 32-bit words, each in host (little-endian) order.
        words = b"".join(raw[i : i + 4][::-1] for i in range(0, 16, 4))
        ip = socket.inet_ntop(socket.AF_INET6, words)
    return ip, int(port_hex, 16)


def parse_proc_net_tcp(text: str) -> list[TcpSocket]:
    """Parse /proc/net/tcp or /proc/net/tcp6.

    For LISTEN sockets the kernel reports rx_queue as the current accept-queue
    length and tx_queue as the configured backlog, which is what makes the
    accept-queue check possible without ss(8).
    """
    sockets = []
    for line in text.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 10:
            continue
        local_ip, local_port = _decode_address(fields[1])
        remote_ip, remote_port = _decode_address(fields[2])
        tx_queue, rx_queue = (int(x, 16) for x in fields[4].split(":"))
        sockets.append(
            TcpSocket(
                local_ip=local_ip,
                local_port=local_port,
                remote_ip=remote_ip,
                remote_port=remote_port,
                state=TCP_STATES.get(fields[3].upper(), fields[3]),
                tx_queue=tx_queue,
                rx_queue=rx_queue,
                inode=int(fields[9]),
            )
        )
    return sockets


def read_tcp_sockets(proc_root: Path) -> list[TcpSocket]:
    out: list[TcpSocket] = []
    for name in ("tcp", "tcp6"):
        try:
            out.extend(parse_proc_net_tcp((proc_root / "net" / name).read_text()))
        except FileNotFoundError:
            continue
    return out


def read_loadavg(proc_root: Path) -> list[float] | None:
    try:
        return [float(x) for x in (proc_root / "loadavg").read_text().split()[:3]]
    except (OSError, ValueError):
        return None


_PYTHON = re.compile(r"^python[0-9.]*$")


def program_names(cmdline: str) -> list[str]:
    """The names a process is "running": argv[0], plus the script or module when
    argv[0] is a Python interpreter (`python -m gunicorn`, `python bin/gunicorn`).

    Matching on these instead of the whole command line keeps wrappers such as
    `sh -c "... gunicorn ..."` or `sysdiag --match gunicorn` from being mistaken
    for the server itself.
    """
    argv = cmdline.split()
    if not argv:
        return []
    names = [os.path.basename(argv[0])]
    if _PYTHON.match(names[0]):
        args = iter(argv[1:])
        for arg in args:
            if arg == "-m":
                names.append(next(args, ""))
                break
            if not arg.startswith("-"):
                names.append(os.path.basename(arg))
                break
    return names


def find_target(procs: list[ProcInfo], match: str, self_pid: int) -> Target:
    """Find the pre-fork server: the matching process whose parent doesn't match."""
    matched = [
        p
        for p in procs
        if p.pid != self_pid and any(match in name for name in program_names(p.cmdline))
    ]
    pids = {p.pid for p in matched}
    roots = [p for p in matched if p.ppid not in pids]
    if not roots:
        return Target(master=None, workers=[])
    master = min(roots, key=lambda p: p.pid)
    workers = [p for p in matched if p.ppid == master.pid]
    return Target(master=master, workers=workers)


# ------------------------------------------------------------------------ checks


def _fmt_limit(value: int | None) -> str:
    return "unlimited" if value is None else str(value)


def check_limits(limits: dict[str, Limit], min_nofile: int, min_nproc: int) -> list[Check]:
    checks = []
    for key, name, floor in (
        ("Max open files", "limits.nofile", min_nofile),
        ("Max processes", "limits.nproc", min_nproc),
    ):
        limit = limits.get(key)
        if limit is None:
            checks.append(Check(name, WARN, f"could not read '{key}'"))
            continue
        ok = limit.soft is None or limit.soft >= floor
        detail = f"soft={_fmt_limit(limit.soft)} hard={_fmt_limit(limit.hard)} (floor {floor})"
        checks.append(Check(name, PASS if ok else FAIL, detail))

    core = limits.get("Max core file size")
    if core is not None:
        enabled = core.soft is None or core.soft > 0
        checks.append(
            Check("limits.core", PASS, "core dumps enabled" if enabled else "core dumps disabled")
        )
    return checks


def check_processes(
    target: Target,
    all_procs: list[ProcInfo],
    *,
    match: str,
    expect_workers: int | None,
    max_rss_mb: float,
    max_fd_ratio: float,
    nofile_soft: int | None,
) -> list[Check]:
    if target.master is None:
        return [Check("process.target", FAIL, f"no process matching {match!r}")]

    checks = []
    count = len(target.workers)
    if expect_workers is None:
        status = PASS if count >= 1 else WARN
        detail = f"{count} workers under master pid {target.master.pid}"
    else:
        status = PASS if count == expect_workers else FAIL
        detail = f"{count} workers under master pid {target.master.pid} (expected {expect_workers})"
    checks.append(Check("process.workers", status, detail))

    zombies = [p.pid for p in all_procs if p.state == "Z"]
    checks.append(
        Check(
            "process.zombies",
            PASS if not zombies else FAIL,
            f"{len(zombies)} zombie processes" + (f" {zombies}" if zombies else ""),
        )
    )

    heaviest = max(target.processes, key=lambda p: p.rss_kb)
    rss_mb = heaviest.rss_kb / 1024
    checks.append(
        Check(
            "process.rss",
            PASS if rss_mb <= max_rss_mb else FAIL,
            f"max RSS {rss_mb:.1f} MiB (pid {heaviest.pid}, budget {max_rss_mb:g} MiB)",
        )
    )

    readable = [p for p in target.processes if p.fds is not None]
    if not readable:
        checks.append(
            Check("process.fds", WARN, "fd tables unreadable (run as the app user or root)")
        )
    else:
        busiest = max(readable, key=lambda p: p.fds or 0)
        if nofile_soft:
            ratio = (busiest.fds or 0) / nofile_soft
            status = PASS if ratio <= max_fd_ratio else FAIL
            detail = (
                f"max {busiest.fds} open fds (pid {busiest.pid}) = {ratio:.2%} of soft "
                f"limit {nofile_soft} (budget {max_fd_ratio:.0%})"
            )
        else:
            status, detail = PASS, f"max {busiest.fds} open fds (pid {busiest.pid}), no soft limit"
        checks.append(Check("process.fds", status, detail))
    return checks


def check_sockets(
    sockets: list[TcpSocket],
    *,
    port: int | None,
    max_close_wait: int,
    max_accept_queue_ratio: float,
) -> list[Check]:
    checks = []
    if port is not None:
        listeners = [s for s in sockets if s.state == "LISTEN" and s.local_port == port]
        if not listeners:
            checks.append(Check("sockets.listen", FAIL, f"nothing is listening on port {port}"))
        else:
            addrs = sorted({f"{s.local_ip}:{s.local_port}" for s in listeners})
            checks.append(Check("sockets.listen", PASS, "listening on " + ", ".join(addrs)))
            worst = max(listeners, key=lambda s: s.rx_queue / s.tx_queue if s.tx_queue else 0)
            ratio = worst.rx_queue / worst.tx_queue if worst.tx_queue else 0.0
            checks.append(
                Check(
                    "sockets.accept_queue",
                    PASS if ratio <= max_accept_queue_ratio else FAIL,
                    f"{worst.rx_queue}/{worst.tx_queue} connections waiting to be accepted",
                )
            )

    states = Counter(s.state for s in sockets)
    close_wait = states.get("CLOSE_WAIT", 0)
    checks.append(
        Check(
            "sockets.close_wait",
            PASS if close_wait <= max_close_wait else FAIL,
            f"{close_wait} in CLOSE_WAIT (budget {max_close_wait}); "
            "these are sockets the peer closed but the app never did",
        )
    )
    time_wait = states.get("TIME_WAIT", 0)
    checks.append(
        Check(
            "sockets.time_wait",
            PASS if time_wait < 20000 else WARN,
            f"{time_wait} in TIME_WAIT",
        )
    )
    return checks


def check_against_baseline(
    current: dict,
    baseline: dict,
    *,
    max_fd_growth: int,
    max_rss_growth_pct: float,
    allow_worker_restarts: bool,
) -> list[Check]:
    cur, base = current["target"], baseline.get("target") or {}
    checks = []

    master_changed = base.get("master_pid") not in (None, cur.get("master_pid"))
    replaced = sorted(set(base.get("worker_pids", [])) - set(cur.get("worker_pids", [])))
    if master_changed:
        checks.append(Check("baseline.restarts", FAIL, "master process restarted during the run"))
    elif replaced:
        checks.append(
            Check(
                "baseline.restarts",
                WARN if allow_worker_restarts else FAIL,
                f"{len(replaced)} worker(s) replaced during the run {replaced}: "
                "crash, timeout or OOM kill?",
            )
        )
    else:
        checks.append(Check("baseline.restarts", PASS, "no worker restarts"))

    if cur.get("total_fds") is not None and base.get("total_fds") is not None:
        growth = cur["total_fds"] - base["total_fds"]
        checks.append(
            Check(
                "baseline.fd_growth",
                PASS if growth <= max_fd_growth else FAIL,
                f"{base['total_fds']} -> {cur['total_fds']} open fds ({growth:+d}, "
                f"budget +{max_fd_growth})",
            )
        )

    if base.get("total_rss_kb"):
        pct = (cur["total_rss_kb"] - base["total_rss_kb"]) / base["total_rss_kb"] * 100
        checks.append(
            Check(
                "baseline.rss_growth",
                PASS if pct <= max_rss_growth_pct else FAIL,
                f"{base['total_rss_kb'] / 1024:.1f} -> {cur['total_rss_kb'] / 1024:.1f} MiB "
                f"({pct:+.1f}%, budget +{max_rss_growth_pct:g}%)",
            )
        )
    return checks


# ---------------------------------------------------------------------- snapshot


def take_snapshot(args: argparse.Namespace) -> dict:
    proc_root = Path(args.proc_root)
    procs = list_processes(proc_root)
    target = find_target(procs, args.match, os.getpid())

    limits_pid = str(target.master.pid) if target.master else "self"
    try:
        limits = parse_limits((proc_root / limits_pid / "limits").read_text())
    except OSError:
        limits = {}
    nofile = limits.get("Max open files")
    sockets = read_tcp_sockets(proc_root)

    fd_counts = [p.fds for p in target.processes]
    snapshot = {
        "schema": 1,
        "timestamp": time.time(),
        "host": socket.gethostname(),
        "kernel": platform.release(),
        "loadavg": read_loadavg(proc_root),
        "target": {
            "match": args.match,
            "master_pid": target.master.pid if target.master else None,
            "worker_pids": [p.pid for p in target.workers],
            "total_fds": None if None in fd_counts or not fd_counts else sum(fd_counts),
            "total_rss_kb": sum(p.rss_kb for p in target.processes),
        },
        "limits": {k: asdict(v) for k, v in limits.items()},
        "processes": [asdict(p) for p in target.processes],
        "sockets": {
            "states": dict(Counter(s.state for s in sockets)),
            "listening": sorted(
                {f"{s.local_ip}:{s.local_port}" for s in sockets if s.state == "LISTEN"}
            ),
        },
    }

    checks = check_limits(limits, args.min_nofile, args.min_nproc)
    checks += check_processes(
        target,
        procs,
        match=args.match,
        expect_workers=args.expect_workers,
        max_rss_mb=args.max_rss_mb,
        max_fd_ratio=args.max_fd_ratio,
        nofile_soft=nofile.soft if nofile else None,
    )
    checks += check_sockets(
        sockets,
        port=args.port,
        max_close_wait=args.max_close_wait,
        max_accept_queue_ratio=args.max_accept_queue_ratio,
    )
    if args.baseline:
        checks += check_against_baseline(
            snapshot,
            load_json(args.baseline),
            max_fd_growth=args.max_fd_growth,
            max_rss_growth_pct=args.max_rss_growth_pct,
            allow_worker_restarts=args.allow_worker_restarts,
        )

    snapshot["checks"] = [asdict(c) for c in checks]
    failing = {FAIL, WARN} if args.strict else {FAIL}
    snapshot["ok"] = not any(c.status in failing for c in checks)
    return snapshot


def load_json(path: str) -> dict:
    if path == "-":
        return json.load(sys.stdin)
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def render(snapshot: dict) -> str:
    t = snapshot["target"]
    lines = [
        f"sysdiag  host={snapshot['host']}  kernel={snapshot['kernel']}  "
        f"loadavg={snapshot['loadavg']}",
        f"target   match={t['match']!r}  master={t['master_pid']}  workers={t['worker_pids']}",
        "",
        f"{'PID':>7} {'PPID':>7} {'ST':>2} {'RSS MiB':>8} {'THR':>4} {'FDS':>5} {'SOCK':>5}  CMD",
    ]
    for p in snapshot["processes"]:
        fds = "-" if p["fds"] is None else p["fds"]
        socks = "-" if p["sockets"] is None else p["sockets"]
        lines.append(
            f"{p['pid']:>7} {p['ppid']:>7} {p['state']:>2} {p['rss_kb'] / 1024:>8.1f} "
            f"{p['threads']:>4} {fds:>5} {socks:>5}  {p['cmdline'][:60]}"
        )
    lines += ["", f"tcp states: {snapshot['sockets']['states'] or '{}'}", ""]
    lines.append(f"{'CHECK':<22} {'RESULT':<6} DETAIL")
    for c in snapshot["checks"]:
        lines.append(f"{c['name']:<22} {c['status']:<6} {c['detail']}")
    lines += ["", "RESULT: " + ("PASS" if snapshot["ok"] else "FAIL")]
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument(
        "--match",
        default="gunicorn",
        help="target program name (argv[0], or the script/module Python runs)",
    )
    p.add_argument("--port", type=int, help="service port that must be in LISTEN")
    p.add_argument("--expect-workers", type=int, help="exact worker count under the master")
    p.add_argument("--min-nofile", type=int, default=4096)
    p.add_argument("--min-nproc", type=int, default=256)
    p.add_argument("--max-rss-mb", type=float, default=300)
    p.add_argument("--max-fd-ratio", type=float, default=0.5)
    p.add_argument("--max-close-wait", type=int, default=10)
    p.add_argument("--max-accept-queue-ratio", type=float, default=0.5)
    p.add_argument("--baseline", help="earlier --json snapshot to compare against ('-' = stdin)")
    p.add_argument("--max-fd-growth", type=int, default=25)
    p.add_argument("--max-rss-growth-pct", type=float, default=50)
    p.add_argument("--allow-worker-restarts", action="store_true")
    p.add_argument("--strict", action="store_true", help="treat WARN as failure")
    p.add_argument("--json", metavar="PATH", help="write the snapshot as JSON ('-' = stdout)")
    p.add_argument("--proc-root", default="/proc", help=argparse.SUPPRESS)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    snapshot = take_snapshot(args)

    # With --json -, stdout carries the machine-readable snapshot, so the
    # human-readable report goes to stderr (it still shows up in CI logs).
    report_stream = sys.stderr if args.json == "-" else sys.stdout
    print(render(snapshot), file=report_stream)
    if args.json == "-":
        json.dump(snapshot, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(snapshot, fh, indent=2)
    return 0 if snapshot["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
