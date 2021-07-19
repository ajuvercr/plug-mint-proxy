defmodule Manipulators.DropHostHeader do
  @behaviour ProxyManipulator

  @impl true
  def headers(headers, connection) do
    new_headers =
      headers
      |> Enum.reject(&match?({"host", _}, &1))

    {new_headers, connection}
  end

  @impl true
  def chunk(_, _), do: :skip

  @impl true
  def finish(_, _), do: :skip
end
