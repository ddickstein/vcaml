open Core
open Async
open Vcaml
open Vcaml_test_helpers

let%expect_test "open neovim and get channel list" =
  let%bind () =
    simple [%here] Nvim.channels (fun channels ->
      channels |> List.length > 0 |> sexp_of_bool)
  in
  [%expect "true"];
  return ()
;;

let%expect_test "get_channel_info" =
  let%bind () =
    simple [%here] (Nvim.get_channel_info 1) ("call-succeeded" |> Sexp.Atom |> Fn.const)
  in
  [%expect "call-succeeded"];
  return ()
;;

let%expect_test "command output" =
  let%bind () = simple [%here] (Nvim.source "echo 'hi'") sexp_of_string in
  [%expect "hi"];
  return ()
;;

let%expect_test "command, list_bufs, Buffer.get_name" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind () = Nvim.command "e foo.txt" |> run_join [%here] client in
      let%bind () = Nvim.command "e bar.txt" |> run_join [%here] client in
      let%bind () = Nvim.command "e baz.txt" |> run_join [%here] client in
      let%bind buffers = Nvim.list_bufs |> run_join [%here] client in
      let%map buffer_names =
        buffers
        |> List.map ~f:(fun buffer ->
          Buffer.get_name (Id buffer) |> run_join [%here] client)
        |> Deferred.Or_error.combine_errors
        |> Deferred.Or_error.map ~f:(fun filenames ->
          List.map filenames ~f:(fun file -> file |> Filename.parts |> List.last_exn))
      in
      print_s [%message (buffers : Buffer.t list) (buffer_names : string list)])
  in
  [%expect {|
    ((buffers (1 2 3)) (buffer_names (foo.txt bar.txt baz.txt)))|}];
  return ()
;;

let%expect_test "eval" =
  let%bind () = simple [%here] (Nvim.eval "1 + 2" ~result_type:Integer) [%sexp_of: int] in
  [%expect {| 3 |}];
  return ()
;;

let%expect_test "set_current_buf" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind () = Nvim.command "e foo.txt" |> run_join [%here] client in
      let%bind expected_buf = Nvim.get_current_buf |> run_join [%here] client in
      let%bind () = Nvim.command "e bar.txt" |> run_join [%here] client in
      let%bind () = Nvim.set_current_buf expected_buf |> run_join [%here] client in
      let%bind actual_buf = Nvim.get_current_buf |> run_join [%here] client in
      print_s [%message (expected_buf : Buffer.t) (actual_buf : Buffer.t)];
      return ())
  in
  [%expect "((expected_buf 1) (actual_buf 1))"];
  return ()
;;

let%expect_test "set_client_info" =
  let test_method =
    { Client_info.Client_method.async = false; nargs = Some (`Fixed 1) }
  in
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      (* The initial setting happens when a VCaml client connects to Neovim. *)
      let get_client_info () =
        let%map.Deferred.Or_error channels = run_join [%here] client Nvim.channels in
        let channel = List.hd_exn channels in
        channel.client
      in
      let%bind client_before_setting_info = get_client_info () in
      let%bind () =
        Nvim.set_client_info
          ~version:
            { major = Some 1
            ; minor = Some 2
            ; patch = Some 3
            ; prerelease = Some "test_prerelease"
            ; commit = Some "test_commit"
            }
          ~methods:(String.Map.of_alist_exn [ "test_method", test_method ])
          ~attributes:(String.Map.of_alist_exn [ "attr1", "val1" ])
          ~name:"foo"
          ~type_:`Embedder
          ()
        |> run_join [%here] client
      in
      let%bind client_after_setting_info = get_client_info () in
      print_s
        [%message
          (client_before_setting_info : Client_info.t option)
            (client_after_setting_info : Client_info.t option)];
      return ())
  in
  [%expect
    {|
    ((client_before_setting_info
      (((version
         (((major (0)) (minor ()) (patch ()) (prerelease ()) (commit ()))))
        (methods ()) (attributes ()) (name (<uuid-omitted-in-test>))
        (type_ (Remote)))))
     (client_after_setting_info
      (((version
         (((major (1)) (minor (2)) (patch (3)) (prerelease (test_prerelease))
           (commit (test_commit)))))
        (methods ((test_method ((async false) (nargs ((Fixed 1)))))))
        (attributes ((attr1 val1))) (name (foo)) (type_ (Embedder))))))|}];
  return ()
;;

let%expect_test "get_current_win, set_current_win" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind original_win = Nvim.get_current_win |> run_join [%here] client in
      let%bind () = Nvim.command "split" |> run_join [%here] client in
      let%bind win_after_split = Nvim.get_current_win |> run_join [%here] client in
      let%bind () = Nvim.set_current_win original_win |> run_join [%here] client in
      let%bind win_after_set = run_join [%here] client Nvim.get_current_win in
      print_s
        [%message
          (original_win : Window.t)
            (win_after_split : Window.t)
            (win_after_set : Window.t)];
      return ())
  in
  [%expect "((original_win 1000) (win_after_split 1001) (win_after_set 1000))"];
  return ()
;;

