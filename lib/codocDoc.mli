(*
 * Copyright (c) 2014 David Sheets <sheets@alum.mit.edu>
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

type path = string

type cmti_root = {
  cmti_path : path;
  unit_name : string;
  unit_digest : Digest.t;
}

(* TODO: time? *)
type resolution = {
  resolution_root : string;
}

type root =
| Cmti of cmti_root
| Resolved of resolution * root
(* TODO: use signature identifier when doc-ock-xml supports it *)
| Proj of (*root DocOckPaths.Identifier.signature*) string * root
| Xml of path * root
| Html of path * root

module Root : sig
  include CodocDocMaps.ROOT with type t = root

  val to_source : t -> t
  val to_path : t -> path
  val equal : t -> t -> bool
  val hash : t -> int
end

module Maps : CodocDocMaps.ROOTED_MAPS with type root = Root.t

type text = root DocOckTypes.Documentation.text

type t =
| Para of text
| Block of text

val xml_of_root : root -> Cow.Xml.t

val root_of_xml : Xmlm.tag -> root option list -> root option
val data_of_xml : string -> root option

val paragraphize : text -> t list
