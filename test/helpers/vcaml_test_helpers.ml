open Core
open Async
open Vcaml

let neovim_path = Core.Sys.getenv "NEOVIM_PATH" |> Option.value ~default:"nvim"
let hundred_ms = Time_ns.Span.create ~ms:100 ()

let time_source_at_epoch =
  Time_source.read_only (Time_source.create ~now:Time_ns.epoch ())
;;

(* Start with no init.vim, no shada file, and no swap files. *)
let default_args = [ "--clean"; "-n" ]

(* Start the editor without a gui, use stdin and stdout instead of Unix pipe for
   communication with the plugin, place socket relative to the temporary working directory
   since there's some undocumented internal limit for the socket length (it doesn't appear
   in `:h limits). *)
let required_args = [ "--headless"; "--embed"; "--listen"; "./socket" ]

let with_client
      ?(args = default_args)
      ?env
      ?links
      ?(time_source = time_source_at_epoch)
      ?(on_error = `Raise)
      ?(before_connecting = ignore)
      f
  =
  Expect_test_helpers_async.within_temp_dir ?links (fun () ->
    let nvim_log_file = "nvim_low_level_log.txt" in
    let args = required_args @ args in
    let%bind working_dir = Sys.getcwd () in
    let env =
      let env =
        let base =
          Core_unix.Env.expand
            (`Extend
               [ "NVIM_LOG_FILE", nvim_log_file; "NVIM_RPLUGIN_MANIFEST", "rplugin.vim" ])
        in
        match env with
        | None -> base
        | Some getenv ->
          Core_unix.Env.expand ~base:(Lazy.from_val base) (getenv (`Tmpdir working_dir))
      in
      `Replace_raw env
    in
    let client = Client.create ~on_error in
    before_connecting client;
    let%bind client, process =
      Client.attach
        client
        (Embed { prog = neovim_path; args; working_dir; env })
        ~time_source
      >>| ok_exn
    in
    let%bind result = f client >>| ok_exn in
    let%bind () = Client.close client in
    let%bind () =
      (* Because the client is embedded, stdin and stdout are used for Msgpack RPC.
         However, there still may be errors reported on stderr that we should capture. *)
      let%map stderr = Reader.contents (Process.stderr process)
      and low_level_log = Reader.file_contents nvim_log_file in
      [ stderr; low_level_log ]
      |> List.filter ~f:(Fn.non String.is_empty)
      |> String.concat ~sep:"\n"
      |> print_string
    in
    return result)
;;

let print_s ?mach sexp =
  let working_dir = Sys_unix.getcwd () in
  let rec filter ~tmp_dir : Sexp.t -> Sexp.t = function
    | Atom atom ->
      Atom (String.substr_replace_all atom ~pattern:tmp_dir ~with_:"${TMPDIR}")
    | List list -> List (List.map list ~f:(filter ~tmp_dir))
  in
  (* [Expect_test_helpers_async.with_temp_dir] uses this suffix. *)
  match String.is_suffix working_dir ~suffix:".tmp" with
  | false -> print_s ?mach sexp
  | true -> print_s ?mach (filter sexp ~tmp_dir:working_dir)
;;

let simple here k to_sexp =
  with_client (fun client ->
    let%map.Deferred.Or_error result = run_join here client k in
    print_s (to_sexp result))
;;

module Test_ui = struct
  type t =
    { mutable buffer : string array array
    ; mutable cursor_col : int
    ; mutable cursor_row : int
    ; flushed : [ `Awaiting_first_flush | `Flush of string | `Detached ] Mvar.Read_write.t
    ; ui : Ui.t Set_once.t
    ; client : [ `connected ] Client.t
    }

  let ui_to_string t =
    let module Buffer = Core.Buffer in
    let buffer = Buffer.create 0 in
    Buffer.add_string buffer "╭";
    Buffer.add_string
      buffer
      (List.init (Array.length t.buffer.(0)) ~f:(Fn.const "─") |> String.concat);
    Buffer.add_string buffer "╮";
    Buffer.add_char buffer '\n';
    Array.iter t.buffer ~f:(fun row ->
      if String.equal row.(0) "─"
      then Buffer.add_string buffer "├"
      else Buffer.add_string buffer "│";
      Array.iter row ~f:(fun string -> Buffer.add_string buffer string);
      if String.equal (Array.last row) "─"
      then Buffer.add_string buffer "┤"
      else Buffer.add_string buffer "│";
      Buffer.add_char buffer '\n');
    Buffer.add_string buffer "╰";
    Buffer.add_string
      buffer
      (List.init (Array.length t.buffer.(0)) ~f:(Fn.const "─") |> String.concat);
    Buffer.add_string buffer "╯";
    Buffer.contents buffer
  ;;

  (* Applies a message from the neovim "redraw" ui message sequence. *)
  let apply t (event : Ui.Event.t) =
    let unflush t =
      match Mvar.peek t.flushed with
      | None | Some (`Awaiting_first_flush | `Detached) -> ()
      | Some (`Flush _) -> ignore (Mvar.take_now_exn t.flushed : _)
    in
    match event with
    | Flush ->
      (match Mvar.peek t.flushed with
       | Some `Detached -> ()
       | Some `Awaiting_first_flush -> ignore (Mvar.take_now_exn t.flushed : _)
       | None | Some (`Flush _) -> Mvar.set t.flushed (`Flush (ui_to_string t)))
    | Grid_line { grid = 1; row; col_start; data } ->
      unflush t;
      let col = ref col_start in
      let write str =
        t.buffer.(row).(!col) <- str;
        incr col
      in
      List.iter data ~f:(function
        | Array ([ String str ] | [ String str; Integer _ ]) -> write str
        | Array [ String str; Integer _; Integer repeat ] ->
          for _ = 1 to repeat do
            write str
          done
        | _ -> raise_s [%message "Malformed gridline data" (data : Msgpack.t list)])
    | Grid_clear { grid = 1 } ->
      unflush t;
      Array.iter t.buffer ~f:(fun row ->
        Array.fill row ~pos:0 ~len:(Array.length row) " ")
    | Grid_cursor_goto { grid = 1; row; col } ->
      unflush t;
      t.cursor_col <- col;
      t.cursor_row <- row
    | Grid_resize { grid = 1; width; height } ->
      unflush t;
      let new_array = Array.init height ~f:(fun _ -> Array.create ~len:width " ") in
      Array.iteri t.buffer ~f:(fun y row ->
        Array.iteri row ~f:(fun x c ->
          if x < width && y < height then new_array.(y).(x) <- c));
      t.buffer <- new_array
    | Grid_scroll { grid = 1; top; bot; left = _; right = _; rows; cols = 0 } ->
      (* In Neovim 0.7.0, [cols] is fixed at [0] so we never need [left] or [right]. *)
      unflush t;
      (* Establish our understanding of grid scrolling. If this is violated we are
         probably misinterpreting this event. *)
      assert (abs rows < bot - top);
      (match Sign.of_int rows with
       | Zero -> ()
       | Neg ->
         for i = bot - 1 downto top - rows do
           t.buffer.(i) <- Array.copy t.buffer.(i + rows)
         done
       | Pos ->
         for i = top to bot - 1 - rows do
           t.buffer.(i) <- Array.copy t.buffer.(i + rows)
         done)
    | Win_viewport _ ->
      (* This only applies to ext_multigrid but is sent anyway due to a bug:
         https://github.com/neovim/neovim/issues/14956 *)
      ()
    | Default_colors_set _
    | Highlight_set _
    | Hl_attr_define _
    | Hl_group_set _
    | Mode_change _
    | Mode_info_set _
    | Mouse_off
    | Mouse_on
    | Option_set _
    | Update_bg _
    | Update_fg _
    | Update_sp _ -> ()
    | _ -> raise_s [%message "Ignored UI event" (event : Ui.Event.t)]
  ;;

  let attach ?(width = 80) ?(height = 30) here client =
    let open Deferred.Or_error.Let_syntax in
    let t =
      { buffer = [||]
      ; cursor_col = 0
      ; cursor_row = 0
      ; flushed = Mvar.create ()
      ; ui = Set_once.create ()
      ; client
      }
    in
    Mvar.set t.flushed `Awaiting_first_flush;
    let%bind ui =
      Ui.attach
        here
        client
        ~width
        ~height
        ~options:Ui.Options.default
        ~on_event:(apply t)
        ~on_parse_error:`Raise
    in
    Set_once.set_exn t.ui [%here] ui;
    return t
  ;;

  let detach t here =
    Mvar.set t.flushed `Detached;
    Ui.detach (Set_once.get_exn t.ui [%here]) here
  ;;

  let with_ui ?width ?height here client f =
    let open Deferred.Or_error.Let_syntax in
    let%bind t = attach here ?width ?height client in
    let%bind result = f t in
    let%bind () = detach t here in
    return result
  ;;
end

let rec get_screen_contents here ui =
  match Mvar.peek ui.Test_ui.flushed with
  | None ->
    let%bind () = Mvar.value_available ui.flushed in
    get_screen_contents here ui
  | Some `Awaiting_first_flush ->
    let%bind () = Clock_ns.after hundred_ms in
    get_screen_contents here ui
  | Some (`Flush screen) ->
    (* Attempt to confirm that Neovim has finished sending updates. We don't want to grab
       a flush if more data is immediately following. *)
    choose
      [ choice (Mvar.taken ui.flushed) (fun () -> get_screen_contents here ui)
      ; choice (Clock_ns.after hundred_ms) (fun () -> Deferred.Or_error.return screen)
      ]
    |> Deferred.join
  | Some `Detached ->
    Deferred.Or_error.error_s [%message "Tried to get screen contents of detached UI"]
;;

let wait_until_text ?(timeout = Time_ns.Span.of_int_sec 2) here ui ~f =
  let open Deferred.Or_error.Let_syntax in
  let wait_until_text ~f =
    let is_timed_out = ref false in
    Clock_ns.run_after timeout (fun () -> is_timed_out := true) ();
    let%bind result =
      let repeating () =
        let%bind output = get_screen_contents here ui in
        match f output, !is_timed_out with
        | true, _ -> return (`Finished (Ok ()))
        | false, true -> return (`Finished (Error output))
        | false, false ->
          let%map _ = Deferred.ok (Clock_ns.after hundred_ms) in
          `Repeat ()
      in
      Deferred.Or_error.repeat_until_finished () repeating
    in
    match result with
    | Ok () -> return ()
    | Error screen_contents ->
      (* print here instead of returning the string in the error in order to
         keep the sexp-printing from ruining all the unicode chars *)
      let error = Error.of_string "ERROR: timeout when looking for value on screen" in
      printf !"%{Error.to_string_hum}\n%s\n" error screen_contents;
      Deferred.Or_error.fail error
  in
  let wait_until_text_stabilizes () =
    let prev_text = ref None in
    let%bind () =
      wait_until_text ~f:(fun text ->
        match !prev_text with
        | Some prev_text when String.equal text prev_text -> true
        | Some _ | None ->
          prev_text := Some text;
          false)
    in
    return (Option.value_exn !prev_text)
  in
  let%bind () = wait_until_text ~f in
  wait_until_text_stabilizes ()
;;

let with_ui_client ?width ?height ?time_source ?on_error ?before_connecting f =
  with_client ?time_source ?on_error ?before_connecting (fun client ->
    Test_ui.with_ui [%here] ?width ?height client (fun ui -> f client ui))
;;

let socket_client
      ?(time_source = time_source_at_epoch)
      ?(on_error = `Raise)
      ?(before_connecting = ignore)
      socket
  =
  let client = Client.create ~on_error in
  before_connecting client;
  Client.attach client ~time_source (Unix (`Socket socket))
;;

module For_debugging = struct
  let with_ui_client
        ?(time_source = time_source_at_epoch)
        ?(on_error = `Raise)
        ?(before_connecting = ignore)
        ~socket
        f
    =
    let%bind client =
      let client = Client.create ~on_error in
      before_connecting client;
      Client.attach client ~time_source (Unix (`Socket socket)) >>| ok_exn
    in
    let%bind attached_uis = run_join [%here] client Ui.describe_attached_uis >>| ok_exn in
    let width, height =
      attached_uis
      |> List.map ~f:(fun { width; height; _ } -> width, height)
      |> List.unzip
      |> Tuple2.map ~f:(List.min_elt ~compare)
      |> Tuple2.map ~f:(fun opt -> Option.value_exn opt)
    in
    let%bind result =
      Test_ui.with_ui [%here] ~width ~height client (fun ui -> f client ui) >>| ok_exn
    in
    let%map () = Client.close client in
    result
  ;;
end

let%expect_test "We cannot have two blocking RPCs with the same name" =
  let register_dummy_rpc_handler ~name client =
    register_request_blocking
      client
      ~name
      ~type_:Defun.Ocaml.Sync.(Nil @-> return Nil)
      ~f:(fun ~keyboard_interrupted:_ ~client:_ () -> Deferred.Or_error.return ())
  in
  let%map () =
    with_client (fun client ->
      register_dummy_rpc_handler client ~name:"test";
      Expect_test_helpers_base.require_does_raise [%here] (fun () ->
        register_dummy_rpc_handler client ~name:"test");
      Deferred.Or_error.return ())
  in
  [%expect {| (Failure "Already defined synchronous RPC 'test'") |}]
;;

let%expect_test "We cannot have two async RPCs with the same name" =
  let register_dummy_rpc_handler ~name client =
    register_request_async
      client
      ~name
      ~type_:Defun.Ocaml.Async.(Nil @-> unit)
      ~f:(fun ~client:_ () -> Deferred.Or_error.return ())
  in
  let%map () =
    with_client (fun client ->
      register_dummy_rpc_handler client ~name:"test";
      Expect_test_helpers_base.require_does_raise [%here] (fun () ->
        register_dummy_rpc_handler client ~name:"test");
      Deferred.Or_error.return ())
  in
  [%expect {| (Failure "Already defined asynchronous RPC 'test'") |}]
;;

(* We allow this in case a plugin wants to implement slightly different semantics based
   on whether it is called with [rpcrequest] or [rpcnotify]. *)
let%expect_test "We can have an async RPC and a blocking RPC with the same name" =
  let%map () =
    with_client (fun client ->
      let name = "test" in
      register_request_blocking
        client
        ~name
        ~type_:Defun.Ocaml.Sync.(Nil @-> return Nil)
        ~f:(fun ~keyboard_interrupted:_ ~client:_ () -> Deferred.Or_error.return ());
      register_request_async
        client
        ~name
        ~type_:Defun.Ocaml.Async.(Nil @-> unit)
        ~f:(fun ~client:_ () -> Deferred.Or_error.return ());
      Deferred.Or_error.return ())
  in
  [%expect {| |}]
;;

let%expect_test "We can have two separate Embedded connections with RPC handlers sharing \
                 names without error (no bleeding state)"
  =
  let register_dummy_rpc_handler ~name client =
    register_request_blocking
      client
      ~name
      ~type_:Defun.Ocaml.Sync.(Nil @-> return Nil)
      ~f:(fun ~keyboard_interrupted:_ ~client:_ () -> Deferred.Or_error.return ());
    Deferred.Or_error.return ()
  in
  let%bind () = with_client (register_dummy_rpc_handler ~name:"test") in
  let%map () = with_client (register_dummy_rpc_handler ~name:"test") in
  [%expect {| |}]
;;