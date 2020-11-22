open Bitstring
open Types
module ST = SolidityTypes

type t = {t: SolidityTypes.t; v: value}

and value =
  | Int of Z.t
  | Bool of bool
  | String of string
  | Address of Address.t
  | Tuple of t list
  | Func of {selector: string; address: Address.t}

let pack where s =
  match String.length s with
  | 0 -> zeroes_bitstring 32
  | len -> (
    match len mod 32 with
    | 0 -> bitstring_of_string s
    | rem -> (
        let pad = 32 - rem in
        match where with
        | `Front -> concat [zeroes_bitstring pad; bitstring_of_string s]
        | `Back -> concat [bitstring_of_string s; zeroes_bitstring pad] ) )

let address (s : Address.t) =
  String.init 32 (fun i -> if i < 12 then '\x00' else (s :> string).[i - 12])
  |> bitstring_of_string

let int x =
  let%bitstring x = {|x: 31|} in
  let pad = zeroes_bitstring (256 - bitstring_length x) in
  concat [pad; x]

let z x =
  let len = Z.numbits x in
  assert (len < 257) ;
  let bs = Bitstring.zeroes_bitstring len in
  for i = 0 to len - 1 do
    if Z.testbit x i then Bitstring.set bs i
  done ;
  let pad = 256 - len in
  concat [zeroes_bitstring pad; bs]

let rec encode x =
  match (x.v, x.t) with
  | Int v, ST.UInt _ when Z.sign v > 0 -> z v
  | Int v, Int _ -> z v
  | Bool true, Bool -> int 1
  | Bool false, Bool -> int 0
  | Address v, Address -> address v
  | String v, NBytes _ -> pack `Back v
  | String v, String | String v, Bytes ->
      Bitstring.concat [int (String.length v); pack `Back v]
  | Tuple values, Tuple typs ->
      let encode_heads x offset =
        if not (ST.is_dynamic x.t) then encode x else int offset in
      let encode_tails x =
        if not (ST.is_dynamic x.t) then zeroes_bitstring 0 else encode x in
      let header_size typs =
        let header_size_of_type typ =
          let open ST in
          match typ with
          | SArray (length, _) when not (ST.is_dynamic typ) -> 32 * length
          | Tuple typs when not (ST.is_dynamic typ) -> 32 * List.length typs
          | _ -> 32 in
        List.fold_left (fun acc typ -> acc + header_size_of_type typ) 0 typs
      in
      (* The types are implicitly contained in the values. *)
      (* compute size of header *)
      let headsz = header_size typs in
      (* convert tail values to bitstrings (possibly empty if not dynamic) *)
      let tails = List.map encode_tails values in
      (* for each value, compute where its dynamic data is stored as an offset,
         taking into account header size. *)
      let _, offsets =
        List.fold_left
          (fun (offset, acc) bitstr ->
            let byte_len = bitstring_length bitstr / 8 in
            let next_offset = offset + byte_len in
            (next_offset, offset :: acc))
          (headsz, []) tails in
      let offsets = List.rev offsets in
      let heads = List.map2 encode_heads values offsets in
      concat (heads @ tails)
  | _ ->
      (* TODO: static/dynamic arrays *)
      failwith "encode: error"

(* -------------------------------------------------------------------------------- *)
(* Convenience functions to create ABI values *)

let notstring =
  CCString.map (fun c ->
      CCChar.to_int c |> lnot |> Int.logand 0xff |> CCChar.of_int_exn)

let unsigned b = string_of_bitstring b |> CCString.rev |> Z.of_bits

let signed b =
  string_of_bitstring b |> CCString.rev |> notstring |> Z.of_bits |> Z.add Z.one
  |> Z.neg

let int w z = {v= Int z; t= ST.int w}
let uint w z = {v= Int z; t= ST.uint w}
let uint256 z = {v= Int z; t= ST.uint 256}
let string v = {v= String v; t= ST.string}
let bytes v = {v= String v; t= ST.bytes}
let bool v = {v= Bool v; t= ST.Bool}
let address v = {v= Address v; t= ST.address}
let tuple vals = {v= Tuple vals; t= ST.Tuple (List.map (fun v -> v.t) vals)}
let static_array vals t = {v= Tuple vals; t= ST.SArray (List.length vals, t)}
let dynamic_array vals t = {v= Tuple vals; t= ST.DArray t}

let rec decode b t =
  (* Printf.eprintf "decoding %s with data %s\n" (ST.print t) (Bitstr.Hex.as_string (Bitstr.uncompress b)); *)
  match (t : ST.t) with
  | UInt w -> uint w (unsigned b)
  | Int w -> int w (signed b)
  | Address ->
      address (Address.of_binary (subbitstring b 12 20 |> string_of_bitstring))
  | Bool -> bool (get b 255 <> 0)
  | Fixed _ | UFixed _ ->
      failwith "decode_atomic: fixed point numbers not handled yet"
  | NBytes n -> bytes (String.sub (string_of_bitstring b) 0 n)
  | Bytes ->
      let n = takebits 256 b |> unsigned |> Z.to_int in
      let b = dropbits 256 b in
      bytes (String.sub (string_of_bitstring b) 0 n)
  | String ->
      let n = takebits 256 b |> unsigned |> Z.to_int in
      let b = dropbits 256 b in
      string (String.sub (string_of_bitstring b) 0 n)
  | Function ->
      let address = takebits 160 b |> string_of_bitstring |> Address.of_binary in
      let selector = takebits 32 (dropbits 160 b) |> string_of_bitstring in
      {v= Func {selector; address}; t= ST.Function}
  | SArray (n, t) -> static_array (decode_tuple b (List.init n (fun _ -> t))) t
  | DArray t ->
      let n = takebits 256 b |> unsigned |> Z.to_int in
      let b = dropbits 256 b in
      dynamic_array (decode_tuple b (List.init n (fun _ -> t))) t
  | Tuple typs -> tuple (decode_tuple b typs)

and decode_tuple b typs =
  (* Printf.eprintf "decoding tuple %s with data = %s\n"  *)
  (*   (ST.print (ST.Ttuple typs))
   *   (Bitstr.Hex.to_string (Bitstr.uncompress b))
   * ; *)
  let _, values =
    List.fold_left
      (fun (header_chunk, values) ty ->
        let chunk = takebits 256 header_chunk in
        let rem = dropbits 256 header_chunk in
        if ST.is_dynamic ty then
          let offset = unsigned chunk in
          let offset = Z.to_int offset in
          (* offsets are computed starting from the beginning of [b] *)
          let tail = dropbits (offset * 8) b in
          let value = decode tail ty in
          (rem, value :: values)
        else
          let value = decode chunk ty in
          (rem, value :: values))
      (b, []) typs in
  List.rev values
