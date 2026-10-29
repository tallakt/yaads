// Beckhoff's own ADS libraries as a peer for test/beckhoff/beckhoff_test.exs, in a container whose
// gateway is the machine the tests run on. Two modes:
//
//   server [CLIENT_NET_ID] - Beckhoff's router on TCP 48898, with a route for CLIENT_NET_ID from
//     the gateway if given; a symbolic server on AMS port 851 with the variables below; and the
//     system service on 10000, with UDP 48899 adding routes for Administrator and "1". It says
//     "ready GATEWAY" once all are up, and stops when its standard input closes.
//   client NET_ID PORT LOOPBACK_PORT - on the host's network: Beckhoff's router on TCP PORT, with
//     a route to NET_ID at 127.0.0.1, which it connects to at PORT too, and its ADS client, on the
//     router's LOOPBACK_PORT, which uploads the device's symbols and data types, reads every value
//     as Beckhoff makes it out, writes a few, and prints all that as one Erlang term.
//
// Only the libraries' documented API is used. An error is one line on standard error.
using System.Collections;
using System.Globalization;
using System.Net;
using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using TwinCAT;
using TwinCAT.Ads;
using TwinCAT.Ads.Server;
using TwinCAT.Ads.Server.TypeSystem;
using TwinCAT.Ads.SystemService;
using TwinCAT.Ads.TcpRouter;
using TwinCAT.Ads.TypeSystem;
using TwinCAT.PlcOpen;
using TwinCAT.TypeSystem;

static class Program
{
    const string RouterNetId = "10.99.0.1.1.1";

