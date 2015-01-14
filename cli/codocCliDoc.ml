(*
 * Copyright (c) 2014-2015 David Sheets <sheets@alum.mit.edu>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open CodocCli

module StringMap = Map.Make(String)

let doc_xml_parser = DocOckXmlParse.build (fun input ->
  match Xmlm.input_tree
    ~el:CodocDoc.root_of_xml
    ~data:CodocDoc.data_of_xml
    input
  with None -> failwith "can't find root" (* TODO: fixme *)
  | Some root -> root
)

let xml_error xml_file ?start (line,col) s = match start with
  | Some (start_line, start_col) ->
    Printf.eprintf "\n%s line %d column %d - line %d column %d:\n%s\n\n"
      xml_file start_line start_col line col s
  | None ->
    Printf.eprintf "\n%s line %d column %d:\n%s\n\n" xml_file line col s

let depth path =
  max 0 (List.length (Stringext.split path ~on:'/') - 1)

let rel_of_path depth path =
  if path <> "" && path.[0] = '/'
  then path
  else (CodocUtil.ascent_of_depth "" depth) ^ path

module LinkIndex = struct (* TODO: use digest, too *)
  open CodocDoc
  type t = {
    root_by_name : (string, root Lazy.t) Hashtbl.t;
    unit_by_root : (root, root DocOckTypes.Unit.t) Hashtbl.t;
    path_by_root : (root, string) Hashtbl.t;
    doc_root     : string;
    focus        : string;
  }

  let root_by_name idx name =
    try Some (Lazy.force (Hashtbl.find idx.root_by_name name))
    with Not_found -> None

  let unit_by_root idx root =
    try Hashtbl.find idx.unit_by_root root
    with Not_found ->
      let name = CodocDoc.Maps.name_of_root root in
      failwith ("couldn't find unit for root "^name) (* TODO *)

  let unit_by_name idx name = match root_by_name idx name with
    | None -> failwith ("couldn't find unit for name "^name) (* TODO *)
    | Some root -> unit_by_root idx root

  let path_by_root idx root =
    try Filename.concat
          (Hashtbl.find idx.path_by_root root)
          (CodocDoc.Root.to_path root)
    with Not_found ->
      let name = CodocDoc.Maps.name_of_root root in
      failwith ("couldn't find path for root "^name) (* TODO *)

  let index idx path name root unit =
    Hashtbl.replace idx.root_by_name name (Lazy.from_val root);
    Hashtbl.replace idx.unit_by_root root unit;
    Hashtbl.replace idx.path_by_root root path

  let rec index_units idx path doc_index =
    StringMap.iter (fun name ({ CodocIndex.xml_file }) ->
      Hashtbl.replace idx.root_by_name name
        (Lazy.from_fun (fun () ->
          let unit_dir = Filename.(dirname (concat path xml_file)) in
          let path_root = Filename.concat idx.doc_root path in
          let xml_file = Filename.concat path_root xml_file in
          let ic = open_in xml_file in
          let input = Xmlm.make_input (`Channel ic) in
          match DocOckXmlParse.file doc_xml_parser input with
          | DocOckXmlParse.Error (start, pos, s) ->
            close_in ic;
            (* TODO: fixme? different/better error style? *)
            xml_error xml_file ?start pos s;
            exit 1
          | DocOckXmlParse.Ok unit ->
            match CodocDoc.Maps.root_of_ident
              (DocOckPaths.Identifier.any unit.DocOckTypes.Unit.id) with
              | Some (root, mod_name) ->
                Hashtbl.replace idx.unit_by_root root unit;
                Hashtbl.replace idx.path_by_root root
                  (rel_of_path (depth idx.focus + 1) unit_dir);
                root
              | None -> (* TODO: fixme *) failwith "missing root"
         ))
    ) doc_index.CodocIndex.units;
    StringMap.iter (fun name pkg ->
      let index_path = Filename.concat path pkg.CodocIndex.index in
      let path = Filename.concat path pkg.CodocIndex.pkg_name in
      let index = CodocIndex.read (Filename.concat idx.doc_root index_path) in
      index_units idx path index
    ) doc_index.CodocIndex.pkgs

  let create path doc_index focus =
    let idx = {
      root_by_name = Hashtbl.create 10;
      unit_by_root = Hashtbl.create 10;
      path_by_root = Hashtbl.create 10;
      doc_root = path;
      focus;
    } in
    index_units idx "" doc_index;
    idx

  let focus_path ({ doc_root; focus }) = Filename.concat doc_root focus
end

let resource_of_cmti output = Filename.(
  if check_suffix output ".cmti"
  then chop_suffix output ".cmti"
  else output
)

let read_cmti root path = DocOck.(match read_cmti root path with
  | Not_an_interface -> failwith (path^" is not an interface") (* TODO *)
  | Wrong_version_interface ->
    failwith (path^" has the wrong format version") (* TODO *)
  | Corrupted_interface -> failwith (path^" is corrupted") (* TODO *)
  | Not_a_typedtree -> failwith (path^" is not a typed tree") (* TODO *)
  | Ok unit -> unit
)

let read focus root =
  let cmti_path = CodocDoc.Root.(to_path (to_source root)) in
  let cmti = Uri.(resolve "" (of_string focus) (of_string cmti_path)) in
  read_cmti root (Uri.to_string cmti)

let read_and_index index (root, file) =
  let mod_name = CodocDoc.Maps.name_of_root root in
  let index_path = Filename.concat (LinkIndex.focus_path index) file in
  let unit = read index_path root in
  LinkIndex.index index (resource_of_cmti file) mod_name root unit;
  (mod_name, file)

let resolver failure_set index = DocOckResolve.build_resolver
  (fun _req_unit mod_name -> match LinkIndex.root_by_name index mod_name with
  | Some root -> Some root
  | None -> Hashtbl.replace failure_set mod_name (); None (* TODO *)
  )
  (LinkIndex.unit_by_root index)

let xml index mod_name xml_file = (* TODO: mark the root for "this"? *)
  let unit = LinkIndex.unit_by_name index mod_name in
  let failures = Hashtbl.create 10 in
  let unit = DocOckResolve.resolve (resolver failures index) unit in
  let issues = Hashtbl.fold (fun name () issues ->
    (CodocIndex.Module_resolution_failed name)::issues
  ) failures [] in
  let out_file = open_out xml_file in
  let output = Xmlm.make_output (`Channel out_file) in
  let printer = DocOckXmlPrint.build (fun output root ->
    Xmlm.output_tree (fun x -> x) output (List.hd (CodocDoc.xml_of_root root))
  ) in
  DocOckXmlPrint.file printer output unit;
  close_out out_file;
  issues

let uri_of_path ~scheme path =
  Uri.of_string begin
    if scheme <> "file" && Filename.check_suffix path "/index.html"
    then Filename.chop_suffix path "index.html"
    else path
  end

let normal_uri ~scheme uri =
  if scheme <> "file"
  then uri
  else Uri.(resolve "" uri (of_string "index.html"))

let write_html ~doc_root_depth ~css ~title html_file html =
  let root = Uri.of_string (CodocUtil.ascent_of_depth "" doc_root_depth) in
  let css = Uri.resolve "" root css in
  let html = <:html<<html>
  <head>
    <meta charset="utf-8" />
    <link rel="stylesheet" type="text/css" href=$uri:css$ />
    <title>$str:title$</title>
  </head>
  <body>
$html$
  </body>
</html>&>> in
  let out_file = open_out html_file in
  output_string out_file "<!DOCTYPE html>\n";
  let output = Xmlm.make_output ~decl:false (`Channel out_file) in
  Htmlm.Xhtmlm.output_doc_tree output (List.hd html);
  close_out out_file

let html ~pathloc ~doc_root_depth ~css ~pkg xml_file html_file =
  let in_file = open_in xml_file in
  let input = Xmlm.make_input (`Channel in_file) in
  match DocOckXmlParse.file doc_xml_parser input with
  | DocOckXmlParse.Error (start, pos, s) ->
    close_in in_file;
    [CodocIndex.Xml_error (xml_file, s)]
  | DocOckXmlParse.Ok unit ->
    close_in in_file;
    let pathloc = pathloc unit in
    let html =
      CodocDocHtml.of_unit ~pathloc unit
    in
    let title = pkg ^ " / " ^ (
      CodocDoc.Maps.string_of_ident
        (DocOckPaths.Identifier.any unit.DocOckTypes.Unit.id)
    ) in
    write_html ~doc_root_depth ~css ~title html_file html;
    [] (* TODO: issues *)

let only_cmti f file path output =
  if Filename.check_suffix file ".cmti"
  then begin
    Printf.eprintf "%s\n%!" path;
    f file path output
  end
  else false

open Webmaster_cli

let resolve_path base rel =
  Uri.(to_string (resolve "" (of_string base) (of_string rel)))

let cmti_path path output = rel_of_path (depth output) path

let generate ({ force }) formats (_os,output) (_ps,path) pkg scheme css share =
  let cmd = "doc" in
  let output_type = Webmaster_file.output_type path output in
  let doc_index_path, doc_index = match output_type with
    | Some (`Dir output) -> output, CodocIndex.(read (index_file output))
    | Some (`File _) | None -> "", CodocIndex.empty
  in
  let css = match css with
    | None ->
      let css_name = "codoc.css" in
      let shared_css = Filename.concat share css_name in
      Webmaster_file.ensure_directory_exists ~perm:0o700 doc_index_path;
      Webmaster_file.copy shared_css (Filename.concat doc_index_path css_name);
      Uri.of_string css_name
    | Some css -> css
  in
  let ((pkg_path, pkg_index_path), pkg_index), pkg_parents =
    CodocIndex.traverse doc_index_path pkg
  in
  let index = LinkIndex.create doc_index_path doc_index pkg_path in
  let roots = ref [] in
  let record file path output =
    let mod_name = FindlibUnits.unit_name_of_path path in
    let root = CodocDoc.(
      Html ("index.html",
            Xml ("index.xml",
                 Cmti (cmti_path path output,
                       mod_name)
            )
      )
    ) in
    roots := (root,file) :: !roots;
    false
  in
  let ret =
    Webmaster_file.output_of_input ~force ~cmd (only_cmti record) path
      (match output, output_type with
      | `Dir _, _ | `Missing _, Some (`Dir _) ->
        let dir = Filename.concat doc_index_path pkg_path in
        Webmaster_file.ensure_directory_exists ~perm:0o700 dir;
        `Dir dir
      | `File _, _ | `Missing _, (Some (`File _) | None) -> output
      )
  in
  match ret with
  | `Ok () ->
    let units = List.map (read_and_index index) !roots in
    let gunits =
      List.fold_left (fun gunits (name, file) ->
        let pkg_name = Filename.concat pkg_path (resource_of_cmti file) in
        let base_name = Filename.concat doc_index_path pkg_name in
        let xml_file = base_name ^ "/index.xml" in
        let html_file = base_name ^ "/index.html" in
        let () = Webmaster_file.ensure_directory_exists ~perm:0o700 base_name in
        let doc_root_depth = depth pkg_name + 1 in
        let xml_issues = xml index name xml_file in
        let local_resource = resource_of_cmti file in
        let pkg = pkg_path in
        let pkg_root_depth = depth local_resource + 1 in
        let pkg_root = CodocUtil.ascent_of_depth "" pkg_root_depth in
        let pathloc unit = CodocDocHtml.pathloc (* TODO: fixme *)
          ~unit
          ~index:(fun root -> (* TODO: report failures *)
            let path = LinkIndex.path_by_root index root in
            Some (uri_of_path ~scheme (Filename.concat pkg_root path))
          )
          ~pkg_root
          ~normal_uri:(normal_uri ~scheme)
        in
        let html_issues =
          html ~pathloc ~doc_root_depth ~css ~pkg xml_file html_file
        in
        { CodocIndex.mod_name = name;
          xml_file = local_resource ^ "/index.xml";
          html_file = Some (local_resource ^ "/index.html");
          issues=html_issues @ xml_issues;
        } :: gunits
      ) [] units
    in

    begin match output_type with
    | Some (`Dir output) ->
      let open CodocIndex in
      let unit_index = List.fold_left (fun map unit ->
        StringMap.add unit.mod_name unit map
      ) pkg_index.units gunits in
      let index = { pkg_index with units = unit_index } in
      write (Filename.concat doc_index_path pkg_index_path) index;
      let normal_uri = normal_uri ~scheme in
      let uri_of_path = uri_of_path ~scheme in
      let html =
        CodocIndexHtml.of_package
          ~name:pkg_path ~index ~normal_uri ~uri_of_path
      in
      let pkg_dir = Filename.concat doc_index_path pkg_path in
      write_html ~doc_root_depth:(depth pkg_path + 1) ~css ~title:pkg_path
        (Filename.concat pkg_dir "index.html") html;

      List.iter (fun ((name, index_path), index) ->
        write (Filename.concat doc_index_path index_path) index;
        let html =
          CodocIndexHtml.of_package
            ~name ~index ~normal_uri ~uri_of_path
        in
        let pkg_dir = Filename.concat doc_index_path name in
        let doc_root_depth = if name = "" then 0 else depth name + 1 in
        let title = if name = "" then "~" else name in
        write_html ~doc_root_depth ~css ~title
          (Filename.concat pkg_dir "index.html") html
      ) pkg_parents
    | Some (`File _) | None -> ()
    end;

    let warns = List.fold_left (fun err gunit ->
      (List.length gunit.CodocIndex.issues <> 0) || err
    ) false gunits in
    `Ok (Webmaster_file.check ~cmd warns)
  | ret -> ret