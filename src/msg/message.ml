(*
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010 Incubaid BVBA

Licensees holding a valid Incubaid license may use this file in
accordance with Incubaid's Arakoon commercial license agreement. For
more information on how to enter into this agreement, please contact
Incubaid (contact details can be found on www.arakoon.org/licensing).

Alternatively, this file may be redistributed and/or modified under
the terms of the GNU Affero General Public License version 3, as
published by the Free Software Foundation. Under this license, this
file is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

See the GNU Affero General Public License for more details.
You should have received a copy of the
GNU Affero General Public License along with this program (file "COPYING").
If not, see <http://www.gnu.org/licenses/>.
*)

module Message = struct

  type t = {kind:string; payload:string} (* primitive, bug suffices *)


  let create kind payload = 
    {kind = kind; payload = payload} 
  
  let kind_of t = t.kind

  let payload_of t = t.payload

  let string_of t= 
    Printf.sprintf "{kind=%s;payload=%S}" t.kind t.payload
      
  let to_buffer t buffer = 
    Llio.string_to buffer t.kind;
    Llio.string_to buffer t.payload
    
  let from_buffer buffer pos = 
    let k, pos1  = Llio.string_from buffer pos in
    let p, pos2  = Llio.string_from buffer pos1 
    in {kind=k;payload=p}, pos2
end
