(** One embedded SQL interface over SQLite and Turso, the OCaml side of the
    Rust crate and Python package of the same name.

    A {!database} is opened with an {!engine} and a {!journal}; each domain
    takes its own {!connection}. The rules that keep the two engines' files
    apart are enforced at open, for every caller (see the README):

    - Turso never writes a file with auto-vacuum: its experimental support
      leaves a database that SQLite's integrity check rejects.
    - A file in Turso's MVCC mode (header bytes 18 and 19 are 255) opens only
      with Turso; SQLite calls it "not a database".
    - Turso has no rollback journal. [Delete] under Turso writes WAL, and
      {!close} seals the file back to a standard one.

    Threads and domains: a {!database} is shared; a {!connection} belongs to
    one domain at a time. Under MVCC every connection may write at once with
    [BEGIN CONCURRENT]; otherwise writers take turns with [BEGIN IMMEDIATE],
    waiting up to [busy_ms]. *)

type engine = Sqlite | Turso

(** [Existing] leaves a file's journal as it is found. *)
type journal = Delete | Wal | Mvcc | Existing

(** What closing leaves of a file Turso wrote: [Standard] a rollback journal,
    as SQLite made it; [Keep_wal] a WAL file, which Turso reopens as it was. *)
type seal = Standard | Keep_wal

(** Turso's experimental features, off unless asked for and refused for
    SQLite. [Without_rowid]: [CREATE TABLE .. WITHOUT ROWID]. Turso 0.8.3
    writes such tables in WAL mode only (not MVCC) and refuses secondary
    indexes on them; a sealed file is a standard one SQLite reads. *)
type experimental = Without_rowid

type value = Types.value = Null | Integer of int64 | Real of float | Text of string | Blob of string

(** The rows of a query with their column names. *)
type rows = { columns : string array; rows : value array list }

(** What went wrong. [Conflict]: busy, locked, or a concurrent transaction
    lost; roll back and retry. [Refused]: one of the rules above. *)
type error_kind = Conflict | Constraint | Not_a_database | Read_only | Refused | Other

(** Every failure of this library. *)
exception Error of { kind : error_kind; message : string }

val error_kind_name : error_kind -> string
val engine_name : engine -> string
val parse_engine : string -> engine

(** Whether this build links the engine. *)
val available : engine -> bool

(** The Turso version this build links, pinned exactly. *)
val turso_version : unit -> string

val experimental_name : experimental -> string

(** What the first 100 bytes of a database file say. *)
type header = { page_size : int; write_version : int; read_version : int; auto_vacuum : bool }

(** The header of a database file; [None] when it is missing or still empty. *)
val inspect : string -> header option

val is_mvcc : header -> bool

(** The engine that may open [path] for [want], or why none may. [want] is
    honoured when it can be: a file Turso may not write falls to SQLite for
    reading, an MVCC file to Turso always. *)
val resolve : string -> engine -> read_only:bool -> engine

type database
type connection

(** Opens [path]. The engine actually used is {!engine}: see {!resolve} for
    when it differs from the one asked for. [page_size] and [auto_vacuum]
    (SQLite only) apply to a new file. [immutable] is SQLite's
    [immutable=1]: read-only, no locks, no journal; it always uses SQLite and
    refuses an unsealed MVCC file. *)
val open_database :
  ?engine:engine -> ?journal:journal -> ?page_size:int -> ?auto_vacuum:bool -> ?read_only:bool ->
  ?immutable:bool -> ?create:bool -> ?busy_ms:int -> ?seal:seal -> ?experimental:experimental list ->
  string -> database

val engine : database -> engine

(** In MVCC mode now, whatever was asked for: an unsealed file. *)
val mvcc : database -> bool

(** A connection of its own for one domain. Only MVCC lets several write. *)
val connect : database -> connection

val disconnect : connection -> unit

(** Closes the file. What Turso wrote is sealed: checkpointed, out of MVCC,
    and as [seal] at open says, back to a rollback journal with the empty
    companion files gone, or left as a WAL file. Every connection must be
    closed first with {!disconnect}. *)
val close : database -> unit

(** Runs statements with no parameters, separated by semicolons. *)
val exec : connection -> string -> unit

val run : connection -> string -> value list -> unit

(** Runs one statement and returns its rows. *)
val query : connection -> string -> value list -> value array list

(** Runs one statement and returns its rows with the column names. *)
val query_rows : connection -> string -> value list -> rows

(** The index of a column by name. *)
val column : rows -> string -> int

(** [f] on each row. SQLite hands rows over as it reads them; Turso reads
    them all first. SQLite statements are prepared once per connection. *)
val iter : connection -> string -> value list -> (value array -> unit) -> unit

val fold : connection -> string -> value list -> init:'a -> ('a -> value array -> 'a) -> 'a

(** The first row, if there is one. *)
val query_one : connection -> string -> value list -> value array option

(** The one value of a one-row, one-column result. *)
val query_value : connection -> string -> value list -> value

val last_insert_rowid : connection -> int64

(** [work] in one write transaction, concurrent under MVCC. A lost
    transaction runs again, so [work] must be repeatable. *)
val transaction : connection -> (unit -> 'a) -> 'a

val is_null : value -> bool
val as_int64 : value -> int64
val as_int : value -> int

(** A real, or an integer widened to one. *)
val as_float : value -> float

(** Text, or a blob's bytes. *)
val as_string : value -> string

(** [None] for [Null], else [Some (f v)]. *)
val as_option : (value -> 'a) -> value -> 'a option
