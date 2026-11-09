# firstpair-tursolite

One embedded SQL interface over SQLite and Turso, with the same shape in Rust, OCaml, OxCaml and
Python. It is the database layer of packdir and DNG Compare, and meant for any program that wants
an embedded SQL file.

| | SQLite | Turso | Turso MVCC, concurrent writers |
| --- | --- | --- | --- |
| Rust | rusqlite, bundled | the `turso` crate | threads, a connection each |
| OxCaml 5.4.0+ox | the opam `sqlite3` | the C ABI | domains, a connection each |
| Stock OCaml 5 | the opam `sqlite3` | the C ABI | domains, a connection each |
| Python 3.12+ | the standard `sqlite3` | `pyturso` | threads, a connection each |

Turso is pinned exactly, at 0.8.3. The opam `firstpair-tursolite-sdk` package holds the C ABI. Without
it `firstpair-tursolite` builds on SQLite alone and refuses Turso when asked. Python takes Turso from
the `turso` extra, `pyturso==0.8.3`, and refuses any other version.

## Building

```sh
cargo build --features turso        # Rust: features sqlite (default) and turso
make sdk                            # Turso's C library; opam's sandbox allows no cargo
opam pin add firstpair-tursolite-sdk .
opam pin add firstpair-tursolite .
make test                           # Rust, stock OCaml, OxCaml 5.4.0+ox and Python
```

The OCaml tests run in the opam switches `default` (stock OCaml 5.2) and `5.4.0+ox` (OxCaml); pin
both packages in each switch that uses them.

The stamp beside the built library is a copy of `Cargo.lock`, and a build copies the library only
when it matches, so an out-of-date Turso cannot be linked by accident.

## Use

```rust
use firstpair_tursolite::{Database, Engine, Journal, Options, Value};

let o = Options::new().engine(Engine::Turso).journal(Journal::Mvcc);
let db = Database::open("x.db".as_ref(), &o)?;
let c = db.connect()?;                      // one per thread
c.exec("CREATE TABLE IF NOT EXISTS t(a)")?;
c.transaction(|| c.run("INSERT INTO t VALUES (?)", &[Value::Integer(1)]))?;
drop(c);
db.close()?;                                // seals what Turso wrote
```

```ocaml
open Tursolite

let db = open_database ~engine:Turso ~journal:Mvcc "x.db" in
let c = connect db in                       (* one per domain *)
exec c "CREATE TABLE IF NOT EXISTS t(a)";
transaction c (fun () -> run c "INSERT INTO t VALUES (?)" [Integer 1L]);
disconnect c;
close db                                    (* seals what Turso wrote *)
```

```python
from firstpair_tursolite import Database, Engine, Journal

db = Database.open("x.db", engine=Engine.TURSO, journal=Journal.MVCC)
c = db.connect()                            # one per thread
c.exec("CREATE TABLE IF NOT EXISTS t(a)")
c.transaction(lambda: c.run("INSERT INTO t VALUES (?)", [1]))
c.close()
db.close()                                  # seals what Turso wrote
```

`transaction` is `BEGIN IMMEDIATE`, or `BEGIN CONCURRENT` under MVCC, where a transaction that loses a
conflict rolls back and runs again, so its work must be repeatable. A row every writer updates
belongs in a short transaction of its own.

## The interface

The same names in each language, spelled as each spells them.

| | Rust | OCaml | Python |
| --- | --- | --- | --- |
| Open | `Database::open(path, &Options::new().engine(..)..)` | `open_database ?engine ?journal .. path` | `Database.open(path, Options(..))` or keywords |
| Options | `engine journal page_size auto_vacuum read_only immutable create busy_ms seal experimental` | the same, as optional arguments | the same, as `Options` fields |
| Seal | `Seal::{Standard, KeepWal}` | `Standard \| Keep_wal` | `Seal.STANDARD`, `Seal.KEEP_WAL` |
| Experimental | `Experimental::WithoutRowid` | `Without_rowid` | `Experimental.WITHOUT_ROWID` |
| Connection | `db.connect()`, dropped | `connect db`, `disconnect c` | `db.connect()`, `c.close()` |
| Statements | `exec run query` | `exec run query` | `exec run query` |
| Rows | `query_rows for_each query_map query_one query_value::<T>` | `query_rows iter fold query_one query_value` | `query_rows rows for_each query_one query_value` |
| Column names | `Rows { columns, rows }`, `Row::named` | `{ columns; rows }`, `column` | `Rows(columns, rows)`, `.column` |
| Values | `Value::{Null, Integer, Real, Text, Blob}`, `From`, `FromValue`, `as_i64 as_f64 as_str as_bytes` | `Null Integer Real Text Blob`, `as_int64 as_int as_float as_string as_option` | `None int float str bytes` |
| Transaction | `c.transaction(\|\| ..)` | `transaction c (fun () -> ..)` | `c.transaction(lambda: ..)` |
| Close | `db.close()` | `close db` | `db.close()` |
| Errors | `Error { kind, message }`, `ErrorKind` | `exception Error of { kind; message }`, `error_kind` | `Error` with `.kind`, `.message`, `ErrorKind` |