    // PEER_LOG=1 has Beckhoff's libraries log to standard error.
    public static readonly ILoggerFactory Log = LoggerFactory.Create(builder =>
    {
        if (Environment.GetEnvironmentVariable("PEER_LOG") == "1")
            builder.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace).SetMinimumLevel(LogLevel.Trace);
    });

    static async Task<int> Main(string[] args)
    {
        try
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return args[0] switch
            {
                "server" => await Server(args.Length > 1 ? args[1] : null, Gateway()),
                "client" => await Client(args[1], args[2], args[3]),
                _ => throw new ArgumentException($"no mode {args[0]}"),
            };
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"{e.GetType().Name}: {e.Message}");
            return 1;
        }
    }

    // The default route's gateway, from /proc/net/route.
    static IPAddress Gateway()
    {
        foreach (var line in File.ReadLines("/proc/net/route").Skip(1))
        {
            var fields = line.Split('\t', StringSplitOptions.RemoveEmptyEntries);
            if (fields[1] == "00000000")
                return new IPAddress(BitConverter.GetBytes(Convert.ToUInt32(fields[2], 16)));
        }

        throw new InvalidOperationException("no default route");
    }

    static IConfiguration Configuration(Dictionary<string, string> settings) =>
        new ConfigurationBuilder().AddInMemoryCollection(settings).Build();

    static async Task<AmsTcpIpRouter> StartRouter(IConfiguration configuration, CancellationToken stop)
    {
        var router = new AmsTcpIpRouter(configuration, Log);
        _ = router.StartAsync(stop);
        await Until(() => router.IsRunning, "the router");
        return router;
    }

    static async Task Until(Func<bool> condition, string what)
    {
        for (var i = 0; i < 200 && !condition(); i++) await Task.Delay(50);
        if (!condition()) throw new TimeoutException($"{what} didn't start");
    }

    static async Task<int> Server(string clientNetId, IPAddress gateway)
    {
        using var stop = new CancellationTokenSource();

        var settings = new Dictionary<string, string>
        {
            ["AmsRouter:Name"] = "yaads-beckhoff",
            ["AmsRouter:NetId"] = RouterNetId,
            ["AmsRouter:TcpPort"] = "48898",
            ["AmsRouter:Discovery:EnforceAuthentication"] = "true",
            ["AmsRouter:Discovery:UserName"] = "Administrator",
            ["AmsRouter:Discovery:Password"] = "1",
        };

        if (clientNetId != null)
        {
            settings["AmsRouter:RemoteConnections:0:Name"] = "yaads";
            settings["AmsRouter:RemoteConnections:0:Address"] = gateway.ToString();
            settings["AmsRouter:RemoteConnections:0:NetId"] = clientNetId;
            settings["AmsRouter:RemoteConnections:0:Type"] = "TCP_IP";
        }

        var configuration = Configuration(settings);

        var router = await StartRouter(configuration, stop.Token);
        var system = new SystemServiceServer(router, configuration, Log);
        var plc = new Plc();
        _ = system.ConnectServerAndWaitAsync(stop.Token);
        _ = plc.ConnectServerAndWaitAsync(stop.Token);
        await Until(() => system.IsConnected && plc.IsConnected, "the servers");

        Console.WriteLine($"ready {gateway}");
        await Console.In.ReadToEndAsync();
        stop.Cancel();
        return 0;
    }

    static async Task<int> Client(string netId, string port, string loopbackPort)
    {
        using var stop = new CancellationTokenSource();

        var configuration = Configuration(new()
        {
            ["AmsRouter:Name"] = "yaads-beckhoff",
            ["AmsRouter:NetId"] = RouterNetId,
            ["AmsRouter:TcpPort"] = port,
            ["AmsRouter:LoopbackPort"] = loopbackPort,
            ["AmsRouter:RemoteConnections:0:Name"] = "fake",
            ["AmsRouter:RemoteConnections:0:Address"] = "127.0.0.1",
            ["AmsRouter:RemoteConnections:0:NetId"] = netId,
            ["AmsRouter:RemoteConnections:0:Type"] = "TCP_IP",
        });

        await StartRouter(configuration, stop.Token);

        using var client = new AdsClient(configuration, Log);
        client.Connect(AmsNetId.Parse(netId), 851);

        var loader = SymbolLoaderFactory.Create(client, new SymbolLoaderSettings(SymbolsLoadMode.Flat));
        var symbols = new List<object>();

        foreach (ISymbol symbol in loader.Symbols)
            symbols.Add(Term.Map(
                ("name", symbol.InstancePath),
                ("type", symbol.TypeName),
                ("size", symbol.ByteSize),
                ("value", Try(() => Value(client, symbol)))));

        var types = new List<object>();

        foreach (IDataType type in loader.DataTypes)
            types.Add(Term.Map(
                ("name", type.Name),
                ("category", type.Category.ToString()),
                ("size", type.ByteSize)));

        var writes = new List<object>();

        foreach (var (path, value) in new (string, object)[]
                 {
                     ("MAIN.nSpeed", (short)1234),
                     ("MAIN.fTemp", -0.25),
                     ("MAIN.sName", "Beckhoff"),
                     ("MAIN.wsText", "Ωmega"),
                     ("MAIN.aValues[3]", (short)33),
                     ("MAIN.stPump.fTemp", 99.5),
                     ("MAIN.aPumps[1].nSpeed", (short)-2),
                 })
            writes.Add(Term.Map(
                ("name", path),
                ("result", Try(() =>
                {
                    // By index group and offset, as Beckhoff makes them out of the descriptions,
                    // for a member or element too, which the fake has no handles for.
                    var symbol = (IAdsSymbol)Find(loader.Symbols, path);
                    var bytes = new byte[symbol.ByteSize];
                    if (!Marshaler.TryMarshal(symbol, value, bytes, out _))
                        throw new InvalidOperationException("can't marshal");
                    client.Write(symbol.IndexGroup, symbol.IndexOffset, bytes);
                    return "ok";
                }))));

        Console.WriteLine(Term.Write(Term.Map(("symbols", symbols), ("types", types), ("writes", writes))) + ".");
        stop.Cancel();
        return 0;
    }

    static object Try(Func<object> f)
    {
        try
        {
            return f();
        }
        catch (Exception e)
        {
            return Term.Map(("error", $"{e.GetType().Name}: {e.Message}"));
        }
    }

    // A symbol by its instance path, among the roots and what they hold.
    public static ISymbol Find(IEnumerable symbols, string path)
    {
        foreach (ISymbol symbol in symbols)
        {
            if (string.Equals(symbol.InstancePath, path, StringComparison.OrdinalIgnoreCase)) return symbol;

            if (path.StartsWith(symbol.InstancePath, StringComparison.OrdinalIgnoreCase) && symbol.SubSymbols != null)
            {
                var found = Find(symbol.SubSymbols, path);
                if (found != null) return found;
            }
        }

        return null;
    }

    static readonly SymbolicAnyTypeMarshaler Marshaler = new(Encoding.GetEncoding(1252));

    // A value as Beckhoff's client makes it out: the variable's bytes, read by its index group
    // and offset, and its members and elements taken out of them where Beckhoff's reading of the
    // descriptions puts them, each decoded by Beckhoff's marshaler. A struct is a map of its
    // members, an array a list of its elements, an enumeration the name of its value.
    static object Value(AdsClient client, ISymbol symbol)
    {
        var variable = (IAdsSymbol)symbol;
        var result = client.ReadAsResult(variable.IndexGroup, variable.IndexOffset, symbol.ByteSize);
        result.ThrowOnError();
        return Decoded(symbol, result.Data.ToArray(), variable.IndexOffset);
    }

    static object Decoded(ISymbol symbol, byte[] bytes, uint at)
    {
        var type = Resolved(symbol.DataType);

        switch (type?.Category)
        {
            case DataTypeCategory.Struct:
                var members = new List<(string, object)>();
                foreach (ISymbol member in symbol.SubSymbols)
                    members.Add((member.InstanceName, Try(() => Decoded(member, bytes, at))));
                return Term.Map(members.ToArray());

            case DataTypeCategory.Array:
                var elements = new List<object>();
                foreach (ISymbol element in symbol.SubSymbols)
                    elements.Add(Try(() => Decoded(element, bytes, at)));
                return elements;
        }

        // A bit's offset is in bits, in the index group after its variable's.
        if (symbol.IsBitType)
        {
            var bit = (int)(((IAdsSymbol)symbol).IndexOffset - at * 8);
            return (bytes[bit / 8] >> (bit % 8) & 1) == 1;
        }

        var offset = (int)(((IAdsSymbol)symbol).IndexOffset - at);

        Marshaler.Unmarshal(symbol, bytes.AsSpan(offset, symbol.ByteSize), null, out var value);

        if (type?.Category == DataTypeCategory.Enum)
            foreach (IEnumValue field in ((IEnumType)type).EnumValues)
                if (Convert.ToInt64(field.Value) == Convert.ToInt64(value is IEnumValue v ? v.Value : value))
                    return field.Name;

        return Plain(value);
    }

    // Aliases down to what they name; an enumeration, though an alias of its base type too, kept.
    static IDataType Resolved(IDataType type)
    {
        while (type is IAliasType alias && type.Category == DataTypeCategory.Alias && alias.BaseType != null)
            type = alias.BaseType;
        return type;
    }

    static object Plain(object value) => value switch
    {
        TIME t => Term.Map(("ms", (long)t.Time.TotalMilliseconds)),
        LTIME t => Term.Map(("ns", t.Time.Ticks * 100)),
        DT dt => Term.Map(("dt", ((DateTime)dt.Value).ToString("s", CultureInfo.InvariantCulture))),
        DATE d => Term.Map(("date", ((DateTime)d.Value).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture))),
        TOD tod => Term.Map(("tod", tod.Value.ToString())),
        TimeSpan ts => Term.Map(("timespan_ms", ts.TotalMilliseconds)),
        DateTime dt => Term.Map(("datetime", dt.ToString("s", CultureInfo.InvariantCulture))),
        _ => value,
    };
}

