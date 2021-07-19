defmodule Manipulators.AddHelloWorldHeader do
  @behaviour ProxyManipulator

  @impl true
  def headers(headers, connection) do
    {[{"hello", "world"} | headers], connection}
  end

  @impl true
  def chunk(_, _), do: :skip

  @impl true
  def finish(_, _), do: :skip
end
