(* Turso through firstpair-tursolite-sdk. *)
module S = Tursolite_sdk
let available = true
type database = S.database
type connection = S.connection
let version = S.version
let open_database = S.open_database
let connect = S.connect
let to_sdk = function
  | Types.Null -> S.Null | Types.Integer n -> S.Integer n | Types.Real x -> S.Real x
  | Types.Text s -> S.Text s | Types.Blob s -> S.Blob s
let of_sdk = function
  | S.Null -> Types.Null | S.Integer n -> Types.Integer n | S.Real x -> Types.Real x
  | S.Text s -> Types.Text s | S.Blob s -> Types.Blob s
let execute c sql params =
  List.map (Array.map of_sdk) (S.execute c sql (Array.map to_sdk params))
let close_connection = S.close_connection
let close_database = S.close_database
