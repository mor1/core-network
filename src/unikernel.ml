open Lwt.Infix
open Mirage_types_lwt

let bridge_src = Logs.Src.create "bridge" ~doc:"Databox bridge"
module Log = (val Logs_lwt.src_log bridge_src : Logs_lwt.LOG)

let netmask = 16

type pkt = [
    `Tcp of Ipaddr.V4.t * Ipaddr.V4.t * Cstruct.t
  | `Udp of Ipaddr.V4.t * Ipaddr.V4.t * Cstruct.t
]

type endpoint = {
  port     :  Ipaddr.V4.Prefix.t;
  pkt_in   :  pkt Lwt_stream.t;
  push_pkt :  pkt option -> unit
}

let pp_port = Ipaddr.V4.Prefix.pp_hum


(* dns and look-up/forward *)
module Dispatcher = struct

  type mux_tbl = (Ipaddr.V4.Prefix.t, pkt option -> unit) Hashtbl.t

  let create () : mux_tbl = Hashtbl.create 7

  let find_port tbl dst =
    let n =
      let m = Ipaddr.V4.Prefix.mask netmask in
      Ipaddr.V4.Prefix.of_netmask m dst
    in
    if Hashtbl.mem tbl n then Some (Hashtbl.find tbl n)
    else None

  let register tbl {port; pkt_in; push_pkt} =
    Hashtbl.replace tbl port push_pkt;
    Log.info (fun m -> m "[dispatcher] port %a registered" Ipaddr.V4.Prefix.pp_hum port) >>= fun () ->
    let rec drain_n_push () =
      Lwt_stream.get pkt_in >>= (function
        | None -> Log.err (fun m -> m "[dispatcher] stream closed of %a" pp_port port)
        | Some (`Tcp (_, dst, _)) as pkt ->
            (match find_port tbl dst with
            | Some push -> Lwt.return @@ push pkt
            | None -> Log.err (fun m -> m "[dispatcher] no port found for %a" Ipaddr.V4.pp_hum dst))
        | Some (`Udp (_, dst, _)) ->
            Log.info (fun m -> m "[dispatcher] got udp pkt for %a" Ipaddr.V4.pp_hum dst))
      >>= fun () -> drain_n_push ()
    in
    Lwt.async (fun () -> drain_n_push ());
    Lwt.return_unit
end


