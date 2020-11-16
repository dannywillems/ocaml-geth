open Geth
open Contract

val deploy_rpc :
  uri:string ->
  account:Types.Address.t ->
  contract:Compile.solidity_output ->
  arguments:ABI.value list ->
  ?gas:Z.t ->
  ?value:Z.t ->
  unit ->
  Types.Tx.receipt Lwt.t

val call_method_tx :
  uri:string ->
  abi:ABI.method_abi ->
  arguments:ABI.value list ->
  src:Types.Address.t ->
  ctx:Types.Address.t ->
  ?gas:Z.t ->
  ?value:Z.t ->
  unit ->
  Types.Tx.t Lwt.t

val call_void_method_tx :
  mname:string ->
  src:Types.Address.t ->
  ctx:Types.Address.t ->
  ?gas:Z.t ->
  unit ->
  Types.Tx.t Lwt.t

val execute_method :
  uri:string ->
  abi:ABI.method_abi ->
  arguments:ABI.value list ->
  src:Types.Address.t ->
  ctx:Types.Address.t ->
  ?gas:Z.t ->
  ?value:Z.t ->
  unit ->
  Types.Tx.receipt Lwt.t

val call_method :
  uri:string ->
  abi:ABI.method_abi ->
  arguments:ABI.value list ->
  src:Types.Address.t ->
  ctx:Types.Address.t ->
  ?gas:Z.t ->
  ?value:Z.t ->
  unit ->
  string Lwt.t