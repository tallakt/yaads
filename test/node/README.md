# Tests against jisotalo's Node packages

Two of [jisotalo](https://github.com/jisotalo)'s Node.js packages for ADS, both MIT licensed, used
as they are on the network, by what they send; nothing of them is read or included:

- [ads-client](https://github.com/jisotalo/ads-client) 2.2.0, a client used with real PLCs, reads
  the fake PLC of `test/support` by its descriptions of its variables and types, decoded its own
  way, writes by them, and takes its notifications (`client_test.exs`, by `client.js`). A
  misreading of the format that the fake and yaads share would show here.
- [ads-server](https://github.com/jisotalo/ads-server) 1.1.2 plays a device for `ADS.Client`, its
  packets and notifications built by ads-server (`server_test.exs`, by `server.js`).

They need Node.js, the packages installed here at the versions of `package-lock.json`, and OTP 27
or newer, for its `:json`; and they run only when asked:

```
(cd test/node && npm ci)
mix test --only node
```

`NODE=/path/to/node` runs another Node.

Where a package differs from a PLC or a PLC's client, the tests go around it, and say so at
their top.