(*
module STACK (N: NETWORK) = struct

  (*
  let create n e a i =
    let in_s, in_push = Lwt_stream.create () in
    let out_s, out_push = Lwt_stream.create () in

    let with_log f = function
    | Some (`Tcp (src, dst, _)) | Some (`Udp (src, dst, _)) as pkt ->
        Log.info (fun m -> m "[tcp/udp] from %a to %a" Ipaddr.V4.pp_hum src Ipaddr.V4.pp_hum dst)
        >>= fun () -> Lwt.return @@ f pkt
    | _ -> Log.err (fun m -> m "[tcp/udp] unrecognised pkt type")
    in

    (*let ipv4 =
      let tcp ~src ~dst buf = with_log in_push @@ Some (`Tcp (src, dst, buf)) in
      let udp ~src ~dst buf = with_log in_push @@ Some (`Udp (src, dst, buf)) in
      let default ~proto ~src ~dst buf =
        Log.debug (fun m -> m "[ipv4] proto:%d src:%a dst %a" proto
                      Ipaddr.V4.pp_hum src Ipaddr.V4.pp_hum dst) in
      I.input i ~tcp ~udp ~default
      in*)
    let ipv4 = fun pkt ->
      let default ~proto ~src ~dst buf =
        Log.debug (fun m -> m "[ipv4] proto:%d src:%a dst %a" proto
                      Ipaddr.V4.pp_hum src Ipaddr.V4.pp_hum dst) in
      let open Ipv4_packet in
      match Unmarshal.of_cstruct pkt with
      | Error s ->
          Log.info (fun f -> f "IP.input: unparseable header (%s)" s)
      | Ok (packet, payload) ->
          match Unmarshal.int_to_protocol packet.proto, Cstruct.len payload with
          | Some _, 0 -> Lwt.return_unit
          | None, 0 | Some `ICMP, _ | None, _ ->
              default ~proto:packet.proto ~src:packet.src ~dst:packet.dst payload
          | Some `TCP, _ ->
              with_log in_push @@ Some (`Tcp (packet.src, packet.dst, pkt)) >>= fun () ->
              let len = Cstruct.len pkt - Ipv4_wire.sizeof_ipv4 in
              let src = packet.src and dst = packet.dst in
              let pseudoheader = Ipv4_packet.Marshal.pseudoheader ~src ~dst ~proto:`TCP len in
              let datag = Cstruct.shift pkt Ipv4_wire.sizeof_ipv4 in
              let cksum = Tcp.Tcp_wire.get_tcp_checksum datag in
              let () = Tcp.Tcp_wire.set_tcp_checksum datag 0 in
              let cksum' = Tcpip_checksum.ones_complement_list [pseudoheader; datag] in
              let () = Tcp.Tcp_wire.set_tcp_checksum datag cksum' in
              Log.info (fun m -> m "[cksum] %d :: %d" cksum cksum')
          | Some `UDP, _ -> with_log in_push @@ Some (`Udp (packet.src, packet.dst, pkt))
    in
    let arpv4 buf = A.input a buf in
    let ipv6  buf = Log.debug (fun m -> m "[ipv6] discard") in

    let ethif = E.input ~arpv4 ~ipv4 ~ipv6 e in
    let rec stack_driver () =
      N.listen n ethif >>= (function
        | Ok () -> Lwt.return_unit
        | Error err -> Log.err (fun m -> m "[net] error: %a" N.pp_error err))
      >>= stack_driver
    in

    let rec write_loop () =
      Lwt_stream.get out_s >>= begin function
      | None -> Log.info (fun m -> m "[stack] stream closed")
      | Some (`Udp (src, dst, pkt)) ->
          let frame, len = I.allocate_frame i ~dst ~proto:`UDP in
          let headers = Cstruct.set_len frame len in
          let () = Cstruct.blit pkt 0 headers Ethif_wire.sizeof_ethernet Ipv4_wire.sizeof_ipv4 in
          let ip_payload = Cstruct.shift pkt Ipv4_wire.sizeof_ipv4 in
          I.write i headers ip_payload >>= (function
            | Ok () -> Lwt.return_unit
            | Error err -> Log.err (fun m -> m "[ipv4 udp] write error: %a" I.pp_error err))
          (* src is different from the address from `i', rewrite header *)
          (*let ip_header = Ipv4_packet.({
              options = Cstruct.create 0;
              src; dst; ttl = 38;
              proto = Marshal.protocol_to_int `UDP})
          in
          let pkt = Cstruct.shift frame Ethif_wire.sizeof_ethernet in
          Ipv4_packet.Marshal.into_cstruct ~payload_len:0 ip_header pkt |> (function
            | Ok () -> I.write i frame buf >>= (function
              | Ok () -> Lwt.return_unit
              | Error err ->
                  Log.err (fun m -> m "[ipv4] write error: %a" I.pp_error err))
            | Error err ->
                Log.err (fun m -> m "[ipv4] marshal error: %s" err))*)
      | Some (`Tcp (src, dst, pkt)) ->
          let frame, len = I.allocate_frame i ~dst ~proto:`TCP in
          let headers = Cstruct.set_len frame len in
          let () = Cstruct.blit pkt 0 headers Ethif_wire.sizeof_ethernet Ipv4_wire.sizeof_ipv4 in
          let ip_payload = Cstruct.shift pkt Ipv4_wire.sizeof_ipv4 in
          I.write i headers ip_payload >>= (function
            | Ok () -> Lwt.return_unit
            | Error err -> Log.err (fun m -> m "[ipv4 tcp] write error: %a" I.pp_error err))
          (* src is different from the address from `i', rewrite header *)
          (*let ip_header = Ipv4_packet.({
              options = Cstruct.create 0;
              src; dst; ttl = 38;
              proto = Marshal.protocol_to_int `TCP})
          in
          let pkt = Cstruct.shift frame Ethif_wire.sizeof_ethernet in
          Ipv4_packet.Marshal.into_cstruct ~payload_len:0 ip_header pkt |> (function
            | Ok () -> I.write i frame buf >>= (function
              | Ok () -> Log.info (fun m -> m "[ipv4] write out successfully: %a -> %a"
                                  Ipaddr.V4.pp_hum src Ipaddr.V4.pp_hum dst)
              | Error err ->
                  Log.err (fun m -> m "[ipv4] write error: %a" I.pp_error err))
            | Error err ->
                Log.err (fun m -> m "[ipv4] marshal error: %s" err))*)
      end
      >>= write_loop
    in

    let port = Ipaddr.V4.Prefix.make netmask @@ List.hd @@ I.get_ip i in
    Lwt.return ({port; pkt_in = in_s; push_pkt = out_push},
                stack_driver, write_loop)*)

  let rec drain_pkts n fn () =
    N.listen n fn >>= (function
        | Ok () -> Lwt.return_unit
        | Error err -> Log.err (fun m -> m "[net] error: %a" N.pp_error err))
    >>= drain_pkts n fn

