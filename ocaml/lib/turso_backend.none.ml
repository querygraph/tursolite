(* Built without firstpair-tursolite-sdk: SQLite only. *)
let available = false
type database = unit
type connection = unit
exception Failed of int * string
let absent () = raise (Failed (128, "this build does not link Turso"))
let version () = absent ()
let open_database (_ : string) (_ : bool) (_ : string) : database = absent ()
let connect (_ : database) (_ : int) : connection = absent ()
let execute (_ : connection) (_ : string) (_ : Types.value array) : string array * Types.value array list =
  absent ()
let close_connection (_ : connection) = ()
let close_database (_ : database) = ()
