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

(* ---- 1b. HOL filesystem: synchronous fetch from same origin.

   `make site` deploys the parent HOL Light tree at the site root, so a
   request for "/Library/words.ml" resolves to <origin>/Library/words.ml.
   Sync XHR is allowed inside Web Workers (it's only forbidden on the main
   thread), so loadt's expectation of synchronous Sys.file_exists/open_in
   is satisfiable.

   Once a file is fetched, jsoo caches it in its in-memory FS — so
   Digest.file works (loaded_files de-dup) and re-loadt is a no-op. *)

let http_fetch_sync url =
  (* Synchronous XHR via Js.Unsafe so we don't have to pull in the jsoo
     PPX just for ##.  Sync XHR is allowed in workers — it's only
     deprecated on the main thread. *)
  let xhr_ctor = Js.Unsafe.get Js.Unsafe.global (Js.string "XMLHttpRequest") in
  let xhr = Js.Unsafe.new_obj xhr_ctor [||] in
  let call m args =
    Js.Unsafe.meth_call xhr m (Array.map Js.Unsafe.inject args) in
  let _ : unit = call "open"
    [| Js.Unsafe.inject (Js.string "GET");
       Js.Unsafe.inject (Js.string url);
       Js.Unsafe.inject Js._false |] in
  (try
     let _ : unit = call "send" [||] in ()
   with _ -> ());
  let status : int = Js.Unsafe.get xhr (Js.string "status") in
  if status = 200 then
    let resp : Js.js_string Js.t Js.opt =
      Js.Unsafe.get xhr (Js.string "responseText") in
    Js.Opt.case resp (fun () -> None) (fun s -> Some (Js.to_string s))
  else None

let hol_fs_handler ~prefix:_ ~path =
  (* path is the part after the mount prefix, e.g. "Library/words.ml".
     Map it back to the deploy root over HTTP. *)
  http_fetch_sync ("/" ^ path)

(* Mount the deploy root at /hol/ rather than /.  jsoo's runtime already
   registers a default device at "/" during startup; a second mount at
   the same path is silently shadowed by the first (resolve_fs_device in
   fs.js prefers the earlier registration on equal-length prefixes), so
   Sys.file_exists "/meson.ml" would never reach our handler.  Mounting
   at /hol/ sidesteps the conflict; we then point HOL Light's $ at /hol
   so loadt's expansion `$/foo.ml` -> `/hol/foo.ml` lands on our device. *)
let () = Sys_js.mount ~path:"/hol/" hol_fs_handler

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

(* Wire HOL Light's [file_loader] hook to the jsoo toplevel so loads/loadt/
   needs evaluate fetched .ml files through the same execute path the REPL
   uses.  We set the ref directly from OCaml (rather than feeding a phrase
   through `exec`) because the runtime toplevel only resolves names listed
   in export.txt — embedding `Js_of_ocaml_toplevel.JsooTop.use` in a string
   that goes through the toplevel raises "Unbound value …".  Compiled
   OCaml has no such restriction; JsooTop is already linked into the
   bundle and `JsooTop.use` runs each ;;-terminated phrase through the
   same camlp5-equipped toplevel as the REPL. *)
let install_file_loader () =
  (* Point $ at our /hol/ mount.  The default load_path is ["."; "$"],
     so loadt "Library/foo.ml" tries "./Library/foo.ml" (which fails,
     since the worker's cwd is the default fs root with nothing there)
     and "/hol/Library/foo.ml" — the latter hits our XHR mount. *)
  Hol_loader.hol_dir := "/hol";
  Hol_loader.file_loader := (fun fname ->
    let ic = open_in fname in
    let n = in_channel_length ic in
    let buf = Bytes.create n in
    really_input ic buf 0 n;
    close_in ic;
    Js_of_ocaml_toplevel.JsooTop.use Format.std_formatter
      (Bytes.unsafe_to_string buf))

let () =
  (* `loadt`/`loads`/`needs` live in Hol_loader, not Hol_lib — open both
     so they're reachable bare from the REPL like in plain hol.sh. *)
  exec "open Hol_lib;;";
  exec "open Hol_loader;;";
  install_printers ();
  install_file_loader ();
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
        exec "open Hol_loader;;";
        install_printers ();
        install_file_loader ();
        post_tag "ready"
    | other ->
        post_chunk "stderr"
          (Printf.sprintf "<worker: unknown message kind %s>\n" other))
