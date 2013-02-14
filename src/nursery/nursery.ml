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
open Lwt
open Routing
open Client_cfg
open Ncfg
open Interval

let so2s = Log_extra.string_option_to_string

let try_connect (ips, port) =
  Lwt.catch
    (fun () -> 
      let sa = Network.make_address ips port in
      Network.__open_connection sa >>= fun (ic,oc) ->
      let r = Some (ic,oc) in
      Lwt.return r
    )
    (fun exn -> Lwt.return None)



module NC = struct
  type connection = Lwt_io.input_channel * Lwt_io.output_channel 
  type lc = 
    | Address of (string * int)
    | Connection of connection

  type nn = string * string (* cluster_name,node_name *)

  type t = {
    rc : NCFG.t; 
    keeper_cn: string;
    connections : (nn ,lc) Hashtbl.t;
    masters: (string, string option) Hashtbl.t;
  }

  let make rc keeper_cn = 
    let masters = Hashtbl.create 5 in
    let () = NCFG.iter_cfgs rc (fun k _ -> Hashtbl.add masters k None) in
    let connections = Hashtbl.create 13 in
    let () = NCFG.iter_cfgs rc
      (fun cluster v -> 
	Hashtbl.iter (fun node (ip,port) ->
	  let nn = (cluster,node) in
	  let a = Address (ip,port) in
	  Hashtbl.add connections nn a) v)
    in
    {rc; connections;masters;keeper_cn}

  let _get_connection t nn = 
    let (cn,node) = nn in
    match Hashtbl.find t.connections nn with
      | Address (ip,port) -> 
	begin
	  try_connect (ip,port) >>= function
	    | Some conn -> 
	      Common.prologue cn conn >>= fun () ->
	      let () = Hashtbl.add t.connections nn (Connection conn) in
	      Lwt.return conn
	    | None -> Llio.lwt_failfmt "Connection to (%s,%i) failed" ip port
	end
      | Connection conn -> Lwt.return conn
  
  let _find_master_remote t cn = 
    let ccfg = NCFG.get_cluster t.rc cn in
    let node_names = ClientCfg.node_names ccfg in
    Lwt_log.debug_f "names:%s" (Log_extra.string_of_list (fun s->s) node_names) 
    >>= fun () ->
    Lwt_list.map_s 
      (fun n -> 
	let nn = (cn,n) in 
	_get_connection t nn
      ) 
      node_names 
    >>= fun connections ->
    let get_master acc conn =
      begin
        match acc with
          | None ->
            Common.who_master conn
          | x -> Lwt.return x
      end
    in
    Lwt_list.fold_left_s get_master None connections >>= function 
      | None -> 
        Lwt_log.error_f "Could not find master for cluster %s" cn >>= fun () ->
        Lwt.fail (Failure "Could not find master.")
      | Some m ->
        Lwt_log.debug_f "Found master %s" m >>= fun () ->
        Lwt.return m
   
    
	
  let _find_master t cn = 
    let m = Hashtbl.find t.masters cn in
    match m with
      | None -> _find_master_remote t cn 
      | Some master -> Lwt.return master 	  

  let _with_master_connection t cn (todo: connection -> 'c Lwt.t) =
    Lwt_log.debug_f "_with_master_connection %s" cn >>= fun () ->
    _find_master t cn >>= fun master ->
    let nn = cn, master in
    _get_connection t nn >>= fun connection ->
    todo connection
    
  let set t key value = 
    let cn = NCFG.find_cluster t.rc key in
    Lwt_log.debug_f "set %S => %s" key cn >>= fun () ->
    let todo conn = Common.set conn key value in
    _with_master_connection t cn todo

  let get t key = 
    Lwtc.log "get %s" key  >>= fun () ->
    let cn = NCFG.find_cluster t.rc key in
    Lwt_log.debug_f "get %s => %s" key cn >>= fun () ->
    let todo conn = Common.get conn false key in
    _with_master_connection t cn todo

  let force_interval t cn i = 
    Lwt_log.debug_f "force_interval %s: %s" cn (Interval.to_string i) >>= fun () ->
    _with_master_connection t cn 
    (fun conn -> Common.set_interval conn i)


  let close t = Llio.lwt_failfmt "close not implemented"

  let _log_fringe fringe = 
    let size = List.length fringe in
    Lwt_log.debug_f "fringe. size = %i" size >>= fun () ->
    Lwt_list.iter_s (fun (k,_) -> Lwt_log.debug_f "   %s:_" k) fringe
 
  let __migrate t clu_left sep clu_right finalize publish migration = 
    Lwt_log.debug_f "migrate %s" (Log_extra.string_option_to_string sep) >>= fun () ->
    let from_cn, to_cn, direction = migration in
    Lwt_log.debug_f "from:%s to:%s" from_cn to_cn >>= fun () ->
    let pull () = 
      Lwt_log.debug "pull">>= fun () ->
      _with_master_connection t from_cn 
        (fun conn -> Common.get_fringe conn sep direction )
    in
    let push fringe i = 
      let seq = List.map (fun (k,v) -> Arakoon_client.Set(k,v)) fringe in
      Lwt_log.debug "push" >>= fun () ->
      _with_master_connection t to_cn 
        (fun conn -> Common.migrate_range conn i seq)
      >>= fun () ->
      Lwt_log.debug "done pushing" 
    in

    let delete fringe = 
      let seq = List.map (fun (k,_) -> Arakoon_client.Delete k) fringe in
      Lwt_log.debug "delete" >>= fun () ->
      _with_master_connection t from_cn 
        (fun conn -> Common.sequence conn seq)
    in
    let get_next_key k =
      k ^ (String.make 1 (Char.chr 1))
    in
    let get_interval cn = _with_master_connection t cn Common.get_interval in
    let set_interval cn i = force_interval t cn i in
    let i2s i = Interval.to_string i in
    Lwt_log.debug_f "Getting initial interval from %s" from_cn >>= fun () ->
    get_interval from_cn >>= fun from_i -> 
    Lwt_log.debug_f "from_i: %s" (Interval.to_string from_i) >>= fun () ->
    Lwt_log.debug_f "Getting initial interval from %s" to_cn >>= fun () ->
    get_interval to_cn >>= fun to_i ->
    Lwt_log.debug_f "to_i: %s" (Interval.to_string to_i) >>= fun () ->
    let rec loop from_i to_i =
      pull () >>= fun fringe ->
      match fringe with
        | [] -> 
            begin
              Lwt_log.debug_f "from_i: %s to_i: %s => empty fringe" 
                (Interval.to_string from_i) 
                (Interval.to_string to_i)
              >>= fun () ->
              finalize from_i to_i
            end 
        | fringe -> 
            _log_fringe fringe >>= fun () ->
	        (* 
	         - change public interval on 'from'
	         - push fringe & change private interval on 'to'
	         - delete fringe & change private interval on 'from'
	         - change public interval 'to'
	         - publish new route.
          *)
          let (fpu_b,fpu_e),(fpr_b,fpr_e) = from_i in
          let (tpu_b,tpu_e),(tpr_b,tpr_e) = to_i in
          begin 
            match direction with
              | Routing.UPPER_BOUND -> 
                let b, _ = List.hd fringe in
                let e, _ = List.hd( List.rev fringe ) in
                let e = get_next_key  e in
                Lwt_log.debug_f "b:%S e:%S" b e >>= fun () ->
                let from_i' = Interval.make (Some e) fpu_e fpr_b fpr_e in
                set_interval from_cn from_i' >>= fun () ->
                let to_i1 = Interval.make tpu_b tpu_e tpr_b (Some e) in
                push fringe to_i1 >>= fun () ->
                Lwt_log.debug "going to delete fringe" >>= fun () ->
                delete fringe >>= fun () ->
                Lwt_log.debug "Fringe now is deleted. Time to change intervals" >>= fun () ->
                let to_i2 = Interval.make tpu_b (Some e) tpr_b (Some e) in
                set_interval to_cn to_i2 >>= fun () ->
                let from_i2 = Interval.make (Some e) fpu_e (Some e) fpr_e in
                set_interval from_cn from_i2 >>= fun () ->
                Lwt.return (e, from_i2, to_i2, to_cn, from_cn)
                
              | Routing.LOWER_BOUND ->
                let b, _ = List.hd( List.rev fringe ) in
                let e, _ = List.hd fringe in
                Lwt_log.debug_f "b:%S e:%S" b e >>= fun () ->
                let from_i' = Interval.make fpu_b (Some b) fpr_b fpr_e in
                set_interval from_cn from_i' >>= fun () ->
                let to_i1 = Interval.make tpu_b tpu_e (Some b) tpr_e in
                push fringe to_i1 >>= fun () ->
                delete fringe >>= fun () ->
                Lwt_log.debug "Fringe now is deleted. Time to change intervals" >>= fun () ->
                let to_i2 = Interval.make (Some b) tpu_e (Some b) tpr_e in
                set_interval to_cn to_i2 >>= fun () ->
                let from_i2 = Interval.make fpu_b (Some b) fpr_b (Some b) in
                set_interval from_cn from_i2 >>= fun () ->
                Lwt.return (b, from_i2, to_i2, from_cn, to_cn)
          end
          >>= fun (pub, from_i2, to_i2, left, right) ->
          (* set_interval to_cn to_i1 >>= fun () -> *)
          Lwt_log.debug_f "from {%s:%s;%s:%s}" from_cn (i2s from_i) to_cn (i2s to_i) >>= fun () ->
          Lwt_log.debug_f "to   {%s:%s;%s:%s}" from_cn (i2s from_i2) to_cn (i2s to_i2) >>= fun () ->
          publish (Some pub) left right >>= fun () ->
          loop from_i2 to_i2
    in 
    loop from_i to_i
    
    
  let migrate t clu_left (sep: string) clu_right  =
    Lwt_log.debug_f "migrate: %s %S %s" clu_left sep clu_right >>= fun () ->
    let r = NCFG.get_routing t.rc in
    let from_cn, to_cn, direction = Routing.get_diff r clu_left sep clu_right in
    let publish sep left right = 
      let route = NCFG.get_routing t.rc in 
      Lwt_log.debug_f "old_route:%S" (Routing.to_s route) >>= fun () ->
      Lwt_log.debug_f "left: %s - sep: %s - right: %s" left (Log_extra.string_option_to_string sep) right >>= fun () ->
      begin
        match sep with
          | Some sep ->
            let new_route = Routing.change route left sep right in
            let () = NCFG.set_routing t.rc new_route in
            Lwt_log.debug_f "new route:%S" (Routing.to_s new_route) >>= fun () -> 
            _with_master_connection t t.keeper_cn
              (fun conn -> Common.set_routing_delta conn left sep right)
          | None -> failwith "Cannot end up with an empty separator during regular migration"
      end 
    in
    let set_interval cn i = force_interval t (cn: string) (i: Interval.t) in
    let finalize (from_i: Interval.t) (to_i: Interval.t) = 
      Lwt_log.debug "Setting final intervals en routing" >>= fun () ->
      let (fpu_b, fpu_e), (fpr_b, fpr_e) = from_i in
      let (tpu_b, tpu_e), (tpr_b, tpr_e) = to_i in
      let (from_i', to_i', left, right) = 
        begin
          match direction with
            | Routing.UPPER_BOUND ->
              let from_i' = (Some sep, fpu_e), (Some sep, fpr_e) in
              let to_i' = (tpu_b, Some sep), (tpr_b, Some sep) in
              from_i', to_i', to_cn, from_cn
             
            | Routing.LOWER_BOUND ->
              let from_i' = (fpu_b, Some sep), (fpr_b, Some sep) in
              let to_i' = (Some sep, tpu_e), (Some sep, tpr_e) in
              from_i', to_i', from_cn, to_cn
        end 
      in
      Lwt_log.debug_f "final interval: from: %s" (Interval.to_string from_i') >>= fun () ->
      Lwt_log.debug_f "final interval: to  : %s" (Interval.to_string to_i') >>= fun () ->
      set_interval from_cn from_i' >>= fun () ->
      set_interval to_cn to_i' >>= fun () ->
      publish (Some sep) left right
    in
    __migrate t clu_left (Some sep) clu_right finalize publish (from_cn, to_cn, direction)
  
  let delete t (cluster_id: string) (sep: string option) =
    Lwt_log.debug_f "Nursery.delete %s %s" cluster_id (so2s sep) >>= fun () -> 
    let r = NCFG.get_routing t.rc in
    let lower = Routing.get_lower_sep None cluster_id r in
    let upper = Routing.get_upper_sep None cluster_id r in
    let publish sep left right = 
      let route = NCFG.get_routing t.rc in 
      Lwt_log.debug_f "old_route:%S" (Routing.to_s route) >>= fun () ->
      Lwt_log.debug_f "left: %s - sep: %s - right: %s" left (Log_extra.string_option_to_string sep) right >>= fun () ->
      begin
        match sep with
          | Some sep ->
            let new_route = Routing.change route left sep right in
            let () = NCFG.set_routing t.rc new_route in
            Lwt_log.debug_f "new route:%S" (Routing.to_s new_route) >>= fun () -> 
            _with_master_connection t t.keeper_cn
              (fun conn -> Common.set_routing_delta conn left sep right)
          | None -> 
            let new_route = Routing.remove route cluster_id in
            let () = NCFG.set_routing t.rc new_route in
            Lwt_log.debug_f "new route:%S" (Routing.to_s new_route) >>= fun () -> 
            _with_master_connection t t.keeper_cn
              (fun conn -> Common.set_routing conn new_route)
      end 
    in
    let set_interval cn i = force_interval t (cn: string) (i: Interval.t) in
    let finalize from_cn to_cn direction (from_i: Interval.t) (to_i: Interval.t) = 
      Lwt_log.debug "Setting final intervals en routing" >>= fun () ->
      let (fpu_b, fpu_e), (fpr_b, fpr_e) = from_i in
      let (tpu_b, tpu_e), (tpr_b, tpr_e) = to_i in
      let (from_i', to_i', left, right) = 
        begin
          match direction with
            | Routing.UPPER_BOUND ->
              let from_i' = (sep, fpu_e), (sep, fpr_e) in
              let to_i' = (tpu_b, sep), (tpr_b, sep) in
              from_i', to_i', to_cn, from_cn
             
            | Routing.LOWER_BOUND ->
              let from_i' = (fpu_b, sep), (fpr_b, sep) in
              let to_i' = (sep, tpu_e), (sep, tpr_e) in
              from_i', to_i', from_cn, to_cn
        end 
      in
      Lwt_log.debug_f "final interval: from: %s" (Interval.to_string from_i') >>= fun () ->
      Lwt_log.debug_f "final interval: to  : %s" (Interval.to_string to_i') >>= fun () ->
      set_interval from_cn from_i' >>= fun () ->
      set_interval to_cn to_i' >>= fun () ->
      publish sep left right
    in
    begin
      Lwt_log.debug_f "delete lower - upper : %s - %s" (so2s lower) (so2s upper) >>= fun () ->
	    match lower, upper with
	      | None, None -> failwith "Cannot remove last cluster from nursery"
	      | Some x, None ->
	        begin
	          match sep with
	            | None ->
	              let m_prev = Routing.prev_cluster r cluster_id in
                begin
                  match m_prev with 
                    | None -> failwith "Invalid routing request. No previous??"
                    | Some prev ->
	                    __migrate t cluster_id sep prev 
                        (finalize cluster_id prev Routing.UPPER_BOUND) 
                        publish (cluster_id, prev, Routing.UPPER_BOUND)
                end
	            | Some y ->
	              failwith "Cannot set separator when removing a boundary cluster from the nursery"
	        end
	      | None, Some x ->
	        begin
	          match sep with
	            | None ->
	              let m_next = Routing.next_cluster r cluster_id in
                begin
                  match m_next with
                    | None -> failwith "Invalid routing request. No next??"
                    | Some next ->
    	                __migrate t cluster_id sep next 
                        (finalize cluster_id next Routing.LOWER_BOUND)
                        publish (cluster_id, next, Routing.LOWER_BOUND)
                end
	            | Some y ->
	              failwith "Cannot set separator when removing a boundary cluster from a nursery"
	        end
	      | Some x, Some y ->
          begin
            match sep with
              | None -> 
                failwith "Need to set replacement boundary when removing an inner cluster from the nursery"
              | Some y -> 
                let m_next = Routing.next_cluster r cluster_id in
                let m_prev = Routing.prev_cluster r cluster_id in
                begin
                  match m_next, m_prev with
                    | Some next, Some prev -> 
                      __migrate t cluster_id sep prev 
                        (finalize cluster_id prev Routing.UPPER_BOUND)
                        publish (cluster_id, prev, Routing.UPPER_BOUND) 
                      >>= fun () ->
                      __migrate t cluster_id sep next 
                        (finalize cluster_id next Routing.LOWER_BOUND)
                        publish (cluster_id, next, Routing.LOWER_BOUND)
                    | _ -> failwith "Invalid routing request. No next or previous??"
                end
          end
    end
    
end
(*
let nursery_test_main () =
  (* All_test.configure_logging (); *)
  let repr = [("left", "ZZ")], "right" in (* all in left *)
  let routing = Routing.build repr in
  let left_cfg = ClientCfg.make () in
  let right_cfg = ClientCfg.make () in
  let () = ClientCfg.add left_cfg "left_0"   ("127.0.0.1", 4000) in
  let () = ClientCfg.add right_cfg "right_0" ("127.0.0.1", 5000) in
  let nursery_cfg = NCFG.make routing in
  let () = NCFG.add_cluster nursery_cfg "left" left_cfg in
  let () = NCFG.add_cluster nursery_cfg "right" right_cfg in
  let keeper = "left" in
  let nc = NC.make nursery_cfg keeper in
  (*
  let test k v = 
    NC.set client k v >>= fun () ->
    NC.get client k >>= fun v' ->
    Lwt_log.debug_f "get '%s' yields %s" k v' >>= fun () ->
    Lwt_log.debug "done"
  in
  let t () = 
    test "a" "A" >>= fun () ->
    test "z" "Z" 
  *)
  let t () = 
    Lwt_log.info "pre-fill" >>= fun () ->
    let rec fill i = 
      if i = 64 
      then Lwt.return () 
      else 
	let k = Printf.sprintf "%c" (Char.chr i) 
	and v = Printf.sprintf "%c_value" (Char.chr i) in
	NC.set nc k v >>= fun () -> 
	fill (i-1)
    in
    let left_i  = Interval.make None None None None    (* all *)
    and right_i = Interval.make None None None None in (* all *)
    NC.force_interval nc "left" left_i >>= fun () ->
    NC.force_interval nc "right" right_i >>= fun () ->
    fill 90 >>= fun () ->
    
    NC.migrate nc "left" "T" "right"
  in
  Lwt_main.run (t ())

*)
