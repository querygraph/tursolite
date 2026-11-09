"""Every engine and journal, the files they leave, and the guards between them:
the Python side of tests/matrix.rs and ocaml/test/matrix.ml."""

import os
import shutil
import sqlite3
import subprocess
import threading
import urllib.parse
from pathlib import Path

import pytest

from firstpair_tursolite import (
    Database, Engine, Error, ErrorKind, Experimental, Journal, Options, Seal, inspect, resolve,
)
from firstpair_tursolite import _standard

REPO = Path(__file__).resolve().parents[2]
SCHEMA = "CREATE TABLE IF NOT EXISTS t(name TEXT PRIMARY KEY, n INT, data BLOB)"


def options(engine, journal, **kw):
    return Options(engine=engine, journal=journal, page_size=65536, **kw)


def write(path, o, rows):
    db = Database.open(path, o)
    c = db.connect()
    c.exec(SCHEMA)

    def work():
        for i in rows:
            c.run("INSERT INTO t VALUES (?, ?, ?)", [f"r{i}", i, bytes([i % 256]) * 70000])

    c.transaction(work)
    c.close()
    db.close()


def count(path, engine):
    db = Database.open(path, engine=engine, read_only=True, create=False)
    c = db.connect()
    n = c.query_value("SELECT count(*) FROM t")
    c.close()
    db.close()
    return n


def immutable(path):
    """Stock SQLite, as a reader that trusts the file never changes."""
    uri = "file:" + urllib.parse.quote(str(path)) + "?mode=ro&immutable=1"
    return sqlite3.connect(uri, uri=True)


def companions(path):
    return sorted(p.name for p in path.parent.iterdir() if p.name.startswith(path.stem) and p != path)


def test_sqlite_round_trip(tmp_path):
    for name, j in [("delete", Journal.DELETE), ("wal", Journal.WAL)]:
        p = tmp_path / f"{name}.db"
        write(p, options(Engine.SQLITE, j), range(3))
        assert count(p, Engine.SQLITE) == 3
        assert inspect(p).page_size == 65536
    p = tmp_path / "values.db"
    with Database.open(p) as db:
        c = db.connect()
        c.exec("CREATE TABLE v(i INTEGER, r REAL, s TEXT, b BLOB, z)")
        c.run("INSERT INTO v VALUES (?, ?, ?, ?, ?)", [2**62, 1.25, "naïve", b"\x00\xff", None])
        assert c.query("SELECT * FROM v") == [(2**62, 1.25, "naïve", b"\x00\xff", None)]
        assert c.query_one("SELECT i FROM v WHERE i = ?", [0]) is None
        got = []
        c.for_each("SELECT s FROM v", [], got.append)
        assert got == [("naïve",)]
        assert list(c.rows("SELECT b FROM v")) == [(b"\x00\xff",)]
        r = c.query_rows("SELECT i, s AS name FROM v")
        assert r.columns == ("i", "name") and r.column("name") == 1 and r.rows[0][1] == "naïve"
        assert c.query_rows("SELECT s AS who FROM v WHERE 0").columns == ("who",)
        c.close()


def test_foreign_keys_stay_off(tmp_path):
    with Database.open(tmp_path / "x.db") as db:
        c = db.connect()
        c.exec("CREATE TABLE a(k TEXT PRIMARY KEY); CREATE TABLE b(k TEXT PRIMARY KEY REFERENCES a(k));"
               "INSERT INTO a VALUES ('x'); INSERT INTO b VALUES ('x')")
        c.exec("UPDATE a SET k = 'y' WHERE k = 'x'")
        c.exec("INSERT INTO b VALUES ('no parent')")
        c.close()


def test_errors_say_what_failed(tmp_path):
    with Database.open(tmp_path / "x.db") as db:
        c = db.connect()
        c.exec(SCHEMA)
        c.run("INSERT INTO t VALUES ('a', 1, NULL)")
        with pytest.raises(Error) as e:
            c.run("INSERT INTO t VALUES ('a', 2, NULL)")
        assert e.value.kind is ErrorKind.CONSTRAINT and not e.value.conflict
        c.close()
    junk = tmp_path / "junk.db"
    junk.write_bytes(b"not sqlite" * 20)
    with pytest.raises(Error) as e:
        Database.open(junk)
    assert e.value.kind is ErrorKind.NOT_A_DATABASE


def test_a_failed_transaction_rolls_back(tmp_path):
    with Database.open(tmp_path / "x.db") as db:
        c = db.connect()
        c.exec(SCHEMA)

        def work():
            c.run("INSERT INTO t VALUES ('a', 1, NULL)")
            raise RuntimeError("no")

        with pytest.raises(RuntimeError):
            c.transaction(work)
        assert c.query_value("SELECT count(*) FROM t") == 0
        c.close()


def test_mvcc_needs_turso(tmp_path):
    p = tmp_path / "x.db"
    write(p, options(Engine.SQLITE, Journal.MVCC), range(1))
    h = inspect(p)
    assert not h.mvcc and h.write_version == 1


