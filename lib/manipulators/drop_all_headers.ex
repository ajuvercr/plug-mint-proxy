defmodule Manipulators.DropAllHeaders do
  @behaviour ProxyManipulator

  @impl true
  def headers(headers, connection) do
    IO.inspect(headers, label: "Dropping headers")
    {[], connection}
  end

  @impl true
  def chunk(_, _), do: :skip

  @impl true
  def finish(_, _), do: :skip
end
