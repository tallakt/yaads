// DUT ST_Packed: no padding at all
{attribute 'pack_mode' := '1'}
TYPE ST_Packed :
STRUCT
    nSmall : SINT;
    fBig   : LREAL;
END_STRUCT
END_TYPE
