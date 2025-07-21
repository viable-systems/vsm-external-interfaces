defmodule VsmExternalInterfaces.Adapters.WebSocket do
  @moduledoc """
  WebSocket adapter base module for VSM external interfaces.
  
  Configures Phoenix endpoint for WebSocket communication.
  """
  
  use Phoenix.Endpoint, otp_app: :vsm_external_interfaces
  
  socket "/socket", VsmExternalInterfaces.Adapters.WebSocket.Socket,
    websocket: true,
    longpoll: false
  
  # Serve at "/" the static files from "priv/static" directory.
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :vsm_external_interfaces,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)
  
  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end
  
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:vsm_external_interfaces, :endpoint]
  
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  
  plug Plug.MethodOverride
  plug Plug.Head
  
  plug VsmExternalInterfaces.Adapters.HTTP
end

defmodule VsmExternalInterfaces.Adapters.WebSocket.Socket do
  @moduledoc """
  WebSocket socket handler for VSM external interfaces.
  """
  
  use Phoenix.Socket
  
  # Channels
  channel "system:*", VsmExternalInterfaces.Adapters.WebSocket.SystemChannel
  channel "events:*", VsmExternalInterfaces.Adapters.WebSocket.EventsChannel
  
  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error`.
  #
  # See `Phoenix.Token` documentation for examples in
  # performing token verification on connect.
  @impl true
  def connect(params, socket, _connect_info) do
    # Optionally authenticate the connection
    case authenticate(params) do
      {:ok, user_info} ->
        {:ok, assign(socket, :user_info, user_info)}
      
      {:error, _reason} ->
        # Allow anonymous connections for now
        {:ok, socket}
    end
  end
  
  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     Elixir.VsmExternalInterfaces.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  @impl true
  def id(_socket), do: nil
  
  defp authenticate(%{"token" => token}) do
    # Implement token verification logic
    # For now, just accept any token
    {:ok, %{authenticated: true, token: token}}
  end
  
  defp authenticate(_params), do: {:error, :no_token}
end