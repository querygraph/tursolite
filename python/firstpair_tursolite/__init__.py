"""One embedded SQL interface over SQLite and Turso, the Python side of the
Rust crate and OCaml library of the same name.

A `Database` is opened with an `Engine` and a `Journal`; each thread takes its
own `Connection`. The rules that keep the two engines' files apart are
enforced here, at open, for every caller (see the README):

- Turso never writes a file with auto-vacuum: its experimental support leaves
  a database that SQLite's integrity check rejects.
- A file in Turso's MVCC mode (header bytes 18 and 19 are 255) opens only with
  Turso; SQLite calls it "not a database".
- Turso has no rollback journal. `Journal.DELETE` under Turso writes WAL, and
  `Database.close` seals the file back to a standard one.

SQLite is the standard library's `sqlite3`; Turso is `pyturso`, pinned at
0.8.3 and refused at any other version.
"""

from __future__ import annotations

import dataclasses
import enum
import importlib.metadata
import os
import sqlite3
import threading
import time
import urllib.parse
import warnings
from typing import Any, Callable, Iterator, Optional, Sequence, TypeVar, Union

__all__ = [
    "Connection", "Database", "Engine", "Error", "ErrorKind", "Experimental", "Header", "Journal",
    "Options", "Rows", "Seal", "Value", "TURSO_VERSION", "inspect", "resolve", "turso_version",
]

__version__ = "0.2.0"

TURSO_VERSION = "0.8.3"

#: A column value: None, int, float, str (text) or bytes (blob).
Value = Union[None, int, float, str, bytes]
T = TypeVar("T")


class Engine(enum.Enum):
    SQLITE = "sqlite"
    TURSO = "turso"

    @classmethod
    def parse(cls, name: str) -> "Engine":
        try:
            return cls(name)
        except ValueError:
            raise Error(ErrorKind.OTHER, f"unknown engine {name}") from None

    @property
    def available(self) -> bool:
        """Whether this installation can use the engine."""
        return self is Engine.SQLITE or _turso() is not None


class Journal(enum.Enum):
    DELETE = "delete"
    WAL = "wal"
    MVCC = "mvcc"
    #: Leave a file's journal as it is found.
    EXISTING = "existing"


class Experimental(enum.Enum):
    """One of Turso's experimental features, off unless asked for. Turso
    only: asking for one with the SQLite engine is refused."""

    #: `CREATE TABLE .. WITHOUT ROWID`. Turso 0.8.3 writes such tables in WAL
    #: mode only (not MVCC), and refuses secondary indexes on them; a sealed
    #: file is a standard one SQLite reads.
    WITHOUT_ROWID = "without_rowid"


class Seal(enum.Enum):
    """What closing leaves of a file Turso wrote."""

    #: A rollback journal, as SQLite made it.
    STANDARD = "standard"
    #: A WAL file, which Turso reopens as it was.
    KEEP_WAL = "keep_wal"


@dataclasses.dataclass(frozen=True)
class Options:
    engine: Engine = Engine.SQLITE
    journal: Journal = Journal.DELETE
    #: Set on a new file only.
    page_size: Optional[int] = None
    #: Incremental auto-vacuum on a new file; SQLite only.
    auto_vacuum: bool = False
    read_only: bool = False
    #: SQLite's `immutable=1`: read-only, no locks, no journal; the file must
    #: not change while open. Implies `read_only`; always SQLite.
    immutable: bool = False
    create: bool = True
    busy_ms: int = 60000
    seal: Seal = Seal.STANDARD
    #: Turso's experimental features; none by default, refused for SQLite.
    experimental: tuple[Experimental, ...] = ()


class ErrorKind(enum.Enum):
    #: Busy, locked, or a concurrent transaction lost: roll back and retry.
    CONFLICT = "conflict"
    #: A UNIQUE, NOT NULL, CHECK or foreign key constraint failed.
    CONSTRAINT = "constraint"
    #: The file is not a database, or not one this engine can read.
    NOT_A_DATABASE = "not_a_database"
    #: A write through a read-only open.
    READ_ONLY = "read_only"
    #: One of tursolite's rules refused the open (see the README).
    REFUSED = "refused"
    OTHER = "other"


class Error(Exception):
    """Every failure of this package."""

    def __init__(self, kind: ErrorKind, message: str):
        super().__init__(message)
        self.kind = kind
        self.message = message

    @property
    def conflict(self) -> bool:
        """A concurrent transaction lost; the caller may roll back and retry."""
        return self.kind is ErrorKind.CONFLICT


