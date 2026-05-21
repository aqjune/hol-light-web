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

(* Override `help` after loading help.ml.  The upstream `help` calls
   Sys.readdir on Help/ (HTTP can't enumerate directories — we serve a
   pre-computed Help/index.txt instead) and then shells out to
   `sed -f doc-to-help.sed` (no shell under jsoo).  This replacement
   reads the pre-computed listing for fuzzy match, fetches the .hlp
   file directly, and applies a minimal subset of the sed transforms
   in OCaml.  Same external behaviour as `hol.sh`'s `help "type_of"`. *)
let help_override = {ocaml|
let _web_read_file fn =
  let ic = open_in fn in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.unsafe_to_string buf;;

let _web_help_listing () =
  let s = _web_read_file (Hol_loader.hol_expand_directory "$/Help/index.txt") in
  String.split_on_char '\n' s
  |> List.filter (fun l -> l <> "");;

(* Minimal OCaml port of doc-to-help.sed: enough to make the .hlp files
   readable in a terminal pane, not bit-identical to the sed output. *)
let _web_format_hlp text =
  let lines = String.split_on_char '\n' text in
  let buf = Buffer.create (String.length text) in
  let drop_until_blank = ref false in
  let rename_section l = match l with
    | "\\SYNOPSIS"   -> Some "SYNOPSIS"
    | "\\CATEGORIES" -> Some "CATEGORIES"
    | "\\DESCRIBE"   -> Some "DESCRIPTION"
    | "\\FAILURE"    -> Some "FAILURE CONDITIONS"
    | "\\EXAMPLE"    -> Some "EXAMPLES"
    | "\\USES"       -> Some "USES"
    | "\\COMMENTS"   -> Some "COMMENTS"
    | "\\SEEALSO"    -> Some "SEE ALSO"
    | _ -> None in
  let starts s prefix =
    String.length s >= String.length prefix
    && String.sub s 0 (String.length prefix) = prefix in
  let strip_braces s =
    let b = Buffer.create (String.length s) in
    String.iter (fun c -> if c <> '{' && c <> '}' then Buffer.add_char b c) s;
    Buffer.contents b in
  List.iter (fun raw ->
    if !drop_until_blank then
      (if String.trim raw = "" then drop_until_blank := false)
    else if starts raw "\\KEYWORDS" || starts raw "\\LIBRARY" then
      drop_until_blank := true
    else if starts raw "\\DOC" || starts raw "\\BLTYPE"
         || starts raw "\\ELTYPE" || starts raw "\\ENDDOC" then
      ()
    else if starts raw "\\TYPE" then
      let rest = String.sub raw 5 (String.length raw - 5) in
      Buffer.add_string buf (strip_braces (String.trim rest));
      Buffer.add_char buf '\n'
    else match rename_section (String.trim raw) with
      | Some name ->
          Buffer.add_string buf name;
          Buffer.add_string buf "\n\n"
      | None ->
          Buffer.add_string buf (strip_braces raw);
          Buffer.add_char buf '\n'
  ) lines;
  Buffer.contents buf;;

let help s =
  let listing = _web_help_listing () in
  let edit_distance s1 s2 =
    let l1 = String.length s1 and l2 = String.length s2 in
    let a = Array.make_matrix (l1 + 1) (l2 + 1) 0 in
    for i = 1 to l1 do a.(i).(0) <- i done;
    for j = 1 to l2 do a.(0).(j) <- j done;
    for i = 1 to l1 do for j = 1 to l2 do
      let cost = if s1.[i-1] = s2.[j-1] then 0 else 1 in
      a.(i).(j) <- min (min (a.(i-1).(j) + 1) (a.(i).(j-1) + 1))
                       (a.(i-1).(j-1) + cost)
    done done;
    a.(l1).(l2) in
  Format.print_string
    "-------------------------------------------------------------------\n";
  Format.print_flush ();
  if List.mem s listing then begin
    let path = Hol_loader.hol_expand_directory ("$/Help/" ^ s ^ ".hlp") in
    Format.print_string (_web_format_hlp (_web_read_file path))
  end else begin
    let scored =
      List.map (fun s' ->
        let su  = String.uppercase_ascii s
        and s'u = String.uppercase_ascii s' in
        s', 2.0 *. float_of_int (edit_distance su s'u)
            /. float_of_int (String.length s + String.length s')) listing in
    let scored = List.sort (fun (_,a) (_,b) -> compare a b) scored in
    let rec take n = function
      | _ when n = 0 -> []
      | [] -> []
      | x :: xs -> x :: take (n - 1) xs in
    Format.print_string ("No help found for \"" ^ s ^ "\"; did you mean:\n\n");
    List.iter (fun (g, _) ->
      Format.print_string ("help \"" ^ g ^ "\";;\n")) (take 3 scored);
    Format.print_string "\n?\n"
  end;
  Format.print_string
    "--------------------------------------------------------------------\n";
  Format.print_flush ();;
|ocaml}

let () =
  (* `loadt`/`loads`/`needs` live in Hol_loader, not Hol_lib — open both
     so they're reachable bare from the REPL like in plain hol.sh. *)
  exec "open Hol_lib;;";
  exec "open Hol_loader;;";
  install_printers ();
  install_file_loader ();
  (* Auto-load help.ml and update_database.ml so search/help "just work"
     out of the box, as in hol.sh.  Order: help.ml first, then our
     override (which redefines `help`), then update_database.ml. *)
  exec "loadt \"help.ml\";;";
  exec help_override;
  exec "loadt \"update_database.ml\";;";
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
        exec "loadt \"help.ml\";;";
        exec help_override;
        exec "loadt \"update_database.ml\";;";
        post_tag "ready"
    | other ->
        post_chunk "stderr"
          (Printf.sprintf "<worker: unknown message kind %s>\n" other))
