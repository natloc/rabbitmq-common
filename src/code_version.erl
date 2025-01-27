%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%
-module(code_version).

-export([update/1]).

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

%%----------------------------------------------------------------------------
%% @doc Reads the abstract code of the given `Module`, modifies it to adapt to
%% the current Erlang version, compiles and loads the result.
%% This function finds the current Erlang version and then selects the function
%% call for that version, removing all other versions declared in the original
%% beam file. `code_version:update/1` is triggered by the module itself the
%% first time an affected function is called.
%%
%% The purpose of this functionality is to support the new time API introduced
%% in ERTS 7.0, while providing compatibility with previous versions.
%%
%% `Module` must contain an attribute `erlang_version_support` containing a list of
%% tuples:
%%
%% {ErlangVersion, [{OriginalFuntion, Arity, PreErlangVersionFunction,
%%                   PostErlangVersionFunction}]}
%%
%% All these new functions may be exported, and implemented as follows:
%%
%% OriginalFunction() ->
%%    code_version:update(?MODULE),
%%    ?MODULE:OriginalFunction().
%%
%% PostErlangVersionFunction() ->
%%    %% implementation using new time API
%%    ..
%%
%% PreErlangVersionFunction() ->
%%    %% implementation using fallback solution
%%    ..
%%
%% See `time_compat.erl` for an example.
%%
%% end
%%----------------------------------------------------------------------------
-spec update(atom()) -> ok | no_return().
update(Module) ->
    AbsCode = get_abs_code(Module),
    Forms = replace_forms(Module, get_otp_version(), AbsCode),
    Code = compile_forms(Forms),
    load_code(Module, Code).

%%----------------------------------------------------------------------------
%% Internal functions
%%----------------------------------------------------------------------------
load_code(Module, Code) ->
    unload(Module),
    case code:load_binary(Module, "loaded by rabbit_common", Code) of
        {module, _} ->
            ok;
        {error, Reason} ->
            throw({cannot_load, Module, Reason})
    end.

unload(Module) ->
    code:soft_purge(Module),
    code:delete(Module).

compile_forms(Forms) ->
    case compile:forms(Forms, [debug_info]) of
        {ok, _ModName, Code} ->
            Code;
        {ok, _ModName, Code, _Warnings} ->
            Code;
        Error ->
            throw({cannot_compile_forms, Error})
    end.

get_abs_code(Module) ->
    get_forms(get_object_code(Module)).

get_object_code(Module) ->
    case code:get_object_code(Module) of
        {_Mod, Code, _File} ->
            Code;
        error ->
            throw({not_found, Module})
    end.

get_forms(Code) ->
    case beam_lib:chunks(Code, [abstract_code]) of
        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            Forms;
        {ok, {Module, [{abstract_code, no_abstract_code}]}} ->
            throw({no_abstract_code, Module});
        {error, beam_lib, Reason} ->
            throw({no_abstract_code, Reason})
    end.

get_otp_version() ->
    Version = erlang:system_info(otp_release),
    case re:run(Version, "^[0-9][0-9]", [{capture, first, list}]) of
        {match, [V]} ->
            list_to_integer(V);
        _ ->
            %% Could be anything below R17, we are not interested
            0
    end.

get_original_pairs(VersionSupport) ->
    [{Orig, Arity} || {Orig, Arity, _Pre, _Post} <- VersionSupport].

get_delete_pairs(true, VersionSupport) ->
    [{Pre, Arity} || {_Orig, Arity, Pre, _Post} <- VersionSupport];
get_delete_pairs(false, VersionSupport) ->
    [{Post, Arity} || {_Orig, Arity, _Pre, Post} <- VersionSupport].

get_rename_pairs(true, VersionSupport) ->
    [{Post, Arity} || {_Orig, Arity, _Pre, Post} <- VersionSupport];
get_rename_pairs(false, VersionSupport) ->
    [{Pre, Arity} || {_Orig, Arity, Pre, _Post} <- VersionSupport].

%% Pairs of {Renamed, OriginalName} functions
get_name_pairs(true, VersionSupport) ->
    [{{Post, Arity}, Orig} || {Orig, Arity, _Pre, Post} <- VersionSupport];
get_name_pairs(false, VersionSupport) ->
    [{{Pre, Arity}, Orig} || {Orig, Arity, Pre, _Post} <- VersionSupport].

