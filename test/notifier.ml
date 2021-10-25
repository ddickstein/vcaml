open! Core
open! Async
open! Import
open Vcaml
open Test_client
module Notifier = Vcaml.Expert.Notifier
module Notification = Notifier.Notification

let get_current_chan ~client =
  let%map.Deferred.Or_error chan_list = Nvim.list_chans |> run_join [%here] client in
  List.hd_exn chan_list
;;

let%expect_test "Simple asynchronous notification" =
  let result =
    let result = Ivar.create () in
    with_client
      ~on_error_event:(fun error_type ~message ->
        print_s [%message message (error_type : Notifier.Error_type.t)])
      (fun client ->
         let open Deferred.Or_error.Let_syntax in
         let%bind channel =
           let%map channel = get_current_chan ~client in
           channel.id
         in
         let call_async_func =
           Notification.custom
             ~type_:Notification.Defun.Vim.(Integer @-> String @-> Nil @-> unit)
             ~function_name:"rpcnotify"
             channel
             "async_func"
         in
         register_request_async
           [%here]
           client
           ~name:"async_func"
           ~type_:Defun.Ocaml.Async.(Nil @-> unit)
           ~f:(fun () -> Deferred.return (Ivar.fill result "Called!"));
         Notifier.notify client (call_async_func ());
         Ivar.read result |> Deferred.ok)
  in
  let%bind result = with_timeout (Time.Span.of_int_sec 3) result in
  print_s [%sexp (result : [ `Result of string | `Timeout ])];
  [%expect {| (Result Called!) |}];
  return ()
;;

let%expect_test "Bad asynchronous notification" =
  let result =
    let result = Ivar.create () in
    with_client
      ~on_error_event:(fun error_type ~message ->
        print_s [%message message (error_type : Notifier.Error_type.t)];
        Ivar.fill result "Received asynchronous failure message.")
      (fun client ->
         Notifier.For_testing.send_raw client ~function_name:"" ~params:[];
         Ivar.read result |> Deferred.ok)
  in
  let%bind result = with_timeout (Time.Span.of_int_sec 3) result in
  print_s [%sexp (result : [ `Result of string | `Timeout ])];
  [%expect
    {|
    ("Invalid method: <empty>" (error_type Exception))
    (Result "Received asynchronous failure message.") |}];
  return ()
;;