// The symbolic server: the variables of ADS.Test.FakePLC and more, in one data area, each kept as
// the bytes of its root symbol, read and written by Beckhoff's own symbol tables, and its first
// values marshalled by Beckhoff's own marshaler.
sealed class Plc : AdsSymbolicServer
{
    readonly Dictionary<string, byte[]> _bytes = new(StringComparer.OrdinalIgnoreCase);
    readonly SymbolicAnyTypeMarshaler _marshaler = new(Encoding.GetEncoding(1252));
    AdsState _state = AdsState.Run;

    // The version a device info gives; left as it comes from the assembly, 1.0 with no build,
    // Beckhoff's server can't make one and answers nothing.
    public Plc() : base(851, "yaads-beckhoff", Program.Log)
    {
        BaseTick = TimeSpan.FromMilliseconds(10);
        serverVersion = new Version(3, 1, 4026);
    }

    protected override void OnConnected()
    {
        var dtBool = new PrimitiveType("BOOL", typeof(bool));
        var dtSint = new PrimitiveType("SINT", typeof(sbyte));
        var dtUsint = new PrimitiveType("USINT", typeof(byte));
        var dtByte = new PrimitiveType("BYTE", typeof(byte));
        var dtInt = new PrimitiveType("INT", typeof(short));
        var dtUint = new PrimitiveType("UINT", typeof(ushort));
        var dtWord = new PrimitiveType("WORD", typeof(ushort));
        var dtDint = new PrimitiveType("DINT", typeof(int));
        var dtUdint = new PrimitiveType("UDINT", typeof(uint));
        var dtDword = new PrimitiveType("DWORD", typeof(uint));
        var dtLint = new PrimitiveType("LINT", typeof(long));
        var dtUlint = new PrimitiveType("ULINT", typeof(ulong));
        var dtLword = new PrimitiveType("LWORD", typeof(ulong));
        var dtReal = new PrimitiveType("REAL", typeof(float));
        var dtLreal = new PrimitiveType("LREAL", typeof(double));
        var dtTime = new PrimitiveType("TIME", typeof(TIME));
        var dtLtime = new PrimitiveType("LTIME", typeof(LTIME));
        var dtDate = new PrimitiveType("DATE", typeof(DATE));
        var dtDt = new PrimitiveType("DATE_AND_TIME", typeof(DT));
        var dtTod = new PrimitiveType("TIME_OF_DAY", typeof(TOD));
        var dtString20 = new StringType(20, Encoding.GetEncoding(1252));
        var dtString10 = new StringType(10, Encoding.GetEncoding(1252));
        var dtString255 = new StringType(255, Encoding.GetEncoding(1252));
        var dtUtf8 = new StringType(20, Encoding.UTF8);
        var dtWstring = new WStringType(10);

        var dtMode = new EnumType<short>("E_Mode", dtInt,
            new EnumValueCollection<short>().AddValue("eOff", 0).AddValue("eAuto", 1).AddValue("eManual", 2));

        var dtPump = new StructType("ST_Pump", null)
            .AddAligned(new Member("nSpeed", dtInt))
            .AddAligned(new Member("fTemp", dtLreal))
            .AddAligned(new Member("bRunning", dtBool))
            .AddAligned(new Member("eMode", dtMode))
            .AddAligned(new Member("sTag", dtString10));

        var dtValues = new ArrayType(dtInt, 1, 5);
        var dtPumps = new ArrayType(dtPump, 0, 2);
        var dtMatrix = new ArrayType(dtDint, new DimensionCollection().AddDimension(new Dimension(0, 3)).AddDimension(new Dimension(1, 2)));
        var dtMaxString = new AliasType("T_MaxString", dtString255);

        foreach (var type in new DataType[]
                 {
                     dtBool, dtSint, dtUsint, dtByte, dtInt, dtUint, dtWord, dtDint, dtUdint, dtDword, dtLint,
                     dtUlint, dtLword, dtReal, dtLreal, dtTime, dtLtime, dtDate, dtDt, dtTod, dtString20,
                     dtString10, dtString255, dtUtf8, dtWstring, dtMode, dtPump, dtValues, dtPumps, dtMatrix,
                     dtMaxString,
                 })
            symbolFactory.AddType(type);

        var area = new DataArea("PlcData", 0x4040, 0, 0x10000);
        symbolFactory.AddDataArea(area);

        foreach (var (name, type) in new (string, DataType)[]
                 {
                     ("MAIN.nCounter", dtDint), ("MAIN.nSpeed", dtInt), ("MAIN.bOn", dtBool),
                     ("MAIN.fTemp", dtLreal), ("MAIN.fReal", dtReal), ("MAIN.sName", dtString20),
                     ("MAIN.wsText", dtWstring), ("MAIN.aValues", dtValues), ("MAIN.stPump", dtPump),
                     ("MAIN.aPumps", dtPumps), ("MAIN.eMode", dtMode), ("MAIN.tDelay", dtTime),
                     ("MAIN.tLong", dtLtime), ("MAIN.dDate", dtDate), ("MAIN.dtStamp", dtDt),
                     ("MAIN.todTime", dtTod), ("MAIN.sText", dtMaxString), ("MAIN.nSint", dtSint),
                     ("MAIN.nUsint", dtUsint), ("MAIN.nByte", dtByte), ("MAIN.nUint", dtUint),
                     ("MAIN.nWord", dtWord), ("MAIN.nUdint", dtUdint), ("MAIN.nDword", dtDword),
                     ("MAIN.nLint", dtLint), ("MAIN.nUlint", dtUlint), ("MAIN.nLword", dtLword),
                     ("MAIN.aMatrix", dtMatrix), ("GVL.sUtf8", dtUtf8),
                 })
        {
            symbolFactory.AddSymbol(name, type, area);
            _bytes[name] = new byte[type.ByteSize];
        }

        foreach (var (path, value) in new (string, object)[]
                 {
                     ("MAIN.nCounter", -5), ("MAIN.nSpeed", (short)1500), ("MAIN.bOn", true),
                     ("MAIN.fTemp", 21.5), ("MAIN.fReal", 1.5f), ("MAIN.sName", "Pump 1"),
                     ("MAIN.wsText", "Grüße"),
                     ("MAIN.aValues[1]", (short)1), ("MAIN.aValues[2]", (short)2), ("MAIN.aValues[3]", (short)3),
                     ("MAIN.aValues[4]", (short)4), ("MAIN.aValues[5]", (short)5),
                     ("MAIN.stPump.nSpeed", (short)7), ("MAIN.stPump.fTemp", -1.5), ("MAIN.stPump.bRunning", true),
                     ("MAIN.stPump.eMode", (short)1), ("MAIN.stPump.sTag", "P1"),
                     ("MAIN.aPumps[0].nSpeed", (short)1), ("MAIN.aPumps[0].fTemp", 1.0),
                     ("MAIN.aPumps[0].sTag", "A"),
                     ("MAIN.aPumps[1].nSpeed", (short)2), ("MAIN.aPumps[1].fTemp", 2.0),
                     ("MAIN.aPumps[1].bRunning", true), ("MAIN.aPumps[1].eMode", (short)2),
                     ("MAIN.aPumps[1].sTag", "B"),
                     ("MAIN.eMode", (short)2), ("MAIN.tDelay", new TIME(TimeSpan.FromMilliseconds(2500))),
                     ("MAIN.tLong", new LTIME(TimeSpan.FromMilliseconds(1500))),
                     ("MAIN.dDate", new DATE(new DateTime(2026, 10, 28))),
                     ("MAIN.dtStamp", new DT(new DateTime(2026, 10, 28, 12, 0, 0))),
                     ("MAIN.todTime", new TOD(new TimeSpan(0, 12, 34, 56, 789))),
                     ("MAIN.sText", "a text longer than eighty characters, which T_MaxString holds, being a STRING(255) by another name"),
                     ("MAIN.nSint", (sbyte)-100), ("MAIN.nUsint", (byte)200), ("MAIN.nByte", (byte)0xAB),
                     ("MAIN.nUint", (ushort)60000), ("MAIN.nWord", (ushort)0xABCD),
                     ("MAIN.nUdint", 4000000000u), ("MAIN.nDword", 0xDEADBEEFu),
                     ("MAIN.nLint", -9000000000000000000L), ("MAIN.nUlint", 18000000000000000000UL),
                     ("MAIN.nLword", 0x0123456789ABCDEFUL),
                     ("MAIN.aMatrix[0,1]", 1), ("MAIN.aMatrix[0,2]", 2), ("MAIN.aMatrix[1,1]", 3),
                     ("MAIN.aMatrix[1,2]", 4), ("MAIN.aMatrix[2,1]", 5), ("MAIN.aMatrix[2,2]", 6),
                     ("GVL.sUtf8", "€uro, ½"),
                 })
        {
            var symbol = Program.Find(Symbols, path) ?? throw new KeyNotFoundException(path);
            var (bytes, offset) = Place(symbol);

            if (!_marshaler.TryMarshal(symbol, value, bytes.AsSpan(offset, symbol.ByteSize), out _))
                throw new InvalidOperationException($"can't marshal {path}");
        }

        base.OnConnected();
    }

