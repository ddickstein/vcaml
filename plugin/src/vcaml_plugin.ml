open! Core
open! Async
open Vcaml_test
open Vcaml
open Deferred.Or_error.Let_syntax
module Rpc_handler = Vcaml_plugin_intf.Rpc_handler

let get_client () =
  let pipe = Sys.getenv_exn "NVIM_LISTEN_ADDRESS" in
  let%bind client, _process = Client.attach (Unix pipe) in
  return client
;;

let handle_buffer_event ~client ~event ~on_buffer_event ~on_buffer_close ~state =
  match event with
  | (Buf.Event.Lines _ | Changed_tick _) as event -> on_buffer_event state client event
  | Detach _ -> on_buffer_close state client
;;

let setup_buffer_events ~client ~buffer ~state ~on_buffer_event ~on_buffer_close =
  let%bind pipe_reader = Buf.attach client ~buffer:(`Numbered buffer) ~send_buffer:true in
  Async.don't_wait_for
  @@ Pipe.iter pipe_reader ~f:(fun event ->
    let%bind.Deferred handle_res =
      handle_buffer_event ~client ~event ~on_buffer_event ~on_buffer_close ~state
    in
    Or_error.iter_error ~f:(Fn.compose print_s Error.sexp_of_t) handle_res;
    Deferred.return ());
  return ()
;;

module Oneshot = struct
  module type Arg = Vcaml_plugin_intf.Oneshot_arg
  module type S = Vcaml_plugin_intf.Oneshot_s

  module Make (O : Arg) = struct
    let run_for_testing = O.execute

    let run () =
      let%bind client = get_client () in
      O.execute client
    ;;

    let command ~summary () =
      Command.async_or_error ~summary (Command.Param.return (fun () -> run ()))
    ;;
  end
end

module Persistent = struct
  module type Arg = Vcaml_plugin_intf.Persistent_arg
  module type S = Vcaml_plugin_intf.Persistent_s

  module Make (P : Arg) = struct
    type state = P.state

    let register_handler ~client ~state ~handler ~shutdown =
      match handler with
      | Rpc_handler.Sync_handler { name; type_; f } ->
        Vcaml.register_request_blocking
          client
          ~name
          ~type_
          ~f:(f (client, state, shutdown))
      | Async_handler { name; type_; f } ->
        Or_error.return
          (Vcaml.register_request_async
             client
             ~name
             ~type_
             ~f:(f (client, state, shutdown)))
    ;;

    let perform_handler_registration ~client ~state ~handlers ~shutdown =
      Deferred.return
        (handlers
         |> List.map ~f:(fun handler -> register_handler ~client ~state ~handler ~shutdown)
         |> Or_error.all_unit)
    ;;

    let notify_vim_of_plugin_start ~client ~chan_id ~vimscript_notify_fn =
      match vimscript_notify_fn with
      | None -> return ()
      | Some fn_name ->
        let%map.Deferred.Or_error (_ : Msgpack.t) =
          Client.call_function ~fn:fn_name ~args:[ Integer chan_id ] |> run_join client
        in
        ()
    ;;

    let send_dummy_request ~client =
      Vcaml.run_join client (Client.call_function ~fn:"abs" ~args:[ Integer 0 ])
    ;;

    (* Due to a bug in the way that neovim handles messages
       (https://github.com/neovim/neovim/issues/12722), it is possible that synchronous RPCs
       which kick off asynchronous updates under the hood will hang. As a result, we send
       dummy requests to neovim occasionally, to ensure that the messages are actually being
       consumed by neovim and things don't hang on people who create persistent plugins. *)
    let start_heartbeating_neovim client =
      let open Deferred.Let_syntax in
      don't_wait_for
      @@ Deferred.repeat_until_finished () (fun () ->
        let%bind () = Async.after (Core.sec 0.1) in
        match%map send_dummy_request ~client with
        | Ok _ -> `Repeat ()
        (* We think that the only scenario where this call will fail is when neovim dies. *)
        | Error _ -> `Finished ())
    ;;

    let run_internal ~client ~during_plugin =
      let terminate_var = Ivar.create () in
      let shutdown () = Ivar.fill_if_empty terminate_var () in
      let%bind chan_id = Client.get_rpc_channel_id client in
      start_heartbeating_neovim client;
      let%bind state = P.startup (client, shutdown) in
      let%bind () =
        perform_handler_registration ~client ~state ~handlers:P.rpc_handlers ~shutdown
      in
      let%bind () =
        notify_vim_of_plugin_start
          ~client
          ~chan_id
          ~vimscript_notify_fn:P.vimscript_notify_fn
      in
      let%bind () = during_plugin ~client ~chan_id ~state in
      let%bind () = Deferred.ok (Ivar.read terminate_var) in
      let%bind () = P.on_shutdown (client, state) in
      Deferred.Or_error.return state
    ;;

    let ignore_during_plugin ~chan_id:_ ~state:_ = Deferred.Or_error.return ()

    let run () =
      let%bind client = get_client () in
      let%bind _state =
        run_internal ~client ~during_plugin:(fun ~client:_ -> ignore_during_plugin)
      in
      return ()
    ;;

    let run_for_testing ?(during_plugin = ignore_during_plugin) client =
      run_internal ~client ~during_plugin:(fun ~client:_ -> during_plugin)
    ;;

    let command ~summary () =
      Command.async_or_error ~summary (Command.Param.return (fun () -> run ()))
    ;;
  end
end

module For_testing = struct
  let with_client = Test_client.with_client

  let run_rpc_call ~client ~chan_id ~name ~args =
    Vcaml.run_join
      client
      (Client.call_function
         ~fn:"rpcrequest"
         ~args:([ Msgpack.Integer chan_id; String name ] @ args))
  ;;
end