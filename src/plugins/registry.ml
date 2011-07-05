class type user_db = 
object 
  method set : string -> string -> unit
  method get : string -> string
  method delete: string -> unit
end

module Registry = struct
  type f = user_db -> string option -> string option
  let _r = Hashtbl.create 42
  let register name (f:f) = Hashtbl.replace _r name f
  let lookup name = Hashtbl.find _r name
end