%%%-----------------------------------------------------------------------------
%%%
%%% Copyright (c) 2018-2019 Klarna Bank AB (publ).
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%-----------------------------------------------------------------------------

%% @doc This module is a http client of confluent.io schema registry.
%% It implements two data serializers
%%   1: Confluent.io schema tagging convention.
%%      see http://docs.confluent.io/
%%          current/schema-registry/docs/serializer-formatter.html
%%      That is: Encoded objects are tagged with 5-byte schema ID.
%%               The first byte is currently always 0 (work as version)
%%               And the following 4 bytes is the schema registration ID
%%               assigned by schema-registry
%%   2: Schema name (subject) + fingerprint based registration.
%%      In this case, the payload is encoded avro (binary or JSON) object
%%      itself (i.e. no tagging on the playload) schema name and fingerprint
%%      are provided by callers.
%%      Caller provided schema name is included in registration subject to
%%      lower the risk of schema fingerprint collision, since the fingerprint
%%      is essentially a 64-bit hash.
%%      Caller is also given liberty to assign or generate fingerprint for
%%      the schema before registeration. see `register_schema_with_fp/3'
%%
%%  Registration ID is more 'compact' in payload (only 5 bytes overhead).
%%  Fingerprint is more static (can be obtained at compile time) comparing
%%  to the assigned registration ID which is assigned at runtime, and
%%  most likely different across registries.

-module(avlizer_confluent).
-behaviour(gen_server).

-export([ code_change/3
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , init/1
        , terminate/2
        ]).

-export([ start_link/0
        , start_link/2
        , stop/0
        , stop/1
        ]).

-export([ decode/1
        , decode/2
        , decode/3
        , decode/4
        , encode/2
        , encode/3
        , make_decoder/1
        , make_decoder/2
        , make_decoder/3
        , make_decoder2/3
        , make_decoder2/4
        , make_encoder/1
        , make_encoder/2
        , make_encoder2/3
        , get_decoder/1
        , get_decoder/2
        , get_decoder/3
        , get_encoder/1
        , get_encoder/2
        , maybe_download/1
        , maybe_download/3
        , register_schema/2
        , register_schema/3
        , register_schema_with_fp/2
        , register_schema_with_fp/3
        , register_schema_with_fp/5
        , tag_data/2
        , untag_data/1
        ]).

-export([ get_table/1
        ]).

-export_type([ regid/0
             , fp/0
             ]).

-include_lib("erlavro/include/erlavro.hrl").

%% confluent.io convention magic version
-define(VSN, 0).
-define(SERVER, ?MODULE).
-define(CACHE, ?MODULE).
-define(HTTPC_TIMEOUT, 10000).

-define(DEFAULT_CODEC_OPTIONS, [{encoding, avro_binary}]).

-define(IS_REGID(Id), is_integer(Id)).
-define(IS_NAME_FP(NF), (is_tuple(Ref) andalso size(Ref) =:= 2)).
-define(IS_REF(Ref), (?IS_REGID(Ref) orelse ?IS_NAME_FP(Ref))).
-type regid() :: non_neg_integer().
-type name() :: string() | binary().
-type fp() :: avro:crc64_fingerprint() | binary() | string().
-type ref() :: regid() | {name(), fp()}.
-type codec_options() :: avro:codec_options().

-type auth() :: {basic, _Username :: string(), _Password :: string()}.
-type init_opts() :: #{
    url => string(),
    auth => auth(),
    table_name => atom()
}.
-type state() :: #{
    table := ets:table(),
    url := string(),
    auth := auth() | nil()
}.

-define(ASSIGNED_NAME, <<"_avlizer_assigned">>).
-define(LKUP(Ref), fun(?ASSIGNED_NAME) -> ?MODULE:maybe_download(Ref) end).

%%%_* APIs =====================================================================

%% @doc Start a gen_server which owns a ets cache for schema
%% registered in schema registry.
%% Schema registry URL is configured in app env.
-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
  start_link({local, ?SERVER}, #{table_name => ?CACHE}).

-spec start_link(gen_server:server_ref() | undefined, init_opts()) -> {ok, pid()} | {error, any()}.
start_link(_ServerRef = undefined, InitOpts) ->
  gen_server:start_link(?MODULE, InitOpts, []);
start_link(ServerRef, InitOpts) ->
  gen_server:start_link(ServerRef, ?MODULE, InitOpts, []).

%% @doc Stop the gen_server, mostly used for tets.
-spec stop() -> ok.
stop() ->
  stop(?SERVER).

-spec stop(gen_server:server_ref()) -> ok.
stop(ServerRef) ->
  ok = gen_server:call(ServerRef, stop).

-spec get_table(gen_server:server_ref()) -> ets:table().
get_table(ServerRef) ->
  gen_server:call(ServerRef, get_table, infinity).

%% @doc Make an avro decoder from the given schema reference.
%% This call has an overhead of ets lookup (and maybe a `gen_server'
%% call to perform a http download) to fetch the avro schema, hence
%% the caller should keep the built decoder function and re-use it
%% for the same reference.
%% The decoder made by this API has better performance than the one
%% returned from `get_decoder/1' which has the lookup overhead included
%% in the decoder. It may not be performant when decoding a large
%% number (or a stream) of objects having the same reference.
-spec make_decoder(ref()) -> avro:simple_decoder().
make_decoder(Ref) ->
  do_make_decoder(?SERVER, ?CACHE, Ref, ?DEFAULT_CODEC_OPTIONS).

-spec make_decoder(ref(), codec_options()) -> avro:simple_decoder();
                  (name(), fp()) -> avro:simple_decoder().
make_decoder(Ref, CodecOptions) when ?IS_REF(Ref) ->
  do_make_decoder(?SERVER, ?CACHE, Ref, CodecOptions);
make_decoder(Name, Fp) ->
  do_make_decoder(?SERVER, ?CACHE, {Name, Fp}, ?DEFAULT_CODEC_OPTIONS).

-spec make_decoder(name(), fp(), codec_options()) -> avro:simple_decoder().
make_decoder(Name, Fp, CodecOptions) ->
  do_make_decoder(?SERVER, ?CACHE, {Name, Fp}, CodecOptions).

-spec do_make_decoder(gen_server:server_ref(), ets:table(), ref(), codec_options()) -> avro:simple_decoder().
do_make_decoder(ServerRef, Table, Ref, CodecOptions) ->
  Schema = maybe_download(ServerRef, Table, Ref),
  avro:make_simple_decoder(Schema, CodecOptions).

make_decoder2(ServerRef, Table, Ref) ->
  make_decoder2(ServerRef, Table, Ref, ?DEFAULT_CODEC_OPTIONS).

make_decoder2(ServerRef, Table, Ref, CodecOptions) ->
  do_make_decoder(ServerRef, Table, Ref, CodecOptions).

%% @doc Make an avro encoder from the given schema reference.
%% This call has an overhead of ets lookup (and maybe a `gen_server'
%% call to perform a http download) to fetch the avro schema, hence
%% the caller should keep the built decoder function and re-use it
%% for the same reference.
%% The encoder made by this API has better performance than the one
%% returned from `get_encoder/1' which has the lookup overhead included
%% in the encoder. It may not be performant when encoding a large
%% number of objects in a tight loop.
-spec make_encoder(ref()) -> avro:simple_encoder().
make_encoder(Ref) ->
  make_encoder2(?SERVER, ?CACHE, Ref).

-spec make_encoder2(gen_server:server_ref(), ets:table(), ref()) -> avro:simple_encoder().
make_encoder2(ServerRef, Table, Ref) ->
  Schema = maybe_download(ServerRef, Table, Ref),
  avro:make_simple_encoder(Schema, []).

-spec make_encoder(name(), fp()) -> avro:simple_encoder().
make_encoder(Name, Fp) -> make_encoder2(?SERVER, ?CACHE, {Name, Fp}).

%% @doc Get avro decoder by lookup already decoded avro schema
%% from cache, and make a decoder from it.
%% Schema lookup is performed inside the decoder function for each call,
%% use `make_encoder/1' for better performance.
-spec get_decoder(ref()) -> avro:simple_decoder().
get_decoder(Ref) ->
  do_get_decoder(Ref, ?DEFAULT_CODEC_OPTIONS).

