(* Linked FIRST in the worker bundle so its top-level init runs before
   Hol_lib.cmo starts printing "solved at N" during boot.  Registers the
   Sys_js channel flushers and exposes [post_chunk] so hol_top_worker.ml
   can reuse them for the sharp/caml channels it owns. *)

open Js_of_ocaml

let post_chunk stream text =
  Worker.post_message
    (Js.Unsafe.obj
       [| "kind",   Js.Unsafe.inject (Js.string "out");
          "stream", Js.Unsafe.inject (Js.string stream);
          "text",   Js.Unsafe.inject (Js.string text) |])

let () =
  Sys_js.set_channel_flusher stdout (post_chunk "stdout");
  Sys_js.set_channel_flusher stderr (post_chunk "stderr")
