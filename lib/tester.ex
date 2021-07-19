defmodule WebSocket do
  use GenServer

  # TODO
  @type this_spec :: {:ws | :wss, String.t(), integer}
  @type backend_string_info :: {:ws | :wss, String.t(), integer, String.t()}

  def start(params) do
    GenServer.start(__MODULE__, params)
  end

  @spec forward(
          Plug.Conn.t(),
          [String.t()],
          String.t() | backend_string_info
        ) :: Plug.Conn.t() | {:error, any()}
  def forward(frontend_conn, extra_path, backend_string) when is_binary(backend_string) do
    backend_string_info =
      backend_string
      |> ConnectionForwarder.extract_info_from_backend_string()
      |> EnvLog.inspect(:log_connection_setup, label: "Parsed info from backend string")

    forward(frontend_conn, extra_path, backend_string_info)
  end

  def forward(frontend_conn, extra_path, {scheme, host, port, base_path}) do

    case WebSocket.start({host, port, base_path, frontend_conn, self()}) do
      {:ok, state} ->
        {:reply, conn} = GenServer.call(state, {:proxy, "much bla"}, 1000)
        conn

      {:error, error} ->
        IO.inspect(error, label: "Error error error")
        Plug.Conn.send_resp(frontend_conn, 200, "{ \"message\": \"Error error\" }")
    end
  end

  ## Callbacks
  ## Create process for handling proxy things to specified backend
  @impl true
  def init({host, port, path, frontend_conn, from} = connection_spec) do
    {:ok, conn} = :gun.open(to_charlist(host), port)
    {:ok, :http} = :gun.await_up(conn)
    :gun.ws_upgrade(conn, path)

    {:ok, %{conn: conn, connection_spec: connection_spec, frontend_conn: frontend_conn, from: from}}
  end

  @impl true
  def handle_call({:proxy, bla}, from, state) do
    new_state =
      state
      |> Map.put(:from, from)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(matchthing, from, state) do
    IO.inspect(matchthing, label: "handle call")
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_ws, pid, ref, message}, state) do
    IO.inspect({:gun_ws, pid, message}, label: "handle info gun_ws")
    IO.inspect(state, label: "handle info gun_ws")
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_upgrade, _pid, _ref, _types, headers} = msg, state) do
    IO.inspect(msg, label: "handle info gun_upgrade")
    IO.inspect(state, label: "handle info gun_upgrade")

    conn = state.frontend_conn
    conn = headers
      |> Enum.reject(fn ({key, value}) -> String.downcase(key) == "sec-websocket-accept" end)
      |> Enum.reduce(conn, fn ({key, value}, conn) -> Plug.Conn.put_resp_header(conn, key, value) end)
    conn = Plug.Conn.send_chunked(conn, 101)


    GenServer.reply(state.from, {:reply, conn})

    new_state = state |> Map.put(:frontend_conn, conn)

    # conn = send_resp(state.frontend_conn.send_resp, 200, "{ \"message\": \"Hello Aad\" }")

    {:noreply, state}
  end

  @impl true
  def handle_info(info, state) do
    IO.inspect(info, label: "handle info")
    IO.inspect(state, label: "handle info")
    {:noreply, state}
  end

  def connect(params) do
    hostname = params.hostname
    port = params.port
    path = params.path
    timeout = params.connection_timeout
    {:ok, conn} = :gun.open(hostname, port)
    {:ok, :http} = :gun.await_up(conn)
    :gun.ws_upgrade(conn, path)

    receive do
      {:gun_ws_upgrade, ^conn, :ok, _} ->
        established(conn)
    after
      timeout ->
        raise "timeout"
    end
  end

  def established(conn) do
    receive do
      {:gun_down, ^conn, _, _, _, _} ->
        IO.puts("Transport: received down event")

      {:gun_ws, ^conn, {:binary, data}} ->
        IO.puts("Transport: received: #{inspect(data)}")
        established(conn)

      {:send, data} ->
        IO.puts("Transport: sending frame #{inspect(data)}")
        :gun.ws_send(conn, {:binary, data})
        established(conn)

      :shutdown ->
        IO.puts("Transport: good bye!")
        :gun.shutdown(conn)

      msg ->
        IO.puts("Transport: unhandled message: #{inspect(msg)}")
        established(conn)
    end
  end

  def start() do
    Application.ensure_all_started(:dispatcher)
  end
end