def _refused(path: str, message: str) -> Error:
    return Error(ErrorKind.REFUSED, f"{path}: {message}")


_turso_module: Any = None


def _turso() -> Any:
    """pyturso, when installed at exactly the pinned version; else None."""
    global _turso_module
    if _turso_module is None:
        try:
            version = importlib.metadata.version("pyturso")
        except importlib.metadata.PackageNotFoundError:
            return None
        if version != TURSO_VERSION:
            return None
        with warnings.catch_warnings():
            # pyturso 0.8.3 returns from a finally block, which Python 3.14 warns of.
            warnings.simplefilter("ignore", SyntaxWarning)
            import turso
            import turso._turso
            import turso.lib
        _turso_module = turso
    return _turso_module


def turso_version() -> str:
    """The pyturso version this installation uses; an error when it has none."""
    if _turso() is None:
        try:
            found = importlib.metadata.version("pyturso")
        except importlib.metadata.PackageNotFoundError:
            raise Error(ErrorKind.REFUSED, "Turso is not installed: pip install 'firstpair-tursolite[turso]'") from None
        raise Error(ErrorKind.REFUSED, f"Turso needs pyturso=={TURSO_VERSION}, found {found}")
    return TURSO_VERSION


@dataclasses.dataclass(frozen=True)
class Header:
    """What the first 100 bytes of a database file say."""

    page_size: int
    write_version: int
    read_version: int
    auto_vacuum: bool

    @property
    def mvcc(self) -> bool:
        return self.write_version == 255 and self.read_version == 255


def inspect(path: Union[str, os.PathLike]) -> Optional[Header]:
    """The header of a database file; None when it is missing or still empty."""
    path = os.fspath(path)
    try:
        with open(path, "rb") as f:
            b = f.read(100)
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Error(ErrorKind.OTHER, f"{path}: {e}") from e
    if not b:
        return None
    if len(b) < 100 or b[:16] != b"SQLite format 3\0":
        raise Error(ErrorKind.NOT_A_DATABASE, f"{path}: not a database")
    raw = int.from_bytes(b[16:18], "big")
    return Header(
        page_size=65536 if raw == 1 else raw,
        write_version=b[18],
        read_version=b[19],
        # Largest root b-tree page: nonzero exactly with auto-vacuum.
        auto_vacuum=b[52:56] != b"\0\0\0\0",
    )


def resolve(path: Union[str, os.PathLike], want: Engine, read_only: bool) -> Engine:
    """The engine that may open `path` for `want`, or why none may. `want` is
    honoured when it can be: a file Turso may not write falls to SQLite for
    reading, an MVCC file to Turso always."""
    path = os.fspath(path)

    def usable(e: Engine) -> Engine:
        if not e.available:
            raise _refused(path, f"needs {e.value}, which this installation does not have "
                                 f"(pyturso=={TURSO_VERSION})")
        return e

    h = inspect(path)
    if h is not None and h.mvcc:
        return usable(Engine.TURSO)
    if h is not None and h.auto_vacuum and want is Engine.TURSO:
        if read_only:
            return usable(Engine.SQLITE)
        raise _refused(path, "has auto-vacuum, which Turso cannot write safely; rebuild it without")
    return usable(want)


def _first_word(sql: str) -> str:
    s = sql.lstrip()
    return s.split(None, 1)[0].upper() if s else ""


def _sqlite_error(e: Exception) -> Error:
    code = getattr(e, "sqlite_errorcode", None)
    primary = code & 0xFF if isinstance(code, int) else None
    kind = {5: ErrorKind.CONFLICT, 6: ErrorKind.CONFLICT, 19: ErrorKind.CONSTRAINT,
            26: ErrorKind.NOT_A_DATABASE, 8: ErrorKind.READ_ONLY}.get(primary, ErrorKind.OTHER)
    if primary is None and isinstance(e, sqlite3.IntegrityError):
        kind = ErrorKind.CONSTRAINT
    return Error(kind, str(e))


