// DUT U_Value
TYPE U_Value :
UNION
    nDint  : DINT;
    fReal  : REAL;
    aBytes : ARRAY [0..3] OF BYTE;
END_UNION
END_TYPE
