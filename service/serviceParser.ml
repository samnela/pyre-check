(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Expression
open Pyre
open PyreParser

module Scheduler = ServiceScheduler


let parse_source ?(show_parser_errors = true) file =
  File.path file |> Path.relative
  >>= fun path ->
  File.lines file
  >>= fun lines ->
  let metadata = Source.Metadata.parse path lines in
  try
    let statements = Parser.parse ~path lines in
    Some (
      Source.create
        ~docstring:(Statement.extract_docstring statements)
        ~metadata
        ~path
        ~qualifier:(Source.qualifier ~path)
        statements)
  with
  | Parser.Error error ->
      if show_parser_errors then
        Log.log ~section:`Parser "%s" error;
      None
  | Failure error ->
      Log.error "%s" error;
      None


let parse_modules_job ~files =
  let parse file =
    file
    |> parse_source ~show_parser_errors:false
    >>| (fun source ->
        let add_module_from_source
            {
              Source.qualifier;
              path;
              statements;
              metadata = { Source.Metadata.local_mode; _ };
              _;
            } =
          Module.create
            ~qualifier
            ~local_mode
            ~path
            ~stub:(String.is_suffix path ~suffix:".pyi")
            statements
          |> AstSharedMemory.add_module qualifier
        in
        add_module_from_source source)
    |> ignore
  in
  List.iter files ~f:parse


let parse_sources_job ~files =
  let parse handles file =
    (file
     |> parse_source
     >>= fun source ->
     Path.relative (File.path file)
     >>| fun relative ->
     AstSharedMemory.add_path_hash ~path:relative;
     let handle = File.Handle.create relative in
     source
     |> Analysis.Preprocessing.preprocess
     |> Plugin.apply_to_ast
     |> AstSharedMemory.add_source handle;
     handle :: handles)
    |> Option.value ~default:handles
  in
  List.fold ~init:[] ~f:parse files


let parse_sources ~configuration ~scheduler ~files =
  let handles =
    if Scheduler.is_parallel scheduler then
      begin
        Scheduler.iter scheduler ~configuration ~f:(fun files -> parse_modules_job ~files) files;
        Scheduler.map_reduce
          scheduler
          ~configuration
          ~init:[]
          ~map:(fun _ files -> parse_sources_job ~files)
          ~reduce:(fun new_handles processed_handles -> processed_handles @ new_handles)
          files
      end
    else
      begin
        parse_modules_job ~files;
        parse_sources_job ~files
      end
  in
  let () =
    let get_qualifier file =
      File.path file
      |> Path.relative
      >>| (fun path -> Source.qualifier ~path)
    in
    List.filter_map files ~f:get_qualifier
    |> AstSharedMemory.remove_modules
  in
  handles


let log_parse_errors_count ~not_parsed ~description =
  if not_parsed > 0 then
    let hint =
      if not (Log.is_enabled `Parser) then
        " Run with `--show-parse-errors` for more details."
      else
        ""
    in
    Log.warning "Could not parse %d %s%s due to syntax errors!%s"
      not_parsed
      description
      (if not_parsed > 1 then "s" else "")
      hint


let parse_stubs
    scheduler
    ~configuration:({ Configuration.source_root; typeshed; search_path; _ } as configuration) =
  let timer = Timer.start () in

  let paths =
    let stubs =
      let typeshed_directories =
        let list_subdirectories typeshed_path =
          let root = Path.absolute typeshed_path in
          if Core.Sys.is_directory root = `Yes then
            match Core.Sys.ls_dir root with
            | entries ->
                let select_directories sofar path =
                  if Core.Sys.is_directory (root ^/ path) = `Yes then
                    (Path.create_relative ~root:typeshed_path ~relative:path) :: sofar
                  else
                    sofar
                in
                List.fold ~init:[] ~f:select_directories entries
            | exception Sys_error _ ->
                Log.error "Could not list typeshed directory: `%s`" root;
                []
          else
            begin
              Log.info "Not a typeshed directory: `%s`" root;
              []
            end
        in
        Option.value_map ~default:[] ~f:(fun path -> list_subdirectories path) typeshed
      in
      let stubs root =
        Log.info "Finding type stubs in `%a`..." Path.pp root;
        let is_stub path =
          let is_python_2_stub path =
            String.is_substring ~substring:"/2/" path ||
            String.is_substring ~substring:"/2.7/" path
          in
          String.is_suffix path ~suffix:".pyi" && not (is_python_2_stub path)
        in
        File.list ~filter:is_stub ~root
      in
      List.map ~f:stubs (source_root :: (typeshed_directories @ search_path))
    in
    let modules =
      let modules root =
        Log.info "Finding external sources in `%a`..." Path.pp root;
        File.list ~filter:(String.is_suffix ~suffix:".py") ~root
      in
      List.map ~f:modules search_path
    in
    stubs @ modules
  in

  let source_count =
    let count sofar paths = sofar + (List.length paths) in
    List.fold paths ~init:0 ~f:count
  in
  Log.info "Parsing %d stubs and external sources..." source_count;

  let handles =
    (* The fold ensures the order of parsing is deterministic. *)
    let parse_sources sofar paths =
      sofar @ (parse_sources ~configuration ~scheduler ~files:(List.map ~f:File.create paths))
    in
    List.fold paths ~init:[] ~f:parse_sources
  in

  Statistics.performance ~name:"stubs parsed" ~timer ();
  let not_parsed = source_count - (List.length handles) in
  log_parse_errors_count ~not_parsed ~description:"external file";
  handles


let find_sources ?(filter = fun _ -> true) { Configuration.source_root; _ } =
  let filter path = String.is_suffix ~suffix:".py" path && filter path in
  File.list ~filter ~root:source_root


type result = {
  stubs: File.Handle.t list;
  sources: File.Handle.t list;
}


let parse_all scheduler ~configuration:({ Configuration.source_root; _ } as configuration) =
  let stubs = parse_stubs scheduler ~configuration in
  let known_stubs =
    let add_to_known_stubs sofar handle =
      match AstSharedMemory.get_source handle with
      | Some { Ast.Source.qualifier; path; _ } ->
          if Set.mem sofar qualifier then
            Statistics.event ~name:"interfering stub" ~normals:["path", path]();
          Set.add sofar qualifier
      | _ ->
          sofar
    in
    List.fold stubs ~init:Access.Set.empty ~f:add_to_known_stubs
  in
  let sources =
    let filter path =
      let relative =
        Path.get_relative_to_root
          ~root:source_root
          (* We want to filter based on the path of the symlink instead of the path the
             symlink points to. *)
          ~path:(Path.create_absolute ~follow_symbolic_links:false path)
      in
      match relative with
      | Some path ->
          not (Set.mem known_stubs (Source.qualifier ~path))
      | _ ->
          true
    in
    let timer = Timer.start () in
    let paths = find_sources configuration ~filter in
    Log.info "Parsing %d sources in `%a`..." (List.length paths) Path.pp source_root;
    let handles =
      parse_sources ~configuration ~scheduler ~files:(List.map ~f:File.create paths)
    in
    let not_parsed = (List.length paths) - (List.length handles) in
    log_parse_errors_count ~not_parsed ~description:"file";
    Statistics.performance ~name:"sources parsed" ~timer ();
    handles
  in
  { stubs; sources }
