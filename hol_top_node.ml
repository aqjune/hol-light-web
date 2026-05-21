(* Node-based jsoo toplevel smoke test for HOL Light.
   Mirrors test_toplevel1.ml but linked with hol_lib.cma so the
   in-browser/node OCaml toplevel sees Hol_lib's identifiers. *)

let () = Js_of_ocaml_toplevel.JsooTop.initialize ()

let () =
  Load_path.reset ();
  Topdirs.dir_directory "/static/cmis"

let fmt = Format.std_formatter

let () =
  Js_of_ocaml.Sys_js.set_channel_flusher stderr (fun str ->
      Printf.printf "<ERR>: %s" str)

let exec code =
  Js_of_ocaml_toplevel.JsooTop.execute
    true
    ~pp_code:fmt
    ~highlight_location:(fun _ -> ())
    fmt
    code

let () =
  exec "open Hol_lib;;";
  Format.printf "@.--- Test 1: backquote syntax for terms ---@.";
  exec "let tm = `x + 1 = 1 + x`;;";
  Format.printf "@.--- Test 2: prove with ARITH_TAC ---@.";
  exec "let th = prove (`x + 1 = 1 + x`, ARITH_TAC);;";
  Format.printf "@.--- Test 3: interactive goal stack ---@.";
  exec "g `(x + 2) * y = x * y + 2 * y`;;";
  exec "e ARITH_TAC;;";
  exec "let mythm = top_thm();;"
