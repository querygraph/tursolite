(* One embedded SQL interface over SQLite and Turso, the OCaml side of the Rust
   crate of the same name. The rules that keep the two engines' files apart
   are enforced here, at open, for every caller (see the README):

   - Turso never writes a file with auto-vacuum: its experimental support
     leaves a database that SQLite's integrity check rejects.
   - A file in Turso's MVCC mode (header bytes 18 and 19 are 255) opens only
     with Turso; SQLite calls it "not a database".
   - Turso has no rollback journal. Delete under Turso writes WAL, and [close]
     seals the file back to a standard one. *)

type engine = Sqlite | Turso
(* Existing leaves a file's journal as it is found. *)
type journal = Delete | Wal | Mvcc | Existing

(* What closing leaves of a file Turso wrote: Standard a rollback journal, as
   SQLite made it; Wal a WAL file, which Turso reopens as it was. *)
type seal = Standard | Sealed_wal
type value = Types.value = Null | Integer of int64 | Real of float | Text of string | Blob of string

exception Conflict of string

let engine_name = function Sqlite -> "sqlite" | Turso -> "turso"
let parse_engine = function
  | "sqlite" -> Sqlite | "turso" -> Turso | e -> failwith ("unknown engine " ^ e)
let available = function Sqlite -> true | Turso -> Turso_backend.available
let turso_version = Turso_backend.version

type header = { page_size : int; write_version : int; read_version : int; auto_vacuum : bool }

(* The header of a database file; None when it is missing or still empty. *)
let inspect path =
  match open_in_bin path with
  | exception Sys_error _ when not (Sys.file_exists path) -> None
  | ic ->
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let b = really_input_string ic (min 100 (in_channel_length ic)) in
        if b = "" then None
        else if String.length b < 100 || String.sub b 0 16 <> "SQLite format 3\000" then
          failwith (path ^ ": not a database")
        else
          let raw = String.get_uint16_be b 16 in
          Some { page_size = (if raw = 1 then 65536 else raw);
                 write_version = Char.code b.[18]; read_version = Char.code b.[19];
                 (* Largest root b-tree page: nonzero exactly with auto-vacuum. *)
                 auto_vacuum = String.sub b 52 4 <> "\000\000\000\000" })

let is_mvcc h = h.write_version = 255 && h.read_version = 255

(* The engine that may open [path] for [want], or why none may. [want] is
   honoured when it can be: a file Turso may not write falls to SQLite for
   reading, an MVCC file to Turso always. *)
let resolve path want ~read_only =
  let usable e =
    if available e then e
    else failwith (path ^ ": needs " ^ engine_name e ^ ", which this build does not link") in
  match inspect path with
  | Some h when is_mvcc h -> usable Turso
  | Some h when h.auto_vacuum && want = Turso ->
      if read_only then usable Sqlite
      else failwith (path ^ ": has auto-vacuum, which Turso cannot write safely; rebuild it without")
  | _ -> usable want

type backend = S | T of Turso_backend.database

type database = {
  backend : backend; path : string; journal : journal; read_only : bool; busy_ms : int; seal : seal;
  mvcc : bool; (* in MVCC mode now, whatever was asked for: an unsealed file *)
  lock : Mutex.t;
  (* The connection that set up the file. A new file's page size and vacuum
     mode belong to it, so it is the first handed out. *)
  mutable first : connection option;
}

and connection = { inner : inner; conn_mvcc : bool }
and inner = Sq of Sqlite3.db | Tu of Turso_backend.connection

let engine db = match db.backend with S -> Sqlite | T _ -> Turso
let mvcc db = db.mvcc

let conflict_message m =
  let m = String.lowercase_ascii m in
  let has k =
    let n = String.length k in
    let rec go i = i + n <= String.length m && (String.sub m i n = k || go (i + 1)) in
    go 0 in
  has "conflict" || has "database is locked" || has "busy" || has "status 4:" || has "status 6:"

let check_sqlite db what rc =
  if not (Sqlite3.Rc.is_success rc) then
    let m = Printf.sprintf "%s: %s (%s)" what (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db) in
    if rc = Sqlite3.Rc.BUSY || rc = Sqlite3.Rc.LOCKED then raise (Conflict m) else failwith m

let to_data = function
  | Null -> Sqlite3.Data.NULL | Integer n -> Sqlite3.Data.INT n | Real x -> Sqlite3.Data.FLOAT x
  | Text s -> Sqlite3.Data.TEXT s | Blob s -> Sqlite3.Data.BLOB s

let of_data = function
  | Sqlite3.Data.NULL | Sqlite3.Data.NONE -> Null | Sqlite3.Data.INT n -> Integer n
  | Sqlite3.Data.FLOAT x -> Real x | Sqlite3.Data.TEXT s -> Text s | Sqlite3.Data.BLOB s -> Blob s

let sqlite_query db sql params =
  let st = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize st)) (fun () ->
    List.iteri (fun i p -> check_sqlite db "bind" (Sqlite3.bind st (i + 1) (to_data p))) params;
    let rec rows acc = match Sqlite3.step st with
      | Sqlite3.Rc.ROW -> rows (Array.map of_data (Sqlite3.row_data st) :: acc)
      | Sqlite3.Rc.DONE -> List.rev acc
      | rc -> check_sqlite db sql rc; List.rev acc in
    rows [])

(* Runs one statement and returns its rows. *)
let query c sql params = match c.inner with
  | Sq db -> sqlite_query db sql params
  | Tu t ->
      (try Turso_backend.execute t sql (Array.of_list params)
       with Failure m when conflict_message m -> raise (Conflict m))