def _turso_error(e: Exception) -> Error:
    m = str(e)
    lower = m.lower()
    t = _turso()
    if "conflict" in lower or "database is locked" in lower or "busy" in lower:
        kind = ErrorKind.CONFLICT
    elif (t is not None and isinstance(e, t.IntegrityError)) or "constraint" in lower:
        kind = ErrorKind.CONSTRAINT
    elif "not a database" in lower or "notadb" in lower:
        kind = ErrorKind.NOT_A_DATABASE
    elif "readonly" in lower or "read-only" in lower or "read only" in lower:
        kind = ErrorKind.READ_ONLY
    else:
        kind = ErrorKind.OTHER
    return Error(kind, m)


def _uri(path: str, **query: str) -> str:
    return "file:" + urllib.parse.quote(os.path.abspath(path)) + "?" + urllib.parse.urlencode(query)


def _param(v: Any) -> Any:
    if isinstance(v, (bytearray, memoryview)):
        return bytes(v)
    return v


@dataclasses.dataclass(frozen=True)
class Rows:
    """The rows of a query with their column names."""

    columns: tuple[str, ...]
    rows: list[tuple]

    def column(self, name: str) -> int:
        """The index of the column named `name`."""
        try:
            return self.columns.index(name)
        except ValueError:
            raise Error(ErrorKind.OTHER, f"no column {name}") from None


class Connection:
    """One thread's connection. Not to be used by two threads at once; a lock
    serialises any that try."""

    def __init__(self, db: "Database", inner: Any, turso: bool):
        self._db = db
        self._inner = inner
        self._turso = turso
        self._lock = threading.RLock()
        self.mvcc = db.mvcc
        self.closed = False

    def _error(self, e: Exception) -> Error:
        return _turso_error(e) if self._turso else _sqlite_error(e)

    def _execute(self, sql: str, params: Sequence[Any]) -> Any:
        """A cursor positioned before the first row."""
        if self.closed:
            raise Error(ErrorKind.OTHER, "connection is closed")
        args = tuple(_param(p) for p in params)
        if not self._turso:
            try:
                return self._inner.execute(sql, args)
            except sqlite3.Error as e:
                raise _sqlite_error(e) from e
        # pyturso 0.8.3 has no busy timeout: wait here, as SQLite's handler
        # would, for a statement that starts a transaction or stands alone.
        deadline = time.monotonic() + self._db.options.busy_ms / 1000
        delay = 0.001
        while True:
            retry = not self._inner.in_transaction or _first_word(sql) == "BEGIN"
            try:
                return self._inner.execute(sql, args)
            except Exception as e:
                err = _turso_error(e)
                busy = err.conflict and "conflict" not in err.message.lower()
                if not (retry and busy and time.monotonic() < deadline):
                    raise err from e
            time.sleep(delay)
            delay = min(delay * 2, 0.1)

    def query(self, sql: str, params: Sequence[Any] = ()) -> list[tuple]:
        """Runs one statement and returns its rows."""
        return self.query_rows(sql, params).rows

    def query_rows(self, sql: str, params: Sequence[Any] = ()) -> Rows:
        """Runs one statement and returns its rows with the column names."""
        with self._lock:
            cur = self._execute(sql, params)
            try:
                rows = [tuple(r) for r in cur.fetchall()]
                columns = tuple(d[0] for d in cur.description or ())
                return Rows(columns, rows)
            except Exception as e:
                raise self._error(e) from e
            finally:
                cur.close()

    def rows(self, sql: str, params: Sequence[Any] = ()) -> Iterator[tuple]:
        """Runs one statement and yields its rows as they are read. The
        connection is held until the iterator is exhausted or closed."""
        with self._lock:
            cur = self._execute(sql, params)
            try:
                while True:
                    try:
                        r = cur.fetchone()
                    except Exception as e:
                        raise self._error(e) from e
                    if r is None:
                        return
                    yield tuple(r)
            finally:
                cur.close()

    def for_each(self, sql: str, params: Sequence[Any], f: Callable[[tuple], None]) -> None:
        """Runs one statement, calling `f` on each row as it is read."""
        for row in self.rows(sql, params):
            f(row)

    def query_one(self, sql: str, params: Sequence[Any] = ()) -> Optional[tuple]:
        """The first row, or None."""
        rows = self.query(sql, params)
        return rows[0] if rows else None

    def query_value(self, sql: str, params: Sequence[Any] = ()) -> Value:
        """The one value of a one-row, one-column result."""
        rows = self.query(sql, params)
        if len(rows) != 1 or len(rows[0]) != 1:
            raise Error(ErrorKind.OTHER, f"expected one value from {sql!r}, got {len(rows)} rows")
        return rows[0][0]

    def run(self, sql: str, params: Sequence[Any] = ()) -> None:
        self.query(sql, params)

    def exec(self, sql: str) -> None:
        """Runs statements with no parameters, separated by semicolons."""
        with self._lock:
            one = sql.strip().rstrip(";").strip()
            if ";" not in one:
                if one:
                    self.query(one)
                return
            if self.closed:
                raise Error(ErrorKind.OTHER, "connection is closed")
            try:
                self._inner.executescript(sql)
            except Exception as e:
                raise self._error(e) from e

    def last_insert_rowid(self) -> int:
        return self.query_value("SELECT last_insert_rowid()")  # type: ignore[return-value]

    @property
    def in_transaction(self) -> bool:
        return bool(self._inner.in_transaction)

    def transaction(self, work: Callable[[], T]) -> T:
        """`work` in one write transaction, concurrent under MVCC. A lost
        transaction runs again, so `work` must be repeatable."""
        begin = "BEGIN CONCURRENT" if self.mvcc else "BEGIN IMMEDIATE"
        delay = 0.001
        with self._lock:
            while True:
                try:
                    self.exec(begin)
                    value = work()
                    self.exec("COMMIT")
                    return value
                except Error as e:
                    self._rollback()
                    if not (self.mvcc and e.conflict):
                        raise
                except BaseException:
                    self._rollback()
                    raise
                time.sleep(delay)
                delay = min(delay * 2, 0.25)

    def _rollback(self) -> None:
        try:
            if self._inner.in_transaction:
                self._inner.execute("ROLLBACK")
        except Exception:
            pass

    def close(self) -> None:
        """Closes the connection: `disconnect` in OCaml, a drop in Rust."""
        with self._lock:
            if self.closed:
                return
            self._rollback()
            self.closed = True
            try:
                self._inner.close()
            finally:
                self._inner = None
                self._db._forget(self)

    def __enter__(self) -> "Connection":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()


