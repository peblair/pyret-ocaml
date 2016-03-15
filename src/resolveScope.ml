module A = Ast
module SD = PyretUtils.StringDict
module U = AstUtils
module G = Gensym
module T = TypeStructs

open CompileStructs
open PyretUtils

type binding_group =
  | LetBinds of Ast.let_bind list
  | LetrecBinds of Ast.letrec_bind list
  | TypeLetBinds of Ast.type_let_bind list

let mk_bind l id = A.SBind(l,false,id,A.ABlank)

type mk_id_res = {id : A.name; id_b : A.bind; id_e : A.expr }
let mk_id loc base : mk_id_res =
  let t = A.SName(loc,base) in
  {id = t; id_b = mk_bind loc t; id_e = A.SId(loc,t)}

let resolve_provide (p : A.provide) (b : A.expr) =
  match p with
  | A.SProvideAll(l) ->
    let ids = A.block_ids b in
    let obj = A.SObj(l, List.map
                       (fun id -> A.SDataField(l, A.name_tosourcestring id, A.SId(l,id))) ids) in
    A.SProvide(l, obj)
  | _ -> p

let resolve_type_provide (p : A.provide_types) (b : A.expr) =
  match p with
  | A.SProvideTypesAll(l) ->
    let ids = A.block_type_ids b in
    let type_fields = List.map (function
        | A.TypeID(_,name) -> A.AField(l, A.name_toname name, A.AName(l, name))
      ) ids in
    A.SProvideTypes(l, type_fields)
  | _ -> p

let expand_import (imp : A.import) (env : CompileEnvironment.t) : A.import =
  match imp with
  | A.SImport(l,imp,name) ->
    A.SImportComplete(l,[],[],imp,name,name)
  | A.SImportFields(l,fields,imp) ->
    A.SImportComplete(l,fields,[],imp,A.SUnderscore(l),A.SUnderscore(l))
  | A.SInclude(l,imp) ->
    let imp_name = A.SUnderscore(l) in
    let info_key = Dependency.key (U.import_to_dep imp) in
    let safe_find sd key =
      try
        Some(SD.find sd key)
      with
      | Invalid_argument(_) -> None in
    let mod_info =
      safe_find info_key (match env with | CompileEnvironment.CompileEnvironment(_,e) -> e) in
    (match mod_info with
    | None -> failwith ("No compile-time information provided for module "^info_key)
    | Some(provides) ->
      match provides with
      | Provides.Provides(_,values,aliases,_) ->
        let val_names = List.map (fun n -> A.SName(l,fst n)) (SD.bindings values) in
        let type_names = List.map (fun n -> A.SName(l, fst n)) (SD.bindings aliases) in
        A.SImportComplete(l,val_names,type_names,imp,imp_name,imp_name))
  | A.SImportComplete(_,_,_,_,_,_) -> imp
  | _ -> failwith "NYI: SImportTypes"

let desugar_toplevel_types stmts =
  let rev_type_binds = ref [] in
  let rev_stmts = ref [] in
  List.iter (function
      | (Ast.SType(l, name, ann) as s) ->
        rev_stmts := s :: !rev_stmts
      | Ast.SNewtype(l, name, namet) ->
        rev_type_binds := (A.SNewtypeBind(l, name, namet)) :: !rev_type_binds
      | Ast.SData(l, name, params, mixins, variants, shared, _check) ->
        let namet = Ast.global_names name in
        rev_type_binds := (A.SNewtypeBind(l, A.SName(l, name), namet)) :: !rev_type_binds;
        rev_stmts := (A.SDataExpr(l, name, namet, params, mixins, variants, shared, _check)) :: !rev_stmts
      | (_ as s) -> rev_stmts := s :: !rev_stmts) stmts;
  match List.rev !rev_type_binds with
  | [] -> stmts
  | ((Ast.STypeBind(l,_,_)) :: _ as type_binds)
  | ((Ast.SNewtypeBind(l,_,_)) :: _ as type_binds) ->
    let new_stmts = List.rev !rev_stmts in
    [A.STypeLetExpr(l, type_binds, A.SBlock(l, new_stmts))]