Options grow without breaking callers: Rust's `Options` is `#[non_exhaustive]` and built with one
method per field from `Options::new()`, and OCaml and Python take every option by name with a
default. The OCaml interface is `tursolite.mli`; `database` and `connection` are abstract.

Rows come back as arrays of values in column order; `query_rows` adds the column names, and a Rust
`Row` in `for_each` gives a value by name with `named`. Each connection prepares a statement once and
reuses it (rusqlite's and Turso's caches in Rust, a per-connection cache over the opam `sqlite3`, the
standard `sqlite3` module's own cache); the OCaml Turso C ABI and `pyturso` prepare each time.

### Errors

Every failure is one error with a kind to match on: `Conflict` (busy, locked, or a concurrent
transaction that lost; roll back and retry), `Constraint`, `NotADatabase`, `ReadOnly`, `Refused` (one
of the rules below) and `Other`. OCaml spells them `Conflict | Constraint | Not_a_database |
Read_only | Refused | Other` and raises `Error { kind; message }`; Python raises `Error` with
`ErrorKind.CONFLICT` and so on.

### Experimental features

`experimental` turns on Turso's experimental features, none by default; asking for one with the SQLite
engine is refused. The one offered is `WithoutRowid`, for `CREATE TABLE .. WITHOUT ROWID`, which Turso
0.8.3 refuses without it. With it, Turso writes such a table and a file sealed `Standard` passes
SQLite's integrity check. Turso 0.8.3 still refuses inserts into one in MVCC mode, will not create a
secondary index on one, and will not write one that SQLite made with such an index. A table SQLite made without one opens, reads and
takes writes with no flag (in WAL mode).

### Reading

`read_only` opens a file without writing it. `immutable` is SQLite's `immutable=1` for a file that
nothing changes while it is open: no locks, no journal, nothing written beside it. It implies
`read_only`, always uses SQLite, and refuses an unsealed MVCC file.

### Threads and domains

A `Database` is shared; a `Connection` belongs to one thread (Rust, Python) or domain (OCaml) at a
time, and each takes its own from `connect`. The first `connect` hands out the connection that set the
file up. Under MVCC every connection may write at once with `BEGIN CONCURRENT`; otherwise writers
take turns with `BEGIN IMMEDIATE`, waiting up to `busy_ms`. Close every connection before `close`.

## Python

```sh
cd python
uv sync                                     # pyturso==0.8.3 and pytest, into python/.venv
uv run pytest -q                            # or: make test-python
pip install './python[turso]'               # elsewhere; without [turso] it is SQLite only
```

The package is `firstpair_tursolite`, one module over the standard `sqlite3` and `pyturso`. Its tests
include a cross-language check: a file Python's Turso path wrote and sealed is read by the Rust crate's
SQLite engine through `cargo test`.

`pyturso` 0.8.3 differs from the Rust and C interfaces in three ways the package works around:

- It has no read-only open, and opening a standard file rewrites its header. So a read-only open of
  any file not in MVCC mode goes to SQLite, which reads it untouched; `Database.engine` says so.
- It has no busy timeout. Statements that start a transaction or stand alone wait out `busy_ms`
  here instead.
- It has no statement cache.

## The rules

Each came from testing Turso against stock SQLite, on 0.8.2 and 0.8.3, and is enforced when a file
is opened.

- **Turso never writes a file with auto-vacuum.** With its experimental flag on, stock SQLite's
  integrity check then fails on the file. Reads fall to SQLite, and a write is an error.
- **A file in MVCC mode opens only with Turso.** Its header bytes 18 and 19 are 255, and SQLite calls
  it "not a database".
- **Turso has no rollback journal.** It ignores `journal_mode = DELETE`.
- **Opening a standard file with Turso for writing changes its header.** A read-only open does not.

So `close` seals: it checkpoints, leaves MVCC, checkpoints again and, as `seal` says, either hands
the file to SQLite to return to a rollback journal (`Standard`, the default) or leaves it as a WAL
file (`Wal`). Empty `-wal` and `.db-log` files are removed, and one with content is an error, since it
may hold commits. A crash leaves a file unsealed until Turso next opens it.

`Journal::Existing` (`Existing`, `Journal.EXISTING`) leaves a SQLite file's journal alone. Foreign keys are off on every SQLite
connection, because the bundled SQLite and the system's disagree on the default; a program that wants
them says so.

## License

Apache 2.0. `ocaml/sdk/turso.h` is Turso's, MIT, with its notice in `ocaml/sdk/TURSO-LICENSE.md`.
