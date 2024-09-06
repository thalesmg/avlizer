# avlizer - Avro Serializer for Erlang

`avlizer` is built on top of [erlavro](https://github.com/klarna/erlavro)
The design goal of this application is to provide APIs for users to serialize
or deserialize data with minimal overhead of schema management.

# Integrations

## Confluent Schema Registry

[Confluent schema registry](https://github.com/confluentinc/schema-registry)
provides REST APIs for schema registration and lookups.

### Config

Start the registry process:

```erlang
%% Use `undefined` as the server ref to spawn an anonymous process
Opts = #{url => URL}.
{ok, Pid} = avlizer_confluent:start_link(undefined = _ServerRef, Opts).
%% Alternatively, provide a server ref to register the process
ServerRef = {via, gproc, {n, l, my_registry}}.
{ok, Pid} = avlizer_confluent:start_link(ServerRef, Opts).
```

Register a schema:

```erlang
%% Get the cache table first; Pid the the server pid above
Table = avlizer_confluent:get_table(Pid).
{ok, SchemaId} = avlizer_confluent:register_schema(Pid, Subject, Schema).
```

Encode:

```erlang
Encoder = avlizer_confluent:make_encoder2(Server, Table, SchemaId).
Encoded = avlizer_confluent:encode(Encoder, Data).
Tagged = avlizer_confluent:tag_data(SchemaId, Encoded).
```

Decode:

```erlang
{Id, Encoded} = avlizer_confluent:untag_data(Encoded).
Decoder = avlizer_confluent:make_decoder2(Server, Table, SchemaId, [{encoding, avro_binary}]).
Decoded = avlizer_confluent:decode(Decoder, Encoded).
```

### Legacy Config (singleton process)

This is only for who wants to run a single `avlizer_confluent` process that requires only a single schema regitry URL for the whole application.

Make sure schema registry URL is present in `sys.config` as below

```
{avlizer, [{avlizer_confluent, #{schema_registry_url => URL}}]}
```

Or set os env variable:

`AVLIZER_CONFLUENT_SCHEMAREGISTRY_URL`

### Authentication support
avlizer currently supports `Basic` authentication mechanism, to use it make sure `schema_registry_auth` tuple `{Mechanism, File}`, is present in `sys.config`, where File is the path to a text file which contains two lines, first line for username and second line for password

```
{avlizer, [{avlizer_confluent, #{
    schema_registry_url => URL,
    schema_registry_auth => {basic, File}}
}]}
```

Or set authorization env variables:

`AVLIZER_CONFLUENT_SCHEMAREGISTRY_AUTH_MECHANISM`

`AVLIZER_CONFLUENT_SCHEMAREGISTRY_AUTH_USERNAME`

`AVLIZER_CONFLUENT_SCHEMAREGISTRY_AUTH_PASSWORD`
