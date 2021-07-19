defmodule ConnectionForwarder do
  use GenServer

  require Logger

  @type connection_spec :: {:http | :https | :ws | :wss, String.t(), integer}
  @type backend_string_info :: {:http | :https | :ws | :wss, String.t(), integer, String.t()}

  @spec start_link(connection_spec) :: {:ok, pid()} | {:error, any}
  def start_link(connection_spec) do
    GenServer.start_link(__MODULE__, connection_spec)
  end

  @spec start(connection_spec) :: {:ok, pid()} | {:error, any}
  def start(connection_spec) do
    GenServer.start(__MODULE__, connection_spec)
  end

  @spec extract_info_from_backend_string(String.t()) :: backend_string_info
  def extract_info_from_backend_string(backend_string) do
    %{host: host, path: base_path, port: port, scheme: string_scheme} = URI.parse(backend_string)

    EnvLog.inspect(backend_string, :log_connection_setup,
      label: "Could not proxy, trying with a new connection"
    )

    scheme =
      case string_scheme do
        "http" -> :http
        "https" -> :https
        "ws" -> :ws
        "wss" -> :wss
        _ -> :unknown
      end

    base_path = base_path || "/"

    {scheme, host, port, base_path}
  end

  @spec forward(
          Plug.Conn.t(),
          [String.t()],
          String.t() | backend_string_info,
          ProxyManipulatorSettings.t()
        ) :: Plug.Conn.t() | {:error, any()}
  def forward(frontend_conn, extra_path, backend_string, manipulators)
      when is_binary(backend_string) do
    backend_string_info =
      backend_string
      |> extract_info_from_backend_string()
      |> EnvLog.inspect(:log_connection_setup, label: "Parsed info from backend string")

    forward(frontend_conn, extra_path, backend_string_info, manipulators)
  end

  def forward(frontend_conn, extra_path, {scheme, host, port, base_path}, manipulators) do
    IO.inspect("Proxying to: #{base_path <> Enum.join(extra_path, "/")}",
      label: "log_proxy_url_on_call"
    )

    frontend_conn =
      frontend_conn
      |> Plug.Conn.assign(:extra_path, extra_path)
      |> Plug.Conn.assign(:base_path, base_path)

    connection_spec = {scheme, host, port}

    {:done, body, frontend_conn} = ConnectionForwarder.get_full_plug_request_body(frontend_conn)

    case ConnectionPool.get_connection(connection_spec) do
      {:ok, pid} ->
        EnvLog.inspect(connection_spec, :log_connection_setup,
          label: "Got connection for spec, ready to proxy"
        )

        case ConnectionForwarder.proxy(pid, frontend_conn, body, manipulators) do
          {:ok, conn} ->
            conn

          {:error, _} ->
            # ignore the old connection and try with a fresh connection

            EnvLog.inspect(connection_spec, :log_connection_setup,
              label: "Could not proxy, trying with a new connection"
            )

            # TODO: kill the old connection process (no need to remove
            # it, it's not in the pool)
            Process.exit(pid, :kill)

            case ConnectionPool.get_new_connection(connection_spec) do
              {:error, reason} ->
                EnvLog.inspect({:error, reason}, :log_connection_failure,
                  label: "Error occurred when getting connection"
                )

                EnvLog.inspect(connection_spec, :log_connection_setup,
                  label: "Could get a new connection"
                )

                frontend_conn

              {:ok, pid} ->
                case ConnectionForwarder.proxy(pid, frontend_conn, body, manipulators) do
                  {:ok, conn} ->
                    conn

                  {:error, reason} ->
                    IO.inspect({:error, reason}, label: "An error occurred")
                    frontend_conn
                end
            end
        end

      {:error, reason} ->
        IO.inspect({:error, reason}, label: "An error occurred")

        EnvLog.inspect(connection_spec, :log_connection_setup, label: "Could not get a connection")

        frontend_conn
    end
  end

  def proxy(pid, conn, body, manipulators) do
    # It seems Cowboy does not succeed in fetching the request inside
    # the proxy process so we now fetch it in the Plug process itself.

    # TODO: make wait time for proxy configurable (here and inside
    # process)
    GenServer.call(pid, {:proxy, conn, body, manipulators}, 600_000)
  end

  ## Callbacks
  ## Create process for handling proxy things to specified backend
  @impl true
  def init({scheme, host, port} = connection_spec) do
    IO.inspect(connection_spec, label: "init conn forwarder")
    {:ok, conn} = Mint.HTTP.connect(scheme, host, port)
    {:ok, %{backend_host_conn: conn, connection_spec: connection_spec}}
  end

  @impl true
  def handle_call({:proxy, frontend_conn, request_body, manipulators}, from, state) do
    %{backend_host_conn: backend_host_conn} = state

    state = Map.put(state, :manipulators, manipulators)

    extra_path = frontend_conn.assigns[:extra_path]
    base_path = frontend_conn.assigns[:base_path]
    full_path = base_path <> Enum.join(extra_path, "/")

    full_path =
      case frontend_conn.query_string do
        "" ->
          full_path

        qs ->
          full_path <> "?" <> qs
      end

    {headers, {frontend_conn, backend_host_conn}} =
      Map.get(frontend_conn, :req_headers)
      |> ProxyManipulatorSettings.process_request_headers(
        manipulators,
        {frontend_conn, backend_host_conn}
      )

    {:done, request_body, frontend_conn, backend_host_conn} =
      manipulate_full_plug_request_body(
        request_body,
        frontend_conn,
        backend_host_conn,
        manipulators
      )

    method = Map.get(frontend_conn, :method)

    EnvLog.log(:log_backend_communication, "Executing backend request")
    EnvLog.inspect(request_body, :log_request_body, label: "Request body for backend")

    case Mint.HTTP.request(backend_host_conn, method, full_path, headers, request_body) do
      {:ok, backend_conn, request_ref} ->
        EnvLog.log(:log_backend_communication, "Backend request started sucessfully")

        new_state =
          state
          |> Map.put(:backend_conn, backend_conn)
          |> Map.put(:frontend_conn, frontend_conn)
          |> Map.put(:request_ref, request_ref)
          |> Map.put(:from, from)
          |> Map.put(:headers_sent, false)

        IO.inspect("Bla bla end here", label: "Mint.HTTP.request")

        {:noreply, new_state}

      {:error, _conn, reason} ->
        EnvLog.inspect(reason, :log_backend_communication,
          label: "Could not initiate backend request"
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, pid}, state) do
    ConnectionPool.remove_connection(Map.get(state, :connection_spec), self())

    {:stop, :normal, state}
  end

  @impl true
  def handle_info(message, %{backend_conn: backend_conn} = state) do
    IO.inspect(message, label: "Mint.HTTP.request")

    case Mint.HTTP.stream(backend_conn, message) do
      :unknown ->
        EnvLog.log(:log_backend_communication, "Received unknown TCP message from backend")
        EnvLog.log(:log_connection_failure, "Received unknown TCP message from backend")
        {:noreply, state}

      {:error, _, %Mint.TransportError{reason: :closed}, _} ->
        EnvLog.log(:log_backend_communication, "Received TCP close message from backend")
        EnvLog.log(:log_connection_failure, "Received unknown TCP message from backend")
        ConnectionPool.remove_connection(Map.get(state, :connection_spec), self())
        {:stop, "Mint transport error", self()}

      error = {:error, _, _, _} ->
        EnvLog.inspect(error, :log_connection_failure, "HTTP stream error occurred")

        IO.inspect(
          error,
          label: "Received erroneous TCP message from backend"
        )

        # TODO: kill the connection PID
        ConnectionPool.remove_connection(Map.get(state, :connection_spec), self())
        {:stop, "Received erroneous TCP message from backend", self()}

      {:ok, backend_conn, responses} ->
        IO.inspect(
          "Received ok TCP message from backend, processing",
          label: "Received some TCP message from backend"
        )

        new_state =
          state
          |> Map.put(:backend_conn, backend_conn)

        new_state =
          responses
          |> Enum.reduce(new_state, fn chunk, state ->
            IO.inspect(elem(chunk, 0),
              label: "Processing chunk type"
            )

            process_chunk(chunk, state)
          end)

        {:noreply, new_state}
    end
  end

  defp process_chunk({:status, _, status_code}, state) do
    # %{frontend_conn: frontend_conn} = state
    # new_frontend_conn = Plug.Conn.put_status(frontend_conn, status_code)
    EnvLog.inspect(status_code, :log_backend_communication, label: "Processing received status")

    Map.put(state, :return_status, status_code)
  end

  defp process_chunk({:headers, _, headers}, state) do
    EnvLog.inspect(headers, :log_backend_communication, label: "Processing received headers")

    %{frontend_conn: frontend_conn, backend_conn: backend_conn, manipulators: manipulators} =
      state

    {headers, {frontend_conn, backend_conn}} =
      ProxyManipulatorSettings.process_response_headers(
        headers,
        manipulators,
        {frontend_conn, backend_conn}
      )

    frontend_conn = Map.put(frontend_conn, :resp_headers, headers)

    state
    |> Map.put(:frontend_conn, frontend_conn)
    |> Map.put(:backend_conn, backend_conn)
  end

  defp process_chunk(
         {:data, _, new_data} = message,
         %{headers_sent: false, return_status: return_status, frontend_conn: frontend_conn} =
           state
       ) do
    EnvLog.log(
      :log_backend_communication,
      "Processing received body chunk when no headers sent yet"
    )

    EnvLog.inspect(new_data, :log_response_body, label: "Received body chunk")

    new_state =
      state
      |> Map.put(:frontend_conn, Plug.Conn.send_chunked(frontend_conn, return_status))
      |> Map.put(:headers_sent, true)

    process_chunk(message, new_state)
  end

  defp process_chunk({:data, _, new_data}, state) do
    EnvLog.log(:log_backend_communication, "Processing received body chunk")
    EnvLog.inspect(new_data, :log_response_body, label: "Received body chunk")

    %{frontend_conn: frontend_conn, backend_conn: backend_conn, manipulators: manipulators} =
      state

    {new_data, {frontend_conn, backend_conn}} =
      ProxyManipulatorSettings.process_response_chunk(
        new_data,
        manipulators,
        {frontend_conn, backend_conn}
      )

    state =
      state
      |> Map.put(:frontend_conn, frontend_conn)
      |> Map.put(:backend_conn, backend_conn)

    EnvLog.log(:log_frontend_communication, "Sending chunked response")

    case Plug.Conn.chunk(frontend_conn, new_data) do
      {:ok, new_frontend_conn} ->
        EnvLog.log(:log_frontend_communication, "Managed to send frontend response")

        state
        |> Map.put(:frontend_conn, new_frontend_conn)

      {:error, :closed} ->
        EnvLog.log(:log_connection_failure, "Could not proxy body further, socket already closed")

        EnvLog.log(
          :log_frontend_communication,
          "Failed to send frontend response due to closed socket"
        )

        state
    end
  end

  defp process_chunk(
         {:done, _},
         %{
           from: from,
           frontend_conn: frontend_conn,
           connection_spec: connection_spec,
           backend_conn: backend_conn,
           manipulators: manipulators,
           return_status: return_status
         } = state
       ) do
    EnvLog.log(:log_backend_communication, "Received done chunk")

    frontend_conn =
      case Map.get(frontend_conn, :state) do
        value when value in [:sent, :chunked] ->
          EnvLog.log(
            :log_backend_communication,
            "Response is sent or chunked, no need to send extra"
          )

          # response was sent
          frontend_conn

        _ ->
          EnvLog.log(:log_backend_communication, "Response status with empty body will be sent")

          frontend_conn
          |> Plug.Conn.send_resp(return_status, "")
      end

    {_, {frontend_conn, backend_conn}} =
      ProxyManipulatorSettings.process_response_finish(
        true,
        manipulators,
        {frontend_conn, backend_conn}
      )

    EnvLog.log(
      :log_connection_setup,
      "Will respond to proxy requester with new frontend connection"
    )

    GenServer.reply(from, {:ok, frontend_conn})

    # should this include backend_host_conn ?
    new_state =
      [:from, :request_ref, :headers_sent, :response_status]
      |> Enum.reduce(state, &Map.delete(&2, &1))
      |> Map.put(:frontend_conn, frontend_conn)
      |> Map.put(:backend_conn, backend_conn)

    EnvLog.log(:log_connection_setup, "Will return connection to pool")

    ConnectionPool.return_connection(connection_spec, self())

    new_state
  end

  defp process_chunk({:error, _, _} = message, state) do
    EnvLog.inspect(message, :log_backend_communication,
      label: "Error message received from backend"
    )

    EnvLog.inspect(message, :log_connection_failure, label: "Error message received from backend")

    state
  end

  defp process_chunk(message, state) do
    EnvLog.inspect(message, :log_backend_communication,
      label: "Unknown message received from backend"
    )

    EnvLog.inspect(message, :log_connection_failure, label: "Unprocessed message")

    state
  end

  def get_full_plug_request_body(conn, body \\ "") do
    EnvLog.log(:log_frontend_communication, "Getting full request body")

    case Plug.Conn.read_body(conn, read_length: 1000, read_timeout: 15000) do
      {:ok, stuff, conn} ->
        EnvLog.inspect(body, :log_frontend_communication, label: "Full request body")
        |> IO.inspect(label: "Full request body")

        {:done, body <> stuff, conn}

      {:more, stuff, conn} ->
        EnvLog.log(:log_frontend_communication, "Got request chunk")
        EnvLog.inspect(stuff, :log_request_body, label: "Request chunk")
        get_full_plug_request_body(conn, body <> stuff)

      {:error, reason} ->
        EnvLog.inspect(reason, :log_frontend_communication, label: "Error receiving request body")
        {:error, conn, reason}
    end
  end

  defp manipulate_full_plug_request_body(body, frontend_conn, backend_conn, manipulators) do
    {body, {frontend_conn, backend_conn}} =
      ProxyManipulatorSettings.process_request_chunk(
        body,
        manipulators,
        {frontend_conn, backend_conn}
      )

    {_, {frontend_conn, backend_conn}} =
      ProxyManipulatorSettings.process_request_finish(
        true,
        manipulators,
        {frontend_conn, backend_conn}
      )

    {:done, body, frontend_conn, backend_conn}
  end
end
