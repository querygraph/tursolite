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

(* Busy, locked, or a concurrent transaction lost: roll back and retry.
   Every other failure is [Failure]; [error_kind] says what it was. *)
exception Conflict of string

let engine_name = function Sqlite -> "sqlite" | Turso -> "turso"
let parse_engine = function
  | "sqlite" -> Sqlite | "turso" -> Turso | e -> failwith ("unknown engine " ^ e)
let available = function Sqlite -> true | Turso -> Turso_backend.available
let turso_version = Turso_backend.version

(* The refusals of the rules in the README; [error_kind] knows them. *)
let refused_auto_vacuum = "has auto-vacuum, which Turso cannot write safely; rebuild it without"
let refused_link = "which this build does not link"
let refused_turso_vacuum = "Turso cannot write auto-vacuum"
let refused_immutable = "is unsealed (MVCC); open it with Turso and close it before reading it immutably"

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
    else failwith (path ^ ": needs " ^ engine_name e ^ ", " ^ refused_link) in
  match inspect path with
  | Some h when is_mvcc h -> usable Turso
  | Some h when h.auto_vacuum && want = Turso ->
      if read_only then usable Sqlite
      else failwith (path ^ ": " ^ refused_auto_vacuum)
  | _ -> usable want

type backend = S | T of Turso_backend.database

type database = {
  backend : backend; path : string; journal : journal; read_only : bool; busy_ms : int; seal : seal;
  mvcc : bool; (* in MVCC mode now, whatever was asked for: an unsealed file *)
  immutable : bool;
  lock : Mutex.t;
  (* The connection that set up the file. A new file's page size and vacuum
     mode belong to it, so it is the first handed out. *)
  mutable first : connection option;
}

and connection = {
  inner : inner; conn_mvcc : bool;
  (* SQLite statements prepared once per connection, by their SQL. *)
  cache : (string, Sqlite3.stmt) Hashtbl.t;
}
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

let prepare db sql =
  try Sqlite3.prepare db sql
  with Sqlite3.SqliteError m | Sqlite3.Error m -> failwith (Printf.sprintf "%s: %s (%s)" sql m (Sqlite3.errmsg db))

(* [f] on each row of [sql], a statement taken from [cache] when it has one
   and put back reset, or prepared and finalized when [cache] is None. A
   statement in use is out of the cache, so [f] may run the same SQL. *)
let sqlite_iter ?cache db sql params f =
  let st = match cache with
    | Some h -> (match Hashtbl.find_opt h sql with
                 | Some st -> Hashtbl.remove h sql; st
                 | None -> prepare db sql)
    | None -> prepare db sql in
  let finally () = match cache with
    | Some h when not (Hashtbl.mem h sql) ->
        ignore (Sqlite3.reset st); ignore (Sqlite3.clear_bindings st); Hashtbl.replace h sql st
    | _ -> ignore (Sqlite3.finalize st) in
  Fun.protect ~finally (fun () ->
    List.iteri (fun i p -> check_sqlite db "bind" (Sqlite3.bind st (i + 1) (to_data p))) params;
    let rec rows () = match Sqlite3.step st with
      | Sqlite3.Rc.ROW -> f (Array.map of_data (Sqlite3.row_data st)); rows ()
      | Sqlite3.Rc.DONE -> ()
      | rc -> check_sqlite db sql rc in
    rows ())

let sqlite_query ?cache db sql params =
  let acc = ref [] in
  sqlite_iter ?cache db sql params (fun r -> acc := r :: !acc);
  List.rev !acc

let turso_query t sql params =
  try Turso_backend.execute t sql (Array.of_list params)
  with Failure m when conflict_message m -> raise (Conflict m)

(* Runs one statement, calling [f] on each row. SQLite hands rows over as it
   reads them; Turso reads them all first. Statements are cached per
   connection on SQLite; the Turso C ABI prepares each time. *)
let iter c sql params f = match c.inner with
  | Sq db -> sqlite_iter ~cache:c.cache db sql params f
  | Tu t -> List.iter f (turso_query t sql params)

let fold c sql params ~init f =
  let acc = ref init in
  iter c sql params (fun r -> acc := f !acc r);
  !acc

(* Runs one statement and returns its rows. *)
let query c sql params = match c.inner with
  | Sq db -> sqlite_query ~cache:c.cache db sql params
  | Tu t -> turso_query t sql params

(* The first row, if there is one. *)
let query_one c sql params = match query c sql params with r :: _ -> Some r | [] -> None

(* The one value of a one-row, one-column result. *)
let query_value c sql params = match query c sql params with
  | [ [| v |] ] -> v
  | rows -> failwith (Printf.sprintf "expected one value from %S, got %d rows" sql (List.length rows))