    // The bytes a symbol is in, those of its variable, and where in them. Above the variables are
    // the symbols of their namespaces, MAIN and GVL, which hold no bytes.
    (byte[], int) Place(ISymbol symbol)
    {
        var root = symbol;
        while (!_bytes.ContainsKey(root.InstancePath)) root = root.Parent;
        var offset = (int)(((IAdsSymbol)symbol).IndexOffset - ((IAdsSymbol)root).IndexOffset);
        return (_bytes[root.InstancePath], offset);
    }

    protected override AdsErrorCode OnReadRawValue(ISymbol symbol, Span<byte> span)
    {
        var (bytes, offset) = Place(symbol);
        if (span.Length < symbol.ByteSize) return AdsErrorCode.DeviceInvalidSize;
        bytes.AsSpan(offset, symbol.ByteSize).CopyTo(span);
        return AdsErrorCode.NoError;
    }

    protected override AdsErrorCode OnWriteRawValue(ISymbol symbol, ReadOnlySpan<byte> span)
    {
        if (span.Length != symbol.ByteSize) return AdsErrorCode.DeviceInvalidSize;
        SetValue(symbol, span.ToArray());
        return AdsErrorCode.NoError;
    }

    protected override AdsErrorCode OnSetValue(ISymbol symbol, object value, out bool valueChanged)
    {
        var (bytes, offset) = Place(symbol);
        var data = (byte[])value;
        valueChanged = !bytes.AsSpan(offset, data.Length).SequenceEqual(data);
        data.CopyTo(bytes, offset);
        return AdsErrorCode.NoError;
    }