let%expect_test "list_wins" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind () = Nvim.command "split" |> run_join [%here] client in
      let%bind () = Nvim.command "split" |> run_join [%here] client in
      let%bind win_list = Nvim.list_wins |> run_join [%here] client in
      print_s [%message (win_list : Window.t list)];
      return ())
  in
  [%expect "(win_list (1002 1001 1000))"];
  return ()
;;

let%expect_test "replace_termcodes" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind escaped_keys =
        Nvim.replace_termcodes_and_keycodes "ifoobar<ESC><Left><Left>XXX"
        |> run_join [%here] client
      in
      let%bind () =
        Nvim.feedkeys (`Already_escaped escaped_keys) ~mode:"n" |> run_join [%here] client
      in
      let%bind lines =
        Buffer.get_lines Current ~start:0 ~end_:(-1) ~strict_indexing:false
        |> run_join [%here] client
      in
      print_s [%message (lines : string list)];
      return ())
  in
  [%expect {| (lines (bar)) |}];
  return ()
;;

let%expect_test "get_color_by_name" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind color = Nvim.get_color_by_name "#f0f8ff" |> run_join [%here] client in
      print_s [%sexp (color : Color.True_color.t)];
      let%bind color = Nvim.get_color_by_name "AliceBlue" |> run_join [%here] client in
      print_s [%sexp (color : Color.True_color.t)];
      return ())
  in
  [%expect {|
    #f0f8ff
    #f0f8ff |}];
  return ()
;;

let%expect_test "color_map" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind color_map = Nvim.get_color_map |> run_join [%here] client in
      print_s [%sexp (color_map : Color.True_color.t String.Map.t)];
      return ())
  in
  [%expect
    {|
    ((AliceBlue #f0f8ff) (AntiqueWhite #faebd7) (AntiqueWhite1 #ffefdb)
     (AntiqueWhite2 #eedfcc) (AntiqueWhite3 #cdc0b0) (AntiqueWhite4 #8b8378)
     (Aqua #00ffff) (Aquamarine #7fffd4) (Aquamarine1 #7fffd4)
     (Aquamarine2 #76eec6) (Aquamarine3 #66cdaa) (Aquamarine4 #458b74)
     (Azure #f0ffff) (Azure1 #f0ffff) (Azure2 #e0eeee) (Azure3 #c1cdcd)
     (Azure4 #838b8b) (Beige #f5f5dc) (Bisque #ffe4c4) (Bisque1 #ffe4c4)
     (Bisque2 #eed5b7) (Bisque3 #cdb79e) (Bisque4 #8b7d6b) (Black #000000)
     (BlanchedAlmond #ffebcd) (Blue #0000ff) (Blue1 #0000ff) (Blue2 #0000ee)
     (Blue3 #0000cd) (Blue4 #00008b) (BlueViolet #8a2be2) (Brown #a52a2a)
     (Brown1 #ff4040) (Brown2 #ee3b3b) (Brown3 #cd3333) (Brown4 #8b2323)
     (BurlyWood #deb887) (Burlywood1 #ffd39b) (Burlywood2 #eec591)
     (Burlywood3 #cdaa7d) (Burlywood4 #8b7355) (CadetBlue #5f9ea0)
     (CadetBlue1 #98f5ff) (CadetBlue2 #8ee5ee) (CadetBlue3 #7ac5cd)
     (CadetBlue4 #53868b) (ChartReuse #7fff00) (Chartreuse1 #7fff00)
     (Chartreuse2 #76ee00) (Chartreuse3 #66cd00) (Chartreuse4 #458b00)
     (Chocolate #d2691e) (Chocolate1 #ff7f24) (Chocolate2 #ee7621)
     (Chocolate3 #cd661d) (Chocolate4 #8b4513) (Coral #ff7f50) (Coral1 #ff7256)
     (Coral2 #ee6a50) (Coral3 #cd5b45) (Coral4 #8b3e2f) (CornFlowerBlue #6495ed)
     (Cornsilk #fff8dc) (Cornsilk1 #fff8dc) (Cornsilk2 #eee8cd)
     (Cornsilk3 #cdc8b1) (Cornsilk4 #8b8878) (Crimson #dc143c) (Cyan #00ffff)
     (Cyan1 #00ffff) (Cyan2 #00eeee) (Cyan3 #00cdcd) (Cyan4 #008b8b)
     (DarkBlue #00008b) (DarkCyan #008b8b) (DarkGoldenRod #b8860b)
     (DarkGoldenrod1 #ffb90f) (DarkGoldenrod2 #eead0e) (DarkGoldenrod3 #cd950c)
     (DarkGoldenrod4 #8b6508) (DarkGray #a9a9a9) (DarkGreen #006400)
     (DarkGrey #a9a9a9) (DarkKhaki #bdb76b) (DarkMagenta #8b008b)
     (DarkOliveGreen #556b2f) (DarkOliveGreen1 #caff70) (DarkOliveGreen2 #bcee68)
     (DarkOliveGreen3 #a2cd5a) (DarkOliveGreen4 #6e8b3d) (DarkOrange #ff8c00)
     (DarkOrange1 #ff7f00) (DarkOrange2 #ee7600) (DarkOrange3 #cd6600)
     (DarkOrange4 #8b4500) (DarkOrchid #9932cc) (DarkOrchid1 #bf3eff)
     (DarkOrchid2 #b23aee) (DarkOrchid3 #9a32cd) (DarkOrchid4 #68228b)
     (DarkRed #8b0000) (DarkSalmon #e9967a) (DarkSeaGreen #8fbc8f)
     (DarkSeaGreen1 #c1ffc1) (DarkSeaGreen2 #b4eeb4) (DarkSeaGreen3 #9bcd9b)
     (DarkSeaGreen4 #698b69) (DarkSlateBlue #483d8b) (DarkSlateGray #2f4f4f)
     (DarkSlateGray1 #97ffff) (DarkSlateGray2 #8deeee) (DarkSlateGray3 #79cdcd)
     (DarkSlateGray4 #528b8b) (DarkSlateGrey #2f4f4f) (DarkTurquoise #00ced1)
     (DarkViolet #9400d3) (DarkYellow #bbbb00) (DeepPink #ff1493)
     (DeepPink1 #ff1493) (DeepPink2 #ee1289) (DeepPink3 #cd1076)
     (DeepPink4 #8b0a50) (DeepSkyBlue #00bfff) (DeepSkyBlue1 #00bfff)
     (DeepSkyBlue2 #00b2ee) (DeepSkyBlue3 #009acd) (DeepSkyBlue4 #00688b)
     (DimGray #696969) (DimGrey #696969) (DodgerBlue #1e90ff)
     (DodgerBlue1 #1e90ff) (DodgerBlue2 #1c86ee) (DodgerBlue3 #1874cd)
     (DodgerBlue4 #104e8b) (Firebrick #b22222) (Firebrick1 #ff3030)
     (Firebrick2 #ee2c2c) (Firebrick3 #cd2626) (Firebrick4 #8b1a1a)
     (FloralWhite #fffaf0) (ForestGreen #228b22) (Fuchsia #ff00ff)
     (Gainsboro #dcdcdc) (GhostWhite #f8f8ff) (Gold #ffd700) (Gold1 #ffd700)
     (Gold2 #eec900) (Gold3 #cdad00) (Gold4 #8b7500) (GoldenRod #daa520)
     (Goldenrod1 #ffc125) (Goldenrod2 #eeb422) (Goldenrod3 #cd9b1d)
     (Goldenrod4 #8b6914) (Gray #808080) (Gray0 #000000) (Gray1 #030303)
     (Gray10 #1a1a1a) (Gray100 #ffffff) (Gray11 #1c1c1c) (Gray12 #1f1f1f)
     (Gray13 #212121) (Gray14 #242424) (Gray15 #262626) (Gray16 #292929)
     (Gray17 #2b2b2b) (Gray18 #2e2e2e) (Gray19 #303030) (Gray2 #050505)
     (Gray20 #333333) (Gray21 #363636) (Gray22 #383838) (Gray23 #3b3b3b)
     (Gray24 #3d3d3d) (Gray25 #404040) (Gray26 #424242) (Gray27 #454545)
     (Gray28 #474747) (Gray29 #4a4a4a) (Gray3 #080808) (Gray30 #4d4d4d)
     (Gray31 #4f4f4f) (Gray32 #525252) (Gray33 #545454) (Gray34 #575757)
     (Gray35 #595959) (Gray36 #5c5c5c) (Gray37 #5e5e5e) (Gray38 #616161)
     (Gray39 #636363) (Gray4 #0a0a0a) (Gray40 #666666) (Gray41 #696969)
     (Gray42 #6b6b6b) (Gray43 #6e6e6e) (Gray44 #707070) (Gray45 #737373)
     (Gray46 #757575) (Gray47 #787878) (Gray48 #7a7a7a) (Gray49 #7d7d7d)
     (Gray5 #0d0d0d) (Gray50 #7f7f7f) (Gray51 #828282) (Gray52 #858585)
     (Gray53 #878787) (Gray54 #8a8a8a) (Gray55 #8c8c8c) (Gray56 #8f8f8f)
     (Gray57 #919191) (Gray58 #949494) (Gray59 #969696) (Gray6 #0f0f0f)
     (Gray60 #999999) (Gray61 #9c9c9c) (Gray62 #9e9e9e) (Gray63 #a1a1a1)
     (Gray64 #a3a3a3) (Gray65 #a6a6a6) (Gray66 #a8a8a8) (Gray67 #ababab)
     (Gray68 #adadad) (Gray69 #b0b0b0) (Gray7 #121212) (Gray70 #b3b3b3)
     (Gray71 #b5b5b5) (Gray72 #b8b8b8) (Gray73 #bababa) (Gray74 #bdbdbd)
     (Gray75 #bfbfbf) (Gray76 #c2c2c2) (Gray77 #c4c4c4) (Gray78 #c7c7c7)
     (Gray79 #c9c9c9) (Gray8 #141414) (Gray80 #cccccc) (Gray81 #cfcfcf)
     (Gray82 #d1d1d1) (Gray83 #d4d4d4) (Gray84 #d6d6d6) (Gray85 #d9d9d9)
     (Gray86 #dbdbdb) (Gray87 #dedede) (Gray88 #e0e0e0) (Gray89 #e3e3e3)
     (Gray9 #171717) (Gray90 #e5e5e5) (Gray91 #e8e8e8) (Gray92 #ebebeb)
     (Gray93 #ededed) (Gray94 #f0f0f0) (Gray95 #f2f2f2) (Gray96 #f5f5f5)
     (Gray97 #f7f7f7) (Gray98 #fafafa) (Gray99 #fcfcfc) (Green #008000)
     (Green1 #00ff00) (Green2 #00ee00) (Green3 #00cd00) (Green4 #008b00)
     (GreenYellow #adff2f) (Grey #808080) (Grey0 #000000) (Grey1 #030303)
     (Grey10 #1a1a1a) (Grey100 #ffffff) (Grey11 #1c1c1c) (Grey12 #1f1f1f)
     (Grey13 #212121) (Grey14 #242424) (Grey15 #262626) (Grey16 #292929)
     (Grey17 #2b2b2b) (Grey18 #2e2e2e) (Grey19 #303030) (Grey2 #050505)
     (Grey20 #333333) (Grey21 #363636) (Grey22 #383838) (Grey23 #3b3b3b)
     (Grey24 #3d3d3d) (Grey25 #404040) (Grey26 #424242) (Grey27 #454545)
     (Grey28 #474747) (Grey29 #4a4a4a) (Grey3 #080808) (Grey30 #4d4d4d)
     (Grey31 #4f4f4f) (Grey32 #525252) (Grey33 #545454) (Grey34 #575757)
     (Grey35 #595959) (Grey36 #5c5c5c) (Grey37 #5e5e5e) (Grey38 #616161)
     (Grey39 #636363) (Grey4 #0a0a0a) (Grey40 #666666) (Grey41 #696969)
     (Grey42 #6b6b6b) (Grey43 #6e6e6e) (Grey44 #707070) (Grey45 #737373)
     (Grey46 #757575) (Grey47 #787878) (Grey48 #7a7a7a) (Grey49 #7d7d7d)
     (Grey5 #0d0d0d) (Grey50 #7f7f7f) (Grey51 #828282) (Grey52 #858585)
     (Grey53 #878787) (Grey54 #8a8a8a) (Grey55 #8c8c8c) (Grey56 #8f8f8f)
     (Grey57 #919191) (Grey58 #949494) (Grey59 #969696) (Grey6 #0f0f0f)
     (Grey60 #999999) (Grey61 #9c9c9c) (Grey62 #9e9e9e) (Grey63 #a1a1a1)
     (Grey64 #a3a3a3) (Grey65 #a6a6a6) (Grey66 #a8a8a8) (Grey67 #ababab)
     (Grey68 #adadad) (Grey69 #b0b0b0) (Grey7 #121212) (Grey70 #b3b3b3)
     (Grey71 #b5b5b5) (Grey72 #b8b8b8) (Grey73 #bababa) (Grey74 #bdbdbd)
     (Grey75 #bfbfbf) (Grey76 #c2c2c2) (Grey77 #c4c4c4) (Grey78 #c7c7c7)
     (Grey79 #c9c9c9) (Grey8 #141414) (Grey80 #cccccc) (Grey81 #cfcfcf)
     (Grey82 #d1d1d1) (Grey83 #d4d4d4) (Grey84 #d6d6d6) (Grey85 #d9d9d9)
     (Grey86 #dbdbdb) (Grey87 #dedede) (Grey88 #e0e0e0) (Grey89 #e3e3e3)
     (Grey9 #171717) (Grey90 #e5e5e5) (Grey91 #e8e8e8) (Grey92 #ebebeb)
     (Grey93 #ededed) (Grey94 #f0f0f0) (Grey95 #f2f2f2) (Grey96 #f5f5f5)
     (Grey97 #f7f7f7) (Grey98 #fafafa) (Grey99 #fcfcfc) (Honeydew #f0fff0)
     (Honeydew1 #f0fff0) (Honeydew2 #e0eee0) (Honeydew3 #c1cdc1)
     (Honeydew4 #838b83) (HotPink #ff69b4) (HotPink1 #ff6eb4) (HotPink2 #ee6aa7)
     (HotPink3 #cd6090) (HotPink4 #8b3a62) (IndianRed #cd5c5c)
     (IndianRed1 #ff6a6a) (IndianRed2 #ee6363) (IndianRed3 #cd5555)
     (IndianRed4 #8b3a3a) (Indigo #4b0082) (Ivory #fffff0) (Ivory1 #fffff0)
     (Ivory2 #eeeee0) (Ivory3 #cdcdc1) (Ivory4 #8b8b83) (Khaki #f0e68c)
     (Khaki1 #fff68f) (Khaki2 #eee685) (Khaki3 #cdc673) (Khaki4 #8b864e)
     (Lavender #e6e6fa) (LavenderBlush #fff0f5) (LavenderBlush1 #fff0f5)
     (LavenderBlush2 #eee0e5) (LavenderBlush3 #cdc1c5) (LavenderBlush4 #8b8386)
     (LawnGreen #7cfc00) (LemonChiffon #fffacd) (LemonChiffon1 #fffacd)
     (LemonChiffon2 #eee9bf) (LemonChiffon3 #cdc9a5) (LemonChiffon4 #8b8970)
     (LightBlue #add8e6) (LightBlue1 #bfefff) (LightBlue2 #b2dfee)
     (LightBlue3 #9ac0cd) (LightBlue4 #68838b) (LightCoral #f08080)
     (LightCyan #e0ffff) (LightCyan1 #e0ffff) (LightCyan2 #d1eeee)
     (LightCyan3 #b4cdcd) (LightCyan4 #7a8b8b) (LightGoldenRodYellow #fafad2)
     (LightGoldenrod #eedd82) (LightGoldenrod1 #ffec8b) (LightGoldenrod2 #eedc82)
     (LightGoldenrod3 #cdbe70) (LightGoldenrod4 #8b814c) (LightGray #d3d3d3)
     (LightGreen #90ee90) (LightGrey #d3d3d3) (LightMagenta #ffbbff)
     (LightPink #ffb6c1) (LightPink1 #ffaeb9) (LightPink2 #eea2ad)
     (LightPink3 #cd8c95) (LightPink4 #8b5f65) (LightRed #ffbbbb)
     (LightSalmon #ffa07a) (LightSalmon1 #ffa07a) (LightSalmon2 #ee9572)
     (LightSalmon3 #cd8162) (LightSalmon4 #8b5742) (LightSeaGreen #20b2aa)
     (LightSkyBlue #87cefa) (LightSkyBlue1 #b0e2ff) (LightSkyBlue2 #a4d3ee)
     (LightSkyBlue3 #8db6cd) (LightSkyBlue4 #607b8b) (LightSlateBlue #8470ff)
     (LightSlateGray #778899) (LightSlateGrey #778899) (LightSteelBlue #b0c4de)
     (LightSteelBlue1 #cae1ff) (LightSteelBlue2 #bcd2ee)
     (LightSteelBlue3 #a2b5cd) (LightSteelBlue4 #6e7b8b) (LightYellow #ffffe0)
     (LightYellow1 #ffffe0) (LightYellow2 #eeeed1) (LightYellow3 #cdcdb4)
     (LightYellow4 #8b8b7a) (Lime #00ff00) (LimeGreen #32cd32) (Linen #faf0e6)
     (Magenta #ff00ff) (Magenta1 #ff00ff) (Magenta2 #ee00ee) (Magenta3 #cd00cd)
     (Magenta4 #8b008b) (Maroon #800000) (Maroon1 #ff34b3) (Maroon2 #ee30a7)
     (Maroon3 #cd2990) (Maroon4 #8b1c62) (MediumAquamarine #66cdaa)
     (MediumBlue #0000cd) (MediumOrchid #ba55d3) (MediumOrchid1 #e066ff)
     (MediumOrchid2 #d15fee) (MediumOrchid3 #b452cd) (MediumOrchid4 #7a378b)
     (MediumPurple #9370db) (MediumPurple1 #ab82ff) (MediumPurple2 #9f79ee)
     (MediumPurple3 #8968cd) (MediumPurple4 #5d478b) (MediumSeaGreen #3cb371)
     (MediumSlateBlue #7b68ee) (MediumSpringGreen #00fa9a)
     (MediumTurquoise #48d1cc) (MediumVioletRed #c71585) (MidnightBlue #191970)
     (MintCream #f5fffa) (MistyRose #ffe4e1) (MistyRose1 #ffe4e1)
     (MistyRose2 #eed5d2) (MistyRose3 #cdb7b5) (MistyRose4 #8b7d7b)
     (Moccasin #ffe4b5) (NavajoWhite #ffdead) (NavajoWhite1 #ffdead)
     (NavajoWhite2 #eecfa1) (NavajoWhite3 #cdb38b) (NavajoWhite4 #8b795e)
     (Navy #000080) (NavyBlue #000080) (OldLace #fdf5e6) (Olive #808000)
     (OliveDrab #6b8e23) (OliveDrab1 #c0ff3e) (OliveDrab2 #b3ee3a)
     (OliveDrab3 #9acd32) (OliveDrab4 #698b22) (Orange #ffa500) (Orange1 #ffa500)
     (Orange2 #ee9a00) (Orange3 #cd8500) (Orange4 #8b5a00) (OrangeRed #ff4500)
     (OrangeRed1 #ff4500) (OrangeRed2 #ee4000) (OrangeRed3 #cd3700)
     (OrangeRed4 #8b2500) (Orchid #da70d6) (Orchid1 #ff83fa) (Orchid2 #ee7ae9)
     (Orchid3 #cd69c9) (Orchid4 #8b4789) (PaleGoldenRod #eee8aa)
     (PaleGreen #98fb98) (PaleGreen1 #9aff9a) (PaleGreen2 #90ee90)
     (PaleGreen3 #7ccd7c) (PaleGreen4 #548b54) (PaleTurquoise #afeeee)
     (PaleTurquoise1 #bbffff) (PaleTurquoise2 #aeeeee) (PaleTurquoise3 #96cdcd)
     (PaleTurquoise4 #668b8b) (PaleVioletRed #db7093) (PaleVioletRed1 #ff82ab)
     (PaleVioletRed2 #ee799f) (PaleVioletRed3 #cd6889) (PaleVioletRed4 #8b475d)
     (PapayaWhip #ffefd5) (PeachPuff #ffdab9) (PeachPuff1 #ffdab9)
     (PeachPuff2 #eecbad) (PeachPuff3 #cdaf95) (PeachPuff4 #8b7765)
     (Peru #cd853f) (Pink #ffc0cb) (Pink1 #ffb5c5) (Pink2 #eea9b8)
     (Pink3 #cd919e) (Pink4 #8b636c) (Plum #dda0dd) (Plum1 #ffbbff)
     (Plum2 #eeaeee) (Plum3 #cd96cd) (Plum4 #8b668b) (PowderBlue #b0e0e6)
     (Purple #800080) (Purple1 #9b30ff) (Purple2 #912cee) (Purple3 #7d26cd)
     (Purple4 #551a8b) (RebeccaPurple #663399) (Red #ff0000) (Red1 #ff0000)
     (Red2 #ee0000) (Red3 #cd0000) (Red4 #8b0000) (RosyBrown #bc8f8f)
     (RosyBrown1 #ffc1c1) (RosyBrown2 #eeb4b4) (RosyBrown3 #cd9b9b)
     (RosyBrown4 #8b6969) (RoyalBlue #4169e1) (RoyalBlue1 #4876ff)
     (RoyalBlue2 #436eee) (RoyalBlue3 #3a5fcd) (RoyalBlue4 #27408b)
     (SaddleBrown #8b4513) (Salmon #fa8072) (Salmon1 #ff8c69) (Salmon2 #ee8262)
     (Salmon3 #cd7054) (Salmon4 #8b4c39) (SandyBrown #f4a460) (SeaGreen #2e8b57)
     (SeaGreen1 #54ff9f) (SeaGreen2 #4eee94) (SeaGreen3 #43cd80)
     (SeaGreen4 #2e8b57) (SeaShell #fff5ee) (Seashell1 #fff5ee)
     (Seashell2 #eee5de) (Seashell3 #cdc5bf) (Seashell4 #8b8682) (Sienna #a0522d)
     (Sienna1 #ff8247) (Sienna2 #ee7942) (Sienna3 #cd6839) (Sienna4 #8b4726)
     (Silver #c0c0c0) (SkyBlue #87ceeb) (SkyBlue1 #87ceff) (SkyBlue2 #7ec0ee)
     (SkyBlue3 #6ca6cd) (SkyBlue4 #4a708b) (SlateBlue #6a5acd)
     (SlateBlue1 #836fff) (SlateBlue2 #7a67ee) (SlateBlue3 #6959cd)
     (SlateBlue4 #473c8b) (SlateGray #708090) (SlateGray1 #c6e2ff)
     (SlateGray2 #b9d3ee) (SlateGray3 #9fb6cd) (SlateGray4 #6c7b8b)
     (SlateGrey #708090) (Snow #fffafa) (Snow1 #fffafa) (Snow2 #eee9e9)
     (Snow3 #cdc9c9) (Snow4 #8b8989) (SpringGreen #00ff7f) (SpringGreen1 #00ff7f)
     (SpringGreen2 #00ee76) (SpringGreen3 #00cd66) (SpringGreen4 #008b45)
     (SteelBlue #4682b4) (SteelBlue1 #63b8ff) (SteelBlue2 #5cacee)
     (SteelBlue3 #4f94cd) (SteelBlue4 #36648b) (Tan #d2b48c) (Tan1 #ffa54f)
     (Tan2 #ee9a49) (Tan3 #cd853f) (Tan4 #8b5a2b) (Teal #008080)
     (Thistle #d8bfd8) (Thistle1 #ffe1ff) (Thistle2 #eed2ee) (Thistle3 #cdb5cd)
     (Thistle4 #8b7b8b) (Tomato #ff6347) (Tomato1 #ff6347) (Tomato2 #ee5c42)
     (Tomato3 #cd4f39) (Tomato4 #8b3626) (Turquoise #40e0d0) (Turquoise1 #00f5ff)
     (Turquoise2 #00e5ee) (Turquoise3 #00c5cd) (Turquoise4 #00868b)
     (Violet #ee82ee) (VioletRed #d02090) (VioletRed1 #ff3e96)
     (VioletRed2 #ee3a8c) (VioletRed3 #cd3278) (VioletRed4 #8b2252)
     (WebGray #808080) (WebGreen #008000) (WebGrey #808080) (WebMaroon #800000)
     (WebPurple #800080) (Wheat #f5deb3) (Wheat1 #ffe7ba) (Wheat2 #eed8ae)
     (Wheat3 #cdba96) (Wheat4 #8b7e66) (White #ffffff) (WhiteSmoke #f5f5f5)
     (X11Gray #bebebe) (X11Green #00ff00) (X11Grey #bebebe) (X11Maroon #b03060)
     (X11Purple #a020f0) (Yellow #ffff00) (Yellow1 #ffff00) (Yellow2 #eeee00)
     (Yellow3 #cdcd00) (Yellow4 #8b8b00) (YellowGreen #9acd32)) |}];
  return ()
;;

let%expect_test "get_hl_by_name" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind color256 =
        Nvim.get_hl_by_name "ErrorMsg" ~color:Color256 |> run_join [%here] client
      in
      let%bind true_color =
        Nvim.get_hl_by_name "ErrorMsg" ~color:True_color |> run_join [%here] client
      in
      let open Color in
      print_s
        [%message
          (color256 : Color256.t Highlight.t) (true_color : True_color.t Highlight.t)];
      return ())
  in
  [%expect
    {|
    ((color256 ((fg 15) (bg 1))) (true_color ((fg #ffffff) (bg #ff0000)))) |}];
  return ()
;;

let%expect_test "get_hl_by_id" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let get_hl_id =
        wrap_viml_function
          ~type_:Defun.Vim.(String @-> return Integer)
          ~function_name:"hlID"
      in
      let%bind hl_id = get_hl_id "ErrorMsg" |> run_join [%here] client in
      let%bind color256 =
        Nvim.get_hl_by_id hl_id ~color:Color256 |> run_join [%here] client
      in
      let%bind true_color =
        Nvim.get_hl_by_id hl_id ~color:True_color |> run_join [%here] client
      in
      let open Color in
      print_s
        [%message
          (color256 : Color256.t Highlight.t) (true_color : True_color.t Highlight.t)];
      return ())
  in
  [%expect
    {|
    ((color256 ((fg 15) (bg 1))) (true_color ((fg #ffffff) (bg #ff0000)))) |}];
  return ()
;;

let%expect_test "Check that all modes documented in the help are covered by [Mode.t]" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%bind () = Nvim.command "h mode()" |> run_join [%here] client in
      let feedkeys keys =
        let%bind keys =
          Nvim.replace_termcodes_and_keycodes keys |> run_join [%here] client
        in
        Nvim.feedkeys (`Already_escaped keys) ~mode:"n" |> run_join [%here] client
      in
      let%bind () = feedkeys "}jy}<C-w>np<C-w>o" in
      let%bind lines =
        Buffer.get_lines Current ~start:1 ~end_:(-1) ~strict_indexing:true
        |> run_join [%here] client
      in
      let modes_in_help, new_modes =
        lines
        |> List.filter ~f:(Fn.non (String.is_prefix ~prefix:"\t\t\t\t"))
        |> List.partition_map ~f:(fun line ->
          let lsplit2_whitespace_exn str =
            let is_space_or_tab = function
              | ' ' | '\t' -> true
              | _ -> false
            in
            let end_of_first_word =
              String.lfindi str ~f:(fun _ -> is_space_or_tab) |> Option.value_exn
            in
            let start_of_second_word =
              String.lfindi str ~pos:end_of_first_word ~f:(fun _ ->
                Fn.non is_space_or_tab)
              |> Option.value_exn
            in
            let word1 = String.subo str ~len:end_of_first_word in
            let word2 = String.subo str ~pos:start_of_second_word in
            word1, word2
          in
          let symbol, description = line |> String.strip |> lsplit2_whitespace_exn in
          let symbol =
            match String.substr_index symbol ~pattern:"CTRL-" with
            | None -> symbol
            | Some idx ->
              let ctrl_char =
                symbol.[idx + 5]
                |> Char.to_int
                |> (fun c -> c - Char.to_int '@')
                |> Char.of_int_exn
                |> String.of_char
              in
              [ String.subo symbol ~len:idx
              ; ctrl_char
              ; String.subo symbol ~pos:(idx + 6)
              ]
              |> String.concat ~sep:""
          in
          match Mode.of_mode_symbol symbol with
          | Ok mode -> First mode
          | Error _ -> Second (symbol, description))
      in
      let modes_in_help = modes_in_help |> Mode.Set.of_list in
      let all_modes = Mode.all |> Mode.Set.of_list in
      let removed_modes = Set.diff all_modes modes_in_help in
      print_s [%message "New modes" ~_:(new_modes : (string * string) list)];
      print_s [%message "Removed modes" ~_:(removed_modes : Mode.Set.t)];
      [%expect {|
        ("New modes" ())
        ("Removed modes" ()) |}];
      return ())
  in
  [%expect {||}];
  return ()
