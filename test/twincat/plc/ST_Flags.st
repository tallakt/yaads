// DUT ST_Flags: two BITs in the first byte, and a BYTE after them
TYPE ST_Flags :
STRUCT
    bA    : BIT;
    bB    : BIT;
    nRest : BYTE;
END_STRUCT
END_TYPE
