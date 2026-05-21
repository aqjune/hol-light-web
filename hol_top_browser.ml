(* Browser-side HOL Light toplevel.

   Exposes a single JS function [holEval(src) : string] that evaluates an
   OCaml/HOL-Light source fragment in the embedded toplevel and returns its
   captured stdout/stderr.  The intent is for index.html to call this from a
   button-handler and append the result to a <pre> log. *)

let () = Js_of_ocaml_toplevel.JsooTop.initialize ()

let () =
  Load_path.reset ();
  Topdirs.dir_directory "/static/cmis"

(* Capture everything the toplevel writes via Format/Printf into a buffer
   so we can hand it back to JavaScript as a string. *)
let buf = Buffer.create 1024
let fmt = Format.formatter_of_buffer buf

let () =
  (* Capture errors written to stderr too. *)
  Js_of_ocaml.Sys_js.set_channel_flusher stderr (fun s -> Buffer.add_string buf s);
  Js_of_ocaml.Sys_js.set_channel_flusher stdout (fun s -> Buffer.add_string buf s)

let eval src =
  Buffer.clear buf;
  (try
     Js_of_ocaml_toplevel.JsooTop.execute
       true
       ~pp_code:fmt
       ~highlight_location:(fun _ -> ())
       fmt
       src
   with e ->
     Format.fprintf fmt "Exception: %s@." (Printexc.to_string e));
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let () =
  (* Open Hol_lib once at startup so user code does not need to. *)
  let banner = eval "open Hol_lib;;" in
  ignore banner;
  let open Js_of_ocaml in
  Js.Unsafe.set Js.Unsafe.global "holEval"
    (Js.wrap_callback (fun s -> Js.string (eval (Js.to_string s))))
