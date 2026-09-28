import json
import os
from pathlib import Path

from diagnostics import sysdiag

LIMITS = """\
Limit                     Soft Limit           Hard Limit           Units
Max cpu time              unlimited            unlimited            seconds
Max core file size        0                    unlimited            bytes
Max processes             63432                63432                processes
Max open files            65536                65536                files
Max realtime timeout      unlimited            unlimited            us
"""

# 0.0.0.0:8080 LISTEN (accept queue 3/128), one ESTABLISHED, two CLOSE_WAIT
TCP = """\
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1F90 00000000:0000 0A 00000080:00000003 00:00000000 00000000  1000        0 1001 1
   1: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 1002 1
   2: 0100007F:1F90 0100007F:D432 08 00000000:00000000 00:00000000 00000000  1000        0 1003 1
   3: 0100007F:1F90 0100007F:D433 08 00000000:00000000 00:00000000 00000000  1000        0 1004 1
"""

# [::1]:9000 LISTEN
TCP6 = """\
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:2328 00000000000000000000000000000000:0000 0A 00000080:00000000 00:00000000 00000000  1000        0 2001 1
"""  # noqa: E501


def make_proc(pid, *, name, ppid, cmdline, state="S (sleeping)", rss_kb=20480, fds=()):
    return {
        "pid": pid,
        "status": f"Name:\t{name}\nState:\t{state}\nPPid:\t{ppid}\n"
        f"Threads:\t4\nVmRSS:\t{rss_kb} kB\n",
        "cmdline": cmdline,
        "fds": fds,
    }


def build_proc_root(tmp_path: Path, procs, tcp=TCP, tcp6=TCP6, limits=LIMITS) -> Path:
    root = tmp_path / "proc"
    (root / "net").mkdir(parents=True)
    (root / "net" / "tcp").write_text(tcp)
    (root / "net" / "tcp6").write_text(tcp6)
    (root / "loadavg").write_text("0.12 0.10 0.05 1/123 4567\n")
    for p in procs:
        base = root / str(p["pid"])
        (base / "fd").mkdir(parents=True)
        (base / "status").write_text(p["status"])
        (base / "cmdline").write_bytes(p["cmdline"].replace(" ", "\0").encode() + b"\0")
        (base / "limits").write_text(limits)
        for i, target in enumerate(p["fds"]):
            os.symlink(target, base / "fd" / str(i))
    return root


def gunicorn_tree(worker_fds=4):
    fds = ["socket:[1001]"] + ["/dev/null"] * (worker_fds - 1)
    cmd = "/opt/venv/bin/python /opt/venv/bin/gunicorn webapp.wsgi:app"
    return [
        make_proc(1, name="gunicorn", ppid=0, cmdline=cmd, fds=["socket:[1001]", "pipe:[5]"]),
        make_proc(7, name="gunicorn", ppid=1, cmdline=cmd, fds=fds),
        make_proc(8, name="gunicorn", ppid=1, cmdline=cmd, fds=fds),
    ]


def test_parse_limits():
    limits = sysdiag.parse_limits(LIMITS)
    assert limits["Max open files"].soft == 65536
    assert limits["Max cpu time"].soft is None
    assert limits["Max core file size"].soft == 0
    assert limits["Max realtime timeout"].hard is None


def test_parse_proc_net_tcp_ipv4():
    sockets = sysdiag.parse_proc_net_tcp(TCP)
    listen = sockets[0]
    assert (listen.local_ip, listen.local_port, listen.state) == ("0.0.0.0", 8080, "LISTEN")
    assert (listen.rx_queue, listen.tx_queue) == (3, 128)
    assert sockets[1].remote_ip == "127.0.0.1"
    assert sockets[1].remote_port == 0xD431
    assert [s.state for s in sockets].count("CLOSE_WAIT") == 2


def test_parse_proc_net_tcp_ipv6_word_order():
    (sock,) = sysdiag.parse_proc_net_tcp(TCP6)
    assert (sock.local_ip, sock.local_port, sock.state) == ("::1", 9000, "LISTEN")


def test_find_target_identifies_master_and_workers(tmp_path):
    procs = gunicorn_tree() + [
        make_proc(20, name="sh", ppid=0, cmdline="/bin/sh -c sleep"),
    ]
    root = build_proc_root(tmp_path, procs)
    target = sysdiag.find_target(sysdiag.list_processes(root), "gunicorn", self_pid=-1)
    assert target.master.pid == 1
    assert [w.pid for w in target.workers] == [7, 8]
    assert target.workers[0].fds == 4
    assert target.workers[0].sockets == 1


def test_program_names():
    assert sysdiag.program_names("/opt/venv/bin/gunicorn -c conf.py app") == ["gunicorn"]
    assert sysdiag.program_names("python3 -m gunicorn -c conf.py") == ["python3", "gunicorn"]
    assert sysdiag.program_names("/usr/bin/python3.12 -u /opt/venv/bin/gunicorn") == [
        "python3.12",
        "gunicorn",
    ]
    assert sysdiag.program_names("/bin/sh -c cd app && gunicorn") == ["sh"]
    assert sysdiag.program_names("") == []


