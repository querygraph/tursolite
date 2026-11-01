(* Built without firstpair-tursolite-sdk: SQLite only. *)
let available = false
type database = unit
type connection = unit
let absent () = failwith "this build does not link Turso"
let version () = absent ()
let open_database (_ : string) (_ : bool) : database = absent ()
let connect (_ : database) (_ : int) : connection = absent ()
let execute (_ : connection) (_ : string) (_ : Types.value array) : Types.value array list = absent ()
let close_connection (_ : connection) = ()
let close_database (_ : database) = ()