    protected override AdsErrorCode OnGetValue(ISymbol symbol, out object value)
    {
        var (bytes, offset) = Place(symbol);
        value = bytes.AsSpan(offset, symbol.ByteSize).ToArray();
        return AdsErrorCode.NoError;
    }

    protected override Task<ResultReadDeviceState> OnReadDeviceStateAsync(AmsAddress sender, uint invokeId, CancellationToken cancel) =>
        Task.FromResult(ResultReadDeviceState.CreateSuccess(new StateInfo(_state, 0)));

    protected override Task<ResultAds> OnWriteControlAsync(AmsAddress sender, uint invokeId, AdsState adsState, ushort deviceState, ReadOnlyMemory<byte> data, CancellationToken cancel)
    {
        _state = adsState;
        return Task.FromResult(ResultAds.CreateSuccess());
    }
}

// Erlang terms as text, for :erl_parse.parse_term/1: maps, lists, binaries, numbers and atoms.
static class Term
{
    public static IDictionary<string, object> Map(params (string, object)[] pairs)
    {
        var map = new SortedDictionary<string, object>(StringComparer.Ordinal);
        foreach (var (key, value) in pairs) map[key] = value;
        return map;
    }

    public static string Write(object value)
    {
        var b = new StringBuilder();
        Write(b, value);
        return b.ToString();
    }

