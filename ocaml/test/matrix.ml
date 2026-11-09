(* Every engine and journal, the files they leave, and the guards between
   them: the OCaml side of tests/matrix.rs. *)
open Tursolite

let checks = ref 0
let check ok what = if not ok then (prerr_endline ("FAIL: " ^ what); exit 1); incr checks
let dir = Filename.temp_dir "tursolite-ml" ""
let path n = Filename.concat dir n
let schema = "CREATE TABLE IF NOT EXISTS t(name TEXT PRIMARY KEY, n INT, data BLOB)"

let write ?engine ?journal ?auto_vacuum p first last =
  let db = open_database ?engine ?journal ?auto_vacuum ~page_size:65536 p in
  let c = connect db in
  exec c schema;
  transaction c (fun () ->
    for i = first to last - 1 do
      run c "INSERT INTO t VALUES (?, ?, ?)"
        [Text (Printf.sprintf "r%d" i); Integer (Int64.of_int i); Blob (String.make 70000 (Char.chr (i land 255)))]
    done);
  disconnect c; close db

let count ?(engine = Sqlite) p =
  let db = open_database ~engine ~read_only:true ~create:false p in
  let c = connect db in
  let n = match query c "SELECT count(*) FROM t" [] with [ [| Integer n |] ] -> Int64.to_int n | _ -> -1 in
  disconnect c; close db; n

let bytes p = In_channel.with_open_bin p In_channel.input_all
let raises f = match f () with _ -> None | exception Error { message; _ } -> Some message
let kind f = match f () with _ -> None | exception Error { kind; _ } -> Some kind

