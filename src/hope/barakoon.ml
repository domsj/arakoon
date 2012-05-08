open Mem_store 
open Bstore

open Lwt
open Mp_driver
open Dispatcher
open Pq 
open Node_cfg.Node_cfg
open Mp
open Statistics

open Modules
module BSC = C.ProtocolHandler(BStore)

(*
module MC = struct
  (* TODO Copied *)
  let __do_unit_update hub q =
    let id = gen_request_id () in
    MyHub.update hub id q >>= fun a ->
    match a with
      | Core.UNIT -> Lwt.return ()
      | Core.FAILURE (rc, msg) -> failwith msg

  let _set hub k v =
    let q = Core.SET(k,v) in
    __do_unit_update hub q

  let _delete hub k =
    let q = Core.DELETE k in
    __do_unit_update hub q

  let one_command hub ((ic, oc) as conn) =
    Memcache_protocol.read_command conn >>= fun comm ->
    match comm with
      | Memcache_protocol.GET keys ->
          begin
            _log "Memcache GET" >>= fun () ->
            Lwt.catch
              (fun () ->
                (* TODO This pulls everything in memory first. We might want to
                 * emit key/value pairs one by one instead *)
                Lwt_list.fold_left_s
                  (fun acc key ->
                    Lwt.catch
                      (fun () ->
                        MyHub.get hub key >>= fun value ->
                        Lwt.return ((key, value) :: acc))
                      (fun _ ->
                        Lwt.return acc))
                  [] keys
                >>=
                Memcache_protocol.response_get oc)
              (Memcache_protocol.handle_exception oc)
          end
      | Memcache_protocol.SET (key, value, noreply) ->
          begin
            _log "Memcache SET" >>= fun () ->
            Lwt.catch
            (fun () ->
              _set hub key value >>= fun () ->
              if noreply
              then
                Lwt.return false
              else
                Memcache_protocol.response_set oc)
            (Memcache_protocol.handle_exception oc)
          end
      | Memcache_protocol.DELETE (key, noreply) ->
          begin
            _log "Memcache DELETE" >>= fun () ->
            Lwt.catch
            (fun () ->
              _delete hub key >>= fun () ->
              (* TODO Handle NOT_FOUND *)
              if noreply
              then
                Lwt.return false
              else
                Memcache_protocol.response_delete oc true)
            (Memcache_protocol.handle_exception oc)
          end
      | Memcache_protocol.VERSION ->
          begin
            _log "Memcache VERSION" >>= fun () ->
            Memcache_protocol.response_version oc Version.git_info
          end
      | Memcache_protocol.QUIT ->
          begin
            _log "Memcache QUIT" >>= fun () ->
            Lwt.return true
          end
      | Memcache_protocol.ERROR ->
          begin
            _log "Memcache ERROR" >>= fun () ->
            Lwt.return true
          end

  let protocol hub (ic, oc) =
    _log "Memcache session started" >>= fun () ->
    let rec loop () =
      begin
        one_command hub (ic, oc) >>= fun stop ->
        if stop
        then _log "End of memcache session"
        else
          begin
            Lwt_io.flush oc >>= fun () ->
            loop ()
          end
      end
    in
    loop ()
end
*)
let server_t me driver store host port =
  let stats = Statistics.create () in
  let inner = Server.make_server_thread host port (BSC.protocol me stats driver store) in
  inner ()

(*
let mc_server_t hub =
  let host = "127.0.0.1"
  and port = 11211 in
  let inner = Server.make_server_thread host port (MC.protocol hub) in
  inner ()
*)
let log_prelude () = 
  Lwtc.log "--- NODE STARTED ---" >>= fun () ->
  Lwtc.log "git info: %s " Version.git_info >>= fun () ->
  Lwtc.log "compile_time: %s " Version.compile_time >>= fun () ->
  Lwtc.log "machine: %s " Version.machine 

let create_msging me others cluster_id =
  let cookie = cluster_id in
  let mapping = List.map
    (fun cfg -> (cfg.node_name, (cfg.ip, cfg.messaging_port)))
    (me::others)
  in
  let drop_it = (fun _ _ _ -> false) in
  let messaging = new Tcp_messaging.tcp_messaging 
    (me.ip, me.messaging_port) cookie drop_it in
  messaging # register_receivers mapping;
  (messaging :> Messaging.messaging)

let get_db_name cfg myname = 
  cfg.home ^ "/" ^ myname ^ ".bs"
  
let create_store cfg myname =
  let fn = get_db_name cfg myname in
  BStore.create fn  

let create_timeout_q () =
  PQ.create ()
  
let create_dispatcher store msging resyncs =
  let timeout_q = create_timeout_q () in 
  let disp = BADispatcher.create msging store timeout_q resyncs in
  (disp, timeout_q)

let range n = 
  let rec range_inner = function
    | 0 -> []
    | i -> (n-i) :: range_inner (i-1)
  in 
  range_inner n
  
