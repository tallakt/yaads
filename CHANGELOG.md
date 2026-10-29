# Changelog

## 0.1.0

The first release: a client for ADS devices, TwinCAT PLCs above all, over TCP and over Secure ADS
(TLS, with a pre-shared key, a shared CA or self-signed certificates). It reads, writes and
subscribes to variables by name, with their types from the PLC's own descriptions, as Elixir
terms; many at once in sum commands; and any ADS command by hand. `ADS.Discovery` finds PLCs on
the network and adds and deletes routes on them, over UDP, `ADS.Client.routes/2` lists them,
and `mix ads.route` does all three from the command line. It has many requests on the way at once, reconnects
by itself, adds notifications again after a reconnect or an online change, and never logs. The
encoding of AMS packets, commands, sum commands, symbols, data types and values is public, for
those who bring their own transport.
