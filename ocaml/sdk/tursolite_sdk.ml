(* Direct in-process Turso C ABI binding. *)
type database
type connection
type value = Null | Integer of int64 | Real of float | Text of string | Blob of string

external version : unit -> string = "tursolite_version"
external open_database : string -> bool -> database = "tursolite_open"
external connect : database -> int -> connection = "tursolite_connect"
external execute : connection -> string -> value array -> value array list = "tursolite_execute"
external close_connection : connection -> unit = "tursolite_close_connection"
external close_database : database -> unit = "tursolite_close_database"
