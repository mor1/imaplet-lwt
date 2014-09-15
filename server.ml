(*
 * Copyright (c) 2013-2014 Gregory Tsipenyuk <gregtsip@cam.ac.uk>
 * 
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)
open Lwt
open BatLog

let try_close (r,w) =
  catch (fun () -> Lwt_io.close r)
  (function _ -> return ()) >>
  catch (fun () -> Lwt_io.close w)
  (function _ -> return ())

let try_close_sock sock =
  catch (fun () -> 
    match sock with |None->return()|Some sock->Lwt_unix.close sock)
  (function _ -> return ())

let init_socket addr port =
  Easy.logf `debug "serverfe: creating socket %s %d\n%!" addr port;
  let sockaddr = Unix.ADDR_INET (Unix.inet_addr_of_string addr, port) in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  Lwt_unix.bind socket sockaddr;
  socket

let create_srv_socket addr port =
  let socket = init_socket addr port in
  Lwt_unix.listen socket 10;
  socket

let accept_ssl sock cert =
  Tls_lwt.accept cert sock >>= fun (channels, addr) ->
  return (None,channels)

let accept_cmn sock =
  Lwt_unix.accept sock >>= fun (sock_c, addr) ->
  let ic = Lwt_io.of_fd ~close:(fun()->return()) ~mode:Lwt_io.input sock_c in
  let oc = Lwt_io.of_fd ~close:(fun()->return()) ~mode:Lwt_io.output sock_c in
  return (Some sock_c,(ic,oc))

let accept_conn sock = function
  | Some cert -> accept_ssl sock cert
  | None -> accept_cmn sock

(* init local delivery *)
let init_local_delivery () =
  let open Core.Std in
  let _ = Unix.fork_exec
  ~prog:(Configuration.lmtp_srv_exec)
  ~args:[Configuration.lmtp_srv_exec] () in
  ()

(* initialize all things *)
let init_all ssl =
  init_local_delivery ();
  if ssl then (
    Ssl.init_ssl () >>= fun cert ->
    return (Some cert)
  ) else
    return None

let init_connection channels =
  let (_,w) = channels in
  let resp = "* OK [CAPABILITY " ^ Configuration.capability ^ "] Imaplet ready.\r\n" in
  Lwt_io.write w resp >>
  Lwt_io.flush w

(**
 * start accepting connections
**)
let create () =
  let open Connections in
  let open Server_config in
  init_all srv_config.!ssl >>= fun cert ->
  let sock  = create_srv_socket srv_config.!addr srv_config.!port in
  let rec connect sock cert =
    accept_conn sock cert >>= fun (sock_c,channels) ->
    init_connection channels >>= fun() ->
    let id = next_id () in
    async(
      fun () ->
      catch(
        fun () ->
        let rec loop_conn channels =
          Imap_cmd.handle_commands id channels >>= fun res ->
          rem_id id;
          try_close channels >>= fun () ->
          match res with
          | `Done -> try_close_sock sock_c 
          | `Starttls ->
            Ssl.init_ssl() >>= fun cert ->
            Tls_lwt.Unix.server_of_fd
              (Tls.Config.server_exn ~certificate:cert ())
              (Core.Std.Option.value_exn sock_c) >>= fun srv ->
            let channels = Tls_lwt.of_t srv in
            loop_conn channels
        in
        loop_conn channels
      )
      (function _ -> rem_id id; try_close channels >> try_close_sock sock_c)
    ); 
    connect sock cert
  in
  connect sock cert
