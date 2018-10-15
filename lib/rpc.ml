open Batteries

open Types
    
module Http_client = Nethttp_client

let debug_flag = ref true

let switch_debug () =
  debug_flag := not !debug_flag
      
let print_debug s =
  ignore s;
  if !debug_flag then
    ()
    (* print_endline s *)
  else
    ()

let rpc_call uri method_name (params : Json.json) =
  let open Yojson.Safe in
  let json : Json.json =
    `Assoc [ ("jsonrpc", `String "2.0");
             ("method", `String method_name);
             ("params", params);
             ("id", `Int 0); (* TODO: this sould be a UID *)
           ]
  in
  let data = Yojson.Safe.to_string json in
  print_debug (Printf.sprintf "Rpc.call: raw request =\n%s\n" data);
  let req = new Http_client.post_raw uri data in
  req#set_req_header "Content-type" "application/json";
  let pipeline = new Http_client.pipeline in
  pipeline#add_with_callback req @@
  (fun call -> match call#response_status with
     | `Ok -> ()
     | `Bad_request ->
       print_debug call#response_body#value;
       let j = Json.from_string call#response_body#value in
       j |> Json.drop_assoc |> List.assoc "message"
         |> Json.drop_string |> print_endline;
     | _ ->
       print_debug call#response_status_text;
       print_debug call#response_body#value
  );
  pipeline#run ();
  let (ans: string) = req#get_resp_body () in
  print_debug ans;
  Json.from_string ans

