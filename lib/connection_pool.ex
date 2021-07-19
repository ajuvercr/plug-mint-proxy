defmodule ConnectionPool do
  @name __MODULE__

  use GenServer

  def start_link(info) do
    GenServer.start_link(__MODULE__, info, name: @name)
  end

  @spec get_connection(ConnectionForwarder.connection_spec()) :: {:ok, pid()} | {:error, any()}
  def get_connection(connection_spec) do
    EnvLog.inspect(connection_spec, :log_connection_setup, label: "Requesting connection for spec")

    GenServer.call(@name, {:get_connection, connection_spec}, 15_000)
    |> EnvLog.inspect(:log_connection_pool_processing,
      label: "Retrieved connection for connection spec #{inspect(connection_spec)}"
    )
  end

  @spec get_new_connection(ConnectionForwarder.connection_spec()) ::
          {:ok, pid()} | {:error, any()}
  def get_new_connection(connection_spec) do
    ConnectionForwarder.start(connection_spec)
  end

  @spec return_connection(ConnectionForwarder.connection_spec(), pid()) :: :ok
  def return_connection(connection_spec, connection) do
    GenServer.cast(@name, {:return_connection, connection_spec, connection})
  end

  @spec remove_connection(ConnectionForwarder.connection_spec(), pid()) :: :ok
  def remove_connection(connection_spec, connection) do
    GenServer.cast(@name, {:remove_connection, connection_spec, connection})
  end

  @spec clear_connections() :: :ok
  def clear_connections() do
    GenServer.call(@name, {:clear_connections})
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:return_connection, connection_spec, connection}, state) do
    connection
    |> EnvLog.inspect(:log_connection_setup, label: "Returned connection")
    |> EnvLog.inspect(:log_connection_pool_processing, label: "Returned connection")

    new_state =
      state
      |> Map.update(connection_spec, [connection], fn values -> [connection | values] end)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:remove_connection, connection_spec, connection}, state) do
    connection
    |> EnvLog.inspect(:log_connection_setup, label: "Removing connection")
    |> EnvLog.inspect(:log_connection_pool_processing, label: "Removing connection")
    |> IO.inspect(label: "connection pool rem")

    IO.inspect(connection_spec, label: "connection_spec")

    IO.inspect(state, label: "before")

    new_state =
      state
      |> Map.update(connection_spec, [], fn values ->
        Enum.reject(values, &(&1 == connection))
      end)

    IO.inspect(new_state, label: "after")

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:clear_connections}, _from, state) do
    process_list =
      Map.keys(state)
      |> Enum.map(&Map.get(state, &1))
      |> Enum.concat()

    process_list
    |> Enum.map(fn proc ->
      proc
      |> IO.inspect(label: "Killing process")
      |> Process.exit(:kill)
    end)

    {:reply, process_list, %{}}
  end

  @impl true
  def handle_call({:get_connection, connection_spec}, _from, state) do
    case Map.get(state, connection_spec) do
      [connection | rest] ->
        new_state = Map.update(state, connection_spec, [], fn _ -> rest end)

        EnvLog.inspect(connection, :log_connection_setup, label: "Found connection for spec")
        {:reply, {:ok, connection}, new_state}

      _ ->
        EnvLog.inspect(connection_spec, :log_connection_setup,
          label: "Made new connection for spec"
        )

        {:reply, get_new_connection(connection_spec), state}
    end
  end
end
