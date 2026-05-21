(* Web Worker entry: HOL Light kernel running in a worker thread.

   Protocol (worker → page):
     { kind: "out"; stream: "stdout"|"stderr"|"sharp"|"caml"; text: string }
     { kind: "ready" }   (* sent once Hol_lib is fully open and printers are
                            installed.  The page enables the input then. *)
     { kind: "done"  }   (* sent after each "eval" finishes *)

   Protocol (page → worker):
     { kind: "eval"; src: string }
     { kind: "reset" }   (* re-init the toplevel; matches Cmd+K in
                            jsoo's lwt_toplevel example *)

   Streaming: the four jsoo Sys_js flushers post immediately, so the page
   sees output land as Format buffers flush.  HOL Light's bootstrap (the
   ~140s of "solved at N" lines) streams the same way because we install
   the flushers *before* JsooTop.initialize runs. *)

open Js_of_ocaml

(* stdout/stderr flushers are already installed by web_init.cmo, which is
   linked first.  We add two extra channels (sharp/caml) for the
   toplevel's own pp_code/output formatters. *)
let post_chunk = Web_init.post_chunk

let post_tag tag =
  Worker.post_message
    (Js.Unsafe.obj [| "kind", Js.Unsafe.inject (Js.string tag) |])

(* Mount /dev/ as a sink so [open_out] on a fresh path under it succeeds.
   (Without the mount, jsoo's default fs raises EACCES.)  Matches the
   convention used by jsoo's own lwt_toplevel example. *)
let () = Sys_js.mount ~path:"/dev/" (fun ~prefix:_ ~path:_ -> None)

let sharp_chan = open_out "/dev/sharp"
let caml_chan  = open_out "/dev/caml"
let sharp_ppf  = Format.formatter_of_out_channel sharp_chan
let caml_ppf   = Format.formatter_of_out_channel caml_chan

let () =
  Sys_js.set_channel_flusher sharp_chan (post_chunk "sharp");
  Sys_js.set_channel_flusher caml_chan  (post_chunk "caml")

(* ---- 2. Toplevel init. *)

let () = Js_of_ocaml_toplevel.JsooTop.initialize ()

let () =
  Load_path.reset ();
  Topdirs.dir_directory "/static/cmis"

let exec src =
  (try
     Js_of_ocaml_toplevel.JsooTop.execute
       true
       ~pp_code:sharp_ppf
       ~highlight_location:(fun _ -> ())
       caml_ppf
       src
   with e ->
     Format.fprintf caml_ppf "Exception: %s@." (Printexc.to_string e));
  Format.pp_print_flush sharp_ppf ();
  Format.pp_print_flush caml_ppf ()

(* ---- 3. HOL Light kernel + printer install.  Each #install_printer is its
        own phrase so the toplevel resolves the names against the env that
        was just extended by `open Hol_lib`. *)

let install_printers () =
  let printers =
    [ "pp_print_num"; "pp_print_fpf";
      "pp_print_colored_qterm"; "pp_print_colored_qtype";
      "pp_print_colored_thm";   "pp_print_colored_goal";
      "pp_print_colored_goalstack" ] in
  List.iter
    (fun name -> exec (Printf.sprintf "#install_printer %s;;" name))
    printers

let () =
  exec "open Hol_lib;;";
  install_printers ();
  post_tag "ready"

(* ---- 4. Main loop. *)

let () =
  Worker.set_onmessage (fun msg ->
    let msg = (msg : < .. > Js.t) in
    let kind = Js.to_string (Js.Unsafe.get msg (Js.string "kind")) in
    match kind with
    | "eval" ->
        let src = Js.to_string (Js.Unsafe.get msg (Js.string "src")) in
        exec src;
        post_tag "done"
    | "reset" ->
        Js_of_ocaml_toplevel.JsooTop.initialize ();
        exec "open Hol_lib;;";
        install_printers ();
        post_tag "ready"
    | other ->
        post_chunk "stderr"
          (Printf.sprintf "<worker: unknown message kind %s>\n" other))