def test_find_target_ignores_shell_wrapper(tmp_path):
    wrapper = make_proc(50, name="sh", ppid=0, cmdline="/bin/sh -c exec gunicorn webapp.wsgi:app")
    tree = gunicorn_tree()
    tree[0]["status"] = tree[0]["status"].replace("PPid:\t0", "PPid:\t50")
    root = build_proc_root(tmp_path, [wrapper, *tree])
    target = sysdiag.find_target(sysdiag.list_processes(root), "gunicorn", self_pid=-1)
    assert target.master.pid == 1
    assert [w.pid for w in target.workers] == [7, 8]


def test_find_target_excludes_itself(tmp_path):
    procs = [make_proc(5, name="python", ppid=0, cmdline="python sysdiag.py --match gunicorn")]
    root = build_proc_root(tmp_path, procs)
    target = sysdiag.find_target(sysdiag.list_processes(root), "gunicorn", self_pid=5)
    assert target.master is None


def test_check_processes_flags_zombies_and_wrong_worker_count(tmp_path):
    procs = gunicorn_tree() + [
        make_proc(30, name="defunct", ppid=1, cmdline="", state="Z (zombie)", rss_kb=0)
    ]
    root = build_proc_root(tmp_path, procs)
    all_procs = sysdiag.list_processes(root)
    target = sysdiag.find_target(all_procs, "gunicorn", self_pid=-1)
    checks = {
        c.name: c
        for c in sysdiag.check_processes(
            target,
            all_procs,
            match="gunicorn",
            expect_workers=4,
            max_rss_mb=300,
            max_fd_ratio=0.5,
            nofile_soft=65536,
        )
    }
    assert checks["process.workers"].status == sysdiag.FAIL
    assert checks["process.zombies"].status == sysdiag.FAIL
    assert checks["process.rss"].status == sysdiag.PASS
    assert checks["process.fds"].status == sysdiag.PASS


def test_check_processes_fd_ratio_against_low_limit(tmp_path):
    root = build_proc_root(tmp_path, gunicorn_tree(worker_fds=40))
    all_procs = sysdiag.list_processes(root)
    target = sysdiag.find_target(all_procs, "gunicorn", self_pid=-1)
    checks = {
        c.name: c
        for c in sysdiag.check_processes(
            target,
            all_procs,
            match="gunicorn",
            expect_workers=2,
            max_rss_mb=300,
            max_fd_ratio=0.5,
            nofile_soft=64,
        )
    }
    assert checks["process.fds"].status == sysdiag.FAIL


def test_check_limits_floor():
    limits = sysdiag.parse_limits(LIMITS.replace("65536                65536", "1024 1024"))
    checks = {c.name: c for c in sysdiag.check_limits(limits, min_nofile=4096, min_nproc=256)}
    assert checks["limits.nofile"].status == sysdiag.FAIL
    assert checks["limits.nproc"].status == sysdiag.PASS
    assert "disabled" in checks["limits.core"].detail


def test_check_sockets():
    sockets = sysdiag.parse_proc_net_tcp(TCP)
    ok = {
        c.name: c.status
        for c in sysdiag.check_sockets(
            sockets, port=8080, max_close_wait=5, max_accept_queue_ratio=0.5
        )
    }
    assert ok == {
        "sockets.listen": "PASS",
        "sockets.accept_queue": "PASS",
        "sockets.close_wait": "PASS",
        "sockets.time_wait": "PASS",
    }
    bad = {
        c.name: c.status
        for c in sysdiag.check_sockets(
            sockets, port=9999, max_close_wait=1, max_accept_queue_ratio=0.5
        )
    }
    assert bad["sockets.listen"] == "FAIL"
    assert bad["sockets.close_wait"] == "FAIL"


def test_baseline_detects_leaks_and_restarts():
    base = {
        "target": {"master_pid": 1, "worker_pids": [7, 8], "total_fds": 20, "total_rss_kb": 100_000}
    }
    cur = {
        "target": {"master_pid": 1, "worker_pids": [7, 9], "total_fds": 80, "total_rss_kb": 180_000}
    }
    checks = {
        c.name: c.status
        for c in sysdiag.check_against_baseline(
            cur, base, max_fd_growth=25, max_rss_growth_pct=50, allow_worker_restarts=False
        )
    }
    assert checks == {
        "baseline.restarts": "FAIL",
        "baseline.fd_growth": "FAIL",
        "baseline.rss_growth": "FAIL",
    }


def test_main_end_to_end_with_baseline(tmp_path, capsys):
    root = build_proc_root(tmp_path, gunicorn_tree())
    before = tmp_path / "before.json"
    common = ["--proc-root", str(root), "--port", "8080", "--expect-workers", "2"]

    assert sysdiag.main([*common, "--json", str(before)]) == 0
    snapshot = json.loads(before.read_text())
    assert snapshot["ok"] is True
    assert snapshot["target"]["worker_pids"] == [7, 8]
    assert snapshot["sockets"]["listening"] == ["0.0.0.0:8080", "::1:9000"]

    assert sysdiag.main([*common, "--baseline", str(before)]) == 0
    out = capsys.readouterr().out
    assert "baseline.fd_growth" in out
    assert "RESULT: PASS" in out


def test_main_fails_when_port_not_listening(tmp_path):
    root = build_proc_root(tmp_path, gunicorn_tree())
    assert sysdiag.main(["--proc-root", str(root), "--port", "1234"]) == 1