let bind_wrap bg expr =
  match bg with
  | LetBinds([])
  | LetrecBinds([])
  | TypeLetBinds([]) -> expr
  | LetBinds((Ast.SLetBind(loc,_,_)) :: _ as binds)
  | LetBinds((Ast.SVarBind(loc,_,_)) :: _ as binds) ->
    Ast.SLetExpr(loc, List.rev binds, expr)
  | LetrecBinds((Ast.SLetrecBind(loc,_,_)) :: _ as binds) ->
    Ast.SLetrec(loc, List.rev binds, expr)
  | TypeLetBinds((Ast.STypeBind(loc,_,_)) :: _ as binds)
  | TypeLetBinds((Ast.SNewtypeBind(loc,_,_)) :: _ as binds) ->
    Ast.STypeLetExpr(loc, List.rev binds, expr)

let rec add_letrec_bind bg lrb stmts = add_letrec_binds bg [lrb] stmts

and add_letrec_binds bg lrbs stmts =
  match bg with
  | LetrecBinds(binds) ->
    desugar_scope_block stmts (LetrecBinds (lrbs @ binds))
  | LetBinds(_)
  | TypeLetBinds(_) ->
    bind_wrap bg @@ desugar_scope_block stmts (LetrecBinds lrbs)

and add_let_bind bg lb stmts =
  match bg with
  | LetBinds(binds) ->
    desugar_scope_block stmts (LetBinds(lb :: binds))
  | LetrecBinds(_)
  | TypeLetBinds(_) ->
    bind_wrap bg @@ desugar_scope_block stmts (LetBinds [lb])

and add_type_let_bind bg tlb stmts =
  match bg with
  | TypeLetBinds(binds) ->
    desugar_scope_block stmts (TypeLetBinds(tlb :: binds))
  | LetBinds(_)
  | LetrecBinds(_) ->
    bind_wrap bg @@ desugar_scope_block stmts (TypeLetBinds [tlb])

