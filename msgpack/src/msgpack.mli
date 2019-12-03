open Base
module Message : module type of Message

module Internal : sig
  module Parser : module type of Parser
  module Serializer : module type of Serializer
end

module Custom : sig
  type t = Message.custom =
    { type_id : int
    ; data : Bytes.t
    }
  [@@deriving sexp, equal]
end

type t = Message.t =
  | Nil
  | Integer of int
  | Int64 of Int64.t
  | UInt64 of Int64.t
  | Boolean of bool
  | Floating of float
  | Array of t list
  | Map of (t * t) list
  | String of string
  | Binary of Bytes.t
  | Extension of Custom.t
[@@deriving sexp, equal]

val t_of_string : string -> t Or_error.t
val t_of_string_exn : string -> t
val string_of_t_exn : ?bufsize:int -> t -> string
