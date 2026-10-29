// DUT ST_Pump: laid out by TwinCAT 3's default pack_mode, 8
TYPE ST_Pump :
STRUCT
    nSpeed   : INT;
    fTemp    : LREAL;
    bRunning : BOOL;
    eMode    : E_Mode;
    sTag     : STRING(10);
END_STRUCT
END_TYPE