(* https://github.com/ethereum/wiki/wiki/JSON-RPC#json-rpc-api-reference *)

module Get = Json.GetExn

module Net =
struct

  let version ~uri =
    rpc_call uri "net_version" `Null
      
  let listening ~uri =
    rpc_call uri "net_listening" `Null

  let peer_count ~uri =
    rpc_call uri "net_peerCount" `Null    
  
end

module Eth =
struct

  type time =
    [`block of int | `latest | `earliest | `pending]

  let time_to_json (at_time : time) =
    match at_time with
    | `block i  ->
      let s = Printf.sprintf "0x%x" i in
      `String s
    | `latest   -> `String "latest"
    | `earliest -> `String "earliest"
    | `pending  -> `String "pending"    
                       
  let protocol_version ~uri =
    rpc_call uri "eth_protocolVersion" `Null |> Get.int_as_string
  
  let syncing ~uri =
    rpc_call uri "eth_syncing" `Null |> Get.bool

  let coinbase ~uri =
    rpc_call uri "eth_coinbase" `Null |> Get.string |> Address.from_string

  let mining ~uri =
    rpc_call uri "eth_mining" `Null |> Get.bool

  let hashrate ~uri =
    rpc_call uri "eth_hashrate" `Null |> Get.bigint_as_string

  let gas_price ~uri =
    rpc_call uri "eth_gasPrice" `Null |> Get.bigint_as_string

  let accounts ~uri =
    rpc_call uri "eth_accounts" `Null
    |> Get.string_list
    |> List.map Address.from_string

  let block_number ~uri =
    rpc_call uri "eth_blockNumber" `Null |> Get.int_as_string

  let get_balance ~uri ~address ~(at_time : time) =
    let time = time_to_json at_time in
    let params = `List [ `String (Address.show address); time ] in
    rpc_call uri "eth_getBalance" params |> Get.bigint_as_string

  let get_storage_at ~uri ~address ~position ~(at_time : time) =
    let time = time_to_json at_time in
    let params = `List [ `String (Address.show address); `String (Z.to_string position); time ] in
    rpc_call uri "eth_getStorageAt" params |> Get.string

  let get_transaction_count ~uri ~address ~(at_time : time) =
    let time = time_to_json at_time in
    let params = `List [ `String (Address.show address); time ] in
    rpc_call uri "eth_getTransactionCount" params |> Get.int

  let get_transaction_count_by_hash ~uri ~block_hash =
    let args = `List [`String (Hash256.show block_hash)] in
    rpc_call uri "eth_getTransactionCountByHash" args |> Get.int

  let get_transaction_count_by_number ~uri ~(at_time : time) =
    let args = `List [time_to_json at_time] in
    rpc_call uri "eth_getTransactionCountByNumber" args |> Get.int

  (* eth_getUncleCountByBlockHash, eth_getUncleCountByBlockNumber *)

  let get_code ~uri ~address ~(at_time : time) =
    let params = `List [ `String (Address.show address); time_to_json at_time ] in
    rpc_call uri "eth_getCode" params |> Get.string (* TODO: it would be nice to parse it back to bytecode *)

  let get_block_by_hash ~uri ~block_hash =
    let params = `List [ `String (Hash256.show block_hash) ] in
    rpc_call uri "eth_getBlockByHash" params
    |> Get.result
    |> Json.maybe Block.from_json

  let get_block_by_number ~uri ~at_time =
    let params = `List [ time_to_json at_time; `Bool true ] in
    rpc_call uri "eth_getBlockByNumber" params
    |> Get.result
    |> Json.maybe Block.from_json
  
  let sign ~uri ~address ~message =
    rpc_call uri "eth_sign" (`List [`String (Address.show address); `String message]) |> Get.string

  let send_transaction ~uri ~transaction =
    let args = `List [Tx.to_json transaction] in
    rpc_call uri "eth_sendTransaction" args |> Get.string |> Hash256.from_string
      
  let send_raw_transaction ~uri ~data =
    let args = `List [`String data] in
    rpc_call uri "eth_sendRawTransaction" args |> Get.string  |> Hash256.from_string

  let call ~uri ~transaction ~(at_time : time) =
    rpc_call uri "eth_call" (`List [ Tx.to_json transaction; time_to_json at_time ]) |> Get.string

  let estimate_gas ~uri ~transaction ~(at_time : time) =
    rpc_call uri "eth_estimateGas" (`List [ Tx.to_json transaction; time_to_json at_time ]) |> Get.int

  (* getBlockByHash/byNumber, etc *)
  (* getTransactionReceipt *)
  let get_transaction_receipt ~uri ~transaction_hash =
    rpc_call uri "eth_getTransactionReceipt" (`List [ `String (Hash256.show transaction_hash) ])
    |> Get.result
    |> Tx.receipt_from_json

  let send_transaction_and_get_receipt ~uri ~transaction =
    let hash = send_transaction ~uri ~transaction in
    let rec loop () =
      match get_transaction_receipt ~uri ~transaction_hash:hash with
      | None ->
        Unix.sleep 2; loop ()
      | Some receipt ->
        receipt
      | exception err ->
        Printf.eprintf "send_transaction_and_get_receipt: error in get_transaction_receipt\n";
        raise err
    in
    loop ()

  let send_contract_and_get_receipt ~uri ~src ~data ~gas () =
    let open Tx in
    let tx =
      {
        src;
        dst   = None;
        gas   = Some gas;
        gas_price = None;
        value = None;
        data  = Bitstr.Hex.as_string data;
        nonce = None
      }
    in
    send_transaction_and_get_receipt ~uri ~transaction:tx

  let send_contract_and_get_receipt ~uri ~src ~data ~gas ?value () =
    let open Tx in
    let tx =
      {
        src;
        dst   = None;
        gas   = Some gas;
        gas_price = None;
        value;
        data  = Bitstr.Hex.as_string data;
        nonce = None
      }
    in
    send_transaction_and_get_receipt ~uri ~transaction:tx
  
end

module EthLwt =
struct

    let send_transaction_and_get_receipt ~uri ~transaction =
    let hash = Eth.send_transaction ~uri ~transaction in
    let rec loop () =
      match Eth.get_transaction_receipt ~uri ~transaction_hash:hash with
      | None ->
        Lwt_unix.sleep 2.0;%lwt
        loop ()
      | Some receipt ->
        Lwt.return receipt
      | exception err ->
        Lwt_io.eprintf "send_transaction_and_get_receipt: error in get_transaction_receipt\n";%lwt
        Lwt.fail err
    in
    loop ()

    let send_contract_and_get_receipt ~uri ~src ~data ~gas () =
    let open Tx in
    let tx =
      {
        src;
        dst   = None;
        gas   = Some gas;
        gas_price = None;
        value = None;
        data  = Bitstr.Hex.as_string data;
        nonce = None
      }
    in
    send_transaction_and_get_receipt ~uri ~transaction:tx
  
end
  
module Personal =
struct

  let send_transaction ~uri ~src ~dst ~value ~src_pwd =
    (* let value = Bitstr.(hex_as_string (hex_of_bigint value)) in *)
    let args  =
        `List [`Assoc [ ("from", `String (Address.show src));
                        ("to", `String (Address.show dst));
                        ("value", Json.zhex value) ];
               `String src_pwd
              ]
    in
    rpc_call uri "personal_sendTransaction" args
    |> Get.string
    |> Hash256.from_string

  let new_account ~uri ~passphrase =
    let args  = `List [`String passphrase] in
    rpc_call uri "personal_newAccount" args
    |> Get.string
    |> Address.from_string

  let unlock_account ~uri ~account ~passphrase ~unlock_duration =
    let args  =
      `List[`String (Address.show account); `String passphrase; `Int unlock_duration]
    in
    assert (rpc_call uri "personal_unlockAccount" args |> Get.bool)
  
end

module Miner =
struct

  let set_gas_price ~uri ~gas_price =
    rpc_call uri "miner_setGasPrice" (`List [ Json.zhex gas_price ]) |> Get.bool

  let start ~uri ~thread_count =
    let args = `Int thread_count in
    rpc_call uri "miner_start" (`List [args]) |> Get.null

  let stop ~uri =
    rpc_call uri "miner_stop" `Null |> Get.bool

  let set_ether_base ~uri ~address =
    let args = `List [`String (Address.show address)] in
    rpc_call uri "miner_setEtherbase" args |> Get.bool

end

module Admin =
struct

  let add_peer ~uri ~peer_url =
    rpc_call uri "admin_addPeer" (`List [`String peer_url]) |> Get.bool

  let datadir ~uri =
    rpc_call uri "admin_datadir" `Null |> Get.string
      
  let node_info ~uri =
    rpc_call uri "admin_nodeInfo" `Null |> Get.result |> Types.node_info_from_json

  let peers ~uri =
    rpc_call uri "admin_peers" `Null |> Get.result |> Types.peer_info_from_json

end

module Debug =
struct

  let dump_block ~uri ~block_number =
    let bnum = Printf.sprintf "0x%x" block_number in
    rpc_call uri "debug_dumpBlock" (`List [`String bnum])
    |> Get.result
    |> Types.block_from_json
  
end
