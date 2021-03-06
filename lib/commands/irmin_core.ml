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
open Irmin_unix
open Sexplib
open Server_config
open Imaplet_types
open Storage_meta
open Utils
open Sexplib.Conv
open Lazy_message
open Parsemail

exception KeyDoesntExist
exception DuplicateUID
exception InvalidKey of string
exception EmptyPrivateKey

module Store = Irmin.Basic (Irmin_git.FS) (Irmin.Contents.String)
module View = Irmin.View(Store)
module MapStr = Map.Make(String)

type hashes =
  {message:string;postmark:string;headers:string;content:string;attachments:int} with sexp

type irmin_accessors =
  (unit -> string Lwt.t) * (* postmark *)
  (unit -> (Email_parse.email_map * string) Lwt.t) * (* headers *)
  (unit -> string Lwt.t) * (* content *)
  (string -> string Lwt.t) * (* attachment *) 
  (unit -> mailbox_message_metadata Lwt.t)

type irmin_accessors_rec = {
  postmark:string Lwt.t lazy_t;
  headers:(Email_parse.email_map * string) Lwt.t lazy_t;
  content:string Lwt.t lazy_t;
  attachment:(string -> string Lwt.t);
  metadata:mailbox_message_metadata Lwt.t lazy_t;
}

type email_irmin_accessors =
  Email_parse.email_map * string * (string Lwt.t lazy_t) * 
    (string Lwt.t lazy_t Map.Make(String).t)

