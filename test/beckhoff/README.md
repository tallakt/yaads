# Tests against Beckhoff's own libraries

`beckhoff_test.exs` runs the client against Beckhoff's ADS libraries for .NET, and Beckhoff's
client against the fake PLC in `test/support`, and only when asked:

    mix test --only beckhoff

It needs Docker, on Linux, as the second runs on the host's network. Nothing of .NET is needed on
the machine: `peer/` is built in Microsoft's .NET SDK image, `mcr.microsoft.com/dotnet/sdk:8.0.425`,
which the first run pulls (about 900 MB), with the NuGet packages it restores in the volume
`yaads-beckhoff-nuget` and what it builds in `yaads-beckhoff-build`. After that, a run takes
seconds. `docker volume rm yaads-beckhoff-nuget yaads-beckhoff-build` lets go of both.

## What runs

The packages, all version 7.0.389 and under the MIT License, are used by their documented API
only: their READMEs and API documentation, and Beckhoff's Information System.

| Package | For |
|---|---|
| `Beckhoff.TwinCAT.Ads.TcpRouter` | an AMS router, on TCP 48898 |
| `Beckhoff.TwinCAT.Ads.SymbolicServer` | a device on AMS port 851 with variables, their symbols and data types, handles, sum commands and notifications |
| `Beckhoff.TwinCAT.Ads.SystemServer` | the system service, on port 10000, which also answers UDP 48899 and adds routes there for Administrator and the password `1` |
| `Beckhoff.TwinCAT.Ads` | Beckhoff's client, which uploads the fake PLC's descriptions and reads and writes its values by them |

Each test has a server of its own. `BECKHOFF_LOG=1` has the libraries log all they do to standard
error.

Where the libraries differ from a PLC, the tests go around it, as `beckhoff_test.exs` says.
