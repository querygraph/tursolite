(* Direct in-process Turso C ABI binding. *)
type database
type connection
type value = Null | Integer of int64 | Real of float | Text of string | Blob of string

(* A Turso status code (see turso.h) and its message. *)
exception Turso_error of int * string
let () =
  (Callback.register_exception [@alert "-unsafe_multidomain"]) "tursolite_sdk_error" (Turso_error (0, ""))

external version : unit -> string = "tursolite_version"
(* [open_database path read_only features]: [features] is Turso's comma
   separated list of experimental features, or "". *)
external open_database : string -> bool -> string -> database = "tursolite_open"
external connect : database -> int -> connection = "tursolite_connect"
(* The column names and the rows. *)
external execute : connection -> string -> value array -> string array * value array list = "tursolite_execute"
external close_connection : connection -> unit = "tursolite_close_connection"
external close_database : database -> unit = "tursolite_close_database"
