defmodule PlugMintProxyExample do
  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  @request_manipulators [Manipulators.DropHostHeader, Manipulators.AddHelloWorldHeader]
  @response_manipulators [Manipulators.AddHelloWorldHeader]
  @manipulators ProxyManipulatorSettings.make_settings(
                  @request_manipulators,
                  @response_manipulators
                )

  def print_diagnostics() do
    ProxyManipulatorSettings.print_diagnostics(@manipulators)
  end

  defmacro easy_forward(conn, path, endpoint) do
    endpoint_info =
      if is_binary(endpoint) do
        ConnectionForwarder.extract_info_from_backend_string(endpoint)
      else
        endpoint
      end

    quote do
      ConnectionForwarder.forward(
        unquote(conn),
        unquote(path),
        unquote(Macro.escape(endpoint_info)),
        @manipulators
      )
    end
  end

  match "/" do
    easy_forward(conn, [], "http://redpencil.io")
  end

  match "/editor-documents/*path" do
    ConnectionForwarder.forward(
      conn,
      path,
      "http://localhost:8080/editor-documents/",
      @manipulators
    )
  end

  match "/hello/*path" do
    ConnectionForwarder.forward(conn, path, "https://veeakker.be/", @manipulators)
  end

  match "/nieuws/*path" do
    ConnectionForwarder.forward(conn, path, "https://veeakker.be/nieuws/", @manipulators)
  end
end
