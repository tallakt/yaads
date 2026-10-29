# Tests against a real PLC

`twincat_test.exs` runs against a TwinCAT 3 PLC (3.1.4020 or later) with the program in `plc/`,
and only when asked:

    TWINCAT_HOST=10.0.0.5 TWINCAT_NET_ID=5.36.69.176.1.1 mix test --only twincat

The tests write the program's variables. They don't stop the PLC or change its configuration,
unless `TWINCAT_PASSWORD` is set, which adds a route (below).

## The program

In TwinCAT XAE, make a standard PLC project, which has Tc2_System, the library `T_MaxString`
comes from. Then add, by right-clicking the project's folders:

| File | Add as | Where |
|---|---|---|
| `E_Mode.st` | DUT, enumeration | DUTs |
| `ST_Pump.st`, `ST_Flags.st`, `ST_Packed.st` | DUT, structure | DUTs |
| `U_Value.st` | DUT, union | DUTs |
| `GVL.st` | global variable list `GVL` | GVLs |
| `GVL_Long.st` | global variable list `GVL_Long`, from 3.1.4026 on only | GVLs |
| `MAIN.st` | the existing `MAIN`: its declaration, then its two lines of code | POUs |

Paste each file's text over what the editor starts with, without its first comment line. Build,
activate the configuration, log in, download, and start the PLC.

## A route

The PLC talks only to clients it has a route for. On the PLC's system, add a static route to the
machine that runs the tests: its address, and its AMS NetId, which is the address with `.1.1`
added unless `TWINCAT_LOCAL_NET_ID` says otherwise. TwinCAT XAE, the system tray menu, or the
target's web interface can add one, or `mix ads.route` with the password of the PLC's
Administrator:

    mix ads.route 10.0.0.5

`TWINCAT_PASSWORD` has the tests add it themselves, as a route named `yaads-test`, which stays.
The tests over UDP, in `discovery_test.exs`, need no route.

## Optional

| Variable | For |
|---|---|
| `TWINCAT_LOCAL_NET_ID` | the client's NetId, when the route has another than its address with `.1.1` |
| `TWINCAT_LONG=1` | LDATE, LDATE_AND_TIME and LTIME_OF_DAY, in `GVL_Long` |
| `TWINCAT_PSK=identity:password` | Secure ADS with a pre-shared key, set up on the PLC as Beckhoff's manual "TwinCAT 3 Secure ADS" describes |
| `TWINCAT_SEARCH=1` | a broadcast search, which finds the PLC only on this machine's network |
| `TWINCAT_PASSWORD`, `TWINCAT_USER` | adding the route `yaads-test` with the login of a user on the PLC, Administrator unless `TWINCAT_USER` says otherwise, and trying a wrong password first |
