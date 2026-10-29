// ads-server's StandAloneServer, for test/node/server_test.exs: an ADS device on 127.0.0.1 at the
// TCP port given, with the NetId 10.11.12.13.1.1 and these on AMS port 851:
//
//   * its device info and state, which write control sets
//   * 64 bytes at index group 0x4020, read and written by offset; a read-write of 0x4021 answers
//     its data backwards; sum commands, and every other index group, are refused
//   * notifications of 0x4020, each sent by ads-server: the value at once, then when written,
//     or every cycle
//
// It says "ready" once it takes connections, and stops when its standard input closes.
const { StandAloneServer } = require("ads-server");

const fail = (error) => {
  console.error(`${error.name}: ${error.message}`);
  process.exit(1);
};

process.on("uncaughtException", fail);
process.on("unhandledRejection", fail);

const server = new StandAloneServer({
  localAmsNetId: "10.11.12.13.1.1",
  listeningAddress: "127.0.0.1",
  listeningTcpPort: Number(process.argv[2]),
  hideConsoleWarnings: true,
});

const area = Buffer.alloc(64);
let state = { adsState: 5, deviceState: 7 };
let nextHandle = 1;
const subscribers = new Map();

// A request for another AMS port than 851 is answered "target port not found".
const on851 = (handler) => async (req, res, packet, adsPort) =>
  adsPort === 851 ? handler(req, res, packet) : res({ error: 6 });

const inArea = (offset, length) => offset + length <= area.length;

const notify = (sub) =>
  server.sendDeviceNotification(sub, area.subarray(sub.offset, sub.offset + sub.length));

server.onReadDeviceInfo(
  on851((_req, res) =>
    res({ deviceName: "ads-server", majorVersion: 1, minorVersion: 2, versionBuild: 3 }),
  ),
);

server.onReadState(on851((_req, res) => res(state)));

server.onWriteControl(
  on851((req, res) => {
    state = { adsState: req.adsState, deviceState: req.deviceState };
    return res({});
  }),
);

server.onReadReq(
  on851((req, res) => {
    if (req.indexGroup !== 0x4020) return res({ error: 0x702 });
    if (!inArea(req.indexOffset, req.readLength)) return res({ error: 0x703 });
    return res({ data: area.subarray(req.indexOffset, req.indexOffset + req.readLength) });
  }),
);

server.onWriteReq(
  on851(async (req, res) => {
    if (req.indexGroup !== 0x4020) return res({ error: 0x702 });
    if (!inArea(req.indexOffset, req.data.length)) return res({ error: 0x703 });
    const before = Buffer.from(area);
    req.data.copy(area, req.indexOffset);
    await res({});

    for (const sub of subscribers.values()) {
      const changed = !before
        .subarray(sub.offset, sub.offset + sub.length)
        .equals(area.subarray(sub.offset, sub.offset + sub.length));

      if (sub.onChange && changed) await notify(sub);
    }
  }),
);

server.onReadWriteReq(
  on851((req, res) =>
    req.indexGroup === 0x4021
      ? res({ data: Buffer.from(req.data).reverse().subarray(0, req.readLength) })
      : res({ error: 0x702 }),
  ),
);

server.onAddNotification(
  on851(async (req, res, packet) => {
    if (req.indexGroup !== 0x4020) return res({ error: 0x702 });
    if (!inArea(req.indexOffset, req.dataLength)) return res({ error: 0x703 });

    const handle = nextHandle++;
    // ads-server 1.1.2 addresses notifications to its own NetId, rather than the client's, which
    // the client passes over as not its own; so they go to the NetId the request came from.
    const sub = {
      ...req.notificationTarget,
      targetAmsNetId: packet.ams.sourceAmsNetId,
      notificationHandle: handle,
      offset: req.indexOffset,
      length: req.dataLength,
      onChange: req.transmissionMode === 4,
    };

    subscribers.set(handle, sub);
    await res({ notificationHandle: handle });
    await notify(sub);

    if (!sub.onChange) {
      sub.timer = setInterval(() => notify(sub).catch(() => {}), Math.max(req.cycleTime, 10));
    }
  }),
);

server.onDeleteNotification(
  on851((req, res) => {
    const sub = subscribers.get(req.notificationHandle);
    if (!sub) return res({ error: 0x714 });
    clearInterval(sub.timer);
    subscribers.delete(req.notificationHandle);
    return res({});
  }),
);

server.listen().then(() => {
  console.log("ready");
  process.stdin.resume();
  process.stdin.on("end", () => process.exit(0));
});