def test_sqlite_immutable_open(tmp_path):
    p = tmp_path / "x y?.db"
    write(p, options(Engine.SQLITE, Journal.DELETE), range(2))
    with Database.open(p, immutable=True, create=False) as db:
        c = db.connect()
        assert c.query_value("SELECT count(*) FROM t") == 2
        with pytest.raises(Error) as e:
            c.run("DELETE FROM t")
        assert e.value.kind is ErrorKind.READ_ONLY
        c.close()


turso = pytest.mark.skipif(not Engine.TURSO.available, reason="pyturso==0.8.3 is not installed")


@turso
def test_turso_seals_to_a_standard_file(tmp_path):
    for name, j in [("wal", Journal.DELETE), ("mvcc", Journal.MVCC)]:
        p = tmp_path / f"{name}.sqlar"
        write(p, options(Engine.TURSO, j), range(5))
        h = inspect(p)
        assert (h.write_version, h.read_version, h.page_size, h.auto_vacuum) == (1, 1, 65536, False)
        assert companions(p) == []
        assert count(p, Engine.SQLITE) == 5
        assert count(p, Engine.TURSO) == 5
        write(p, options(Engine.SQLITE, Journal.DELETE), range(5, 6))
        write(p, options(Engine.TURSO, j), range(6, 7))
        assert count(p, Engine.SQLITE) == 7
        assert companions(p) == []