class Database:
    """An open file. Shared between threads; each takes its own connection."""

    path: str
    options: Options
    #: In MVCC mode now, whatever was asked for: an unsealed file.
    mvcc: bool

    def __init__(self) -> None:
        raise TypeError("use Database.open(path, options)")

    @classmethod
    def open(cls, path: Union[str, os.PathLike], options: Optional[Options] = None, **kw: Any) -> "Database":
        """Opens `path` with `options`, or with keyword arguments naming its
        fields. The engine actually used is `Database.engine`: see `resolve`
        for when it differs from the one asked for."""
        o = dataclasses.replace(options or Options(), **kw)
        path = os.fspath(path)
        if o.experimental and o.engine is Engine.SQLITE:
            raise _refused(path, "Turso's experimental features need the turso engine")
        existing = inspect(path)
        if existing is None and not o.create:
            raise Error(ErrorKind.OTHER, f"{path}: no such database")
        if o.immutable:
            if existing is not None and existing.mvcc:
                raise _refused(path, "is unsealed (MVCC); open it with Turso and close it before reading it immutably")
            o = dataclasses.replace(o, read_only=True, engine=Engine.SQLITE)
        engine = resolve(path, o.engine, o.read_only)
        if engine is Engine.TURSO and o.read_only and not (existing is not None and existing.mvcc):
            # pyturso 0.8.3 cannot open read-only, and its open rewrites a
            # standard header. SQLite reads every file that is not in MVCC mode.
            engine = Engine.SQLITE
        o = dataclasses.replace(o, engine=engine)
        if o.journal is Journal.MVCC and engine is not Engine.TURSO:
            o = dataclasses.replace(o, journal=Journal.DELETE)
        if o.auto_vacuum and engine is Engine.TURSO:
            raise _refused(path, "Turso cannot write auto-vacuum")

        self = object.__new__(cls)
        self.path = path
        self.options = o
        self.mvcc = o.journal is Journal.MVCC or (existing is not None and existing.mvcc)
        self._lock = threading.Lock()
        self._open: set[Connection] = set()
        self._first: Optional[Connection] = None
        self._native = None
        self._closed = False
        if engine is Engine.TURSO:
            t = _turso()
            try:
                features = ",".join(Experimental(f).value for f in o.experimental) or None
                self._native = t._turso.py_turso_database_open(
                    t._turso.PyTursoDatabaseConfig(path=path, experimental_features=features))
            except Exception as e:
                raise _turso_error(t.lib._map_turso_exception(e)) from e
        # The connection that sets up the file. A new file's page size and
        # vacuum mode belong to it, so it is the first handed out.
        c = self._open_connection()
        try:
            if not o.read_only:
                if existing is None:
                    if o.page_size is not None:
                        c.exec(f"PRAGMA page_size = {int(o.page_size)}")
                    if o.auto_vacuum:
                        c.exec("PRAGMA auto_vacuum = INCREMENTAL")
                if self.mvcc:
                    if c.query("PRAGMA journal_mode = mvcc") != [("mvcc",)]:
                        raise Error(ErrorKind.OTHER, f"{path}: Turso did not enable MVCC")
                elif engine is Engine.SQLITE:
                    if o.journal is Journal.WAL:
                        c.exec("PRAGMA journal_mode = WAL")
                    elif o.journal is Journal.DELETE:
                        c.exec("PRAGMA journal_mode = DELETE")
        except BaseException:
            c.close()
            self._native = None
            raise
        self._first = c
        return self

    @property
    def engine(self) -> Engine:
        return self.options.engine

    def connect(self) -> Connection:
        """A connection of its own for one thread. Only MVCC lets several write."""
        with self._lock:
            if self._closed:
                raise Error(ErrorKind.OTHER, f"{self.path}: database is closed")
            c, self._first = self._first, None
        return c if c is not None else self._open_connection()

    def _open_connection(self) -> Connection:
        o = self.options
        if self._native is None:
            if o.read_only:
                query = {"mode": "ro"}
                if o.immutable:
                    query["immutable"] = "1"
                target, uri = _uri(self.path, **query), True
            else:
                target, uri = self.path, False
            try:
                inner = sqlite3.connect(target, uri=uri, timeout=o.busy_ms / 1000,
                                        autocommit=True, check_same_thread=False)
                # Off on every connection of every engine and language, since
                # SQLite builds disagree on the default.
                inner.execute("PRAGMA foreign_keys = OFF")
            except sqlite3.Error as e:
                raise _sqlite_error(e) from e
            c = Connection(self, inner, turso=False)
        else:
            t = _turso()
            try:
                inner = t.Connection(self._native.connect(), isolation_level=None)
            except Exception as e:
                raise _turso_error(t.lib._map_turso_exception(e)) from e
            c = Connection(self, inner, turso=True)
        with self._lock:
            self._open.add(c)
        return c

    def _forget(self, c: Connection) -> None:
        with self._lock:
            self._open.discard(c)

    def close(self) -> None:
        """Closes the file. What Turso wrote is sealed: checkpointed, out of
        MVCC, and as `seal` says, back to a rollback journal with the empty
        companion files gone, or left as a WAL file. Every connection but the
        first must be closed first."""
        with self._lock:
            if self._closed:
                return
            first = self._first
            others = [c for c in self._open if c is not first]
        if others:
            raise Error(ErrorKind.OTHER, f"{self.path}: {len(others)} connection(s) still open; close them first")
        o = self.options
        if o.engine is not Engine.TURSO or o.read_only:
            if first is not None:
                first.close()
            self._closed = True
            self._native = None
            return
        c = self.connect()
        try:
            c.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            if self.mvcc:
                c.exec("PRAGMA journal_mode = wal")
                c.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        finally:
            c.close()
            self._closed = True
            self._native = None
        if o.journal is not Journal.WAL and o.seal is Seal.STANDARD:
            _standard(self.path)

    def __enter__(self) -> "Database":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()


def _standard(path: str) -> None:
    """A sealed Turso file back to a rollback journal, and its empty
    companions removed. A companion with content is reported: it may hold
    commits."""
    try:
        c = sqlite3.connect(path, autocommit=True)
        try:
            mode = c.execute("PRAGMA journal_mode = DELETE").fetchone()[0]
        finally:
            c.close()
    except sqlite3.Error as e:
        raise _sqlite_error(e) from e
    if mode != "delete":
        raise Error(ErrorKind.OTHER, f"{path}: journal stayed {mode}")
    for companion in (os.path.splitext(path)[0] + ".db-log", path + "-wal"):
        try:
            size = os.stat(companion).st_size
        except FileNotFoundError:
            continue
        if size:
            raise Error(ErrorKind.OTHER, f"{companion}: not empty after sealing")
        os.remove(companion)
    # Only an index of a WAL that is gone; some SQLite builds leave it behind.
    try:
        os.remove(path + "-shm")
    except FileNotFoundError:
        pass