(** Treating stmts as a block, resolve scope.
There should be no blocks left after this stage of the compiler pipeline. *)
and desugar_scope_block stmts binding_group =
  match stmts with
  | [] -> failwith "Should not get an empty block in desugar_scope_block"
  | f :: rest_stmts ->
    match f with
    | Ast.SType(l, name, ann) ->
      add_type_let_bind binding_group (Ast.STypeBind(l, name, ann)) rest_stmts
    | Ast.SLet(l, bind, expr, _) ->
      add_let_bind binding_group (Ast.SLetBind(l, bind, expr)) rest_stmts
    | Ast.SVar(l, bind, expr) ->
      add_let_bind binding_group (Ast.SVarBind(l, bind, expr)) rest_stmts
    | Ast.SRec(l, bind, expr) ->
      add_letrec_bind binding_group (Ast.SLetrecBind(l, bind, expr)) rest_stmts
    | Ast.SFun(l, name, params, args, ann, doc, body, _check) ->
      let sbind = Ast.SBind(l, false, Ast.SName(l, name), Ast.ABlank)
      and slam  = Ast.SLam(l, params, args, ann, doc, body, _check) in
      add_letrec_bind binding_group (Ast.SLetrecBind(l, sbind, slam)) rest_stmts
    | Ast.SDataExpr(l, name, namet, params, mixins, variants, shared, _check) ->
      let b loc id = Ast.SBind(loc, false, Ast.SName(l, id), Ast.ABlank)
      and bn loc n = Ast.SBind(loc, false, n, Ast.ABlank) in
      let variant_binds data_blob_id = function
        | Ast.SVariant(loc,_,vname,_,_) ->
          let checker_name = Ast.make_checker_name vname in
          let get_part x = Ast.SDot(loc, data_blob_id, x) in
          [Ast.SLetrecBind(loc, b loc vname, get_part vname);
           Ast.SLetrecBind(loc, b loc checker_name, get_part checker_name)]
        | _ -> failwith "Non-letrec-id given to variant_binds" in
      let blob_id = Ast.global_names name
      and data_expr = Ast.SDataExpr(l, name, namet, params, mixins, variants, shared, _check) in
      let bind_data = Ast.SLetrecBind(l, bn l blob_id, data_expr)
      and bind_data_pred = Ast.SLetrecBind(l, b l @@ Ast.make_checker_name name, Ast.SDot(l, Ast.SIdLetrec(l, blob_id, true), name))
      and bind_data_pred2 = Ast.SLetrecBind(l, b l name, Ast.SDot(l, Ast.SIdLetrec(l, blob_id, true), name)) in
      let all_binds = List.fold_left (fun acc v ->
          (variant_binds (Ast.SIdLetrec(l, blob_id, true)) v) @ acc)
          [bind_data_pred; bind_data_pred2; bind_data] variants in
      add_letrec_binds binding_group all_binds rest_stmts
    | Ast.SContract(_, _, _) ->
      desugar_scope_block rest_stmts binding_group
    | Ast.SCheck(l, name, body, keyword) ->
      let b loc = Ast.SBind(loc, false, Ast.SUnderscore(l), Ast.ABlank) in
      let lrb = Ast.SLetrecBind(l, b l, Ast.SCheck(l, name, body, keyword)) in
      add_letrec_binds binding_group [lrb] rest_stmts
    | _ ->
      match rest_stmts with
      | [] -> bind_wrap binding_group f
      | _ :: _ ->
        let rest_stmt = desugar_scope_block rest_stmts (LetBinds([])) in
        let rest_stmts = match rest_stmt with
          | Ast.SBlock(_, stmts) -> f :: stmts
          | _ -> [f; rest_stmt] in
        bind_wrap binding_group (Ast.SBlock(Ast.expr_loc f, rest_stmts))