let build_mpc mycfg others =
  let myname = mycfg.node_name in
  let other_cnt = List.length others in
  let name_others = List.fold_left 
    (fun acc cfg -> cfg.node_name :: acc) [] others
  in 
  let node_cnt = other_cnt + 1 in
  let q = 1 + (node_cnt / 2 ) in
  let lease = mycfg.lease_period in
  let all_nodes = List.fold_left (fun acc cfg-> cfg.node_name :: acc) [myname] others in
  let all_nodes_s = List.sort String.compare all_nodes in
  let nodes_with_ixs = List.combine all_nodes_s (range node_cnt) in
  let my_ix = List.assoc myname nodes_with_ixs in 
  MULTI.build_mp_constants q myname name_others (float_of_int lease) my_ix node_cnt 
  
let create_driver disp q = 
  DRIVER.create disp q (PQ.create())

let build_start_state store mycfg others =
  let n = Core.start_tick in
  BStore.last_update store >>= fun m_last ->
  let p, a, u =
    begin
      match m_last with
        | Some (i_time, u) -> 
          begin
            match u with
              | None -> i_time, i_time, None
              | _ -> i_time, (Core.prev_tick i_time), u
          end
        | None -> Core.start_tick, Core.start_tick, None
    end
  in
  let c = build_mpc mycfg others in
  let s = MULTI.build_state c n p a u in
  Lwt.return s 

let rec pass_msg msging q target =
  msging # recv_message ~target >>= fun (msg_s, id) ->
  let msg = MULTI.msg_of_string msg_s in
  PQ.push q msg ;
  pass_msg msging q target

type action_type =
  | ShowUsage
  | ShowVersion
  | RunNode
  | InitDb
  | DumpDb
  | Set
  | Get
  | Delete
  | Benchmark
  | LastEntries


let split_cfgs cfg myname =
  let (others, me_as_list) = List.partition (fun cfg -> cfg.node_name <> myname) cfg.cfgs in
  begin
    match me_as_list with
      | [] -> Lwtc.failfmt "Node '%s' does not exist in config" myname 
      | cfg :: [] -> Lwt.return (others, cfg)
      | _ -> Lwtc.failfmt "Node '%s' occurs multiple times in config" myname
  end

let create_resyncs others cluster_id =
  let resyncs = Hashtbl.create (List.length others) in
  let extract_name_ip_port cfg = (cfg.node_name, cfg.ip, cfg.client_port) in
  List.iter 
    (fun cfg -> 
      let (n, ip, port) = extract_name_ip_port cfg in
      Hashtbl.replace resyncs n 
        (fun l -> 
          let log = (l: Bstore.BStore.t) in
          Sync.sync ip port cluster_id log) 
    )
    others;
  resyncs

let run_node myname config_file daemonize =      
  Lwt_io.set_default_buffer_size 32768;
  let killswitch = Lwt_mutex.create () in
  Lwt_mutex.lock killswitch >>= fun () ->
  let unlock_killswitch () = Lwt_mutex.unlock killswitch in
  let wait_for_sigterm () = Lwt_mutex.lock killswitch in
  (* Clean shutdown on signals  SIGINT SIGQUIT SIGABRT SIGTERM *)
  let quit_signals = [2;3;6;15] in
  List.iter 
    (fun sign -> let _ = Lwt_unix.on_signal sign (fun i -> unlock_killswitch ()) in () ) 
    quit_signals ;
  let cfg = read_config config_file in
  split_cfgs cfg myname >>= fun (others, mycfg) ->
  let () = if daemonize then Lwt_daemon.daemonize () in
  Lwtc.configure_logging mycfg >>= fun () ->
  log_prelude () >>= fun () ->
  let cluster_id = cfg.cluster_id in 
  let msging = create_msging mycfg others cluster_id in
  let start = Unix.gettimeofday() in
  Lwtc.log "Creating store" >>= fun () ->
  create_store mycfg myname >>= fun store ->
  Lwtc.log "Created store (took %f seconds)" (Unix.gettimeofday() -. start) >>= fun () ->
  let resyncs = create_resyncs others cluster_id in
  let disp, q = create_dispatcher store msging resyncs in
  let driver = create_driver disp q in
  let service driver = server_t mycfg.node_name driver store mycfg.ip mycfg.client_port in
  build_start_state store mycfg others >>= fun s ->
  let delayed_timeout = MULTI.A_START_TIMER (s.MULTI.round, Core.start_tick, float_of_int mycfg.lease_period) in
  DRIVER.dispatch driver s delayed_timeout >>= fun s' ->
  let other_names = List.fold_left (fun acc c -> c.node_name :: acc) [] others in
  let pass_msgs = List.map (pass_msg msging q) (myname :: other_names) in
  let close_store () =
    BStore.close store >>= fun () ->
    Lwtc.log "Closed store"
  in
  Lwt.finalize
  ( fun () ->
    Lwt.pick [ DRIVER.serve driver s' None ;
             service driver;
             msging # run ();
             Lwt.join pass_msgs;
             wait_for_sigterm (); 
             ]
  ) ( fun () ->
    close_store()  
  )


