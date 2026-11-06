%% S-5 (v26.11.4 ZP-19 soak): minimal real loader for the cgap AOQ slab NIF.
%% The dylib's ErlNifEntry.name is `cgap_beam` (module-name law, witnessed
%% court flip — see lib/smalt/aoq/quic/nif.ex); OTP requires the binding
%% module to be named `cgap_beam` and to define one Erlang function per
%% ErlNifFunc entry (bad_lib "Function not found" otherwise), so this
%% bench-local copy declares the full dylib surface as nif_error stubs. It
%% is path-shadowed ahead of smalt's compiled :cgap_beam for the soak
%% process only. Staged dylib: priv/aoq/aq_beam_nif (build artifact from
%% scripts/build_aoq_nif.sh). Resolution: SMALT_ROOT env, else cwd-relative.
-module(cgap_beam).
-export([
         cgap_new/2,         cgap_new_fast/2,         cgap_len/1,         cgap_get/2,         cgap_free/1,         cgap_version/0,
         cgap_new_i64/2,         cgap_get_i64/2,         cgap_stats/1,         cgap_envelope_new/1,         cgap_envelope_len/1,         cgap_batch_binary/1,
         pointer_of/1,         cgap_binary_data_pointer/1,         cgap_dtor_stats/0,         cgap_alloc_stats/0,         cgap_flush_to_parquet/1,         cgap_seal_to_packfile/1,
         cgap_receipt_query/1,         cgap_open/1,         cgap_scan/3,         aq_slab_open/1,         aq_slab_frame/2,         aq_slab_window/4,
         aq_slab_stamp/2,         aq_slab_lease/2,         aq_slab_sync/1,         aq_quic_open/2,         aq_quic_connect/3,         aq_quic_send/2,
         aq_quic_recv/2,         aq_quic_serve/4,         aq_quic_accept/2,         aq_quic_accept_bi/2,         aq_quic_stream_open/1,         aq_quic_stream_send/2,
         aq_quic_stream_recv/2,         aq_quic_stream_close/1
         ]).

-on_load(load_nif/0).

load_nif() ->
    Path =
        case os:getenv("SMALT_ROOT") of
            false -> "priv/aoq/aq_beam_nif";
            R -> filename:join([R, "priv", "aoq", "aq_beam_nif"])
        end,
    case erlang:load_nif(Path, 0) of
        ok -> ok;
        {error, Reason} -> erlang:error({nif_load_failed, Path, Reason})
    end.

%% Stubs: one Erlang function per ErlNifFunc entry; each is overridden by
%% the bound NIF at load. nif_error is unreachable on a successful load.
cgap_new(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
cgap_new_fast(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
cgap_len(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_get(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
cgap_free(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_version() -> erlang:nif_error(nif_not_loaded).
cgap_new_i64(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
cgap_get_i64(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
cgap_stats(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_envelope_new(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_envelope_len(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_batch_binary(_A1) -> erlang:nif_error(nif_not_loaded).
pointer_of(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_binary_data_pointer(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_dtor_stats() -> erlang:nif_error(nif_not_loaded).
cgap_alloc_stats() -> erlang:nif_error(nif_not_loaded).
cgap_flush_to_parquet(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_seal_to_packfile(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_receipt_query(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_open(_A1) -> erlang:nif_error(nif_not_loaded).
cgap_scan(_A1, _A2, _A3) -> erlang:nif_error(nif_not_loaded).
aq_slab_open(_A1) -> erlang:nif_error(nif_not_loaded).
aq_slab_frame(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_slab_window(_A1, _A2, _A3, _A4) -> erlang:nif_error(nif_not_loaded).
aq_slab_stamp(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_slab_lease(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_slab_sync(_A1) -> erlang:nif_error(nif_not_loaded).
aq_quic_open(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_quic_connect(_A1, _A2, _A3) -> erlang:nif_error(nif_not_loaded).
aq_quic_send(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_quic_recv(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_quic_serve(_A1, _A2, _A3, _A4) -> erlang:nif_error(nif_not_loaded).
aq_quic_accept(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_quic_accept_bi(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_quic_stream_open(_A1) -> erlang:nif_error(nif_not_loaded).
aq_quic_stream_send(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_quic_stream_recv(_A1, _A2) -> erlang:nif_error(nif_not_loaded).
aq_quic_stream_close(_A1) -> erlang:nif_error(nif_not_loaded).
%% end of generated stubs
