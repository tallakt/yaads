# Tests against Wireshark's dissector

[Wireshark](https://www.wireshark.org) reads AMS over TCP its own way. `wireshark_test.exs` writes
the client's packets, of every command and of sum commands, both a fixed set and thousands made
up by StreamData, and every packet of a session of the client with the fake PLC, both ways, as
frames of TCP in a pcap; then `rawshark` reads them, and each must read the same, field by
field, as it was meant, and none may be malformed. Wireshark is only run; nothing of it is read
or included.

They need `rawshark`, which comes with Wireshark (on Debian and Ubuntu, in `wireshark-common`;
`tshark` isn't needed), and run only when asked:

```
mix test --only wireshark
```

`RAWSHARK=/path/to/rawshark` runs another; `FUZZ_RUNS` makes more packets, as for the fuzz tests.

What Wireshark 4.2 reads, and so what's tested, has limits, which the test lists at its top:
not UDP port 48899, so not discovery; of a notification, only how many stamps it has; and one
packet to a TCP segment.
