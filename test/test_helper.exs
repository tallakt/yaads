# The TwinCAT tests need a PLC with the program in test/twincat, and run only when asked:
#
#     TWINCAT_HOST=10.0.0.5 TWINCAT_NET_ID=5.36.69.176.1.1 mix test --only twincat
#
# The pyads tests need a Python with pyads installed, and also run only when asked:
#
#     PYADS_PYTHON=~/.venvs/pyads/bin/python mix test --only pyads
#
# test/beckhoff, test/node and test/wireshark run the client against other implementations of
# ADS, as their READMEs say, and also only when asked: --only beckhoff, node or wireshark.
#
# The real-time test times each request on a network that goes wrong, which a machine that's slow
# or busy can fail while the client isn't wrong, and runs when it is asked for:
# mix test --only realtime.
#
# FUZZ_RUNS=2000 runs each property that many times, rather than StreamData's 100.
if runs = System.get_env("FUZZ_RUNS"),
  do: Application.put_env(:stream_data, :max_runs, String.to_integer(runs))

ExUnit.start(exclude: [:realtime, :twincat, :pyads, :beckhoff, :node, :wireshark])
