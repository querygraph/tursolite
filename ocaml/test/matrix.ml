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
let raises f = match f () with _ -> None | exception Failure m -> Some m

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
    disconnect c; close db;
    check (count p = 1) "sealed";
    (* Sealed only as far as WAL when asked: what dng-compare's archives do. *)
    let p = path "kept.sqlar" in
    let db = open_database ~engine:Turso ~journal:Mvcc ~seal:Sealed_wal p in
    let c = connect db in
    exec c schema;
    transaction c (fun () -> run c "INSERT INTO t VALUES ('a', 1, x'00')" []);
    disconnect c; close db;
    check ((Option.get (inspect p)).write_version = 2) "a WAL file";
    let db = open_database ~engine:Turso ~journal:Mvcc ~seal:Sealed_wal p in
    let c = connect db in
    check (query c "SELECT count(*) FROM t" [] = [ [| Integer 1L |] ]) "and reopens";
    disconnect c; close db;
    (* A journal left as it is found. *)
    let p = path "existing.db" in
    write ~engine:Sqlite ~journal:Wal p 0 1;
    write ~engine:Sqlite ~journal:Existing p 1 2;
    check ((Option.get (inspect p)).write_version = 2) "Existing keeps WAL";
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
