%% smalt_wasm_pool.erl — thin adapter the ARM references call.
%% smalt_wasm_pool:gl_call maps to a stub siever in-court: there is no
%% standalone LawHandle, so the "graphlaw siever" here is a deterministic
%% sha256 classifier — it stamps each body with a sieved digest + class
%% byte. Real wasm execution slots in behind the same gl_call signature
%% when a LawHandle exists.
-module(smalt_wasm_pool).
-export([gl_call/2]).

gl_call(sieve, Body) when is_binary(Body) ->
    Digest = crypto:hash(sha256, Body),
    Class = class_of(Body),
    {ok, {sieved, Class, Digest}};
%% Op 1 (digital-twin upsert/link): same sieve classification, integer
%% op code on the wire.
gl_call(1, Body) when is_binary(Body) ->
    gl_call(sieve, Body);
%% Op 15 (analytical query): dispatches to the lakehouse mount executor.
gl_call(15, Body) ->
    case smalt_lakehouse_mount:op15(Body) of
        {ok, Result} -> {ok, Result};
        {error, Reason} -> {error, Reason}
    end;
gl_call(Op, _Body) ->
    {error, {unknown_gl_op, Op}}.

%% class 0 = plain, 1 = ANDON op-1 pull-cord (leading <<1:8>>)
class_of(<<1:8, _/binary>>) -> 1;
class_of(_) -> 0.
