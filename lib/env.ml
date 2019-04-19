let secrets_dir = Fpath.v "/run/secrets/"

let cm_key = ref ""

let cm_key () =
  if !cm_key <> "" then Rresult.R.ok !cm_key
  else begin
    let key_file = Fpath.add_seg secrets_dir "DATABOX_NETWORK_KEY" in
    let get_key file = Base64.encode_exn (String.trim file) in
    let open Rresult.R.Infix in
    (Bos.OS.File.read key_file) >>| get_key
    |> function
    | Ok key ->
        cm_key := key;
        Rresult.R.ok key
    | Error msg ->
        Logs.err (fun m ->
            m "[env] DATABOX_NETWORK_KEY %a" Rresult.R.pp_msg msg
          );
        Error msg
  end

let https_creds () =
  let cert_file = Fpath.add_seg secrets_dir "DATABOX_NETWORK.pem" in
  let key_file = Fpath.add_seg secrets_dir "DATABOX_NETWORK.pem" in
  Rresult.R.ok (cert_file, key_file)
