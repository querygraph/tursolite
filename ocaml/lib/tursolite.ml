(* One embedded SQL interface over SQLite and Turso, the OCaml side of the Rust
   crate and Python package of the same name. See tursolite.mli and the
   README for the rules enforced here, at open, for every caller. *)

type engine = Sqlite | Turso
type journal = Delete | Wal | Mvcc | Existing
type seal = Standard | Keep_wal
type experimental = Without_rowid
type value = Types.value = Null | Integer of int64 | Real of float | Text of string | Blob of string
type rows = { columns : string array; rows : value array list }

type error_kind = Conflict | Constraint | Not_a_database | Read_only | Refused | Other
exception Error of { kind : error_kind; message : string }

let error_kind_name = function
  | Conflict -> "conflict" | Constraint -> "constraint" | Not_a_database -> "not a database"
  | Read_only -> "read-only" | Refused -> "refused" | Other -> "error"

let () =
  (Printexc.register_printer [@alert "-unsafe_multidomain"]) (function
    | Error { kind; message } -> Some (Printf.sprintf "Tursolite.Error (%s): %s" (error_kind_name kind) message)
    | _ -> None)

let fail kind message = raise (Error { kind; message })
let other message = fail Other message
let refused path message = fail Refused (path ^ ": " ^ message)

let engine_name = function Sqlite -> "sqlite" | Turso -> "turso"
let parse_engine = function
  | "sqlite" -> Sqlite | "turso" -> Turso | e -> other ("unknown engine " ^ e)
let available = function Sqlite -> true | Turso -> Turso_backend.available
let turso_version () =
  if Turso_backend.available then Turso_backend.version () else fail Refused "this build does not link Turso"
let experimental_name = function Without_rowid -> "without_rowid"

type header = { page_size : int; write_version : int; read_version : int; auto_vacuum : bool }

let inspect path =
  match open_in_bin path with
  | exception Sys_error _ when not (Sys.file_exists path) -> None
  | exception Sys_error m -> other m
  | ic ->
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let b = really_input_string ic (min 100 (in_channel_length ic)) in
        if b = "" then None
        else if String.length b < 100 || String.sub b 0 16 <> "SQLite format 3\000" then
          fail Not_a_database (path ^ ": not a database")
        else
          let raw = String.get_uint16_be b 16 in
          Some { page_size = (if raw = 1 then 65536 else raw);
                 write_version = Char.code b.[18]; read_version = Char.code b.[19];
                 (* Largest root b-tree page: nonzero exactly with auto-vacuum. *)
                 auto_vacuum = String.sub b 52 4 <> "\000\000\000\000" })

let is_mvcc h = h.write_version = 255 && h.read_version = 255

let resolve path want ~read_only =
  let usable e =
    if available e then e else refused path ("needs " ^ engine_name e ^ ", which this build does not link") in
  match inspect path with
  | Some h when is_mvcc h -> usable Turso
  | Some h when h.auto_vacuum && want = Turso ->
      if read_only then usable Sqlite
      else refused path "has auto-vacuum, which Turso cannot write safely; rebuild it without"
  | _ -> usable want

type backend = S | T of Turso_backend.database

