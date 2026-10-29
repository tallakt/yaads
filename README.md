# yaads

[![CI](https://github.com/tallakt/yaads/actions/workflows/ci.yml/badge.svg)](https://github.com/tallakt/yaads/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/yaads.svg)](https://hex.pm/packages/yaads)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/yaads)
[![License](https://img.shields.io/hexpm/l/yaads.svg)](https://github.com/tallakt/yaads/blob/main/LICENSE)

*Implemented by AI under the supervision of Tallak Tveide.*

Yet another ADS: a client for Beckhoff's ADS in pure Elixir, for reading, writing and watching
the variables of TwinCAT PLCs by name, over TCP or Secure ADS, with no C in the BEAM.

It was written from Beckhoff's own documentation of ADS in the Beckhoff Information System, not
from another implementation's code, but for UDP discovery, which Beckhoff documents only in its
own open-source ADS library, and deleting routes over it, which follows Apache PLC4X. Values are Elixir terms: a structure is a map, an array a list, an
enumeration the name of its value, with the types from the PLC's own descriptions of its
variables.

**Status:** the client, over TCP and Secure ADS, with every ADS command, sum commands, handles and
notifications, and finding PLCs and adding routes over UDP; tested against a fake PLC in
`test/support` made from the same documentation, with fuzzing, a hostile router and a network
that goes wrong, and against others' ADS: Beckhoff's own libraries for .NET, pyads, jisotalo's
Node packages and Wireshark (see [Tests](#tests)). Tried against a real PLC, TwinCAT 3.1 4026,
reading only: its UDP port, its device info and state, all its symbols and data types, every
value, notifications, and Secure ADS up to the route; `test/twincat` has the tests and the PLC
program for writing and the rest. What's left is under [What's missing](#whats-missing).

## Client

```elixir
{:ok, plc} = ADS.Client.start_link(host: "10.0.0.5", net_id: "5.36.69.176.1.1")

{:ok, 1500} = ADS.Client.read(plc, "MAIN.nSpeed")
:ok = ADS.Client.write(plc, "MAIN.nSpeed", 1600)
{:ok, %{"nSpeed" => 1600, "fTemp" => 21.5, "eMode" => "eAuto"}} = ADS.Client.read(plc, "MAIN.stPump")
{:ok, [{:ok, 1600}, {:ok, true}]} = ADS.Client.read_many(plc, ["MAIN.nSpeed", "MAIN.bOn"])

{:error, :device_symbol_not_found} = ADS.Client.read(plc, "MAIN.nNone")
```

The PLC has to have a route for the client: its address, and its AMS NetId, by default the
address with `.1.1` added (`local_net_id:` gives another). `mix ads.route` adds one, as below.
TwinCAT keeps the first connection from a NetId and closes those that come after it, so clients
on one machine to the same PLC share one `ADS.Client`, or each has a NetId and a route of its own.
The client talks to the PLC runtime on AMS port 851 unless told otherwise, with `ams_port:` for
the client or `port:` for one request.

A name is looked up once: the client asks for a handle of it and for the description of its
type, and keeps both for as long as the connection lasts. `type:` gives the type instead, and
also reaches data by index group and offset:

```elixir
{:ok, 1500} = ADS.Client.read(plc, "MAIN.nSpeed", type: :int)
:ok = ADS.Client.write(plc, {0x4020, 4}, [1, 2, 3], type: {:array, :int, [{1, 3}]})
```

| PLC | Elixir |
|---|---|
| BOOL, BIT | `true`, `false` |
| SINT to ULINT, BYTE to LWORD | an integer |
| REAL, LREAL | a float, or `:nan`, `:infinity`, `:neg_infinity` |
| STRING(n), WSTRING(n) | a string; STRING in Latin-1 unless its attribute `TcEncoding` says UTF-8, WSTRING in UCS-2 |
| TIME, LTIME | an integer of ms, of ns |
| DATE, DATE_AND_TIME, TIME_OF_DAY, and their L versions | `Date`, `NaiveDateTime`, `Time` |
| ARRAY | a list, nested for each dimension |
| STRUCT, FUNCTION_BLOCK | a map of its members' names to their values |
| UNION | a map of every member; one of them when written |
| an enumeration | the name of its value, or its number if it has none |

`ADS.Type` has the details, and `ADS.Type.layout/2` lays out a structure by TwinCAT 3's rules for
one given by hand. A value that doesn't fit its type raises in the caller and is never sent.

`read_many/3` and `write_many/3` go in sum commands of up to 500, or one at a time to a device
without them. `symbols/2` and `data_types/2` upload the PLC's descriptions of all its variables
and types, and `request/3` sends any of the nine ADS commands:

```elixir
{:ok, %{name: "Plc30 App", version: {3, 1, 4026}}} = ADS.Client.read_device_info(plc)
{:ok, %{ads_state: :run}} = ADS.Client.read_state(plc)
{:ok, <<42::32-little>>} = ADS.Client.request(plc, {:read, 0x4020, 0, 4})
```

### Notifications

```elixir
{:ok, ref} = ADS.Client.subscribe(plc, ["MAIN.nSpeed", "MAIN.bOn"], cycle_time: 100)

receive do
  {ADS.Client, ^ref, {:value, "MAIN.nSpeed", speed, %DateTime{}}} -> speed
end
```

The PLC sends each value when it changes, or every cycle with `mode: :cyclic`, with its own
timestamp of it. When the connection drops, the subscriber hears `{:disconnected, reason}`, and
the values come again once it's back. After an online change, which leaves the PLC's handles
stale, the client looks names up again and adds the notifications again by itself. A
subscription ends with `unsubscribe/2`, or when the subscriber exits.

### Connections

`start_link/1` returns at once and connects in the background; a request made while it's
connecting waits for it. When the connection drops, the client reconnects by itself, after
100 ms at first and up to 5 seconds between tries; meanwhile requests fail at once with
`{:error, :closed}`, and `status/1` says why. Up to `max_pending:` requests (32 by default) are
on the way at once, each with its own invoke id, so one caller doesn't wait for another's
answers. Two requests in a row that time out with nothing at all heard from the PLC since the
first was sent mean the connection is dead, as one a reboot or a broken cable left half open,
and the client reconnects; a PLC that's only slow keeps its connection.

The client never logs, and never exits the caller: every request gets a result within its
timeout. Stopped, it asks the PLC to let go of its handles and notifications, and waits for the
PLC to close its end, a second at most, so that none are left behind.

## Finding PLCs, and adding routes

`mix ads.route` searches the network, asks which PLC and the login of a user on it, adds a route
for this machine, and connects through it:

```
$ mix ads.route
Searching for PLCs...

  1  CX-1234AB   10.0.0.5   5.36.69.176.1.1
  2  DESKTOP-B9  10.0.0.9   10.0.0.9.1.1

PLC (1-2, or an address): 1
User [Administrator]:
Password:
...
```

`mix help ads.route` has its options; `mix ads.route 10.0.0.5 --yes` asks only for the
password, and `mix ads.route 10.0.0.5 --delete` deletes the route again, by its name, as TwinCAT
does. A firewall on this machine that lets in only answers to what was sent, as ufw does,
drops the answers to a broadcast; a PLC asked by its address answers through it.

`ADS.Discovery` does the same from code, over UDP port 48899, as TwinCAT's own Broadcast Search
and Add Route do:

```elixir
{:ok, [%{address: {10, 0, 0, 5}, net_id: "5.36.69.176.1.1", version: {3, 1, 4026}} | _]} =
  ADS.Discovery.search()

# with the login of a user on the PLC: a route for this machine's address and NetId
:ok = ADS.Discovery.add_route("10.0.0.5", password: "1")
:ok = ADS.Discovery.add_route("10.0.0.5", user: "Administrator", password: "1",
  net_id: "10.0.0.7.1.1", name: "SCADA")

# and gone again
:ok = ADS.Discovery.delete_route("10.0.0.5", password: "1")
```

`add_route/2` adds a route for the NetId the client is to have, `local_net_id:` in
`start_link/1`, or by default this machine's address with `.1.1` as the client's is. The password
goes over the network unencrypted, as with TwinCAT's tools; Secure ADS adds its routes inside TLS.
Beckhoff's manuals say only that discovery uses UDP 48899; what goes in it follows Beckhoff's own
ADS library ([Beckhoff/ADS](https://github.com/Beckhoff/ADS), MIT License), and for deleting a
route, which that library doesn't do, [Apache PLC4X](https://plc4x.apache.org)'s description of
the protocol (Apache License 2.0). Beckhoff's own system service for .NET takes it, as
`test/beckhoff` checks.

## Secure ADS

From TwinCAT 3.1 build 4024 on, ADS also goes inside TLS 1.2, on port 8016:

```elixir
# a pre-shared key, as in the PLC's StaticRoutes.xml
ADS.Client.start_link(host: "10.0.0.5", secure: [psk: {"scada", "secret"}])

# certificates from a CA both sides trust
ADS.Client.start_link(host: "10.0.0.5",
  secure: [cacertfile: "ca.pem", certfile: "scada.crt", keyfile: "scada.key"])

# self-signed: the PLC's certificate known by its fingerprint, and a route added once
{cert, key} = ADS.Certificate.self_signed("scada")
ADS.Client.start_link(host: "10.0.0.5",
  secure: [fingerprint: "6E:3B:...", cert: cert, key: key, add_route: {"Administrator", "1"}])
```

The PLC's NetId comes in its answer, so `net_id:` may be left out. Beckhoff's manual, "TwinCAT
3 Secure ADS", has the setup on the PLC's side. It leaves out what goes inside the TLS
connection; that part follows [beckhoff-secure-ads](https://github.com/kevinherron/beckhoff-secure-ads)'s
description. Against TwinCAT 3.1 4026, TLS and its TlsConnectInfo have been tried as far as a
route, which none was asked for: a pre-shared key that TwinCAT doesn't know is refused, and so
is a self-signed certificate without a route. With certificates TwinCAT takes only DHE-RSA with
AES-CBC and SHA-256, which OTP leaves out of its defaults, so the client offers both after them.
`ADS.Discovery.info/2` gives the PLC's fingerprint, as its UDP port tells it; compare it with
the one TwinCAT shows before trusting it, as anyone on the network can answer over UDP.

Give a secure client a `local_net_id:` that no plain route has. A route added through Secure ADS
for the NetId of a plain route took that NetId over on TwinCAT 3.1 4026, and plain connections
from it got no answers, until the plain route was added again.

## A hostile device

The client takes what comes over its connection as untrusted, from a PLC with a bug, a router
that isn't one, or anyone on the network:

| What comes | What happens |
|---|---|
| An answer longer than `max_size:` (16 MB) says it is, or a frame too short for an AMS header | the connection is dropped and made again, as there's no telling where the next frame starts |
| A frame of another protocol, or an AMS header whose length isn't its data's | passed over |
| An answer to a request that isn't waiting, or of another command than the request's | passed over, so it can't be taken for another's answer |
| An answer that doesn't fit its request, such as a read giving more than asked | `{:error, {:invalid_response, data}}` for that request alone |
| Bytes trickled, never making a frame | they don't count as hearing from the device, so a dead connection doesn't stay open |
| Notifications for handles the client never had | it asks once for each to be deleted, up to 1000, and drops the rest |
| Requests addressed to the client | each answered as a service it doesn't support |
| Descriptions of symbols and types that don't add up | read as far as they do; a type that can't be made out is its bytes, `{:raw, size}` |
| A notification flagged as a response | taken as a notification, as the client sends none |
| UDP datagrams from elsewhere than the device asked, or that aren't its answer | passed over; and nothing the client sends is empty, which stopped older TwinCAT routers |

## What's missing

- Only a client: no ADS server, and no AMS router for other clients to connect through.
- Of UDP, only finding devices and adding and deleting routes; no ADS commands over UDP.
- No calling methods of function blocks, RPC, though their descriptions are read.
- Against a real PLC, only reading has been tried, and Secure ADS only as far as a route.

## Tests

The fake PLC in `test/support` plays a TwinCAT PLC from the same documentation as the client: a
router on a TCP or TLS port, a data area with variables, their symbols and data types, handles,
sum commands and notifications. `test/support/hostile.ex` plays a router that answers as no PLC
would.

`test/ads/fuzz_test.exs` fuzzes with [StreamData](https://github.com/whatyouhide/stream_data):
every packet, request, notification, value and TlsConnectInfo must encode and decode back to
itself, a value read from any bytes must write back to the same, packets cut anywhere must come
back whole, and random and corrupted bytes go into every decoder. `test/ads/hardening_test.exs`
sends a running client garbage, of any kind. Nothing may raise. `test/ads/flaky_test.exs` puts a
network between the client and the fake PLC that splits, delays, stalls and drops connections at
random: each request must have its result in time, the right one or an error, and the client must
recover. It's tagged `:realtime`, as it's timed, and a machine that's slow or busy can fail it
while the client isn't wrong; it runs only when asked: `mix test --only realtime`.
`test/ads/leak_test.exs` has the client do random things, online changes and dropped connections
included: the PLC must hold the notifications of its subscriptions and no more, and once it stops,
no handles or notifications at all. For more runs than StreamData's hundred:

```
FUZZ_RUNS=10000 mix test test/ads/fuzz_test.exs
```

`test/twincat` has tests for a real PLC, with a PLC program to run on it; they run only when
asked, as its README says:

```
TWINCAT_HOST=10.0.0.5 TWINCAT_NET_ID=5.36.69.176.1.1 mix test --only twincat
```

`test/pyads` runs the client against another's idea of an ADS device,
[pyads](https://github.com/stlehmann/pyads)'s test server, used only as a device on the network
is, by what it sends. Where it differs from a PLC, the tests go around it, as they say. They
too run only when asked:

```
python3 -m venv ~/.venvs/pyads && ~/.venvs/pyads/bin/pip install pyads
PYADS_PYTHON=~/.venvs/pyads/bin/python mix test --only pyads
```

`test/beckhoff` runs the client against Beckhoff's own ADS libraries for .NET (MIT License): its
router, a symbolic server and the system service with its UDP port; and Beckhoff's client against
the fake PLC, to check the fake's descriptions as Beckhoff reads them. `test/node` runs
[ads-client](https://github.com/jisotalo/ads-client), a client used with real PLCs, against the
fake PLC, reading every variable by the fake's descriptions, and the client against
[ads-server](https://github.com/jisotalo/ads-server), notifications included; both MIT.
`test/wireshark` has [Wireshark](https://www.wireshark.org)'s dissector, through `rawshark`, read
every packet the client makes, field by field. All are used by what they send and their
documented API only; none of their code is read or included. Each runs only when asked, as its
README says:

```
mix test --only beckhoff
(cd test/node && npm ci) && mix test --only node
mix test --only wireshark
```

CI also runs [Credo](https://github.com/rrrene/credo) and
[Dialyzer](https://github.com/jeremyjh/dialyxir), and on the newest Elixir `mix test --cover`
fails below 88% of the code covered (about 92% is).

## License

Copyright 2026 Tallak Tveide. Licensed under the Apache License, Version 2.0; see
[LICENSE](LICENSE) and [NOTICE](NOTICE).

Beckhoff and TwinCAT are registered trademarks of, and licensed by, Beckhoff Automation GmbH.
yaads is not made, endorsed or supported by Beckhoff.