module LazyIrminEmail : LazyEmail_intf with type c = email_irmin_accessors =
  struct 
    open Email_parse
    type c = email_irmin_accessors
    type t = {
      email:email_map;
      headers: string;
      content: string Lwt.t lazy_t;
      attachment: string Lwt.t lazy_t Map.Make(String).t;
    }

    let empty = {
      email = {part={size=0;lines=0};header={offset=0;length=0};content=`Data_map {offset=0;length=0}};
      headers = "";
      content = Lazy.from_fun (fun () -> return "");
      attachment = MapStr.empty;
    }

    let create c =
      let (email,headers,content,attachment) = c in
      {email;headers;content;attachment}

    let header ?(incl=`Map MapStr.empty) ?(excl=MapStr.empty) t =
      let sexp = Sexp.of_string (Bytes.sub t.headers t.email.header.offset t.email.header.length) in
      List.filter (fun (n,_) ->
        let dont_incl =
        match incl with
        | `Map incl -> 
          MapStr.is_empty incl = false && MapStr.mem (String.lowercase n) incl = false
        | `Regx incl ->
          Regex.match_regex ~case:false ~regx:incl n = false
        in
        (* exclude if it is not on included list or is on excluded list *)
        (dont_incl = true ||
          MapStr.is_empty excl = false && MapStr.mem (String.lowercase n) excl = true) = false
      ) (list_of_sexp (fun sexp -> pair_of_sexp string_of_sexp string_of_sexp sexp) sexp)

    let header_to_str ?(incl=`Map MapStr.empty) ?(excl=MapStr.empty) t =
      List.fold_left (fun str (n,v) ->
        str ^ n ^ ":" ^ v ^ crlf
      ) "" (header ~incl ~excl t)

    let convert t =
      match t.email.content with
      | `Data_map dd -> 
        Lazy.force t.content >>= fun content ->
        return (`Data (Bytes.sub content dd.offset dd.length)) 
      | `Attach_map contid -> 
        Lazy.force (MapStr.find contid t.attachment) >>= fun attachment ->
        return (`Data attachment)
      | `Message_map email -> 
        return (`Message {t with email})
      | `Multipart_map (boundary,lemail) -> 
        return (`Multipart_ (boundary,(List.map (fun email -> {t with email}) lemail)))

    let content t =
      convert t >>= fun c ->
      match c with
      | `Data d -> return (`Data d)
      | `Message m -> return (`Message m)
      | `Multipart_ (_,lemail) -> return (`Multipart lemail)

    let raw_content t =
      let buffer = Buffer.create 100 in
      let rec _raw_content t with_header last_crlf =
        let header t buffer with_header = 
          if with_header then 
            Buffer.add_string buffer ((header_of_sexp_str 
              (Bytes.sub t.headers t.email.header.offset t.email.header.length)) ^ crlf)
        in
        convert t >>= fun c ->
        header t buffer with_header;
        match c with
        | `Data data -> Buffer.add_string buffer (data ^ crlf); return ()
        | `Message email -> _raw_content email true crlf
        | `Multipart_ (boundary,lemail) ->
          Buffer.add_string buffer crlf;
          Lwt_list.iter_s (fun email ->
            Buffer.add_string buffer (boundary ^ crlf);
            _raw_content email true crlf
          ) lemail >>= fun () ->
          Buffer.add_string buffer (boundary ^ "--" ^ crlf ^ last_crlf);
          return ()
      in
      _raw_content t false "" >>
      return (Buffer.contents buffer)

    let to_string ?(incl=`Map MapStr.empty) ?(excl=MapStr.empty) t =
      let headers = header_to_str ~incl ~excl t in
      raw_content t >>= fun content ->
      return (headers ^ crlf ^ content)

    let size t =
      t.email.part.size

    let lines t =
      t.email.part.lines

  end

module LazyIrminMessage : LazyMessage_intf with type c = irmin_accessors =
  struct
    open Email_parse

    type c = irmin_accessors

    type t = irmin_accessors_rec

    let create c =
      let (postmark,headers,content,attachment,metadata) = c in
      {postmark=Lazy.from_fun postmark;
       headers=Lazy.from_fun headers;
       content=Lazy.from_fun content;
       attachment;
       metadata=Lazy.from_fun metadata}

    let get_postmark t =
      Lazy.force t.postmark

    let get_headers_block t =
      Lazy.force t.headers >>= fun (_,headers) ->
      return headers

    let get_content_block (t:irmin_accessors_rec) =
      Lazy.force t.content

    let get_email t =
      let rec walk email acc =
        match email.content with
        | `Data_map d -> acc
        | `Attach_map contid -> MapStr.add contid (Lazy.from_fun (fun () -> t.attachment contid)) acc
        | `Message_map email -> walk email acc
        | `Multipart_map (_,lemail) -> 
          List.fold_left (fun acc email -> walk email acc) acc lemail
      in
      Lazy.force t.headers >>= fun (email,headers) ->
      return (build_lazy_email_inst (module LazyIrminEmail)
        (email,headers,t.content,walk email MapStr.empty))

    let get_message_metadata t =
      Lazy.force t.metadata
  end

module Key_ :
  sig
    type t

    (* user and unix path to key *)
    val t_of_path : string -> t
    val t_of_list : string list -> t
    val add_path : t -> string -> t
    val add_list : t -> string list -> t
    val create_account : string -> t
    val mailbox_of_path : string -> (string*t)
    val mailbox_of_list : string list -> (string*t)
    val mailboxes_of_mailbox : t -> t 
    val key_to_string : t -> string
    val key_to_path : t -> string
    val view_key_to_path : t -> string
    val assert_key : t -> unit
  end with type t = View.key =
  struct
    type t = View.key

    let create_account user =
      ["imaplet";user]

    let assert_key key =
      if List.length key = 0 || list_find key (fun i -> i = "") then
        raise (InvalidKey (String.concat "/" key))

    let t_of_path str =
      if str = "" then
        assert(false);
      let path = Regex.replace ~regx:"^/" ~tmpl:"" str in
      let path = Regex.replace ~regx:"/$" ~tmpl:"" path in
      Str.split (Str.regexp "/") path

    let t_of_list (l:string list) =
      assert_key l;
      l

    let add_path key str =
      List.concat [key;t_of_path str]

    let add_list key l =
      List.concat [key;l]

    let mailbox_of_list l =
      List.fold_right (fun i (mailbox,acc) -> 
        if i <> "" then (
          if List.length acc <> 0 then
            mailbox,"mailboxes" :: (i :: acc)
          else
            i,"mailboxes" :: (i :: acc)
        ) else
          mailbox,acc
      ) l ("",[])

    (* if user is None then relative path, otherwise root, i.e. /imaplet/user *)
    let mailbox_of_path path =
      let key = Str.split (Str.regexp "/") path in
      mailbox_of_list key
      
    let mailboxes_of_mailbox key =
      add_path key "mailboxes"

    (* convert key to path, keep "imaplet", user, and "mailboxes" *)
    let key_to_string key = 
      List.fold_left
      (fun acc item -> 
        if acc = "" then
          "/" ^ item
        else
          acc ^ "/" ^ item
     ) "" key

    (* convert key to path, remove "imaplet",user, and "mailboxes" *)
    let key_to_path key = 
     let (_,acc) =
     List.fold_left
     (fun (i,acc) item -> 
       if i < 2 then (* skip imaplet and user *)
         (i+1,acc)
       else if (Pervasives.(mod) i 2) = 0 then ( (* skip mailboxes *) 
         if acc = "" then
           (i+1,acc)
         else
           (i+1,acc ^ "/") 
       ) else 
         (i+1,acc ^ item)
     ) (0,"") key
     in
     acc

    (* convert view key (relative key) to path, remove "mailboxes" *)
    let view_key_to_path key = 
     let (_,acc) =
     List.fold_left
     (fun (i,acc) item -> 
       if (Pervasives.(mod) i  2) = 0 then ( (* skip mailboxes *) 
         if acc = "" then
           (i+1,acc)
         else
           (i+1,acc ^ "/") 
       ) else 
         (i+1,acc ^ item)
     ) (0,"") key
     in
     acc

  end

let get_irmin_path user config =
  match user with
  | None -> config.irmin_path
  | Some user -> Regex.replace ~regx:"%user%" ~tmpl:user config.irmin_path

module IrminIntf :
  sig
    type store
    val create : ?user:string -> Server_config.imapConfig -> store Lwt.t
    val remove : store -> Key_.t -> unit Lwt.t
    val read_exn : store -> Key_.t -> string Lwt.t
    val mem : store -> Key_.t -> bool Lwt.t
    val list : store -> Key_.t -> View.key list Lwt.t
    val update_view : store -> Key_.t -> View.t -> unit Lwt.t
    val read_view : store -> Key_.t -> View.t Lwt.t
  end =
  struct
    type store = (string -> View.db)
    let fmt t x = Printf.ksprintf (fun str -> t str) x
    let path () = String.concat "/"

    let task msg =
      let date = Int64.of_float (Unix.gettimeofday ()) in
      let owner = "imaplet <imaplet@openmirage.org>" in
      Irmin.Task.create ~date ~owner msg

    let create ?user config =
      let config = Irmin_git.config 
        ~root:(get_irmin_path user config)
        ~bare:(config.irmin_expand=false) () in
      Store.create config task 

    let remove store key =
      Key_.assert_key key;
      Store.remove_rec (fmt store "Remove %a." path key) key

    let read_exn store key =
      Key_.assert_key key;
      Store.read_exn (fmt store "Read %a." path key) key

    let mem store key =
      Key_.assert_key key;
      Store.mem (fmt store "Check if %a exists." path key) key

    let list store key =
      Key_.assert_key key;
      Store.list (fmt store "List the contents of %a" path key) key

    let update_view store key view =
      Key_.assert_key key;
      (*Printf.printf "------ store update_view %s\n%!" (Key_.key_to_string * key);*)
      let msg =
        let buf = Buffer.create 1024 in
        let path buf key = Buffer.add_string buf (String.concat "/" key) in
        Printf.bprintf buf "Updating %a.\n\n" path key;
        let actions = View.actions view in
        List.iter (function
            | `List (k, _)     -> Printf.bprintf buf "- list   %a\n" path k
            | `Read (k, _)     -> Printf.bprintf buf "- read   %a\n" path k
            | `Rmdir k         -> Printf.bprintf buf "- rmdir  %a\n" path k
            | `Write (k, None) -> Printf.bprintf buf "- remove %a\n" path k
            | `Write (k, _)    -> Printf.bprintf buf "- write  %a\n" path k
          ) actions;
        Buffer.contents buf
      in
      View.merge_path_exn (store msg) key view

    let read_view store key =
      Key_.assert_key key;
      (*Printf.printf "------ reading view %s\n%!" (Key_.key_to_string key);*)
      View.of_path (fmt store "Reading %a" path key) key

  end


module IrminIntf_tr :
  sig
    type transaction
    val remove_view : transaction -> unit Lwt.t
    val move_view : transaction -> Key_.t -> unit Lwt.t
    val begin_transaction : ?user:string -> Server_config.imapConfig -> Key_.t -> transaction Lwt.t
    val end_transaction : transaction -> unit Lwt.t
    val update : transaction -> Key_.t -> string -> unit Lwt.t
    val read : transaction -> Key_.t -> string option Lwt.t
    val read_exn : transaction -> Key_.t -> string Lwt.t
    val list : transaction -> Key_.t -> View.key list Lwt.t
    val remove : transaction -> Key_.t -> unit Lwt.t
    val mem : transaction -> Key_.t -> bool Lwt.t
  end =
  struct
    type transaction = IrminIntf.store * View.t * Key_.t * bool ref

    let begin_transaction ?user config key =
      Key_.assert_key key;
      IrminIntf.create ?user config >>= fun store ->
      (*Printf.printf "------ creating view %s\n%!" (Key_.key_to_string key);*)
      IrminIntf.read_view store key >>= fun view ->
      return (store,view,key,ref false)

    let end_transaction tr =
      let (store,view,key,dirty) = tr in
      if !dirty = true then (
        (*Printf.printf "++++++++++++++++++ commiting %s!!!\n%!"
        (Key_.key_to_string key);*)
        IrminIntf.update_view store key view >>= fun () ->
        dirty := false;
        return ()
      ) else
        return ()

    let remove_view tr =
      let (store,_,key,_) = tr in
      IrminIntf.remove store key

    let move_view tr key2 =
      let (store,view,_,_) = tr in
      IrminIntf.update_view store key2 view 


    let update tr key data =
      Key_.assert_key key;
      (*Printf.printf "------ store view.update %s\n" (Key_.key_to_string * key);*)
      let (_,view,_,dirty) = tr in
      View.update view key data >>= fun () ->
      dirty := true;
      return ()

    let read tr key =
      Key_.assert_key key;
      let (_,view,_,_) = tr in
      View.read view key

    let read_exn tr key =
      Key_.assert_key key;
      let (_,view,_,_) = tr in
      View.read_exn view key

    let list tr key =
      Key_.assert_key key;
      (*Printf.printf "------ store list %s\n%!" (Key_.key_to_string key);*)
      let (_,view,_,_) = tr in
      View.list view key

    let remove tr key =
      Key_.assert_key key;
      (*Printf.printf "------ store remove %s\n" (Key_.key_to_string key);*)
      let (_,view,_,dirty) = tr in
      View.remove_rec view key >>= fun () ->
      dirty := true;
      return ()

    let mem tr key =
      Key_.assert_key key;
      let (_,view,_,_) = tr in
      View.mem view key

    let tr_key tr =
      let (_,_,key,_) = tr in
      key

  end

  type mailbox_ = {user:string;mailbox:string;trans:IrminIntf_tr.transaction;
  index:int list option ref;config: Server_config.imapConfig;mbox_key:
    Key_.t;pubpriv: Ssl_.keys}

(* consistency TBD *)
module IrminMailbox :
  sig
    type t
    val create : Server_config.imapConfig -> string -> string -> Ssl_.keys -> t Lwt.t
    val commit : t -> unit Lwt.t
    val exists : t -> [`No|`Folder|`Mailbox] Lwt.t
    val create_mailbox : t -> unit Lwt.t
    val delete_mailbox : t -> unit Lwt.t
    val move_mailbox : t -> string -> unit Lwt.t
    val copy_mailbox : t -> [`Sequence of int|`UID of int] -> t ->
      mailbox_message_metadata -> unit Lwt.t
    val read_mailbox_metadata : t -> mailbox_metadata Lwt.t
    val append_message : t -> Mailbox.Message.t -> mailbox_message_metadata -> unit Lwt.t
    val update_mailbox_metadata : t -> mailbox_metadata -> unit Lwt.t
    val update_message_metadata : t -> [`Sequence of int|`UID of int] -> mailbox_message_metadata ->
      [`NotFound|`Eof|`Ok] Lwt.t
    val read_message : t -> ?filter:(searchKey) searchKeys -> 
      [`Sequence of int|`UID of int] ->
      [`NotFound|`Eof|`Ok of (module Lazy_message.LazyMessage_inst)] Lwt.t
    val read_message_metadata : t -> [`Sequence of int|`UID of int] -> 
      [`NotFound|`Eof|`Ok of mailbox_message_metadata] Lwt.t
    val delete_message : t -> [`Sequence of int|`UID of int] -> unit Lwt.t
    val list : t -> subscribed:bool -> ?access:(string -> bool) -> init:'a -> 
      f:('a -> [`Folder of string*int|`Mailbox of string*int] -> 'a Lwt.t) -> 'a Lwt.t
    val read_index_uid : t -> int list Lwt.t
    val show_all : t -> unit Lwt.t
    val uid_to_seq : t -> int -> int option Lwt.t
    val subscribe : t -> unit Lwt.t
    val unsubscribe : t -> unit Lwt.t
  end with type t = mailbox_ = 
  struct 
    (* user * mailbox * is-folder * irmin key including the mailbox *)
    type t = mailbox_

    let get_key mbox_key = function
    | `Metamailbox -> Key_.add_path mbox_key "meta"
    | `Index -> Key_.add_path mbox_key "index"
    | `Messages -> Key_.add_path mbox_key "messages"
    | `Storage (user,msg_hash,contid) -> Key_.t_of_path ("storage/" ^ msg_hash ^ "/" ^ contid) 
    | `Hashes uid -> Key_.add_path mbox_key ("messages/" ^ (string_of_int uid) ^ "/hashes")
    | `Metamessage uid -> Key_.add_path mbox_key ("messages/" ^ (string_of_int uid) ^ "/meta")
    | `Uid uid -> Key_.add_path mbox_key ("messages/" ^ (string_of_int uid))
    | `Subscriptions -> Key_.t_of_path "subscriptions"

    (* commit should be called explicitly on each created mailbox to have the
     * changes commited to Irmin
     *)
    let create config user path keys =
      let (mailbox,mbox_key) = Key_.mailbox_of_path path in
      IrminIntf_tr.begin_transaction ~user config (Key_.create_account user) >>= fun trans ->
        return {user;mailbox;trans;index=ref None;config;mbox_key;pubpriv=keys}

    let commit mbox =
      IrminIntf_tr.end_transaction mbox.trans

    (* create mailbox metadata and index stores *)
    let create_mailbox mbox =
      let key = get_key mbox.mbox_key `Metamailbox in
      let metadata = empty_mailbox_metadata ~uidvalidity:(new_uidvalidity())()
        ~selectable:true in
      let sexp = sexp_of_mailbox_metadata metadata in
      IrminIntf_tr.update mbox.trans key (Sexp.to_string sexp) >>= fun () ->
      let key = get_key mbox.mbox_key `Index in
      let sexp = sexp_of_list (fun i -> Sexp.of_string i) [] in
      IrminIntf_tr.update mbox.trans key (Sexp.to_string sexp) 

    let delete_mailbox mbox =
      IrminIntf_tr.remove_view mbox.trans

    (* how to make this the transaction? TBD *)
    let move_mailbox mbox path =
      let (_,key2) = Key_.mailbox_of_path path in
      IrminIntf_tr.move_view mbox.trans key2 >>
      IrminIntf_tr.remove_view mbox.trans

    let read_mailbox_metadata mbox =
      IrminIntf_tr.read_exn mbox.trans (get_key mbox.mbox_key `Metamailbox) >>= fun sexp_str ->
      let sexp = Sexp.of_string sexp_str in
      return (mailbox_metadata_of_sexp sexp)

    let update_mailbox_metadata mbox metadata =
      (*Printf.printf "updating mailbox metadata %d\n%!" metadata.uidnext;*)
      let sexp = sexp_of_mailbox_metadata metadata in
      let key = get_key mbox.mbox_key `Metamailbox in
      IrminIntf_tr.update mbox.trans key (Sexp.to_string sexp)

    let exists mbox =
      catch (fun () ->
        read_mailbox_metadata mbox >>= fun metadata ->
        return (if metadata.selectable then `Mailbox else `Folder)
      )
      (fun _ -> return `No)

    let exists_key mbox key =
      catch (fun () ->
        let key = Key_.add_list mbox.mbox_key (Key_.add_path key "meta") in
        IrminIntf_tr.read_exn mbox.trans key >>= fun metadata_sexp_str ->
        let metadata_sexp = Sexp.of_string metadata_sexp_str in
        let metadata = mailbox_metadata_of_sexp metadata_sexp in
        return (if metadata.selectable then `Mailbox else `Folder)
      )
      (fun _ -> return `No)

    let find_flag l fl =
      list_find l (fun f -> f = fl)

    let read_index_uid mbox =
      match mbox.!index with
      | None ->
        IrminIntf_tr.read_exn mbox.trans (get_key mbox.mbox_key `Index) >>= fun index_sexp_str ->
        let uids = list_of_sexp 
          (fun i -> int_of_string (Sexp.to_string i))
          (Sexp.of_string index_sexp_str) in
        mbox.index := Some uids;
        return uids
      | Some uids -> return uids

    let update_index_uids mbox uids = 
      mbox.index := Some uids;
      IrminIntf_tr.update mbox.trans (get_key mbox.mbox_key `Index) 
        (Sexp.to_string (sexp_of_list (fun i -> Sexp.of_string (string_of_int i)) uids ))

    let update_index_uid mbox uid =
      read_index_uid mbox >>= fun uids ->
      if list_find uids (fun u -> u = uid) then
        raise DuplicateUID
      else (
        (* reverse index *)
        let uids = (uid :: uids) in
        update_index_uids mbox uids
      )

    let uid_to_seq mbox uid =
      read_index_uid mbox >>= fun uids ->
      match (list_findi uids (fun i u -> u = uid)) with
      | None -> return None
      | Some (i,_) -> return (Some ((List.length uids) - i))

    let get_hashes mbox uid =
      IrminIntf_tr.read_exn mbox.trans (get_key mbox.mbox_key (`Hashes uid)) >>= fun h ->
      return (hashes_of_sexp (Sexp.of_string h))

    let update_hashes mbox uid msg_hash postmark headers content attachments =
      let h = {
        message=msg_hash;
        postmark = "0";
        headers = "1";
        content = "2";
        attachments;
      } in
      IrminIntf_tr.update mbox.trans (get_key mbox.mbox_key (`Hashes uid)) 
        (Sexp.to_string (sexp_of_hashes h)) >>
      return h

    let append_message_raw mbox ~parse message_metadata =
      let update msg_hash contid data =
        let key = get_key mbox.mbox_key (`Storage (mbox.user,msg_hash,contid)) in
        IrminIntf_tr.update mbox.trans key data
      in
      let uid = message_metadata.uid in
      IrminIntf_tr.update mbox.trans (get_key mbox.mbox_key (`Metamessage uid)) 
          (Sexp.to_string (sexp_of_mailbox_message_metadata message_metadata)) >>
      parse ~save_message:(fun msg_hash postmark headers content attachments ->
        update_hashes mbox uid msg_hash postmark headers content attachments >>= fun h ->
        update h.message h.postmark postmark >>
        update h.message h.content content >>
        update h.message h.headers headers
      ) 
      ~save_attachment:(fun msg_hash contid attachment ->
        update msg_hash contid attachment
      ) >>
      update_index_uid mbox uid

    let append_message mbox message message_metadata =
      let (pub,_) = mbox.pubpriv in
      append_message_raw mbox ~parse:(Email_parse.parse pub mbox.config message) message_metadata

    let get_uid mbox position = 
      read_index_uid mbox >>= fun uids ->
      match position with
      | `Sequence seq -> 
        if seq > List.length uids then
          return `Eof
        else if seq = 0 then
          return `NotFound
        else
          return (`Ok (seq,(List.nth uids ((List.length uids) - seq))))
      | `UID uid -> 
        match (list_findi uids (fun i u -> u = uid)) with 
        | None ->
          if uid > (List.nth uids 0) then
            return `Eof
          else
            return `NotFound
        | Some (seq,uid) ->
            return (`Ok ((List.length uids) - seq,uid))

    let update_message_metadata mbox position metadata =
      get_uid mbox position >>= function
      | `Eof -> return `Eof
      | `NotFound -> return `NotFound
      | `Ok (_,uid) ->
        IrminIntf_tr.update mbox.trans (get_key mbox.mbox_key (`Metamessage uid))
          (Sexp.to_string (sexp_of_mailbox_message_metadata metadata)) >>= fun () ->
        return `Ok

    let read_storage mbox msg_hash contid =
      let key = get_key mbox.mbox_key (`Storage (mbox.user,msg_hash,contid)) in
      IrminIntf_tr.read_exn mbox.trans key

    let get_message_metadata mbox uid =
      IrminIntf_tr.read_exn mbox.trans (get_key mbox.mbox_key (`Metamessage uid)) >>= fun sexp_str ->
      return (mailbox_message_metadata_of_sexp (Sexp.of_string sexp_str))

    let read_lazy_storage mbox lazy_hashes contid =
      Lazy.force lazy_hashes >>= fun h ->
      read_storage mbox h.message contid

    let read_message mbox ?filter position =
      get_uid mbox position >>= function
      | `Eof -> return `Eof
      | `NotFound -> return `NotFound
      | `Ok (seq,uid) -> 
        let (_,priv) = mbox.pubpriv in
        let priv = Utils.option_value_exn ~ex:EmptyPrivateKey priv in
        let lazy_hashes = Lazy.from_fun (fun () -> get_hashes mbox uid) in
        return (`Ok (
          build_lazy_message_inst
            (module LazyIrminMessage)
            ((fun () ->
              Lazy.force lazy_hashes >>= fun h ->
              read_storage mbox h.message h.postmark >>= fun postmark ->
              Email_parse.do_decrypt priv mbox.config postmark 
            ),
            (fun () ->
              Lazy.force lazy_hashes >>= fun h ->
              read_storage mbox h.message h.headers >>= fun headers ->
              Email_parse.do_decrypt_headers priv mbox.config headers 
            ),
            (fun () ->
              Lazy.force lazy_hashes >>= fun h ->
              read_storage mbox h.message h.content >>= fun content ->
              Email_parse.do_decrypt_content priv mbox.config content 
            ),
            (Email_parse.get_decrypt_attachment priv mbox.config (read_lazy_storage mbox lazy_hashes)),
            (fun () ->
              get_message_metadata mbox uid
            ))
          )
        )

    let read_message_metadata mbox position =
      get_uid mbox position >>= function
      | `Eof -> return `Eof
      | `NotFound -> return `NotFound
      | `Ok (seq,uid) -> 
        get_message_metadata mbox uid >>= fun meta ->
        return (`Ok meta)

    let copy_mailbox mbox1 pos mbox2 message_metadata =
      get_uid mbox1 pos >>= function
      | `Eof -> return ()
      | `NotFound -> return ()
      | `Ok (seq,uid) ->
        get_hashes mbox1 uid >>= fun h ->
        IrminIntf_tr.update mbox2.trans (get_key mbox2.mbox_key (`Hashes message_metadata.uid)) 
          (Sexp.to_string (sexp_of_hashes h)) >>
        IrminIntf_tr.update mbox2.trans (get_key mbox2.mbox_key (`Metamessage message_metadata.uid)) 
          (Sexp.to_string (sexp_of_mailbox_message_metadata message_metadata)) >>
        update_index_uid mbox2 message_metadata.uid

    let remove_storage mbox msg_hash contid =
      let key = get_key mbox.mbox_key (`Storage (mbox.user,msg_hash,contid)) in
      IrminIntf_tr.remove mbox.trans key

    let delete_message mbox position =
      get_uid mbox position >>= function
      | `Ok (_,uid) -> 
        get_hashes mbox uid >>= fun h ->
        IrminIntf_tr.remove mbox.trans (get_key mbox.mbox_key (`Hashes uid)) >>
        remove_storage mbox h.message h.postmark >>
        remove_storage mbox h.message h.headers >>
        remove_storage mbox h.message h.content >>
        IrminIntf_tr.remove mbox.trans (get_key mbox.mbox_key (`Metamessage uid)) >>
        IrminIntf_tr.remove mbox.trans (get_key mbox.mbox_key (`Uid uid)) >>
        let rec delattach i =
          if i < h.attachments then
            remove_storage mbox h.message (string_of_int (3 + i)) >>
            delattach (i + 1)
          else
            return ()
        in
        delattach 0 >>
        read_index_uid mbox >>= fun uids ->
        let uids = List.fold_right (fun u uids ->
          if u = uid then
            uids
          else
            u :: uids
        ) uids [] in
        update_index_uids mbox uids
      |_ -> return ()

    let read_subscriptions mbox =
      IrminIntf_tr.read mbox.trans (get_key mbox.mbox_key `Subscriptions) >>= function
      | Some str -> return (list_of_str_sexp str)
      | None -> return []
      
    let subscribe mbox =
      read_subscriptions mbox >>= fun l ->
      if list_find l (fun i -> i = mbox.mailbox) then 
        return ()
      else
        IrminIntf_tr.update mbox.trans (get_key mbox.mbox_key `Subscriptions)
          (str_sexp_of_list (mbox.mailbox :: l))

    let unsubscribe mbox =
      read_subscriptions mbox >>= fun l ->
      let l = List.fold_left (fun acc i -> if i = mbox.mailbox then acc else i :: acc) [] l in
      IrminIntf_tr.update mbox.trans (get_key mbox.mbox_key `Subscriptions)
        (str_sexp_of_list l)

    let list_mailbox mbox key =
      IrminIntf_tr.list mbox.trans (Key_.add_list mbox.mbox_key (Key_.mailboxes_of_mailbox key))

    let is_folder mbox key =
      exists_key mbox key >>= function
      | `Folder -> return true
      | _ -> return false

    let rec list_ mbox key subscriptions access init f =
      list_mailbox mbox key >>= fun listing ->
      Lwt_list.fold_left_s (fun (acc,cnt) name ->
        (* if folder is not accessible then neither are the children *)
        (* need to handle subscriptions TBD *)
        if access (Key_.view_key_to_path key) = false then
          return (acc,cnt)
        else (
          let key = Key_.t_of_list name in
          is_folder mbox key >>= fun res ->
          begin
          if res = true then (
            list_ mbox key subscriptions access acc f >>= fun (acc,cnt) -> 
            f acc (`Folder ((Key_.view_key_to_path key),cnt)) 
          ) else (
            list_ mbox key subscriptions access acc f >>= fun (acc,cnt) -> 
            f acc (`Mailbox ((Key_.view_key_to_path key), cnt)) 
          )
          end >>= fun (acc) ->
          return (acc,cnt+1)
        )
      ) (init,0) listing

    (* assuming that "reference" and "mailbox" arguments in list command
     * are converted into initial mailbox and regular expression to match
     * final mailbox to list is concat of the reference and mailbox minus wild
     * cards starting with the first delimeter followed by the wild card
     *)
    let list mbox ~subscribed ?(access=(fun _ -> true)) ~init ~f =
      let (_,key) = Key_.mailbox_of_path "" in
      begin
      if subscribed then (
        read_subscriptions mbox >>= fun sub -> return (Some sub)
      ) else (
        return None
      ) 
      end >>= fun subscriptions ->
      list_ mbox key subscriptions access init f >>= fun (acc,_) ->
      return acc

    let list_messages mbox k =
      let list_subtr store k =
        IrminIntf.list store k >>= fun l ->
        return (List.fold_left (fun acc i ->
          acc ^ ":" ^ (List.nth i ((List.length i) - 1))
        ) "" l)
      in
      IrminIntf.create ~user:mbox.user mbox.config >>= fun store ->
      IrminIntf.list store k >>= fun l ->
      Lwt_list.fold_left_s (fun acc i ->
        let k = Key_.t_of_list ((List.concat [k;i])) in
        list_subtr store k >>= fun s ->
        return (((Key_.key_to_string (Key_.t_of_list i)) ^ ":" ^ s) :: acc)
      ) [] l

    let show_all mbox =
      Printf.printf "---------- mailbox messages\n%!";
      let (_,key) = Key_.mailbox_of_path mbox.mailbox in
      let key = Key_.add_path key "messages" in
      list_messages mbox key >>= fun l ->
      List.iter (fun i -> Printf.printf "%s %!" i) l; Printf.printf "\n%!";
      Printf.printf "---------- mailbox index\n%!";
      read_index_uid mbox >>= fun uids ->
      List.iter (fun i -> Printf.printf "%d %!" i) uids; Printf.printf "\n%!";
      Printf.printf "---------- mailbox metadata\n%!";
      read_mailbox_metadata mbox >>= fun meta ->
      Printf.printf "%s\n%!" (Sexp.to_string (sexp_of_mailbox_metadata meta));
      Printf.printf "---------- subscriptions\n%!";
      read_subscriptions mbox >>= fun subscr ->
      List.iter (fun i -> Printf.printf "%s %!" i) subscr; Printf.printf "\n%!";
      return ()

  end

module UserAccount :
  sig
    type t

    val create : imapConfig -> string -> t
    val create_account : t -> [`Exists|`Ok] Lwt.t
    val delete_account : t -> unit Lwt.t
  end = 
  struct
    type t = string * imapConfig * Key_.t

    (* create type *)
    let create config user = 
      (user,config,Key_.create_account user)

    (* create new account *)
    let create_account key =
      let (user,config,key) = key in
      IrminIntf_tr.begin_transaction ~user config key >>= fun view ->
      IrminIntf_tr.mem view (Key_.t_of_path "subscriptions") >>= fun res ->
      if res then
        return `Exists
      else (
        IrminIntf_tr.update view (Key_.t_of_path "subscriptions") (str_sexp_of_list []) >>
        IrminIntf_tr.end_transaction view >>
        return `Ok
      )

    (* remove account *)
    let delete_account key =
      let (user,config,key) = key in
      IrminIntf.create ~user config >>= fun store ->
      IrminIntf.remove store key

  end