;;

let%expect_test "Get and set variables" =
  let%bind () =
    with_client (fun client ->
      let open Deferred.Or_error.Let_syntax in
      let%map result =
        run_join
          [%here]
          client
          (let open Api_call.Or_error.Let_syntax in
           let%map () = Nvim.set_var "foo" ~type_:String ~value:"Hello"
           and value = Nvim.get_var "foo" ~type_:String in
           value)
      in
      print_s [%message result])
  in
  [%expect {| Hello |}];
  return ()
;;

module _ = struct
  module Nvim = Nvim.Fast

  let%expect_test "[get_mode] and [input]" =
    let%bind () =
      with_client (fun client ->
        let open Deferred.Or_error.Let_syntax in
        let input keys =
          let%bind bytes_written = Nvim.input keys |> run_join [%here] client in
          assert (bytes_written = String.length keys);
          let%map mode = Nvim.get_mode |> run_join [%here] client in
          print_s [%message keys ~_:(mode : Mode.With_blocking_info.t)]
        in
        let%bind () = input "g" in
        let%bind () = input "<Esc>" in
        let%bind () = input "itest" in
        let%bind () = input "<C-o>" in
        let%bind () = input "<Esc>" in
        let%bind () = input "<Esc>r" in
        let%bind () = input "<Esc>V" in
        let%bind () = input "<Esc><C-v>" in
        let%bind () = input "<Esc>gR" in
        let%bind () = input "<Esc>:" in
        return ())
    in
    [%expect
      {|
      (g ((mode Normal) (blocking true)))
      (<Esc> ((mode Normal) (blocking false)))
      (itest ((mode Insert) (blocking false)))
      (<C-o> ((mode Normal_using_i_ctrl_o_in_insert_mode) (blocking false)))
      (<Esc> ((mode Insert) (blocking false)))
      (<Esc>r ((mode Replace) (blocking true)))
      (<Esc>V ((mode Visual_by_line) (blocking false)))
      (<Esc><C-v> ((mode Visual_blockwise) (blocking false)))
      (<Esc>gR ((mode Virtual_replace) (blocking false)))
      (<Esc>: ((mode Command_line_editing) (blocking false))) |}];
    return ()
  ;;

  let%expect_test "[paste]" =
    let%bind () =
      with_client (fun client ->
        let open Deferred.Or_error.Let_syntax in
        let%bind () = Nvim.paste [ "hello"; "world!" ] |> run_join [%here] client in
        let%bind lines =
          Buffer.get_lines Current ~start:0 ~end_:(-1) ~strict_indexing:false
          |> run_join [%here] client
        in
        let%bind cursor_pos = Window.get_cursor Current |> run_join [%here] client in
        print_s [%message (lines : string list)];
        print_s [%message (cursor_pos : Position.One_indexed_row.t)];
        return ())
    in
    [%expect {|
      (lines (hello world!))
      (cursor_pos ((row 2) (col 5))) |}];
    return ()
  ;;

  let%expect_test "[paste_stream]" =
    let%bind () =
      with_client (fun client ->
        let open Deferred.Or_error.Let_syntax in
        let writer, flushed = Nvim.paste_stream [%here] client in
        let%bind () = Pipe.write writer "hello\n" |> Deferred.ok in
        let%bind () = Pipe.write writer "world!" |> Deferred.ok in
        Pipe.close writer;
        let%bind () = flushed in
        let%bind lines =
          Buffer.get_lines Current ~start:0 ~end_:(-1) ~strict_indexing:false
          |> run_join [%here] client
        in
        let%bind cursor_pos = Window.get_cursor Current |> run_join [%here] client in
        print_s [%message (lines : string list)];
        print_s [%message (cursor_pos : Position.One_indexed_row.t)];
        return ())
    in
    [%expect {|
      (lines (hello world!))
      (cursor_pos ((row 2) (col 5))) |}];
    return ()
  ;;

  (* This behavior is perhaps surprising. *)
  let%expect_test "API calls work while a [paste_stream] is open" =
    let%bind () =
      with_client (fun client ->
        let open Deferred.Or_error.Let_syntax in
        let%bind () =
          Vcaml.Nvim.Untested.set_option "hidden" ~type_:Boolean ~value:true
          |> run_join [%here] client
        in
        let get_lines () =
          Buffer.get_lines Current ~start:0 ~end_:(-1) ~strict_indexing:false
          |> run_join [%here] client
        in
        let switch_buffers buffer =
          let%map.Deferred result =
            Vcaml.Nvim.set_current_buf buffer |> run_join [%here] client
          in
          match result with
          | Ok () -> print_s [%message "Switched buffers!" (buffer : Buffer.t)]
          | Error error -> print_s [%sexp (error : Error.t)]
        in
        let writer, flushed = Nvim.paste_stream [%here] client in
        let%bind () = Pipe.write writer "hello\n" |> Deferred.ok in
        let%bind lines = get_lines () in
        print_s [%sexp (lines : string list)];
        let%bind alt_buf =
          Buffer.create ~listed:true ~scratch:false |> run_join [%here] client
        in
        let%bind () = switch_buffers alt_buf |> Deferred.ok in
        let%bind () = Pipe.write writer "world!" |> Deferred.ok in
        Pipe.close writer;
        let%bind () = flushed in
        let%bind lines = get_lines () in
        print_s [%sexp (lines : string list)];
        return ())
    in
    [%expect {|
      (hello "")
      ("Switched buffers!" (buffer 2))
      (world!) |}];
    return ()
  ;;
end
