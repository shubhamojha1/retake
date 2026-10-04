defmodule RetakeWeb.UserSocket do
  @moduledoc """
  The browser's websocket (`/socket`). Retake v1 is a single-user, self-hosted app with no
  accounts, so any client may connect, like any client may call `/api`.
  """

  use Phoenix.Socket

  channel "video:*", RetakeWeb.VideoChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