@turso
def test_concurrent_mvcc_writers_seal_for_stock_sqlite(tmp_path):
    p = tmp_path / "x.sqlar"
    db = Database.open(p, options(Engine.TURSO, Journal.MVCC))
    assert db.engine is Engine.TURSO and db.mvcc
    setup = db.connect()
    setup.exec(SCHEMA)
    setup.exec("CREATE TABLE IF NOT EXISTS e(k TEXT PRIMARY KEY, v INT); INSERT INTO e VALUES ('epoch', 0)")
    failures = []

    def writer(k):
        try:
            c = db.connect()
            for b in range(10):
                def batch():
                    for i in range(5):
                        c.run("INSERT INTO t VALUES (?, ?, ?)", [f"{k}-{b}-{i}", i, b"\x01" * 70000])
                c.transaction(batch)
                # The one row every writer shares: a short transaction of its own.
                c.transaction(lambda: c.run("UPDATE e SET v = v + 1 WHERE k = 'epoch'"))
            c.close()
        except BaseException as e:  # noqa: BLE001
            failures.append(e)

    threads = [threading.Thread(target=writer, args=(k,)) for k in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert failures == []
    assert setup.query_value("SELECT count(*) FROM t") == 200
    assert setup.query_value("SELECT v FROM e") == 40
    setup.close()
    db.close()
    assert companions(p) == [], "no -wal, -shm or .db-log left"
    h = inspect(p)
    assert (h.write_version, h.read_version) == (1, 1)
    r = immutable(p)
    assert r.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert r.execute("SELECT count(*) FROM t").fetchone()[0] == 200
    assert r.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
    r.close()


@turso
def test_an_unsealed_mvcc_file_needs_turso(tmp_path):
    p = tmp_path / "x.sqlar"
    db = Database.open(p, options(Engine.TURSO, Journal.MVCC))
    c = db.connect()
    c.exec(SCHEMA)
    c.transaction(lambda: c.run("INSERT INTO t VALUES ('a', 1, x'00')"))
    c.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    c.close()
    del db  # a crash, in effect: never sealed
    assert inspect(p).mvcc
    with pytest.raises(sqlite3.DatabaseError):
        sqlite3.connect(p).execute("SELECT count(*) FROM t").fetchall()
    assert resolve(p, Engine.SQLITE, False) is Engine.TURSO
    with pytest.raises(Error) as e:
        Database.open(p, immutable=True)
    assert e.value.kind is ErrorKind.REFUSED
    db = Database.open(p, options(Engine.SQLITE, Journal.DELETE))
    assert db.engine is Engine.TURSO and db.mvcc
    c = db.connect()
    assert c.query("SELECT count(*) FROM t") == [(1,)]
    c.close()
    db.close()
    assert not inspect(p).mvcc
    assert count(p, Engine.SQLITE) == 1


@turso
def test_an_auto_vacuum_file_stays_with_sqlite(tmp_path):
    p = tmp_path / "stock.sqlar"
    write(p, options(Engine.SQLITE, Journal.DELETE, auto_vacuum=True), range(2))
    before = p.read_bytes()
    assert inspect(p).auto_vacuum
    for j in [Journal.DELETE, Journal.WAL, Journal.MVCC]:
        with pytest.raises(Error) as e:
            write(p, options(Engine.TURSO, j), range(2, 3))
        assert "auto-vacuum" in e.value.message and e.value.kind is ErrorKind.REFUSED
    assert resolve(p, Engine.TURSO, True) is Engine.SQLITE
    assert count(p, Engine.TURSO) == 2, "a read falls to SQLite"
    assert p.read_bytes() == before, "nothing asked of Turso touched the file"
    with pytest.raises(Error):
        Database.open(tmp_path / "new.sqlar", engine=Engine.TURSO, auto_vacuum=True)


@turso
def test_reading_with_turso_leaves_a_standard_file_alone(tmp_path):
    p = tmp_path / "x.sqlar"
    write(p, options(Engine.SQLITE, Journal.DELETE), range(3))
    before = p.read_bytes()
    assert count(p, Engine.TURSO) == 3
    assert p.read_bytes() == before
    assert companions(p) == []


@turso
def test_sealing_as_far_as_wal_and_leaving_a_journal_alone(tmp_path):
    p = tmp_path / "kept.sqlar"
    o = options(Engine.TURSO, Journal.MVCC, seal=Seal.KEEP_WAL)
    write(p, o, range(2))
    assert inspect(p).write_version == 2
    write(p, o, range(2, 3))
    assert count(p, Engine.SQLITE) == 3
    p = tmp_path / "existing.db"
    write(p, options(Engine.SQLITE, Journal.WAL), range(1))
    write(p, options(Engine.SQLITE, Journal.EXISTING), range(1, 2))
    assert inspect(p).write_version == 2
    p = tmp_path / "rollback.db"
    write(p, options(Engine.SQLITE, Journal.DELETE), range(1))
    write(p, options(Engine.SQLITE, Journal.EXISTING), range(1, 2))
    assert inspect(p).write_version == 1


@turso
def test_close_refuses_a_companion_with_content(tmp_path):
    p = tmp_path / "x.sqlar"
    db = Database.open(p, options(Engine.TURSO, Journal.MVCC))
    c = db.connect()
    c.exec(SCHEMA)
    c.close()
    other = db.connect()
    with pytest.raises(Error, match="still open"):
        db.close()
    other.close()
    db.close()
    assert companions(p) == []
    # A companion with content may hold commits: sealing must not discard it.
    log = tmp_path / "x.db-log"
    log.write_bytes(b"stale")
    with pytest.raises(Error, match="not empty after sealing"):
        _standard(str(p))
    assert log.read_bytes() == b"stale"


@turso
def test_without_rowid_with_the_flag_seals_for_sqlite(tmp_path):
    p = tmp_path / "w.sqlar"
    table = "CREATE TABLE w(k TEXT PRIMARY KEY, v BLOB) WITHOUT ROWID"
    with Database.open(p, engine=Engine.TURSO) as db:
        c = db.connect()
        with pytest.raises(Error, match="WITHOUT ROWID"):
            c.exec(table)
        c.close()
    p.unlink()
    with Database.open(p, engine=Engine.TURSO, experimental=(Experimental.WITHOUT_ROWID,)) as db:
        c = db.connect()
        c.exec(table)
        c.transaction(lambda: [c.run("INSERT INTO w VALUES (?, ?)", [f"k{i:05d}", bytes([i % 256]) * 300])
                               for i in range(2000)])
        c.close()
    assert companions(p) == []
    r = immutable(p)
    assert r.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert r.execute("SELECT count(*) FROM w").fetchone()[0] == 2000
    r.close()
    with pytest.raises(Error) as e:
        Database.open(tmp_path / "s.db", experimental=(Experimental.WITHOUT_ROWID,))
    assert e.value.kind is ErrorKind.REFUSED


@turso
def test_turso_errors_say_what_failed(tmp_path):
    with Database.open(tmp_path / "x.sqlar", engine=Engine.TURSO, journal=Journal.MVCC) as db:
        c = db.connect()
        c.exec(SCHEMA)
        c.run("INSERT INTO t VALUES ('a', 1, NULL)")
        with pytest.raises(Error) as e:
            c.run("INSERT INTO t VALUES ('a', 2, NULL)")
        assert e.value.kind is ErrorKind.CONSTRAINT
        assert c.query_rows("SELECT name AS who, n FROM t").columns == ("who", "n")
        c.close()


@turso
def test_rust_reads_what_python_sealed(tmp_path):
    """The cross-language check: the Rust crate's SQLite engine reads it."""
    if shutil.which("cargo") is None:
        pytest.skip("no cargo")
    p = tmp_path / "from-python.sqlar"
    write(p, options(Engine.TURSO, Journal.MVCC), range(9))
    env = dict(os.environ, TURSOLITE_PYTHON_FILE=str(p), TURSOLITE_PYTHON_ROWS="9")
    run = subprocess.run(
        ["cargo", "test", "--quiet", "--test", "matrix", "--", "--exact", "reads_a_file_python_sealed"],
        cwd=REPO, env=env, capture_output=True, text=True, timeout=600,
    )
    assert run.returncode == 0, run.stdout + run.stderr
    assert "1 passed" in run.stdout, run.stdout