    static void Write(StringBuilder b, object value)
    {
        switch (value)
        {
            case null:
                b.Append("nil");
                break;
            case bool x:
                b.Append(x ? "true" : "false");
                break;
            case string s:
                b.Append("<<\"");
                foreach (var rune in s.EnumerateRunes())
                    if (rune.Value is >= 32 and < 127 && rune.Value != '"' && rune.Value != '\\')
                        b.Append((char)rune.Value);
                    else
                        b.Append($"\\x{{{rune.Value:X}}}");
                b.Append("\"/utf8>>");
                break;
            case float or double:
                var d = Convert.ToDouble(value);
                if (double.IsNaN(d)) b.Append("nan");
                else if (double.IsPositiveInfinity(d)) b.Append("infinity");
                else if (double.IsNegativeInfinity(d)) b.Append("neg_infinity");
                else
                {
                    var text = d.ToString("R", CultureInfo.InvariantCulture).Replace("E", "e");
                    var e = text.IndexOf('e');
                    var mantissa = e < 0 ? text : text[..e];
                    if (!mantissa.Contains('.')) mantissa += ".0";
                    b.Append(mantissa).Append(e < 0 ? "" : text[e..].Replace("e+", "e"));
                }
                break;
            case sbyte or byte or short or ushort or int or uint or long or ulong:
                b.Append(Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
            case IDictionary<string, object> map:
                b.Append("#{");
                var first = true;
                foreach (var (key, v) in map)
                {
                    if (!first) b.Append(',');
                    first = false;
                    Write(b, key);
                    b.Append("=>");
                    Write(b, v);
                }
                b.Append('}');
                break;
            case IEnumerable list:
                b.Append('[');
                var head = true;
                foreach (var item in list)
                {
                    if (!head) b.Append(',');
                    head = false;
                    Write(b, item);
                }
                b.Append(']');
                break;
            default:
                Write(b, Map(("other", value.GetType().Name), ("text", value.ToString())));
                break;
        }
    }
}
