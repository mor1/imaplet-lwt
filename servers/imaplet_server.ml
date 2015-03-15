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
open Imaplet
open Commands
open Commands.Server_config

exception InvalidCommand

let rec args i net port ssl tls store =
  let bval = function
  | "true" -> true
  | "false" -> false
  | _ -> raise InvalidCommand
  in
  let sval str = 
    if str = "irmin" then
      (`Irmin,"","")
    else if Regex.match_regex ~regx:"^mbox:\\([^,]+\\),\\([.]+\\)$" str then
      (`Mailbox,(Str.matched_group 1 str),(Str.matched_group 2 str))
    else if Regex.match_regex ~regx:"^maildir:\\([^,]+\\)$" str then
      (`Maildir,"",(Str.matched_group 1 str))
    else
      raise InvalidCommand
  in
  if i >= Array.length Sys.argv then
    net,port,ssl,tls,store
  else
    match Sys.argv.(i) with 
    | "-net" -> args (i+2) (Some Sys.argv.(i+1)) port ssl tls store
    | "-port" -> args (i+2) net (Some (int_of_string Sys.argv.(i+1))) ssl tls store
    | "-ssl" -> args (i+2) net port (Some (bval Sys.argv.(i+1))) tls store
    | "-tls" -> args (i+2) net port ssl (Some (bval Sys.argv.(i+1))) store
    | "-store" -> args (i+2) net port ssl tls (Some (sval Sys.argv.(i+1))) 
    | _ -> raise InvalidCommand

let usage () =
  Printf.fprintf stderr "usage: imaplet -net [interface] -port [port] -ssl [true|false]
  -tls [true|false] -store[irmin;mbox:inboxpath,mailboxpath;maildir:maildirpath\n%!"

let commands f =
  try 
    let net,port,ssl,tls,store = args 1 None None None None None in
      try 
        f net port ssl tls store
      with ex -> Printf.printf "%s\n%!" (Printexc.to_string ex)
  with _ -> usage ()

(**
 * start the server
**)
let () = 
  try
    commands 
      (fun net port ssl tls store ->
        Lwt_main.run (catch(fun() ->
            let config = update_config srv_config net port ssl tls store in
            Server.create config >>= function
            | `Ok -> return ()
            | `Error e -> Printf.fprintf stderr "%s" e; return ()
          )
          (fun ex -> Printf.fprintf stderr "imaplet: fatal exception: %s %s"
            (Printexc.to_string ex) (Printexc.get_backtrace()); return()
          )
        )
      )
  with Exit -> 
    Printf.fprintf stderr "imaplet: terminated: %s" (Printexc.get_backtrace())