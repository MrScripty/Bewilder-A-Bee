defmodule PumaBot.WhatsApp.Client do
  @moduledoc """
  HTTP client for the WhatsApp Bridge (Node.js Baileys sidecar).

  Communicates with the bridge service to:
  - Check connection status
  - Retrieve QR code for authentication
  - Fetch messages and chats
  - Send messages

  ## Configuration

  Set the bridge URL in config:

      config :puma_bot, :whatsapp_bridge_url, "http://localhost:3456"

  ## Usage

      # Check if bridge is running and connected
      {:ok, status} = Client.status()

      # Get QR code for authentication
      {:ok, %{qr: qr_string}} = Client.get_qr()

      # Fetch new messages from buffer
      {:ok, messages} = Client.get_buffered_messages()

      # Get list of chats
      {:ok, chats} = Client.get_chats()
  """

  require Logger

  @default_url "http://localhost:3456"
  @timeout 30_000

  # --- Configuration ---

  @doc """
  Returns the configured WhatsApp bridge URL.
  """
  def bridge_url do
    Application.get_env(:puma_bot, :whatsapp_bridge_url, @default_url)
  end

  # --- Status & Connection ---

  @doc """
  Checks the status of the WhatsApp bridge.

  Returns connection status, whether QR is available, and message buffer count.

  ## Examples

      iex> Client.status()
      {:ok, %{status: "connected", connected: true, has_qr: false, buffered_messages: 5}}
  """
  @spec status() :: {:ok, map()} | {:error, term()}
  def status do
    get("/api/status")
  end

  @doc """
  Checks if the bridge service is reachable.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case status() do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Checks if WhatsApp is connected (authenticated and ready).
  """
  @spec connected?() :: boolean()
  def connected? do
    case status() do
      {:ok, %{"connected" => true}} -> true
      {:ok, %{connected: true}} -> true
      _ -> false
    end
  end

  # --- QR Code ---

  @doc """
  Gets the QR code for WhatsApp authentication.

  Returns nil if already connected or QR not yet generated.

  ## Examples

      iex> Client.get_qr()
      {:ok, %{qr: "2@abc123...", status: "waiting_for_scan"}}
  """
  @spec get_qr() :: {:ok, map()} | {:error, term()}
  def get_qr do
    get("/api/qr")
  end

  # --- Chats ---

  @doc """
  Fetches the list of available chats (groups).

  ## Examples

      iex> Client.get_chats()
      {:ok, [%{jid: "123@g.us", name: "Family Group", type: "group"}]}
  """
  @spec get_chats() :: {:ok, [map()]} | {:error, term()}
  def get_chats do
    case get("/api/chats") do
      {:ok, %{"chats" => chats}} -> {:ok, chats}
      {:ok, %{chats: chats}} -> {:ok, chats}
      error -> error
    end
  end

  @doc """
  Fetches missing group names from WhatsApp.

  This queries WhatsApp for group metadata for any groups that don't have
  names yet. Useful for populating chat names after initial sync.

  ## Examples

      iex> Client.fetch_missing_group_names()
      {:ok, %{fetched: 5, total: 10}}
  """
  @spec fetch_missing_group_names() :: {:ok, map()} | {:error, term()}
  def fetch_missing_group_names do
    post("/api/chats/fetch-names", %{})
  end

  @doc """
  Fetches group names for specific JIDs from WhatsApp.

  This is useful when the bridge's chat cache is empty (e.g., after reconnection)
  but we have JIDs in the database that need names.

  ## Examples

      iex> Client.fetch_group_names_for_jids(["123@g.us", "456@g.us"])
      {:ok, %{fetched: 2, results: [%{jid: "123@g.us", name: "Group Name"}]}}
  """
  @spec fetch_group_names_for_jids([String.t()]) :: {:ok, map()} | {:error, term()}
  def fetch_group_names_for_jids(jids) when is_list(jids) do
    post("/api/chats/fetch-names-for-jids", %{jids: jids})
  end

  # --- Messages ---

  @doc """
  Fetches new messages from the buffer.

  The buffer contains messages received since the last fetch.
  Calling this clears the buffer on the bridge side.

  ## Examples

      iex> Client.get_buffered_messages()
      {:ok, [%{message_id: "abc", content: "Hello!", ...}]}
  """
  @spec get_buffered_messages() :: {:ok, [map()]} | {:error, term()}
  def get_buffered_messages do
    case get("/api/messages/buffer") do
      {:ok, %{"messages" => messages}} -> {:ok, messages}
      {:ok, %{messages: messages}} -> {:ok, messages}
      error -> error
    end
  end

  @doc """
  Fetches messages from a specific chat.

  Note: Baileys doesn't support historical message fetch directly.
  Messages are received in real-time via the buffer.

  ## Options
  - `:limit` - Maximum messages to fetch (default: 50)
  """
  @spec get_messages(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_messages(chat_jid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    case get("/api/messages/#{URI.encode(chat_jid)}?limit=#{limit}") do
      {:ok, %{"messages" => messages}} -> {:ok, messages}
      {:ok, %{messages: messages}} -> {:ok, messages}
      error -> error
    end
  end

  @doc """
  Sends a message to a chat.

  ## Examples

      iex> Client.send_message("123456789@s.whatsapp.net", "Hello!")
      {:ok, %{success: true}}
  """
  @spec send_message(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_message(chat_jid, text) do
    post("/api/messages/send", %{chat_jid: chat_jid, text: text})
  end

  # --- Private HTTP helpers ---

  defp get(path) do
    url = bridge_url() <> path

    # Disable retries to avoid noisy warnings when bridge isn't running
    case Req.get(url, receive_timeout: @timeout, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("WhatsApp bridge returned #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        # Bridge not running - this is expected, log at debug level
        Logger.debug("WhatsApp bridge not running (connection refused)")
        {:error, {:request_failed, :econnrefused}}

      {:error, reason} ->
        Logger.error("WhatsApp bridge request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp post(path, body) do
    url = bridge_url() <> path

    case Req.post(url, json: body, receive_timeout: @timeout, retry: false) do
      {:ok, %Req.Response{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: response}} ->
        Logger.warning("WhatsApp bridge returned #{status}: #{inspect(response)}")
        {:error, {:http_error, status, response}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        Logger.debug("WhatsApp bridge not running (connection refused)")
        {:error, {:request_failed, :econnrefused}}

      {:error, reason} ->
        Logger.error("WhatsApp bridge request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end
end