let init_db myname config_file =
  let cfg = read_config config_file in
  split_cfgs cfg myname >>= fun (_, mycfg) ->
  let fn = get_db_name mycfg myname in
  BStore.init fn

let dump_db myname config_file = 
  let cfg = read_config config_file in
  split_cfgs cfg myname >>= fun (_, mycfg) ->
  let fn = get_db_name mycfg myname in
  BStore.create fn >>= fun store ->
  BStore.dump store >>= fun () ->
  BStore.close store


let show_version ()=
  Lwt_io.printlf "git_info: %S" Version.git_info >>= fun () ->
  Lwt_io.printlf "compiled: %S" Version.compile_time >>= fun () ->
  Lwt_io.printlf "machine: %S" Version.machine 
  
let set cfg_name k v =
  Client_main.with_master_client cfg_name (fun client -> client # set k v)

let get cfg_name k = 
  Client_main.with_master_client cfg_name 
    (fun client -> client # get k >>= fun v -> 
      Lwt_io.printlf "%S" v
    )

let delete cfg_name k = Client_main.with_master_client cfg_name (fun client -> client # delete k)

let benchmark cfg_name max_n size = 
  let tx_size = 100 
  and n_clients = 1 
  in
  let with_c = Client_main.with_master_client cfg_name in
  Benchmark.benchmark ~with_c ~size ~tx_size ~max_n n_clients

let last_entries config_file myname i =
  let cfg = read_config config_file in
  split_cfgs cfg myname >>= fun (others , mycfg) ->
  let ip = mycfg.ip
  and port = mycfg.client_port
  in
  let addr = Network.make_address ip port in
  let dump_entry () i alist =
    Lwt_list.iter_s (fun a -> Lwt_io.printlf "%Li : %s" i (Sync._action2s a)) alist 
  in
  Sync.remote_iterate addr cfg.cluster_id i dump_entry ()

let main_t () =
  let node_id = ref "" 
  and action = ref (ShowUsage) 
  and config_file = ref "cfg/arakoon.ini"
  and daemonize = ref false
  and key = ref ""
  and value = ref ""
  and max_n = ref (1000 * 1000)
  and value_size = ref 1024 
  and is = ref ""
  in
  let set_action a = Arg.Unit (fun () -> action := a) in
  let actions = [
    ("--node", 
     Arg.Tuple [set_action RunNode; Arg.Set_string node_id;],
     "<node_id> : Runs a node");
    ("-config", Arg.Set_string config_file,
     "<file> : Specifies config file (default = cfg/arakoon.ini)");
    ("-daemonize", Arg.Set daemonize,
     ": Add if you want the process to daemonize (only for --node)");
    ("--version",
     Arg.Tuple [set_action ShowVersion],
     ": Returns version info");
    ("--set", Arg.Tuple[set_action Set; Arg.Set_string key; Arg.Set_string value],
     "<key> <value> : arakoon[key]:= value"
    );
    ("--get", Arg.Tuple[set_action Get; Arg.Set_string key;],
     "<key> : Returns arakoon[key]"
    );
    ("--delete", Arg.Tuple[set_action Delete;Arg.Set_string key;],
     "<key> : Delete arakoon[key]");
    ("--benchmark", Arg.Tuple [set_action Benchmark],
     " : Runs a benchmark against an existing cluster");
    ("-max_n", Arg.Tuple[Arg.Set_int max_n], 
     "<n> : loop size (benchmark only) default=" ^ (string_of_int !max_n));
    ("-value_size", Arg.Tuple[Arg.Set_int value_size], 
     "<size> : Size of values (benchmark only) default=" ^ (string_of_int !value_size)) ;
    ("--init-db", 
     Arg.Tuple [set_action InitDb; Arg.Set_string node_id;],
     "<node_id> : Initialize the database for the given node");
    ("--dump-db", Arg.Tuple [set_action DumpDb; Arg.Set_string node_id],
     "<node_id> : Dump contents of database");
    ("--last-entries", Arg.Tuple[set_action LastEntries; Arg.Set_string node_id; Arg.Set_string is],
     "<node_id> <i> : Retrieve a nodes update stream starting with <i>");
  ] in
  
  Arg.parse actions  
    (fun x -> raise (Arg.Bad ("Bad argument : " ^ x)))
    "";
  begin 
    match !action with
      | RunNode -> run_node !node_id !config_file !daemonize
      | ShowUsage -> Lwt.return (Arg.usage actions "")
      | InitDb -> init_db !node_id !config_file
      | DumpDb -> dump_db !node_id !config_file
      | ShowVersion -> show_version()
      | Set -> set !config_file !key !value
      | Get -> get !config_file !key
      | Delete -> delete !config_file !key
      | Benchmark -> benchmark !config_file !max_n !value_size
      | LastEntries -> last_entries !config_file !node_id (Int64.of_string !is)
  end

let () = Lwt_main.run (main_t())