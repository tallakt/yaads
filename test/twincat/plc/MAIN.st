// POU MAIN, a PROGRAM in Structured Text, called by the PLC task
PROGRAM MAIN
VAR
    // as ADS.Test.FakePLC has them
    nCounter : DINT;
    nSpeed   : INT;
    bOn      : BOOL;
    fTemp    : LREAL;
    sName    : STRING(20);
    wsText   : WSTRING(10);
    aValues  : ARRAY [1..5] OF INT;
    stPump   : ST_Pump;
    aPumps   : ARRAY [0..1] OF ST_Pump;
    eMode    : E_Mode;
    tDelay   : TIME;
    dtStamp  : DATE_AND_TIME;
    sText    : T_MaxString;
    stFlags  : ST_Flags;

    // the rest of the elementary types
    nSint    : SINT;
    nUsint   : USINT;
    nUint    : UINT;
    nUdint   : UDINT;
    nLint    : LINT;
    nUlint   : ULINT;
    nByte    : BYTE;
    nWord    : WORD;
    nDword   : DWORD;
    nLword   : LWORD;
    fReal    : REAL;
    tLong    : LTIME;
    dDate    : DATE;
    todTime  : TIME_OF_DAY;

    // and of the others
    aMatrix  : ARRAY [0..1, -1..1] OF INT;
    stPacked : ST_Packed;
    uValue   : U_Value;
    pnSpeed  : POINTER TO INT;
    aBig     : ARRAY [0..599] OF USINT;

    // counts the cycles, for the cyclic notifications
    nTicks   : UDINT;
END_VAR

nTicks := nTicks + 1;
pnSpeed := ADR(nSpeed);
