defmodule ADS.DocTest do
  use ExUnit.Case, async: true

  doctest ADS
  doctest ADS.ReturnCode
  doctest ADS.NetId
  doctest ADS.AMS
  doctest ADS.Command
  doctest ADS.Sum
  doctest ADS.Type
  doctest ADS.DataType
  doctest ADS.Secure
  doctest ADS.Route
end
