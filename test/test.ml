open Lwt.Infix
open Lib_core_network

module R = Rresult.R

module Basic = Basic_backend.Make
module Vnet = Vnetif.Make(Basic)
module Eth = Ethernet.Make(Vnet)
module Arp = Arp.Make(Eth)(OS.Time)


let arp_query_pkt src_mac src_ip ip =
  let arp_t = Arp_packet.{
      operation = Arp_packet.Request;
      source_mac = src_mac;
      source_ip = src_ip;
      target_mac = Macaddr.broadcast;
      target_ip = ip
    } in
  let arp_buf = Arp_packet.encode arp_t in
  let eth_t = Ethernet_packet.{
      source = src_mac;
      destination = Macaddr.broadcast;
      ethertype = `ARP;
    } in
  let eth_buf = Ethernet_packet.Marshal.make_cstruct eth_t in
  Cstruct.concat [eth_buf; arp_buf]

let send fd buf =
  let len = Cstruct.len buf in
  Lwt_unix.write fd (Cstruct.to_bytes buf) 0 len
  >>= fun _ -> Lwt.return_unit

let create_recv_st fd =
  let recv () =
    let buf = Cstruct.create 2048 in
    Lwt_cstruct.read fd buf >>= fun len ->
    Lwt.return_some @@ Cstruct.sub buf 0 len
  in
  Lwt_stream.from recv

let assert_arp st expected =
  let to_arp_reply buf =
    match Ethernet_packet.Unmarshal.of_cstruct buf with
    | Ok (_, eth_payload) ->
        (match Arp_packet.decode eth_payload with
        | Ok _ as ok -> ok
        | Error e -> Error (Fmt.to_to_string Arp_packet.pp_error e)
        )
    | Error _ as err -> err
  in
  let rec recv () =
    Lwt_stream.get st >>= function
    | None -> Lwt.return_error "stream closed"
    | Some buf ->
        match to_arp_reply buf with
        | Error _ -> recv ()
        | Ok observed ->
            if observed = expected then Lwt.return_ok ()
            else recv ()
  in
  Lwt.catch recv (function
    | Lwt.Canceled -> Lwt.return_ok ()
    | exn -> Lwt.fail exn)


let test_mac =
  let addr = Bytes.create 6 in
  for i = 0 to 5 do
    Bytes.set addr i (char_of_int i)
  done;
  Macaddr.of_bytes_exn (Bytes.to_string addr)

let test_ip = Ipaddr.V4.of_string_exn "192.168.0.17"

let arp_query fd ip =
  let buf = arp_query_pkt test_mac test_ip ip in
  send fd buf

let init dev cidr =
  let fd, _name = Tuntap.opentap ~pi:false ~devname:dev () in
  let lwt_fd = Lwt_unix.of_unix_file_descr fd in
  let mac = Tuntap.get_macaddr dev in
  let netmask, ip = Ipaddr.V4.Prefix.of_address_string_exn cidr in
  let () = Tuntap.set_ipv4 ~netmask dev ip in

  Intf.create ~dev ~cidr >>= fun (intf, intf_starter) ->
  Lwt.async intf_starter;
  Lwt.return (intf, lwt_fd, ip, mac)

let (>>>=) = Lwt_result.(>>=)

(* test acquire_fake_ip and release_fake_ip *)
let test_intf () =
  let dev = "tap0" in
  let cidr = "192.168.0.7/24" in
  init dev cidr >>= fun (intf, fd, ip, mac) ->
  let recv_st = create_recv_st fd in

  let expected_local = Arp_packet.{
      operation = Arp_packet.Reply;
      source_mac = mac;
      source_ip = ip;
      target_mac = test_mac;
      target_ip = test_ip;
    } in

  Lwt.pick [
    (arp_query fd ip
     >>= fun () -> Lwt_unix.sleep 0.5
     >>= fun () -> Lwt.return_error "time out");
    assert_arp recv_st expected_local;
  ]

  >>>= fun () ->

  intf.Intf.acquire_fake_ip () >>= fun fake_ip ->

  let expected_fake = Arp_packet.{
      operation = Arp_packet.Reply;
      source_mac = mac;
      source_ip = fake_ip;
      target_mac = test_mac;
      target_ip = test_ip;
    } in

  Lwt.pick [
    (arp_query fd fake_ip
     >>= fun () -> Lwt_unix.sleep 0.5
     >>= fun () -> Lwt.return_error "time out");
    assert_arp recv_st expected_fake;
  ]

  >>>= fun () ->

  intf.Intf.release_fake_ip fake_ip >>= fun () ->

  let expected_fake = Arp_packet.{
      operation = Arp_packet.Reply;
      source_mac = mac;
      source_ip = fake_ip;
      target_mac = test_mac;
      target_ip = test_ip;
    } in

  Lwt.pick [
    (arp_query fd fake_ip
     >>= fun () -> Lwt_unix.sleep 1.5
     >>= fun () -> Lwt.return_error "time out");
    assert_arp recv_st expected_fake; ]
  >>= fun err ->
  if R.is_error err
  && R.get_error err = "time out" then Lwt.return_ok ()
  else Lwt.return_error "fake ip not time out error"


let () =
  let test_re = Lwt_main.run @@ test_intf () in
  try
    assert (R.is_ok test_re);
    Printf.printf "test OK!\n"
  with
  | _ when R.is_error test_re ->
      Printf.printf "error: %s" (R.get_error test_re);
      exit 1
  | _ -> exit 1