type database = {
  backend : backend; path : string; journal : journal; read_only : bool; immutable : bool;
  busy_ms : int; seal : seal;
  mvcc : bool; (* in MVCC mode now, whatever was asked for: an unsealed file *)
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

let sqlite_kind = function
  | Sqlite3.Rc.BUSY | Sqlite3.Rc.LOCKED -> Conflict
  | Sqlite3.Rc.CONSTRAINT -> Constraint
  | Sqlite3.Rc.NOTADB -> Not_a_database
  | Sqlite3.Rc.READONLY -> Read_only
  | _ -> Other

let check_sqlite db what rc =
  if not (Sqlite3.Rc.is_success rc) then
    fail (sqlite_kind rc) (Printf.sprintf "%s: %s (%s)" what (Sqlite3.errmsg db) (Sqlite3.Rc.to_string rc))

(* Turso status codes, from turso.h. *)
let turso_kind status message =
  let m = String.lowercase_ascii message in
  let has k =
    let n = String.length k in
    let rec go i = i + n <= String.length m && (String.sub m i n = k || go (i + 1)) in
    go 0 in
  match status with
  | 4 | 6 -> Conflict
  | 129 -> Constraint
  | 130 -> Read_only
  | 132 -> Not_a_database
  | _ when has "conflict" || has "database is locked" || has "busy" -> Conflict
  | _ -> Other

let turso f = try f () with Turso_backend.Failed (status, message) -> fail (turso_kind status message) message

let to_data = function
  | Null -> Sqlite3.Data.NULL | Integer n -> Sqlite3.Data.INT n | Real x -> Sqlite3.Data.FLOAT x
  | Text s -> Sqlite3.Data.TEXT s | Blob s -> Sqlite3.Data.BLOB s

let of_data = function
  | Sqlite3.Data.NULL | Sqlite3.Data.NONE -> Null | Sqlite3.Data.INT n -> Integer n
  | Sqlite3.Data.FLOAT x -> Real x | Sqlite3.Data.TEXT s -> Text s | Sqlite3.Data.BLOB s -> Blob s

let prepare db sql =
  try Sqlite3.prepare db sql
  with Sqlite3.SqliteError m | Sqlite3.Error m -> other (Printf.sprintf "%s: %s (%s)" sql m (Sqlite3.errmsg db))

(* [f] on each row of [sql]; returns the column names. The statement comes
   from [cache] when it has one and goes back reset, or is prepared and
   finalized when [cache] is None. A statement in use is out of the cache, so
   [f] may run the same SQL. *)
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
    rows ();
    Array.init (Sqlite3.column_count st) (Sqlite3.column_name st))

let sqlite_rows ?cache db sql params =
  let acc = ref [] in
  let columns = sqlite_iter ?cache db sql params (fun r -> acc := r :: !acc) in
  { columns; rows = List.rev !acc }

let turso_rows t sql params =
  let columns, rows = turso (fun () -> Turso_backend.execute t sql (Array.of_list params)) in
  { columns; rows }

let query_rows c sql params = match c.inner with
  | Sq db -> sqlite_rows ~cache:c.cache db sql params
  | Tu t -> turso_rows t sql params

let query c sql params = (query_rows c sql params).rows

let iter c sql params f = match c.inner with
  | Sq db -> ignore (sqlite_iter ~cache:c.cache db sql params f)
  | Tu t -> List.iter f (turso_rows t sql params).rows

let fold c sql params ~init f =
  let acc = ref init in
  iter c sql params (fun r -> acc := f !acc r);
  !acc

let query_one c sql params = match query c sql params with r :: _ -> Some r | [] -> None

let query_value c sql params = match query c sql params with
  | [ [| v |] ] -> v
  | rows -> other (Printf.sprintf "expected one value from %S, got %d rows" sql (List.length rows))

let column rows name =
  let rec go i =
    if i >= Array.length rows.columns then other ("no column " ^ name)
    else if rows.columns.(i) = name then i else go (i + 1) in
  go 0

let run c sql params = ignore (query c sql params)

let exec c sql = match c.inner with
  | Sq db -> check_sqlite db sql (Sqlite3.exec db sql)
  | Tu _ ->
      List.iter (fun s -> if String.trim s <> "" then run c (String.trim s) [])
        (String.split_on_char ';' sql)

let is_null = function Null -> true | _ -> false
let as_int64 = function Integer n -> n | _ -> other "expected an integer"
let as_int v = Int64.to_int (as_int64 v)
let as_float = function Real x -> x | Integer n -> Int64.to_float n | _ -> other "expected a number"
let as_string = function Text s | Blob s -> s | _ -> other "expected text"
let as_option f = function Null -> None | v -> Some (f v)

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

let sqlite_open ?mode ?uri path =
  try Sqlite3.db_open ?mode ?uri path
  with Sqlite3.SqliteError m | Sqlite3.Error m -> other (path ^ ": " ^ m)

