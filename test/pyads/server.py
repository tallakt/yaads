# pyads's test server, for test/pyads/pyads_test.exs: an ADS device on 127.0.0.1 at the port
# given, with the variables below. It says "ready" once it takes connections, and stops when its
# standard input closes, as when the test that started it ends.
import os
import socket
import struct
import sys
import threading
import time

from pyads import constants
from pyads.testserver import AdsTestServer, AdvancedHandler, PLCVariable

# An error says what it is, without a traceback, which would quote pyads's code. A request the
# server can't handle ends the thread of its connection, which then answers nothing more.
sys.excepthook = lambda kind, error, _tb: print(f"{kind.__name__}: {error}", file=sys.stderr)
threading.excepthook = lambda _args: None

VARIABLES = [
    ("MAIN.nSpeed", struct.pack("<h", 1500), constants.ADST_INT16, "INT"),
    ("MAIN.nCounter", struct.pack("<i", -5), constants.ADST_INT32, "DINT"),
    ("MAIN.nUdint", struct.pack("<I", 4000000000), constants.ADST_UINT32, "UDINT"),
    ("MAIN.bOn", b"\x01", constants.ADST_BIT, "BOOL"),
    ("MAIN.fTemp", struct.pack("<d", 21.5), constants.ADST_REAL64, "LREAL"),
    ("MAIN.fReal", struct.pack("<f", 1.5), constants.ADST_REAL32, "REAL"),
    ("MAIN.sName", b"Pump 1".ljust(81, b"\x00"), constants.ADST_STRING, "STRING(80)"),
    ("MAIN.aValues", struct.pack("<5h", 1, 2, 3, 4, 5), constants.ADST_INT16,
     "ARRAY [1..5] OF INT"),
]


def main():
    port = int(sys.argv[1])
    handler = AdvancedHandler()

    for name, value, ads_type, symbol_type in VARIABLES:
        handler.add_variable(PLCVariable(name, value, ads_type=ads_type, symbol_type=symbol_type))

    # by index group and offset as well
    handler.add_variable(
        PLCVariable(
            "GVL.nAddressed",
            struct.pack("<h", 42),
            ads_type=constants.ADST_INT16,
            symbol_type="INT",
            index_group=0x4020,
            index_offset=8,
        )
    )

    server = AdsTestServer(handler=handler, ip_address="127.0.0.1", port=port, logging=False)
    server.start()

    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            break
        except OSError:
            time.sleep(0.05)

    print("ready", flush=True)
    sys.stdin.read()
    server.stop()
    os._exit(0)


if __name__ == "__main__":
    main()
