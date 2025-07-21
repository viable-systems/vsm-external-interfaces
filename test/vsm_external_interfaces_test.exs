defmodule VsmExternalInterfacesTest do
  use ExUnit.Case
  doctest VsmExternalInterfaces

  test "greets the world" do
    assert VsmExternalInterfaces.hello() == :world
  end
end
