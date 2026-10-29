// ads-client, for test/node/node_test.exs: a client of the fake PLC at the TCP port given, connected
// to it directly as to a PLC without a router of its own. It prints a line of JSON for each step,
// and goes on to the next when it reads a line; it stops when its standard input closes.
//
//   1. the names of the symbols and data types it uploads, and every variable's value, by name
//   2. "written", once it has written the values below, by name
//   3. "subscribed", once it subscribes to MAIN.nCounter on change, then each value it's sent
const readline = require("node:readline");
const { Client } = require("ads-client");

// An error says what it is, in a line.
const fail = (error) => {
  console.error(`${error.name}: ${error.message}`);
  process.exit(1);
};

process.on("uncaughtException", fail);
process.on("unhandledRejection", fail);

const WRITES = {
  "MAIN.nSpeed": -1234,
  "MAIN.sName": "Tank 2",
  "MAIN.aValues": [5, 4, 3, 2, 1],
  "MAIN.stPump": { nSpeed: 9, fTemp: 0.25, bRunning: false, eMode: "eManual", sTag: "T9" },
  "MAIN.eMode": "eAuto",
  "GVL.sUtf8": "½ € ¾",
};

async function main() {
  const client = new Client({
    localAmsNetId: "127.0.0.1.1.1",
    localAdsPort: 32750,
    targetAmsNetId: "5.36.69.176.1.1",
    targetAdsPort: 851,
    routerAddress: "127.0.0.1",
    routerTcpPort: Number(process.argv[2]),
    autoReconnect: false,
    hideConsoleWarnings: true,
  });

  const lines = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]();
  const next = async () => (await lines.next()).done && (await client.disconnect(), process.exit(0));
  const print = (value) => console.log(JSON.stringify(value));

  await client.connect();

  const symbols = await client.getSymbols();
  const types = await client.getDataTypes();
  const values = {};

  for (const symbol of Object.values(symbols)) {
    values[symbol.name] = (await client.readValue(symbol.name)).value;
  }

  print({
    symbols: Object.values(symbols).map((s) => s.name),
    types: Object.values(types).map((t) => t.name),
    values,
  });

  await next();
  for (const [name, value] of Object.entries(WRITES)) await client.writeValue(name, value);
  print("written");

  await next();
  await client.subscribeValue("MAIN.nCounter", (data) => print({ value: data.value }), 10);
  print("subscribed");

  while (true) await next();
}

main();