class desugar_scope_visitor = object(self)
  inherit Ast.default_map_visitor

  method s_block(l, stmts) =
    desugar_scope_block (List.map self#visit_expr stmts) (LetBinds [])
end

(** Remove x = e, var x = e, and fun f(): e end
and turn them into explicit let and letrec expressions.
Do this recursively through the whole program.
Preconditions on prog:
  - well-formed
Postconditions on prog:
  - contains no SProvide in headers
  - contains no SLet, SVar, SData *)
let desugar_scope prog env =
  match prog with
  | Ast.SProgram(l, _provide_raw, provide_types_raw, imports_raw, body) ->
    let imports = List.map (fun i -> expand_import i env) imports_raw in
    let prov = match resolve_provide _provide_raw body with
      | Ast.SProvideNone(_) -> Ast.SObj(l, [])
      | Ast.SProvide(_, block) -> block
      | _ -> failwith "Should have been resolved away" in
    let provides = resolve_type_provide provide_types_raw body in
    let provt = match provides with
      | Ast.SProvideTypesNone(_) -> []
      | Ast.SProvideTypes(_, anns) -> anns
      | _ -> failwith ("Should have been resolve-typed away"
                       ^ (Sexplib.Sexp.to_string_hum (Ast.sexp_of_provide_types provides))) in
    (* TODO: Need to resolve provide-types here *)
    let with_imports = match body with
      | Ast.SBlock(l2, stmts) -> Ast.SBlock(l2, desugar_toplevel_types stmts)
      | _ -> Ast.SBlock(l, desugar_toplevel_types [body]) in
    let transform_toplevel_last l2 last =
      let app = Ast.SApp(l2, Ast.SDot(l2, AstUtils.checkers l2, "results"), []) in
      Ast.SModule(l2, last, [], [], prov, provt, app) in
    let with_provides = match with_imports with
      | Ast.SBlock(l2, stmts) ->
        let last = PyretUtils.last stmts in
        (match last with
         | Ast.STypeLetExpr(l3, binds, block2) ->
           (match block2 with
            | Ast.SBlock(b2loc, b2stmts) ->
              let inner_last = PyretUtils.last b2stmts in
              let inner_block_body = (PyretUtils.drop 1 b2stmts)
                                     @ [transform_toplevel_last l3 inner_last] in
              let inner_block = Ast.SBlock(b2loc, inner_block_body) in
              let stle = Ast.STypeLetExpr(l3, binds, inner_block) in
              let block_body = (PyretUtils.drop 1 stmts) @ [stle] in
              Ast.SBlock(l2, block_body)
            | _ -> failwith "Non-SBlock in STypeLetExpr body")
         | _ -> Ast.SBlock(l2, (PyretUtils.drop 1 stmts) @ [transform_toplevel_last l2 last]))
      | _ -> failwith "Impossible" in
    Ast.SProgram(l, Ast.SProvideNone(l), Ast.SProvideTypesNone(l), imports,
                 (new desugar_scope_visitor)#visit_expr with_provides)


let scope_env_from_env = function
  | CompileEnvironment.CompileEnvironment(Globals.Globals(values,_),_) ->
    List.fold_left (fun acc name ->
        SD.add name (ScopeBinding.GlobalBind(Ast.Srcloc.Builtin("pyret-builtin"), Ast.SGlobal(name), None)) acc)
      SD.empty (List.map fst (SD.bindings values))

let type_env_from_env = function
  | CompileEnvironment.CompileEnvironment(Globals.Globals(_,types),_) ->
    List.fold_left (fun acc name ->
        SD.add name (TypeBinding.GlobalTypeBind(
            Ast.Srcloc.Builtin("pyret-builtin"), Ast.STypeGlobal(name), None)) acc)
      SD.empty (List.map fst (SD.bindings types))

type 'a bind_pair = { atom : Ast.name; env : 'a SD.t }
type env_and_imps = { e : ScopeBinding.t SD.t; te : TypeBinding.t SD.t; imps : Ast.import list }
class resolve_names_class initial_env =
  object(self)
    inherit Ast.default_map_visitor

    val name_errors = ref []
    val bindings : ScopeBinding.t MutableStringDict.t = MutableStringDict.create 50
    val type_bindings : TypeBinding.t MutableStringDict.t = MutableStringDict.create 50
    val datatypes : Ast.expr MutableStringDict.t = MutableStringDict.create 50
    val env = scope_env_from_env initial_env
    val type_env = type_env_from_env initial_env


    method make_anon_import_for : 'a. string -> 'a SD.t -> 'a MutableStringDict.t -> (Ast.name -> 'a) -> 'a bind_pair =
        fun s env bindings b ->
          let atom = Ast.global_names s in
          MutableStringDict.add bindings (Ast.name_key atom) (b atom);
          { atom = atom; env = env }

    method make_atom_for : 'a. ('a -> Ast.loc) -> Ast.name -> bool -> 'a SD.t -> 'a MutableStringDict.t -> (Ast.loc -> Ast.name -> 'a) -> 'a bind_pair =
        fun get_loc name is_shadowing env bindings make_binding ->
          match name with
          | Ast.SName(l, s) ->
            (if SD.mem s env && not is_shadowing then
               begin
                 let old_loc = get_loc (SD.find s env) in
                 name_errors := (CompileError.ShadowId(s, l, old_loc)) :: !name_errors
               end);
            let atom = Ast.global_names s in
            let binding = make_binding l atom in
            MutableStringDict.add bindings (Ast.name_key atom) binding;
            { atom = atom; env = env }
          | Ast.SUnderscore(l) ->
            let atom = Ast.global_names "$underscore" in
            MutableStringDict.add bindings (Ast.name_key atom) (make_binding l atom);
            { atom = atom; env = env }
          | Ast.SAtom(_,_) ->
            let binding = make_binding Ast.dummy_loc name in
            (* TODO: This is probably what it should be, but that's only true if there's a bug in Pyret *)
            let env = SD.add (Ast.name_key name) binding env in
            MutableStringDict.add bindings (Ast.name_key name) binding;
            { atom = name; env = env }
          | _ -> failwith ("Unexpected atom type: " ^ (Ast.name_tosourcestring name))

    method update_type_binding_ann atom ann =
      let key = Ast.name_key atom in
      if MutableStringDict.mem type_bindings key then
        begin
          let set_to = MutableStringDict.add type_bindings key in
          match MutableStringDict.find type_bindings key with
          | TypeBinding.LetTypeBind(l, _, _) ->
            set_to @@ TypeBinding.LetTypeBind(l, atom, ann)
          | TypeBinding.ModuleTypeBind(l, _, imp, _) ->
            let ann = match ann with
              | Some(Either.Left(ann)) -> Some(ann)
              | None -> None
              | _ -> failwith "Import given to ModuleTypeBind" in
            set_to @@ TypeBinding.ModuleTypeBind(l, atom, imp, ann)
          | TypeBinding.GlobalTypeBind(l, _, _) ->
            let ann = match ann with
              | Some(Either.Left(ann)) -> Some(ann)
              | None -> None
              | _ -> failwith "Import given to GlobalTypeBind" in
            set_to @@ TypeBinding.GlobalTypeBind(l, atom, ann)
          | TypeBinding.TypeVarBind(l, _, _) ->
            let ann = match ann with
              | Some(Either.Left(ann)) -> Some(ann)
              | None -> None
              | _ -> failwith "Import given to TypeVarBind" in
            set_to @@ TypeBinding.TypeVarBind(l, atom, ann)
        end
      else
        Printf.printf "No binding for %s\n" @@ Ast.name_tosourcestring atom

    method update_binding_expr atom expr =
      match MutableStringDict.lookup bindings (Ast.name_key atom) with
      | None -> ()
      | Some(sb) ->
        let set_to = MutableStringDict.add bindings (Ast.name_key atom) in
        match sb with
        | ScopeBinding.LetrecBind(loc, _, ann, _) ->
          (* These match expressions lift the Ast.expr from the Either 'monad' *)
          let expr = match expr with
            | Some(Either.Left(e)) -> Some(e)
            | None -> None
            | Some(Either.Right(_)) -> failwith "LetrecBind cannot be bound to import" in
          set_to @@ ScopeBinding.LetrecBind(loc, atom, ann, expr)
        | ScopeBinding.LetBind(loc, _, ann, _) ->
          let expr = match expr with
            | Some(Either.Left(e)) -> Some(e)
            | None -> None
            | Some(Either.Right(_)) -> failwith "LetBind cannot be bound to import" in
          set_to @@ ScopeBinding.LetBind(loc, atom, ann, expr)
        | ScopeBinding.VarBind(loc, _, ann, _) ->
          let expr = match expr with
            | Some(Either.Left(e)) -> Some(e)
            | None -> None
            | Some(Either.Right(_)) -> failwith "VarBind cannot be bound to import" in
          set_to @@ ScopeBinding.VarBind(loc, atom, ann, expr)
        | ScopeBinding.GlobalBind(loc, _, _) ->
          let expr = match expr with
            | Some(Either.Left(e)) -> Some(e)
            | None -> None
            | Some(Either.Right(_)) -> failwith "GlobalBind cannot be bound to import" in
          set_to @@ ScopeBinding.GlobalBind(loc, atom, expr)
        | ScopeBinding.ModuleBind(loc, _, imp, _) ->
          set_to @@ ScopeBinding.ModuleBind(loc, atom, imp, expr)

    method resolve_letrec_binds binds =
      let (bind_env_and_atoms_env, bind_env_and_atoms_atoms) =
        List.fold_left (fun (env, atoms) ->
          function
          | Ast.SLetrecBind(_,Ast.SBind(loc,shadows,name,ann),_) ->
            let atom_env = self#make_atom_for (ScopeBinding.loc) name shadows env bindings
                (fun l n -> ScopeBinding.LetrecBind(l, n, self#visit_ann ann, None)) in
            (atom_env.env, atom_env.atom :: atoms)) (self#get_env(), []) binds in
      let new_visitor = {< env = bind_env_and_atoms_env >} in
      let visit_binds = List.map2 (fun b a ->
          match b with
          | Ast.SLetrecBind(l2, Ast.SBind(_,_,_,ann), expr) ->
            let new_bind = Ast.SBind(l2, false, a, new_visitor#visit_ann ann) in
            let visit_expr = new_visitor#visit_expr expr in
            self#update_binding_expr a (Some(Either.Left(visit_expr)));
            Ast.SLetrecBind(l2, new_bind, visit_expr))
          binds (List.rev bind_env_and_atoms_atoms) in
      (visit_binds, new_visitor)

    method handle_id env id =
      match id with
      | Ast.SName(l2, s) ->
        if SD.mem s env then
          begin
            match SD.find s env with
            | ScopeBinding.LetBind(_, atom, _, _)
            | ScopeBinding.LetrecBind(_, atom, _, _)
            | ScopeBinding.VarBind(_, atom, _, _)
            | ScopeBinding.GlobalBind(_, atom, _) -> atom
            | ScopeBinding.ModuleBind(_, _, _, _) -> failwith "Can't have a module-bound letrec or var id"
          end
        else
          Ast.global_names s
      | Ast.SAtom(_,_)
      | Ast.SUnderscore(_) -> id
      | _ -> failwith "Wasn't expecting a non-s-name in resolve-names id"

    method handle_ann l type_env id =
      match id with
      | Ast.SName(_, s) ->
        if SD.mem s type_env then
          begin
            match SD.find s type_env with
            | TypeBinding.GlobalTypeBind(_, name, _)
            | TypeBinding.ModuleTypeBind(_, name, _, _)
            | TypeBinding.LetTypeBind(_, name, _) -> Ast.AName(l, name)
            | TypeBinding.TypeVarBind(_, name, _) -> Ast.ATypeVar(l, name)
          end
        else Ast.AName(l, Ast.STypeGlobal(s))
      | _ -> Ast.AName(l, id)

    method get_env () = env

    method s_module(l, answer, _, _, provided_vals, provided_types, checks) =
      let non_globals = List.filter (fun (key,v) ->
          match v with
          | ScopeBinding.GlobalBind(_,_,_)
          | ScopeBinding.ModuleBind(_,_,_,_) -> false
          | _ -> true) @@ SD.bindings env in
      let defined_vals = List.map (fun (key,v) ->
          let id_exp = match v with
            | ScopeBinding.LetBind(_, atom, _, _) -> Ast.SId(l, atom)
            | ScopeBinding.LetrecBind(_, atom, _, _) -> Ast.SIdLetrec(l, atom, true)
            | ScopeBinding.VarBind(_, atom, _, _) -> Ast.SIdVar(l, atom)
            | ScopeBinding.ModuleBind(_, atom, _, _) -> Ast.SId(l, atom)
            | _ -> failwith "Failed to filter out global binding" in
          Ast.SDefinedValue(key, id_exp)) non_globals in
      let non_global_types = List.filter (fun (key, v) ->
          match v with
          | TypeBinding.GlobalTypeBind(_,_,_)
          | TypeBinding.ModuleTypeBind(_,_,_,_) -> false
          | _ -> true) @@ SD.bindings type_env in
      let defined_types = List.map (fun (key, v) ->
          let typ = match v with
            | TypeBinding.LetTypeBind(_, atom, _)
            | TypeBinding.TypeVarBind(_, atom, _) -> Ast.AName(l, atom)
            | _ -> failwith "Failed to filter out global type binding" in
          Ast.SDefinedType(key, typ)) non_global_types in
      Ast.SModule(l, self#visit_expr answer, defined_vals, defined_types,
                  self#visit_expr provided_vals, List.map self#visit_a_field provided_types,
                  self#visit_expr checks)

    method s_program(l, _provide, _provide_types, imports, body) =
      let imports_and_env = List.fold_left (fun acc i ->
          match i with
          | Ast.SImportComplete(l2, vnames, tnames, file, name_vals, name_types) ->
            let atom_env =
              match name_vals with
              | Ast.SUnderscore(l) ->
                self#make_anon_import_for "$import" acc.e bindings
                  (fun x -> ScopeBinding.LetBind(l, x, Ast.AAny, None))
              | _ ->
                self#make_atom_for ScopeBinding.loc name_vals false acc.e bindings
                  (fun l x -> ScopeBinding.LetBind(l, x, Ast.AAny, None)) in
            let atom_env_t =
              match name_types with
              | Ast.SUnderscore(l) ->
                self#make_anon_import_for "$import" acc.te type_bindings
                  (fun x -> TypeBinding.LetTypeBind(l, x, None))
              | _ -> self#make_atom_for TypeBinding.loc name_types false acc.te type_bindings
                       (fun l n -> TypeBinding.LetTypeBind(l, n, None)) in
            let with_vals_e, with_vals_vn = List.fold_left (fun (e,vn) v ->
                let v_atom_env = self#make_atom_for ScopeBinding.loc v false e bindings
                    (fun l n -> ScopeBinding.ModuleBind(l, n, file, None)) in
                (v_atom_env.env, (v_atom_env.atom) :: vn)) (atom_env.env, []) vnames in
            let with_types_et, with_types_tn = List.fold_left (fun (et, tn) t ->
                let t_atom_env = self#make_atom_for TypeBinding.loc t false et type_bindings
                    (fun l n -> TypeBinding.ModuleTypeBind(l, n, file, None)) in
                (t_atom_env.env, t_atom_env.atom :: tn)) (atom_env_t.env, []) tnames in
            let new_header =
              Ast.SImportComplete(l2, with_vals_vn, with_types_tn, file, atom_env.atom, atom_env_t.atom) in
            self#update_binding_expr atom_env.atom (Some(Either.Right(new_header)));
            self#update_type_binding_ann atom_env_t.atom (Some(Either.Right new_header));
            { e = with_vals_e; te = with_types_et; imps = new_header :: acc.imps }
          | _ -> failwith "Should only have SImportComplete when checking scope"
        ) { e = env; te = type_env; imps = []} imports in
      let visit_body = {< env = imports_and_env.e; type_env = imports_and_env.te >}#visit_expr body in
      let vals = ref [] in
      let typs = ref [] in
      let visit_body_visitor = object(self)
        inherit Ast.default_iter_visitor
        method s_module(_,_,dv,dt,_,_,_) =
          vals := dv;
          typs := dt;
          true
      end in
      let _ = visit_body_visitor#visit_expr visit_body in
      let data_defs = List.map (fun (key, v) ->
          match v with
          | Ast.SDataExpr(loc,name,namet,_,_,_,_,_) ->
            Ast.PData(loc, namet, None)
          | _ -> failwith "Invalid input to data_defs")
        @@ MutableStringDict.bindings datatypes in
      let non_module_vals = List.filter (function
          | Ast.SDefinedValue(id,expr) ->
            let id = match expr with
              | Ast.SId(_, name)
              | Ast.SIdVar(_, name)
              | Ast.SIdLetrec(_, name, _) -> name
              | _ -> failwith ("Invalid expr: " ^ (Sexplib.Sexp.to_string_hum @@ Ast.sexp_of_expr expr)) in
            match MutableStringDict.find bindings (Ast.name_key id) with
            | ScopeBinding.ModuleBind(_,_,_,Some(Either.Right(Ast.SImportComplete(_,_,_,_,_,_)))) -> false
            | _ -> true) !vals in
      let val_defs = List.map (function
          | Ast.SDefinedValue(id, expr) ->
            let id = match expr with
              | Ast.SId(_, name)
              | Ast.SIdVar(_, name)
              | Ast.SIdLetrec(_, name, _) -> name
              | _ -> failwith ("Invalid expr: " ^ (Sexplib.Sexp.to_string_hum @@ Ast.sexp_of_expr expr)) in
            let name_key = Ast.name_key id in
            let open ScopeBinding in
            match MutableStringDict.find bindings name_key with
            | LetrecBind(loc, atom, ann, _)
            | LetBind(loc, atom, ann, _)
            | VarBind(loc, atom, ann, _) ->
              Ast.PValue(loc, atom, ann)
            | ModuleBind(loc, atom, _, _) ->
              Ast.PValue(loc, atom, Ast.AAny)
            | _ -> failwith ("Shouldn't happen, defined-value is global")) non_module_vals in
      let non_module_defs = List.filter (function
          | Ast.SDefinedType(_, ann) ->
            let name = match ann with
              | Ast.AName(_,name)
              | Ast.ATypeVar(_, name) -> name
              | _ -> failwith ("Invalid ann: " ^ (Sexplib.Sexp.to_string_hum (Ast.sexp_of_ann ann))) in
            let t_binding = MutableStringDict.find type_bindings (Ast.name_key name) in
            match t_binding with
            | TypeBinding.LetTypeBind(loc, atom, ann) ->
              (match ann with
               | Some(Either.Right(Ast.SImportComplete(_,_,_,_,_,_))) -> false
               | _ -> true)
            | _ -> true) !typs in
      let alias_defs = List.map (function
          | Ast.SDefinedType(name, ann) ->
            let name = match ann with
              | Ast.AName(_,name)
              | Ast.ATypeVar(_, name) -> name
              | _ -> failwith ("Invalid ann: " ^ (Sexplib.Sexp.to_string_hum (Ast.sexp_of_ann ann))) in
            let t_binding = MutableStringDict.find type_bindings (Ast.name_key name) in
            match t_binding with
            | TypeBinding.LetTypeBind(loc, atom, ann) ->
              Ast.PAlias(loc, atom, atom, None)
            | _ -> failwith "Shouldn't happen, defined-alias is not let-bound type.") non_module_defs in
      let one_true_provide = Ast.SProvideComplete(l, val_defs, alias_defs, data_defs) in
      Ast.SProgram(l, one_true_provide, _provide_types, List.rev imports_and_env.imps, visit_body)



    method s_bind(l, shadows, id, ann) =
      match id with
      | Ast.SUnderscore(_) -> Ast.SBind(l, shadows, id, ann)
      | _ ->
        failwith ("Should not reach non-underscore bindigns in resolve-names "
                  ^ (Ast.str_of_loc l) ^ " " ^ (Ast.name_tosourcestring id))

    (* Annotation Type Visitors *)
    method a_blank () = Ast.ABlank
    method a_any () = Ast.AAny
    method a_name(l, id) = self#handle_ann l type_env id
    method a_arrow(l, args, ret, parens) =
      Ast.AArrow(l, List.map self#visit_ann args, self#visit_ann ret, parens)
    method a_method(l, args, ret) =
      Ast.AMethod(l, List.map self#visit_ann args, self#visit_ann ret)
    method a_record(l, fields) =
      Ast.ARecord(l, List.map self#visit_a_field fields)
    method a_app(l, ann, args) = Ast.AApp(l, self#visit_ann ann, List.map self#visit_ann args)
    method a_pred(l, ann, exp) = Ast.APred(l, self#visit_ann ann, self#visit_expr exp)
    method a_dot(l, obj, field) =
      let obj_ann = self#handle_ann l type_env obj in
      match obj_ann with
      | Ast.AName(_, name) -> Ast.ADot(l, name, field)
      | _ ->
        name_errors := (CompileError.UnexpectedTypeVar(l, obj)) :: !name_errors;
        Ast.ABlank
    method a_field(l, name, ann) = Ast.AField(l, name, self#visit_ann ann)
end
