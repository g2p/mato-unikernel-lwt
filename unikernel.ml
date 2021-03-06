open Lwt.Infix

module type INFO = sig
  val sector_size : int
end

module MakeOps(S: Mirage_stack_lwt.V4)(B: Mirage_types_lwt.BLOCK)(Info: INFO) = struct
  let align i n = (i + n - 1) / n * n

  let alloc_sector len = Cstruct.create (align len 512)

  let sector_of_int i =
    let j = `Assoc [ ("magic", `Int 31337); ("counter", `Int i) ] in
    let s = Yojson.Basic.to_string j in
    let buf' = Cstruct.of_string ~allocator:alloc_sector s in
    Cstruct.set_len buf' 512

  let int_of_sector buf =
    let s = Cstruct.to_string buf in
    let s' = String.sub s 0 (String.index s '\000') in
    let j = Yojson.Basic.from_string s' in
    let open Yojson.Basic.Util in
    let magic = j |> member "magic" |> to_int_option in
    match magic with
      | Some 31337 -> j |> member "counter" |> to_int
      | _ -> raise (Failure "bad magic")

  let cstruct_of_int i =
    Cstruct.of_string (Fmt.strf "%d\n" i)

  let log_new flow =
    let dst, dst_port = S.TCPV4.dst flow in
    Logs.info (fun f -> f "[%a:%d] New connection"
                Ipaddr.V4.pp dst dst_port)

  let log_write_err flow e =
    let dst, dst_port = S.TCPV4.dst flow in
    Logs.warn (fun f -> f "[%a:%d] Write error: %a, closing connection"
                Ipaddr.V4.pp dst dst_port S.TCPV4.pp_write_error e)

  let log_block_read_err e = 
    Logs.err (fun f -> f "Block read error: %a" B.pp_error e)

  let log_block_write_err e =
    Logs.err (fun f -> f "Block write error: %a" B.pp_write_error e)
  
  let log_closing flow =
    let dst, dst_port = S.TCPV4.dst flow in
    Logs.info (fun f -> f "[%a:%d] Closing connection"
                Ipaddr.V4.pp dst dst_port)
  
  let store_counter block counter flow =
    let buf = sector_of_int counter in 
    B.write block Int64.zero [ buf ] >>= function
    | Error e -> log_block_write_err e; S.TCPV4.close flow
    | Ok ()   -> log_closing flow; S.TCPV4.close flow
 
  let write_response block counter flow =
    let counter' = counter + 1 in
    S.TCPV4.write flow (cstruct_of_int counter') >>= function
    | Error e -> log_write_err flow e; S.TCPV4.close flow
    | Ok ()   -> store_counter block counter' flow
 
  let load_counter block flow =
    let buf = alloc_sector 1 in
    B.read block Int64.zero [ buf ] >>= function
    | Error e -> log_block_read_err e; S.TCPV4.close flow
    | Ok ()   -> write_response block (int_of_sector buf) flow

  let hello = Cstruct.of_string "Hello\n"

  let start_request block flow =
    log_new flow;
    S.TCPV4.write flow hello >>= function
    | Error e -> log_write_err flow e; S.TCPV4.close flow
    | Ok ()   -> load_counter block flow
  
  let initialize block =
    let buf = sector_of_int 0 in 
    B.write block Int64.zero [ buf ] >>= function
    | Error e -> log_block_write_err e; Lwt.return_unit
    | Ok ()   -> (
      Logs.info (fun m -> m "Successfully initialised block device");
      Lwt.return_unit
    )
end

module Main (S: Mirage_stack_lwt.V4)(B: Mirage_types_lwt.BLOCK) = struct
  let start s b : unit Lwt.t =
    B.get_info b >>= fun binfo ->
    let module Info: INFO = struct
      let sector_size = binfo.sector_size
    end in
    let module Ops = MakeOps(S)(B)(Info) in
    Logs.info (fun m -> m "Sector size %d" binfo.sector_size);
    if Key_gen.init () then Ops.initialize b else (
      let port = Key_gen.port () in
      Logs.info (fun m -> m "Listening on [%a:%d]"
                    Fmt.(list Ipaddr.V4.pp) (S.(IPV4.get_ip @@ ipv4 s)) port);
      S.listen_tcpv4 s ~port (Ops.start_request b);
      S.listen s
    )
end