end *)


module Vmnetd = struct

  let error_of_failure f = Lwt.catch f (fun e -> Lwt_result.fail (`Msg (Printexc.to_string e)))

  module Init = struct

    type t = {
      magic: string;
      version: int32;
      commit: string;
    }

    let to_string t =
      Printf.sprintf "{ magic = %s; version = %ld; commit = %s }" t.magic t.version t.commit

    let sizeof = 5 + 4 + 40

    let default = {
      magic = "VMN3T";
      version = 1l;
      commit = "0123456789012345678901234567890123456789";
    }

    let marshal t rest =
      Cstruct.blit_from_string t.magic 0 rest 0 5;
      Cstruct.LE.set_uint32 rest 5 t.version;
      Cstruct.blit_from_string t.commit 0 rest 9 40;
      Cstruct.shift rest sizeof

    let unmarshal rest =
      let magic = Cstruct.(to_string @@ sub rest 0 5) in
      let version = Cstruct.LE.get_uint32 rest 5 in
      let commit = Cstruct.(to_string @@ sub rest 9 40) in
      let rest = Cstruct.shift rest sizeof in
      Result.Ok ({ magic; version; commit }, rest)
  end

  module Command = struct

    type t =
      | Ethernet of Uuidm.t (* 36 bytes *)
      | Bind_ipv4 of Ipaddr.V4.t * int * bool

    let to_string = function
    | Ethernet x -> "Ethernet " ^ (Uuidm.to_string x)
    | Bind_ipv4 (ip, port, tcp) -> "Bind_ipv4 " ^ (Ipaddr.V4.to_string ip) ^ " " ^ (string_of_int port) ^ " " ^ (string_of_bool tcp)

    let sizeof = 1 + 36

    let marshal t rest = match t with
    | Ethernet uuid ->
        Cstruct.set_uint8 rest 0 1;
        let rest = Cstruct.shift rest 1 in
        let uuid_str = Uuidm.to_string uuid in
        Cstruct.blit_from_string uuid_str 0 rest 0 (String.length uuid_str);
        Cstruct.shift rest (String.length uuid_str)
    | Bind_ipv4 (ip, port, stream) ->
        Cstruct.set_uint8 rest 0 6;
        let rest = Cstruct.shift rest 1 in
        Cstruct.LE.set_uint32 rest 0 (Ipaddr.V4.to_int32 ip);
        let rest = Cstruct.shift rest 4 in
        Cstruct.LE.set_uint16 rest 0 port;
        let rest = Cstruct.shift rest 2 in
        Cstruct.set_uint8 rest 0 (if stream then 0 else 1);
        Cstruct.shift rest 1

    let unmarshal rest =
      match Cstruct.get_uint8 rest 0 with
      | 1 ->
          let uuid_str = Cstruct.(to_string (sub rest 1 36)) in
          let rest = Cstruct.shift rest 37 in
          if Bytes.(compare (make 36 '\000') (of_string uuid_str)) = 0 then
            begin
              let random_uuid = (Uuidm.v `V4) in
              Log.info (fun f -> f "Generated UUID on behalf of client: %s" (Uuidm.to_string random_uuid))
              |> Lwt.ignore_result;
              Result.Ok (Ethernet random_uuid, rest) (* generate random uuid on behalf of client if client sent array of \0 *)
            end else  begin
            let result = match (Uuidm.of_string uuid_str) with (* parse uuid from client *)
            | Some uuid -> begin
                Result.Ok (Ethernet uuid, rest)
              end
            | None -> Result.Error (`Msg (Printf.sprintf "Invalid UUID: %s" uuid_str))
            in
            result
          end
      | n -> Result.Error (`Msg (Printf.sprintf "Unknown command: %d" n))

  end

  module Vif = struct

    type t = {
      mtu: int;
      max_packet_size: int;
      client_macaddr: Macaddr.t;
    }

    let to_string t = Printf.sprintf "{ mtu = %d; max_packet_size = %d; client_macaddr = %s }" t.mtu t.max_packet_size (Macaddr.to_string t.client_macaddr)

    let create client_macaddr mtu () =
      let max_packet_size = mtu + 50 in
      { mtu; max_packet_size; client_macaddr }

    let sizeof = 2 + 2 + 6

    let marshal t rest =
      Cstruct.LE.set_uint16 rest 0 t.mtu;
      Cstruct.LE.set_uint16 rest 2 t.max_packet_size;
      Cstruct.blit_from_string (Macaddr.to_bytes t.client_macaddr) 0 rest 4 6;
      Cstruct.shift rest sizeof

    let unmarshal rest =
      let mtu = Cstruct.LE.get_uint16 rest 0 in
      let max_packet_size = Cstruct.LE.get_uint16 rest 2 in
      let mac = Cstruct.(to_string @@ sub rest 4 6) in
      try
        let client_macaddr = Macaddr.of_bytes_exn mac in
        Result.Ok ({ mtu; max_packet_size; client_macaddr }, Cstruct.shift rest sizeof)
      with _ ->
        Result.Error (`Msg (Printf.sprintf "Failed to parse MAC: [%s]" mac))

  end


  let client_negotiate ~uuid ~in_ch ~out_ch =
  error_of_failure
    (fun () ->
      let open Lwt.Infix in
      let buf = Cstruct.create Init.sizeof in
      let (_: Cstruct.t) = Init.marshal Init.default buf in
      Lwt_io.write out_ch (Cstruct.to_string buf) >>= fun () ->
      Lwt_io.flush out_ch >>= fun () ->

      let in_buf = Bytes.make Init.sizeof '0' in
      Lwt_io.read_into_exactly in_ch in_buf 0 Init.sizeof >>= fun () ->
      let buf = Cstruct.of_bytes in_buf in
      let open Lwt_result.Infix in
      Lwt.return (Init.unmarshal buf) >>= fun (init, _) ->
      let open Lwt.Infix in
      Log.info (fun f -> f "Client.negotiate: received %s" (Init.to_string init)) >>= fun () ->
      let buf = Cstruct.create Command.sizeof in
      let (_: Cstruct.t) = Command.marshal (Command.Ethernet uuid) buf in
      Lwt_io.write out_ch (Cstruct.to_string buf) >>= fun () ->
      Lwt_io.flush out_ch >>= fun () ->

      let in_buf = Bytes.make Vif.sizeof '0' in
      Lwt_io.read_into_exactly in_ch in_buf 0 Vif.sizeof >>= fun () ->
      let buf = Cstruct.of_bytes in_buf in
      let open Lwt_result.Infix in
      Lwt.return (Vif.unmarshal buf)
      >>= fun (vif, _) ->
      Lwt.ignore_result @@ Log.debug (fun f -> f "Client.negotiate: vif %s" (Vif.to_string vif));
      Lwt_result.return (vif)
    )


  module Packet = struct
    let sizeof = 2

    let marshal t rest =
      Cstruct.LE.set_uint16 rest 0 t

    let unmarshal rest =
      let t = Cstruct.LE.get_uint16 rest 0 in
      Result.Ok (t, Cstruct.shift rest sizeof)
  end
end


module CONNECTOR(N: NETWORK) = struct

  let rec drain_pkts n fn () =
    N.listen n fn >>= (function
      | Ok () -> Lwt.return_unit
      | Error err -> Log.err (fun m -> m "[net] error: %a" N.pp_error err))
    >>= drain_pkts n fn


  let connect n addr =
    let fd = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
    let addr = Lwt_unix.ADDR_UNIX addr in

    let in_ch = Lwt_io.(of_fd ~mode:input fd) in
    let out_ch = Lwt_io.(of_fd ~mode:output fd) in

    Lwt_unix.connect fd addr >>= fun () ->
    let uuid = Uuidm.create `V4 in
    Vmnetd.client_negotiate ~uuid ~in_ch ~out_ch >>= function
    | Error (`Msg msg) ->
        Log.err (fun m -> m "connection failed: %s" msg)
    | Ok vif ->
        let wfn buf =
          let f buf () =
            let hd = Cstruct.create Vmnetd.Packet.sizeof in
            Vmnetd.Packet.marshal (Cstruct.len buf) hd;
            Lwt_io.write out_ch (Cstruct.to_string hd) >>= fun () ->
            Lwt_io.write out_ch (Cstruct.to_string buf) >>= fun () ->
            Lwt_io.flush out_ch >>= fun () ->
            let b = Buffer.create 128 in
            Cstruct.hexdump_to_buffer b buf;
            Log.info (fun m -> m "write a packet %d\n%s" (Cstruct.len buf) (Buffer.contents b))
          in
          let f_exn e =
            Log.err (fun m -> m "write err: %s" @@ Printexc.to_string e)
          in

          (* set src to client_macaddr *)
          let src_mac = Macaddr.to_bytes vif.Vmnetd.Vif.client_macaddr in
          let orig_src =
            Cstruct.sub buf 6 6 |> Cstruct.to_string
            |> Macaddr.of_bytes
            |> function
            | Some addr -> Macaddr.to_string addr
            | None -> "none" in
          Cstruct.blit_from_string src_mac 0 buf 6 6;
          Log.info (fun m -> m "before write to vpnkit src %s -> %s" orig_src src_mac) >>= fun () ->

          Lwt.catch (f buf) f_exn
        in

        let rec rt () =
          let hd = Bytes.create Vmnetd.Packet.sizeof in
          Lwt_io.read_into_exactly in_ch hd 0 Vmnetd.Packet.sizeof >>= fun () ->
          let len =
            match Vmnetd.Packet.unmarshal @@ Cstruct.of_bytes hd with
            | Ok (len, _) -> len
            | _ -> 0
          in
          let buf = Bytes.create len in
          Lwt_io.read_into_exactly in_ch buf 0 len >>= fun () ->
          let fr = Cstruct.of_bytes buf in

          let dst_mac = Macaddr.to_bytes @@ N.mac n in
          let orig_dst =
            Cstruct.sub fr 0 6 |> Cstruct.to_string
            |> Macaddr.of_bytes
            |> function
            | Some addr -> Macaddr.to_string addr
            | None -> "none" in
          Cstruct.blit_from_string dst_mac 0 fr 0 6;
          Log.info (fun m -> m "before write to netif dst %s -> %s" orig_dst dst_mac) >>= fun () ->

          N.write n fr >>= function
          | Ok () -> rt ()
          | Error err -> Log.err (fun m -> m "write error: %a" N.pp_error err) >>= rt
        in

        Lwt.join [
          drain_pkts n wfn ();
          rt ();
        ]
end


module Main (S: STACKV4)
    (N0: NETWORK)
    (N1: NETWORK)
    (N2: NETWORK) (* (E2: ETHIF) (A2: ARP) (I2: IPV4) (U2: UDPV4) *)
= struct

  module S0 = CONNECTOR(N0)
  module S1 = CONNECTOR(N1)
  module S2 = CONNECTOR(N2)


  let start s
      n0
      n1
      n2
    =

    let path = "/var/tmp/bridge" in

    Lwt.join [
      S0.connect n0 path;
      S1.connect n1 path;
      S2.connect n2 path;
    ]

  (*
    S0.create n0 e0 a0 i0 >>= fun (ep0, d0, s0) ->
    S1.create n1 e1 a1 i1 >>= fun (ep1, d1, s1) ->
    S2.create n2 e2 a2 i2 >>= fun (ep2, d2, s2) ->

    let disp = Dispatcher.create () in
    Dispatcher.register disp ep0 >>= fun () ->
    Dispatcher.register disp ep1 >>= fun () ->
    Dispatcher.register disp ep2 >>= fun () ->

    Lwt.join [
      d0 (); s0 ();
      d1 (); s1 ();
      d2 (); s2 ();
    ]*)
  (*module DNS = Dns_resolver_mirage.Make(OS.Time)(S)
    module ICMP0 = Icmpv4.Make(I0)
    module ICMP1 = Icmpv4.Make(I1)*)
  (* have a forward dns server, on port 53 of each interface   *)
  (* if couldn't resolve locally, forward to 127.0.0.11:<port> *)
  (* refer to ocaml-dns/examples/forward.ml *)

  (* write out response from forward dns request *)

  (* put resolved domains in local cache db *)

  (* use iptables to disable ICMP unreachable destinations reply *)
  (* forward dns request, amend the id to the match the id from the request *)

  (*let update_cache db answers =
    Lwt_list.iter_p (fun ans ->
        let open Dns.Packet in
        let open Dns.Loader in
        match ans.rdata with
        | A a ->
            Log.info (fun m -> m "add A rdata: %a %s %d" Ipaddr.V4.pp_hum a
                          (Dns.Name.to_string ans.name) (Int32.to_int ans.ttl)) >>= fun () ->
            Lwt.return @@ add_a_rr a ans.ttl ans.name db
        | AAAA a ->
            Log.info (fun m -> m "add AAAA rdata: %a %s" Ipaddr.V6.pp_hum a
                          (Dns.Name.to_string ans.name)) >>= fun () ->
            Lwt.return @@ add_aaaa_rr a ans.ttl ans.name db
        | rdata ->
            Log.info (fun m -> m "got rdata: %s" (rdata_to_string rdata))) answers*)

  (* local network stack is still responding *)

  (* TODO: put different interfaces under central managemment *)

  (*let dns_listener resolve write ~src ~dst ~src_port buf =
    Log.info (fun m -> m "dns query from %a:%d" Ipaddr.V4.pp_hum src src_port)
    >>= fun () ->
    match Dns.Protocol.Server.parse buf with
    | None -> Lwt.return_unit
    | Some pkt ->
        let open Dns in
        let open Packet in
        match pkt.questions with
        | [] -> Lwt.return_unit
        | [q] ->
            resolve q >>= fun resp ->
            let resp' = {resp with id = pkt.id} in
            (match Dns.Protocol.Server.marshal pkt resp' with
            | None -> Log.err (fun m -> m "marshal error")
            | Some buf' -> write ~src_port:53 ~dst:src ~dst_port:src_port buf')
        | _::_::_ -> Lwt.return_unit


  let udp_listeners resolve write ~dst_port =
    match dst_port with
    | 53 -> Some (dns_listener resolve write)
    | _ -> None


  let info arg = Log.info (fun m -> m arg)

  let resolve stack pkt =
    let resolver = DNS.create stack in
    let server = Ipaddr.V4.of_string_exn "127.0.0.11" in
    let dns_port = 53 in
    let open Dns.Packet in
    let module Client = Dns.Protocol.Client in
    Log.info (fun m -> m "forward DNS question: %s" (question_to_string pkt)) >>= fun () ->
    DNS.(resolve (module Client) resolver server dns_port pkt.q_class pkt.q_type pkt.q_name)


  let start s
      n0 e0 a0 i0 u0 t0
      n1 e1 a1 i1 u1 t1
      n2 e2 a2 i2 u2 t2
    =
    let resolver = resolve s in
    let udp0_write ~src_port ~dst ~dst_port buf =
      U0.write ~src_port ~dst ~dst_port u0 buf >>= function
      | Ok () -> Lwt.return_unit
      | Error err -> Log.err (fun m -> m "udp0 error: %a" U0.pp_error err)
    in

    ICMP0.connect i0 >>= fun icmp0 ->
    ICMP1.connect i1 >>= fun icmp1 ->

    (*
    let icmp0_input ~src ~dst buf =
      if List.mem dst @@ I0.get_ip i0 then
        ICMP0.input icmp0 ~src ~dst buf
      else if List.mem dst @@ I1.get_ip i1 then
        ICMP1.write *)

    let t0 = N0.listen n0
        (E0.input
           ~arpv4:(A0.input a0)
           ~ipv4:(
             I0.input
               ~tcp:(fun ~src:_ ~dst:_ _ -> info "0 TCP")
               ~udp:(U0.input ~listeners:(udp_listeners resolver udp0_write) u0)
               ~default:(fun ~proto ~src ~dst data ->
                   match proto with
                   | 1 -> ICMP0.input icmp0 ~src ~dst data
                   | _ -> Log.info (fun m -> m "0 - %d" proto))
               i0)
           ~ipv6:(fun _ -> info "0 IPv6")
           e0) >>= function
      | Result.Ok () -> info "done!"
      | Result.Error _ -> info "ping failed!"
    in

    let udp1_write ~src_port ~dst ~dst_port buf =
      U1.write ~src_port ~dst ~dst_port u1 buf >>= function
      | Ok () -> Lwt.return_unit
      | Error err -> Log.err (fun m -> m "udp0 error: %a" U1.pp_error err)
    in

    let t1 = N0.listen n1
        (E1.input
           ~arpv4:(A1.input a1)
           ~ipv4:(
             I1.input
               ~tcp:(fun ~src:_ ~dst:_ _ -> info "1 TCP")
               ~udp:(U1.input ~listeners:(udp_listeners resolver udp1_write) u1)
               ~default:(fun ~proto ~src ~dst data ->
                   match proto with
                   | 1 -> ICMP1.input icmp1 ~src ~dst data
                   | _ -> Log.info (fun m -> m "1 - %d" proto))
               i1)
           ~ipv6:(fun _ -> info "1 IPv6")
           e1) >>= function
      | Result.Ok () -> info "done!"
      | Result.Error _ -> info "ping failed!"
    in

    Lwt.join [t0; t1]*)
end