let () =
  List.iter (fun (n, j) ->
    let p = path n in
    write ~engine:Sqlite ~journal:j p 0 3;
    check (count p = 3) (n ^ ": rows");
    check ((Option.get (inspect p)).page_size = 65536) (n ^ ": page size"))
    ["delete.db", Delete; "wal.db", Wal];
  let p = path "fallback.db" in
  write ~engine:Sqlite ~journal:Mvcc p 0 1;
  check ((Option.get (inspect p)).write_version = 1) "MVCC falls to a rollback journal";
  (* Typed rows, iteration, cached statements, error kinds and immutable opens. *)
  let p = path "typed x?#%.db" in
  let db = open_database p in
  let c = connect db in
  exec c schema;
  run c "INSERT INTO t VALUES (?, ?, ?)" [Text "a"; Integer 1L; Blob "\000\255"];
  run c "INSERT INTO t VALUES (?, ?, ?)" [Text "b"; Null; Null];
  check (last_insert_rowid c = 2L) "last_insert_rowid";
  check (as_int (query_value c "SELECT count(*) FROM t" []) = 2) "query_value";
  check (as_option as_int64 (query_value c "SELECT n FROM t WHERE name = 'b'" []) = None) "as_option";
  check (as_string (query_value c "SELECT data FROM t WHERE name = ?" [Text "a"]) = "\000\255") "a blob";
  check (query_one c "SELECT 1 FROM t WHERE name = 'z'" [] = None) "query_one";
  check (fold c "SELECT name FROM t ORDER BY name" [] ~init:[] (fun acc r -> as_string r.(0) :: acc) = ["b"; "a"]) "fold";
  let seen = ref 0 in
  iter c "SELECT name FROM t" [] (fun _ ->
    (* The same SQL while its statement is in use. *)
    seen := !seen + List.length (query c "SELECT name FROM t" []));
  check (!seen = 4) "iter, nested";
  let r = query_rows c "SELECT name, n AS number FROM t ORDER BY name" [] in
  check (r.columns = [| "name"; "number" |] && column r "number" = 1) "column names";
  check ((query_rows c "SELECT name AS who FROM t WHERE 0" []).columns = [| "who" |]) "column names, no rows";
  check (kind (fun () -> run c "INSERT INTO t VALUES ('a', 2, NULL)" []) = Some Constraint) "a constraint";
  disconnect c; close db;
  let db = open_database ~immutable:true ~create:false p in
  let c = connect db in
  check (as_int (query_value c "SELECT count(*) FROM t" []) = 2) "immutable reads";
  check (kind (fun () -> run c "DELETE FROM t" []) = Some Read_only) "immutable refuses a write";
  disconnect c; close db;
  let junk = path "junk.db" in
  Out_channel.with_open_bin junk (fun oc -> output_string oc (String.make 200 'x'));
  check (kind (fun () -> open_database junk) = Some Not_a_database) "not a database";
  let p = path "stock.sqlar" in
  write ~engine:Sqlite ~auto_vacuum:true p 0 2;
  check (Option.get (inspect p)).auto_vacuum "auto-vacuum set";
  if available Turso then begin
    let before = bytes p in
    List.iter (fun j ->
      match raises (fun () -> write ~engine:Turso ~journal:j p 2 3) with
      | Some m -> check (String.length m > 0) m
      | None -> check false "Turso must refuse auto-vacuum") [Delete; Wal; Mvcc];
    check (count ~engine:Turso p = 2) "a read falls to SQLite";
    check (bytes p = before) "nothing asked of Turso touched the file";
    List.iter (fun (n, j) ->
      let p = path (n ^ ".sqlar") in
      write ~engine:Turso ~journal:j p 0 5;
      let h = Option.get (inspect p) in
      check ((h.write_version, h.read_version, h.page_size, h.auto_vacuum) = (1, 1, 65536, false)) (n ^ ": a standard file");
      check (Array.for_all (fun f -> not (String.starts_with ~prefix:n f) || Filename.check_suffix f ".sqlar") (Sys.readdir dir))
        (n ^ ": no companions left");
      check (count p = 5 && count ~engine:Turso p = 5) (n ^ ": both engines read it");
      write ~engine:Sqlite p 5 6;
      write ~engine:Turso ~journal:j p 6 7;
      check (count p = 7) (n ^ ": both engines write it"))
      ["sealed-wal", Delete; "sealed-mvcc", Mvcc];
    (* Reading with Turso leaves a standard file alone. *)
    let p = path "readonly.sqlar" in
    write ~engine:Sqlite p 0 3;
    let before = bytes p in
    check (count ~engine:Turso p = 3) "Turso reads";
    check (bytes p = before) "and leaves the bytes alone";
    (* An unsealed file: only Turso opens it, and closing seals it. *)
    let p = path "unsealed.sqlar" in
    let db = open_database ~engine:Turso ~journal:Mvcc ~page_size:65536 p in
    let c = connect db in
    exec c schema;
    transaction c (fun () -> run c "INSERT INTO t VALUES ('a', 1, x'00')" []);
    exec c "PRAGMA wal_checkpoint(TRUNCATE)";
    check (is_mvcc (Option.get (inspect p))) "in MVCC mode";
    check (resolve p Sqlite ~read_only:false = Turso) "an MVCC file resolves to Turso";
    check (kind (fun () -> open_database ~immutable:true p) = Some Refused) "no immutable open unsealed";
    check (kind (fun () -> run c "INSERT INTO t VALUES ('a', 2, NULL)" []) = Some Constraint) "a Turso constraint";
    check ((query_rows c "SELECT name AS who, n FROM t" []).columns = [| "who"; "n" |]) "Turso column names";
    disconnect c; close db;
    check (count p = 1) "sealed";
    (* Sealed only as far as WAL when asked: what dng-compare's archives do. *)
    let p = path "kept.sqlar" in
    let db = open_database ~engine:Turso ~journal:Mvcc ~seal:Keep_wal p in
    let c = connect db in
    exec c schema;
    transaction c (fun () -> run c "INSERT INTO t VALUES ('a', 1, x'00')" []);
    disconnect c; close db;
    check ((Option.get (inspect p)).write_version = 2) "a WAL file";
    let db = open_database ~engine:Turso ~journal:Mvcc ~seal:Keep_wal p in
    let c = connect db in
    check (query c "SELECT count(*) FROM t" [] = [ [| Integer 1L |] ]) "and reopens";
    disconnect c; close db;
    (* A journal left as it is found. *)
    let p = path "existing.db" in
    write ~engine:Sqlite ~journal:Wal p 0 1;
    write ~engine:Sqlite ~journal:Existing p 1 2;
    check ((Option.get (inspect p)).write_version = 2) "Existing keeps WAL";
    (* WITHOUT ROWID: refused by Turso without the flag; with it, sealed to a
       standard file that SQLite reads immutably. *)
    let p = path "without-rowid.sqlar" in
    let table = "CREATE TABLE w(k TEXT PRIMARY KEY, v BLOB) WITHOUT ROWID" in
    let db = open_database ~engine:Turso p in
    let c = connect db in
    check (raises (fun () -> exec c table) <> None) "WITHOUT ROWID needs the flag";
    disconnect c; close db; Sys.remove p;
    let db = open_database ~engine:Turso ~experimental:[Without_rowid] p in
    let c = connect db in
    exec c table;
    transaction c (fun () ->
      for i = 0 to 1999 do
        run c "INSERT INTO w VALUES (?, ?)" [Text (Printf.sprintf "k%05d" i); Blob (String.make 300 'w')]
      done);
    disconnect c; close db;
    let db = open_database ~immutable:true ~create:false p in
    let c = connect db in
    check (query_value c "PRAGMA integrity_check" [] = Text "ok") "WITHOUT ROWID: integrity";
    check (as_int (query_value c "SELECT count(*) FROM w" []) = 2000) "WITHOUT ROWID: rows";
    disconnect c; close db;
    check (kind (fun () -> open_database ~experimental:[Without_rowid] (path "s.db")) = Some Refused)
      "experimental features refused for SQLite";
    (* Four domains writing one database, sharing one row. *)
    let p = path "concurrent.sqlar" in
    let db = open_database ~engine:Turso ~journal:Mvcc ~page_size:65536 p in
    let c = connect db in
    exec c schema;
    exec c "CREATE TABLE e(k TEXT PRIMARY KEY, v INT); INSERT INTO e VALUES ('epoch', 0)";
    let writer k =
      let c = connect db in
      for b = 0 to 9 do
        transaction c (fun () ->
          for i = 0 to 4 do
            run c "INSERT OR REPLACE INTO t VALUES (?, ?, ?)"
              [Text (Printf.sprintf "%d-%d-%d" k b i); Integer 1L; Blob (String.make 70000 'x')]
          done);
        transaction c (fun () -> run c "UPDATE e SET v = v + 1 WHERE k = 'epoch'" [])
      done;
      disconnect c in
    let spawn = (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"]) in
    List.iter Domain.join (List.init 4 (fun k -> spawn (fun () -> writer k)));
    check (query c "SELECT count(*) FROM t" [] = [ [| Integer 200L |] ]) "200 rows";
    check (query c "SELECT v FROM e" [] = [ [| Integer 40L |] ]) "40 epochs";
    disconnect c; close db;
    check (count p = 200) "sealed"
  end else
    check (raises (fun () -> open_database ~engine:Turso (path "x")) <> None) "Turso refused when not linked";
  Printf.printf "PASS%d tursolite matrix (%s)\n" !checks (if available Turso then "sqlite and turso" else "sqlite only")