let is_null = function Null -> true | _ -> false
let as_int64 = function Integer n -> n | _ -> failwith "expected an integer"
let as_int v = Int64.to_int (as_int64 v)
(* A real, or an integer widened to one. *)
let as_float = function Real x -> x | Integer n -> Int64.to_float n | _ -> failwith "expected a number"
(* Text or a blob's bytes. *)
let as_string = function Text s | Blob s -> s | _ -> failwith "expected text"
let as_option f = function Null -> None | v -> Some (f v)

type error_kind = [ `Conflict | `Constraint | `Not_a_database | `Read_only | `Refused | `Other ]

(* What an exception raised here was, for a caller to match on. *)
let error_kind : exn -> error_kind =
  let has m k =
    let n = String.length k in
    let rec go i = i + n <= String.length m && (String.sub m i n = k || go (i + 1)) in
    go 0 in
  function
  | Conflict _ -> `Conflict
  | Failure m ->
      let any = List.exists (has m) in
      if any ["(CONSTRAINT"; "Turso status 129:"; "constraint failed"] then `Constraint
      else if any ["(NOTADB"; "Turso status 132:"; "not a database"] then `Not_a_database
      else if any ["(READONLY"; "Turso status 130:"; "readonly"] then `Read_only
      else if any [refused_auto_vacuum; refused_link; refused_turso_vacuum; refused_immutable]
      then `Refused
      else `Other
  | _ -> `Other

let run c sql params = ignore (query c sql params)

(* Runs statements with no parameters, separated by semicolons. *)
let exec c sql = match c.inner with
  | Sq db -> check_sqlite db sql (Sqlite3.exec db sql)
  | Tu _ ->
      List.iter (fun s -> if String.trim s <> "" then run c (String.trim s) [])
        (String.split_on_char ';' sql)

(* A [file:] URI of [path] with immutable=1, its reserved bytes escaped. *)
let immutable_uri path =
  let path = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path in
  let b = Buffer.create (String.length path + 20) in
  Buffer.add_string b "file:";
  String.iter (fun ch -> match ch with
    | '?' | '#' | '%' | '\128' .. '\255' -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code ch))
    | ch -> Buffer.add_char b ch) path;
  Buffer.add_string b "?immutable=1";
  Buffer.contents b

let open_connection db =
  let inner = match db.backend with
    | S ->
        let d =
          if db.immutable then Sqlite3.db_open ~mode:`READONLY ~uri:true (immutable_uri db.path)
          else if db.read_only then Sqlite3.db_open ~mode:`READONLY db.path
          else Sqlite3.db_open db.path in
        Sqlite3.busy_timeout d db.busy_ms;
        (* The bundled SQLite of the Rust build turns these on; one rule for all. *)
        check_sqlite d "foreign_keys" (Sqlite3.exec d "PRAGMA foreign_keys = OFF");
        Sq d
    | T t -> Tu (Turso_backend.connect t db.busy_ms) in
  { inner; conn_mvcc = db.mvcc; cache = Hashtbl.create 8 }

(* A connection of its own for one thread. Only MVCC lets several write. *)
let connect db =
  Mutex.protect db.lock (fun () ->
    match db.first with
    | Some c -> db.first <- None; c
    | None -> open_connection db)

let last_insert_rowid c = match query c "SELECT last_insert_rowid()" [] with
  | [ [| Integer n |] ] -> n | _ -> failwith "no last_insert_rowid"

let disconnect c = match c.inner with
  | Sq d ->
      Hashtbl.iter (fun _ st -> ignore (Sqlite3.finalize st)) c.cache;
      Hashtbl.reset c.cache;
      ignore (Sqlite3.db_close d)
  | Tu t -> Turso_backend.close_connection t

(* Opens [path]. The engine actually used is [engine db]: see [resolve] for
   when it differs from the one asked for. *)
let open_database ?(engine = Sqlite) ?(journal = Delete) ?page_size ?(auto_vacuum = false)
    ?(read_only = false) ?(immutable = false) ?(create = true) ?(busy_ms = 60000) ?(seal = Standard) path =
  let existing = inspect path in
  if existing = None && not create then failwith (path ^ ": no such database");
  if immutable && (match existing with Some h -> is_mvcc h | None -> false) then
    failwith (path ^ ": " ^ refused_immutable);
  let read_only = read_only || immutable in
  let engine = if immutable then Sqlite else engine in
  let engine = resolve path engine ~read_only in
  let journal = if journal = Mvcc && engine <> Turso then Delete else journal in
  if auto_vacuum && engine = Turso then failwith (path ^ ": " ^ refused_turso_vacuum);
  let fresh = existing = None in
  let mvcc = journal = Mvcc || (match existing with Some h -> is_mvcc h | None -> false) in
  let backend = match engine with
    | Sqlite -> S | Turso -> T (Turso_backend.open_database path read_only) in
  let db = { backend; path; journal; read_only; busy_ms; seal; mvcc; immutable;
             lock = Mutex.create (); first = None } in
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