let run c sql params = ignore (query c sql params)

(* Runs statements with no parameters, separated by semicolons. *)
let exec c sql = match c.inner with
  | Sq db -> check_sqlite db sql (Sqlite3.exec db sql)
  | Tu _ ->
      List.iter (fun s -> if String.trim s <> "" then run c (String.trim s) [])
        (String.split_on_char ';' sql)

let open_connection db =
  let inner = match db.backend with
    | S ->
        let d = if db.read_only then Sqlite3.db_open ~mode:`READONLY db.path else Sqlite3.db_open db.path in
        Sqlite3.busy_timeout d db.busy_ms;
        Sq d
    | T t -> Tu (Turso_backend.connect t db.busy_ms) in
  { inner; conn_mvcc = db.mvcc }

(* A connection of its own for one thread. Only MVCC lets several write. *)
let connect db =
  Mutex.protect db.lock (fun () ->
    match db.first with
    | Some c -> db.first <- None; c
    | None -> open_connection db)

let last_insert_rowid c = match query c "SELECT last_insert_rowid()" [] with
  | [ [| Integer n |] ] -> n | _ -> failwith "no last_insert_rowid"

let disconnect c = match c.inner with
  | Sq d -> ignore (Sqlite3.db_close d)
  | Tu t -> Turso_backend.close_connection t

(* Opens [path]. The engine actually used is [engine db]: see [resolve] for
   when it differs from the one asked for. *)
let open_database ?(engine = Sqlite) ?(journal = Delete) ?page_size ?(auto_vacuum = false)
    ?(read_only = false) ?(create = true) ?(busy_ms = 60000) ?(seal = Standard) path =
  let existing = inspect path in
  if existing = None && not create then failwith (path ^ ": no such database");
  let engine = resolve path engine ~read_only in
  let journal = if journal = Mvcc && engine <> Turso then Delete else journal in
  if auto_vacuum && engine = Turso then failwith (path ^ ": Turso cannot write auto-vacuum");
  let fresh = existing = None in
  let mvcc = journal = Mvcc || (match existing with Some h -> is_mvcc h | None -> false) in
  let backend = match engine with
    | Sqlite -> S | Turso -> T (Turso_backend.open_database path read_only) in
  let db = { backend; path; journal; read_only; busy_ms; seal; mvcc; lock = Mutex.create (); first = None } in
  let c = open_connection db in
  if not read_only then begin
    if fresh then begin
      Option.iter (fun size -> exec c (Printf.sprintf "PRAGMA page_size = %d" size)) page_size;
      if auto_vacuum then exec c "PRAGMA auto_vacuum = INCREMENTAL"
    end;
    if mvcc then begin
      match query c "PRAGMA journal_mode = mvcc" [] with
      | [ [| Text "mvcc" |] ] -> ()
      | _ -> failwith (path ^ ": Turso did not enable MVCC")
    end else if engine = Sqlite then
      (match journal with
       | Wal -> exec c "PRAGMA journal_mode = WAL"
       | Delete -> exec c "PRAGMA journal_mode = DELETE"
       | Mvcc | Existing -> ())
  end;
  db.first <- Some c;
  db

(* A sealed Turso file back to a rollback journal, and its empty companions
   removed. A companion with content is reported: it may hold commits. *)
let standard path =
  let d = Sqlite3.db_open path in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close d)) (fun () ->
    match sqlite_query d "PRAGMA journal_mode = DELETE" [] with
    | [ [| Text "delete" |] ] -> ()
    | _ -> failwith (path ^ ": journal did not return to delete"));
  List.iter (fun f ->
    if Sys.file_exists f then
      if (Unix.stat f).Unix.st_size = 0 then Sys.remove f
      else failwith (f ^ ": not empty after sealing"))
    [Filename.remove_extension path ^ ".db-log"; path ^ "-wal"];
  (* Only an index of a WAL that is gone; some SQLite builds leave it behind. *)
  if Sys.file_exists (path ^ "-shm") then Sys.remove (path ^ "-shm")

(* Closes the file. What Turso wrote is sealed: checkpointed, out of MVCC, and
   as [seal] at open says, back to a rollback journal with the empty companion
   files gone, or left as a WAL file. Every other connection must be closed
   first with [disconnect]. *)
let close db =
  match db.backend with
  | S -> Option.iter disconnect db.first; db.first <- None
  | T t ->
      if not db.read_only then begin
        let c = connect db in
        exec c "PRAGMA wal_checkpoint(TRUNCATE)";
        if db.mvcc then begin
          exec c "PRAGMA journal_mode = wal";
          exec c "PRAGMA wal_checkpoint(TRUNCATE)"
        end;
        disconnect c
      end else Option.iter disconnect db.first;
      db.first <- None;
      Turso_backend.close_database t;
      if not db.read_only && db.seal = Standard && db.journal <> Wal then standard db.path

(* [work] in one write transaction, concurrent under MVCC. A lost transaction
   runs again, so [work] must be repeatable. *)
let transaction c work =
  let begin_ = if c.conn_mvcc then "BEGIN CONCURRENT" else "BEGIN IMMEDIATE" in
  let rec attempt delay =
    match
      exec c begin_;
      let result = work () in
      exec c "COMMIT";
      result
    with
    | result -> result
    | exception Conflict _ when c.conn_mvcc ->
        (try exec c "ROLLBACK" with _ -> ());
        Unix.sleepf delay;
        attempt (Float.min 0.25 (delay *. 2.))
    | exception e ->
        (try exec c "ROLLBACK" with _ -> ());
        raise e in
  attempt 0.001
