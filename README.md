# firstpair-tursolite

One embedded SQL interface over SQLite and Turso, with the same shape in Rust, OCaml and OxCaml.
It is the database layer of packdir and DNG Compare.

| | SQLite | Turso | Turso MVCC, concurrent writers |
| --- | --- | --- | --- |
| Rust | rusqlite, bundled | the `turso` crate | threads, a connection each |
| OxCaml | the opam `sqlite3` | the C ABI | domains, a connection each |
| Stock OCaml 5 | the opam `sqlite3` | the C ABI | domains, a connection each |

Turso is pinned exactly, at 0.8.3. The opam `firstpair-tursolite-sdk` package holds the C ABI. Without
it `firstpair-tursolite` builds on SQLite alone and refuses Turso when asked.

## Building

```sh
cargo build --features turso        # Rust: features sqlite (default) and turso
make sdk                            # Turso's C library; opam's sandbox allows no cargo
opam pin add firstpair-tursolite-sdk .
opam pin add firstpair-tursolite .
make test                           # Rust, stock OCaml and OxCaml
```

The stamp beside the built library is a copy of `Cargo.lock`, and a build copies the library only
when it matches, so an out-of-date Turso cannot be linked by accident.

## Use

```rust
use firstpair_tursolite::{Database, Engine, Journal, Options, Value};

let o = Options { engine: Engine::Turso, journal: Journal::Mvcc, ..Options::default() };
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

`transaction` is `BEGIN IMMEDIATE`, or `BEGIN CONCURRENT` under MVCC, where a transaction that loses a
conflict rolls back and runs again, so its work must be repeatable. A row every writer updates
belongs in a short transaction of its own.

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

`Journal::Existing` leaves a SQLite file's journal alone. Foreign keys are off on every SQLite
connection, because the bundled SQLite and the system's disagree on the default; a program that wants
them says so.

## License

Apache 2.0. `ocaml/sdk/turso.h` is Turso's, MIT, with its notice in `ocaml/sdk/TURSO-LICENSE.md`.