delete_abstract_functions(ToDelete) ->
    fun(Tree, Function) ->
            case lists:member(Function, ToDelete) of
                true ->
                    erl_syntax:comment(["Deleted unused function"]);
                false ->
                    Tree
            end
    end.

rename_abstract_functions(ToRename, ToName) ->
    fun(Tree, Function) ->
            case lists:member(Function, ToRename) of
                true ->
                    FunctionName = proplists:get_value(Function, ToName),
                    erl_syntax:function(
                      erl_syntax:atom(FunctionName),
                      erl_syntax:function_clauses(Tree));
                false ->
                    Tree
            end
    end.

replace_forms(Module, ErlangVersion, AbsCode) ->
    %% Obtain attribute containing the list of functions that must be updated
    Attr = Module:module_info(attributes),
    VersionSupport = proplists:get_value(erlang_version_support, Attr),
    {Pre, Post} = lists:splitwith(fun({Version, _Pairs}) ->
                                          Version > ErlangVersion
                                  end, VersionSupport),
    %% Replace functions in two passes: replace for Erlang versions > current
    %% first, Erlang versions =< current afterwards.
    replace_version_forms(
      true, replace_version_forms(false, AbsCode, get_version_functions(Pre)),
      get_version_functions(Post)).

get_version_functions(List) ->
    lists:append([Pairs || {_Version, Pairs} <- List]).

replace_version_forms(IsPost, AbsCode, VersionSupport) ->
    %% Get pairs of {Function, Arity} for the triggering functions, which
    %% are also the final function names.
    Original = get_original_pairs(VersionSupport),
    %% Get pairs of {Function, Arity} for the unused version
    ToDelete = get_delete_pairs(IsPost, VersionSupport),
    %% Delete original functions (those that trigger the code update) and
    %% the unused version ones
    DeleteFun = delete_abstract_functions(ToDelete ++ Original),
    AbsCode0 = replace_function_forms(AbsCode, DeleteFun),
    %% Get pairs of {Function, Arity} for the current version which must be
    %% renamed
    ToRename = get_rename_pairs(IsPost, VersionSupport),
    %% Get paris of {Renamed, OriginalName} functions
    ToName = get_name_pairs(IsPost, VersionSupport),
    %% Rename versioned functions with their final name
    RenameFun = rename_abstract_functions(ToRename, ToName),
    %% Remove exports of all versioned functions
    remove_exports(replace_function_forms(AbsCode0, RenameFun),
                   ToDelete ++ ToRename).

replace_function_forms(AbsCode, Fun) ->
    ReplaceFunction =
        fun(Tree) ->
                Function = erl_syntax_lib:analyze_function(Tree),
                Fun(Tree, Function)
        end,
    Filter = fun(Tree) ->
                     case erl_syntax:type(Tree) of
                         function -> ReplaceFunction(Tree);
                         _Other -> Tree
                     end
             end,
    fold_syntax_tree(Filter, AbsCode).

filter_export_pairs(Info, ToDelete) ->
    lists:filter(fun(Pair) ->
                         not lists:member(Pair, ToDelete)
                 end, Info).

remove_exports(AbsCode, ToDelete) ->
    RemoveExports =
        fun(Tree) ->
                case erl_syntax_lib:analyze_attribute(Tree) of
                    {export, Info} ->
                        Remaining = filter_export_pairs(Info, ToDelete),
                        rebuild_export(Remaining);
                    _Other -> Tree
                end
        end,
    Filter = fun(Tree) ->
                     case erl_syntax:type(Tree) of
                         attribute -> RemoveExports(Tree);
                         _Other -> Tree
                     end
             end,
    fold_syntax_tree(Filter, AbsCode).

rebuild_export(Args) ->
    erl_syntax:attribute(
      erl_syntax:atom(export),
      [erl_syntax:list(
         [erl_syntax:arity_qualifier(erl_syntax:atom(N),
                                     erl_syntax:integer(A))
          || {N, A} <- Args])]).

fold_syntax_tree(Filter, Forms) ->
    Tree = erl_syntax:form_list(Forms),
    NewTree = erl_syntax_lib:map(Filter, Tree),
    erl_syntax:revert_forms(NewTree).