let open_connection db =
  let inner = match db.backend with
    | S ->
        let d =
          if db.immutable then sqlite_open ~mode:`READONLY ~uri:true (immutable_uri db.path)
          else if db.read_only then sqlite_open ~mode:`READONLY db.path
          else sqlite_open db.path in
        Sqlite3.busy_timeout d db.busy_ms;
        (* The bundled SQLite of the Rust build turns these on; one rule for all. *)
        check_sqlite d "foreign_keys" (Sqlite3.exec d "PRAGMA foreign_keys = OFF");
        Sq d
    | T t -> Tu (turso (fun () -> Turso_backend.connect t db.busy_ms)) in
  { inner; conn_mvcc = db.mvcc; cache = Hashtbl.create 8 }

let connect db =
  Mutex.protect db.lock (fun () ->
    match db.first with
    | Some c -> db.first <- None; c
    | None -> open_connection db)

let last_insert_rowid c = as_int64 (query_value c "SELECT last_insert_rowid()" [])

let disconnect c = match c.inner with
  | Sq d ->
      Hashtbl.iter (fun _ st -> ignore (Sqlite3.finalize st)) c.cache;
      Hashtbl.reset c.cache;
      ignore (Sqlite3.db_close d)
  | Tu t -> Turso_backend.close_connection t

let open_database ?(engine = Sqlite) ?(journal = Delete) ?page_size ?(auto_vacuum = false)
    ?(read_only = false) ?(immutable = false) ?(create = true) ?(busy_ms = 60000) ?(seal = Standard)
    ?(experimental = []) path =
  if experimental <> [] && engine = Sqlite then refused path "Turso's experimental features need the turso engine";
  let existing = inspect path in
  if existing = None && not create then other (path ^ ": no such database");
  if immutable && (match existing with Some h -> is_mvcc h | None -> false) then
    refused path "is unsealed (MVCC); open it with Turso and close it before reading it immutably";
  let read_only = read_only || immutable in
  let engine = resolve path (if immutable then Sqlite else engine) ~read_only in
  let journal = if journal = Mvcc && engine <> Turso then Delete else journal in
  if auto_vacuum && engine = Turso then refused path "Turso cannot write auto-vacuum";
  let fresh = existing = None in
  let mvcc = journal = Mvcc || (match existing with Some h -> is_mvcc h | None -> false) in
  let backend = match engine with
    | Sqlite -> S
    | Turso ->
        let features = String.concat "," (List.map experimental_name experimental) in
        T (turso (fun () -> Turso_backend.open_database path read_only features)) in
  let db = { backend; path; journal; read_only; immutable; busy_ms; seal; mvcc;
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
      | _ -> other (path ^ ": Turso did not enable MVCC")
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
  let d = sqlite_open path in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close d)) (fun () ->
    match (sqlite_rows d "PRAGMA journal_mode = DELETE" []).rows with
    | [ [| Text "delete" |] ] -> ()
    | _ -> other (path ^ ": journal did not return to delete"));
  List.iter (fun f ->
    if Sys.file_exists f then
      if (Unix.stat f).Unix.st_size = 0 then Sys.remove f
      else other (f ^ ": not empty after sealing"))
    [Filename.remove_extension path ^ ".db-log"; path ^ "-wal"];
  (* Only an index of a WAL that is gone; some SQLite builds leave it behind. *)
  if Sys.file_exists (path ^ "-shm") then Sys.remove (path ^ "-shm")

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

let transaction c work =
  let begin_ = if c.conn_mvcc then "BEGIN CONCURRENT" else "BEGIN IMMEDIATE" in
  let rollback () = try exec c "ROLLBACK" with Error _ -> () in
  let rec attempt delay =
    match
      exec c begin_;
      let result = work () in
      exec c "COMMIT";
      result
    with
    | result -> result
    | exception Error { kind = Conflict; _ } when c.conn_mvcc ->
        rollback ();
        Unix.sleepf delay;
        attempt (Float.min 0.25 (delay *. 2.))
    | exception e ->
        rollback ();
        raise e in
  attempt 0.001