-spec get_decoder(ref(), codec_options()) -> avro:simple_decoder();
                 (name(), fp()) -> avro:simple_decoder().
get_decoder(Ref, CodecOptions) when ?IS_REF(Ref) ->
  do_get_decoder(Ref, CodecOptions);
get_decoder(Name, Fp) -> get_decoder({Name, Fp}).

-spec get_decoder(name(), fp(), codec_options()) -> avro:simple_decoder().
get_decoder(Name, Fp, CodecOptions) -> do_get_decoder({Name, Fp}, CodecOptions).

-spec do_get_decoder(ref(), codec_options()) -> avro:simple_decoder().
do_get_decoder(Ref, CodecOptions) ->
  Decoder = avro:make_decoder(?LKUP(Ref), CodecOptions),
  fun(Bin) -> Decoder(?ASSIGNED_NAME, Bin) end.

%% @doc Get avro decoder by lookup already decode avro schema
%% from cache, and make a encoder from it.
%% Schema lookup is performed inside the encoder function for each call,
%% use `make_encoder/1' for better performance.
-spec get_encoder(ref()) -> avro:simple_encoder().
get_encoder(Ref) ->
  Encoder = avro:make_encoder(?LKUP(Ref), [{encoding, avro_binary}]),
  fun(Input) -> Encoder(?ASSIGNED_NAME, Input) end.

-spec get_encoder(name(), fp()) -> avro:simple_encoder().
get_encoder(Name, Fp) -> get_encoder({Name, Fp}).

%% @doc Lookup cache for decoded schema, try to download if not found.
-spec maybe_download(ref()) -> avro:avro_type().
maybe_download(Ref) ->
  maybe_download(?SERVER, ?CACHE, Ref).

-spec maybe_download(gen_server:server_ref(), ets:table(), ref()) -> avro:avro_type().
maybe_download(Server, Table, Ref) ->
  case lookup_cache(Table, Ref) of
    false ->
      case download(Server, Ref) of
        {ok, Type} ->
          Type;
        {error, Reason} ->
          erlang:error(Reason)
      end;
    {ok, Type} ->
      Type
  end.

%% @doc Register a schema.
-spec register_schema(string(), binary() | avro:avro_type()) ->
        {ok, regid()} | {error, any()}.
register_schema(Subject, JSONOrSchema) ->
  register_schema(undefined, Subject, JSONOrSchema).

-spec register_schema(gen_server:server_ref() | undefined, string(), binary() | avro:avro_type()) ->
        {ok, regid()} | {error, any()}.
register_schema(MServerRef, Subject, JSON) when is_binary(JSON) ->
  do_register_schema(MServerRef, Subject, JSON);
register_schema(MServerRef, Subject, Schema) ->
  JSON = avro:encode_schema(Schema),
  register_schema(MServerRef, Subject, JSON).

%% @doc Register schema with name + fingerprint.
%% crc64 fingerprint is returned.
-spec register_schema_with_fp(string() | binary(),
                              binary() | avro:avro_type()) ->
        {ok, fp()} | {error, any()}.
register_schema_with_fp(Name, JSON) when is_binary(JSON) ->
  Fp = avro:crc64_fingerprint(JSON),
  case register_schema_with_fp(Name, Fp, JSON) of
    ok -> {ok, Fp};
    {error, _} = E -> E
  end;
register_schema_with_fp(Name, Schema) ->
  JSON = avro:encode_schema(Schema),
  register_schema_with_fp(Name, JSON).

%% @doc Register schema with name + fingerprint.
%% Different from register_schema_with_fp/2, caller is given the liberty to
%% generate/assign schema fingerprint.
-spec register_schema_with_fp(string() | binary(), fp(),
                              binary() | avro:avro_type()) ->
        ok | {error, any()}.
register_schema_with_fp(Name, Fp, JSONOrSchema) ->
  register_schema_with_fp(undefined, ?CACHE, Name, Fp, JSONOrSchema).

-spec register_schema_with_fp(gen_server:server_ref() | undefined, ets:table(),
                              string() | binary(), fp(),
                              binary() | avro:avro_type()) ->
        ok | {error, any()}.
register_schema_with_fp(MServerRef, Table, Name, Fp, JSON) when is_binary(JSON) ->
  Ref = unify_ref({Name, Fp}),
  DoIt = fun() ->
             case do_register_schema(MServerRef, Ref, JSON) of
               {ok, _RegId} -> ok;
               {error, Rsn} -> {error, Rsn}
             end
         end,
  try lookup_cache(Table, Ref) of
    {ok, _} -> ok; %% found in cache
    false -> DoIt()
  catch
    error : badarg ->
      %% no ets
      DoIt()
  end;
register_schema_with_fp(MServerRef, Table, Name, Fp, Schema) ->
  JSON = avro:encode_schema(Schema),
  register_schema_with_fp(MServerRef, Table, Name, Fp, JSON).

%% @doc Tag binary data with schema registration ID.
-spec tag_data(regid(), binary()) -> binary().
tag_data(SchemaId, AvroBinary) ->
  iolist_to_binary([<<?VSN:8, SchemaId:32/unsigned-integer>>, AvroBinary]).

%% @doc Get schema registeration ID and avro binary from tagged data.
-spec untag_data(binary()) -> {regid(), binary()}.
untag_data(<<?VSN:8, RegId:32/unsigned-integer, Body/binary>>) ->
  {RegId, Body}.

%% @doc Decode tagged payload
-spec decode(binary()) -> avro:out().
decode(Bin) ->
  decode(Bin, ?DEFAULT_CODEC_OPTIONS).

%% @doc Decode untagged payload or with a given schema reference.
%% Decode tagged payload with custom codec options.
-spec decode(binary(), codec_options()) -> avro:out();
            (ref(), binary()) -> avro:out();
            (avro:simple_decoder(), binary()) -> avro:out().
decode(Bin, CodecOptions) when is_binary(Bin) andalso is_list(CodecOptions) ->
  {RegId, Payload} = untag_data(Bin),
  decode(RegId, Payload, CodecOptions);
decode(Ref, Bin) when ?IS_REF(Ref) ->
  decode(Ref, Bin, ?DEFAULT_CODEC_OPTIONS);
decode(Decoder, Bin) when is_function(Decoder) ->
  Decoder(Bin).

%% @doc Decode avro binary with given schema name and fingerprint.
%% Decode avro binary with given schema reference and custom codec options.
-spec decode(name(), fp(), binary()) -> avro:out();
      (ref(), binary(), codec_options()) -> avro:out().
decode(Ref, Bin, CodecOptions) when is_list(CodecOptions) ->
  decode(get_decoder(Ref, CodecOptions), Bin);
decode(Name, Fp, Bin) ->
  decode({Name, Fp}, Bin, ?DEFAULT_CODEC_OPTIONS).

-spec decode(name(), fp(), binary(), codec_options()) -> avro:out().
decode(Name, Fp, Bin, CodecOptions) ->
  decode({Name, Fp}, Bin, CodecOptions).

%% @doc Encoded avro-binary with schema tag.
-spec encode(ref() | avro:simple_encoder(), avro:in()) -> binary().
encode(Ref, Input) when ?IS_REF(Ref) ->
  encode(get_encoder(Ref), Input);
encode(Encoder, Input) when is_function(Encoder) ->
  iolist_to_binary(Encoder(Input)).

%% @doc Encode avro-binary with schema name + fingerprint.
-spec encode(name(), fp(), avro:in()) -> binary().
encode(Name, Fp, Input) -> encode({Name, Fp}, Input).

%%%_* gen_server callbacks =====================================================

-spec init(init_opts()) -> {ok, state()}.
init(Opts) ->
  %% fail fast for bad config
  {URL, Auth} = get_init_config(Opts),
  ETSOpts0 = [protected, {read_concurrency, true}],
  ETSOpts =
    case Opts of
      #{table_name := _} ->
        [named_table | ETSOpts0];
      _ ->
        ETSOpts0
    end,
  Table = maps:get(table_name, Opts, ?CACHE),
  TId = ets:new(Table, ETSOpts),
  State = #{table => TId, url => URL, auth => Auth},
  {ok, State}.

handle_info(Info, State) ->
  error_logger:error_msg("~p: Unknown info: ~p", [?MODULE, Info]),
  {noreply, State}.

handle_cast(Cast, State) ->
  error_logger:error_msg("~p: Unknown cast: ~p", [?MODULE, Cast]),
  {noreply, State}.

handle_call(stop, _From, State) ->
  {stop, normal, ok, State};
handle_call({download, Ref}, _From, State) ->
  Result = handle_download(State, Ref),
  {reply, Result, State};
handle_call(get_table, _From, State) ->
  #{table := TId} = State,
  {reply, TId, State};
handle_call(get_registry_base_request, _From, State) ->
  Reply = get_registry_base_request_from_state(State),
  {reply, Reply, State};
handle_call(Call, _From, State) ->
  {reply, {error, {unknown_call, Call}}, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

%%%_* Internals ================================================================

get_registry_base_request(_ServerRef = undefined) ->
  get_registry_base_request_from_env();
get_registry_base_request(ServerRef) ->
  gen_server:call(ServerRef, get_registry_base_request, infinity).

get_registry_base_request_from_state(State) ->
  #{url := URL, auth := Auth} = State,
  {URL, Auth}.

get_registry_base_request_from_env() ->
  get_config_from_env().

get_init_config(InitOpts) ->
  case InitOpts of
    #{url := URL, auth := Auth} ->
      {URL, [get_registry_auth(Auth)]};
    #{url := URL} ->
      {URL, []};
    _ ->
      get_config_from_env()
  end.

get_config_from_env() ->
  {ok, Cfg} = application:get_env(?APPLICATION, ?MODULE),
  URL = maps:get(schema_registry_url, Cfg),
  case maps:get(schema_registry_auth, Cfg, false) of
    false -> {URL, []};
    Auth -> {URL, [get_registry_auth(Auth)]}
  end.

get_registry_auth({basic, Username, Password}) ->
  {"Authorization", "Basic " ++ base64:encode_to_string(Username ++ ":" ++ unwrap_password(Password))}.

unwrap_password(X) ->
  Y = unwrap(X),
  str(Y).

unwrap(Fun) when is_function(Fun, 0) ->
  unwrap(Fun());
unwrap(X) ->
  X.

str(B) when is_binary(B) -> binary_to_list(B);
str(S) when is_list(S) -> S.

download(Server, Ref) ->
  gen_server:call(Server, {download, Ref}, infinity).

handle_download(State, Ref) ->
  #{table := Table} = State,
  %% lookup again to avoid concurrent callers re-download
  case lookup_cache(Table, Ref) of
    {ok, Schema} ->
      {ok, Schema};
    false ->
      SchemaRegistryBaseRequest = get_registry_base_request_from_state(State),
      case do_download(SchemaRegistryBaseRequest, Ref) of
        {ok, JSON} ->
          Schema = decode_and_insert_cache(State, Ref, JSON),
          {ok, Schema};
        Error ->
          Error
      end
  end.

decode_and_insert_cache(State, Ref, JSON) ->
  AvroType = avro:decode_schema(JSON),
  Lkup = avro:make_lkup_fun(AvroType),
  Schema = avro:expand_type_bloated(AvroType, Lkup),
  ok = insert_cache(State, Ref, Schema),
  Schema.

insert_cache(State, Ref, Schema) ->
  #{table := Table} = State,
  ets:insert(Table, {unify_ref(Ref), Schema}),
  ok.

lookup_cache(Table, Ref0) ->
  Ref = unify_ref(Ref0),
  case ets:lookup(Table, Ref) of
    [] -> false;
    [{Ref, Schema}] -> {ok, Schema}
  end.

unify_ref({Name, Fp}) when is_list(Name) ->
  unify_ref({iolist_to_binary(Name), Fp});
unify_ref({Name, Fp}) when is_list(Fp) ->
  unify_ref({Name, iolist_to_binary(Fp)});
unify_ref(Ref) -> Ref.

do_download({SchemaRegistryURL, SchemaRegistryHeaders}, RegId) when is_integer(RegId) ->
  URL = SchemaRegistryURL ++ "/schemas/ids/" ++ integer_to_list(RegId),
  httpc_download({URL, SchemaRegistryHeaders});
do_download({SchemaRegistryURL, SchemaRegistryHeaders}, {Name, Fp}) ->
  Subject = fp_to_subject(Name, Fp),
  %% fingerprint is unique, hence always version/1
  URL = SchemaRegistryURL ++ "/subjects/" ++ Subject ++ "/versions/1",
  httpc_download({URL, SchemaRegistryHeaders}).

httpc_download({SchemaRegistryURL, SchemaRegistryHeaders}) ->
  HttpOptions = [{timeout, ?HTTPC_TIMEOUT}, {ssl, [{verify, verify_none}]}],
  case httpc:request(get, {SchemaRegistryURL, SchemaRegistryHeaders},
                     HttpOptions, []) of
    {ok, {{_, OK, _}, _RspHeaders, RspBody}} when OK >= 200, OK < 300 ->
      #{<<"schema">> := SchemaJSON} =
        jsone:decode(iolist_to_binary(RspBody)),
      {ok, SchemaJSON};
    {ok, {{_, Other, _}, _RspHeaders, RspBody}}->
      error_logger:error_msg("~p: Failed to download schema from ~s:\n~s",
                             [?MODULE, SchemaRegistryURL, RspBody]),
      {error, {bad_http_code, Other}};
    Other ->
      error_logger:error_msg("~p: Failed to download schema from ~s:\n~p",
                             [?MODULE, SchemaRegistryURL, Other]),
      Other
  end.

%% Equivalent cURL command:
%% curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
%%      --data '{"schema": "{\"type\": \"string\"}"}' \
%%      http://localhost:8081/subjects/com.example.name/versions
-spec do_register_schema(gen_server:server_ref() | undefined, string(), binary()) ->
        {ok, regid()} | {error, any()}.
do_register_schema(MServerRef, {Name, Fp}, SchemaJSON) ->
  Subject = fp_to_subject(Name, Fp),
  do_register_schema(MServerRef, Subject, SchemaJSON);
do_register_schema(MServerRef, Subject, SchemaJSON) ->
  {SchemaRegistryURL, SchemaRegistryHeaders} = get_registry_base_request(MServerRef),
  URL = SchemaRegistryURL ++ "/subjects/" ++ Subject ++ "/versions",
  Body = make_schema_reg_req_body(SchemaJSON),
  Req = {URL, SchemaRegistryHeaders, "application/vnd.schemaregistry.v1+json", Body},
  HttpOptions = [{timeout, ?HTTPC_TIMEOUT}, {ssl, [{verify, verify_none}]}],
  Result = httpc:request(post, Req, HttpOptions, []),
  case Result of
    {ok, {{_, OK, _}, _RspHeaders, RspBody}} when OK >= 200, OK < 300 ->
      #{<<"id">> := Id} = jsone:decode(iolist_to_binary(RspBody)),
      {ok, Id};
    {ok, {{_, Other, _}, _RspHeaders, RspBody}} ->
      error_logger:error_msg("~p: Failed to register schema to ~s:\n~s",
                             [?MODULE, URL, RspBody]),
      {error, {bad_http_code, Other}};
    {error, Reason} ->
      error_logger:error_msg("~p: Failed to register schema to ~s:\n~p",
                             [?MODULE, URL, Reason]),
      {error, Reason}
  end.

%% Make schema registry POST request body.
%% which is: the schema JSON is escaped and wrapped by another JSON object.
-spec make_schema_reg_req_body(binary()) -> binary().
make_schema_reg_req_body(SchemaJSON) ->
  jsone:encode(#{<<"schema">> => SchemaJSON}).

fp_to_subject(Name, Fp) ->
  FpStr = case is_integer(Fp) of
            true -> integer_to_list(Fp);
            false -> unicode:characters_to_list(Fp)
          end,
  NameStr = case is_binary(Name) of
              true -> unicode:characters_to_list(Name);
              false -> Name
            end,
  NameStr ++ "-" ++ FpStr.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
