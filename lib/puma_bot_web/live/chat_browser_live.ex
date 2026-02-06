defmodule PumaBotWeb.ChatBrowserLive do
  use PumaBotWeb, :live_view

  alias PumaBot.Chats
  alias PumaBot.WhatsApp.Bridge
  alias PumaBot.Importers.WhatsAppImporter

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to periodic updates if connected
    if connected?(socket) do
      :timer.send_interval(5000, self(), :refresh_bridge_status)
    end

    stats = Chats.stats()
    whatsapp_chats = Chats.list_whatsapp_chats()
    claude_sessions = Chats.list_claude_sessions()
    bridge_status = Bridge.status()

    socket =
      socket
      |> assign(:page_title, "Chat Browser")
      |> assign(:stats, stats)
      |> assign(:whatsapp_chats, whatsapp_chats)
      |> assign(:claude_sessions, claude_sessions)
      |> assign(:active_tab, :whatsapp)
      |> assign(:selected_chat, nil)
      |> assign(:messages, [])
      |> assign(:search_query, "")
      |> assign(:search_results, nil)
      |> assign(:bridge_status, bridge_status)
      |> assign(:show_settings, false)
      |> assign(:importing, false)
      |> assign(:qr_code, nil)
      |> assign(:show_qr_modal, false)
      |> assign(:total_message_count, 0)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = apply_action(socket, socket.assigns.live_action, params)
    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params) do
    socket
  end

  defp apply_action(socket, :show, %{"source" => "whatsapp", "id" => chat_jid}) do
    chat_jid = URI.decode(chat_jid)
    messages = Chats.get_whatsapp_messages(chat_jid, limit: 500)
    total_count = Chats.count_whatsapp_messages(chat_jid)
    chat = Enum.find(socket.assigns.whatsapp_chats, &(&1.chat_jid == chat_jid))

    socket
    |> assign(:active_tab, :whatsapp)
    |> assign(:selected_chat, %{source: :whatsapp, id: chat_jid, name: chat && chat.display_name})
    |> assign(:messages, messages)
    |> assign(:total_message_count, total_count)
  end

  defp apply_action(socket, :show, %{"source" => "claude", "id" => session_id}) do
    session_id = URI.decode(session_id)
    messages = Chats.get_claude_messages(session_id, limit: 500)
    total_count = Chats.count_claude_messages(session_id)
    session = Enum.find(socket.assigns.claude_sessions, &(&1.session_id == session_id))

    socket
    |> assign(:active_tab, :claude)
    |> assign(:selected_chat, %{source: :claude, id: session_id, name: session && session.display_name})
    |> assign(:messages, messages)
    |> assign(:total_message_count, total_count)
  end

  defp apply_action(socket, _, _), do: socket

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = String.to_existing_atom(tab)
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) when byte_size(query) < 2 do
    {:noreply, assign(socket, search_query: query, search_results: nil)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    results = Chats.search(query, limit: 50)
    {:noreply, assign(socket, search_query: query, search_results: results)}
  end

  @impl true
  def handle_event("clear_search", _, socket) do
    {:noreply, assign(socket, search_query: "", search_results: nil)}
  end

  @impl true
  def handle_event("toggle_settings", _, socket) do
    {:noreply, assign(socket, :show_settings, !socket.assigns.show_settings)}
  end

  @impl true
  def handle_event("start_bridge", _, socket) do
    case Bridge.start_bridge() do
      :ok ->
        Process.sleep(2000)  # Give it time to start
        bridge_status = Bridge.status()
        {:noreply, assign(socket, :bridge_status, bridge_status)}

      {:error, :already_running} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start bridge: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("stop_bridge", _, socket) do
    Bridge.stop_bridge()
    bridge_status = Bridge.status()
    {:noreply, assign(socket, :bridge_status, bridge_status)}
  end

  @impl true
  def handle_event("run_import", _, socket) do
    socket = assign(socket, :importing, true)
    parent = self()

    # Run import in a task to not block the UI
    Task.start(fn ->
      result = WhatsAppImporter.import_all(quiet: true)
      send(parent, {:import_complete, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_data", _, socket) do
    {:noreply, refresh_all_data(socket)}
  end

  @impl true
  def handle_event("show_qr", _, socket) do
    case PumaBot.WhatsApp.Client.get_qr() do
      {:ok, %{"qr" => qr}} when is_binary(qr) ->
        {:noreply, socket |> assign(:qr_code, qr) |> assign(:show_qr_modal, true)}

      {:ok, %{qr: qr}} when is_binary(qr) ->
        {:noreply, socket |> assign(:qr_code, qr) |> assign(:show_qr_modal, true)}

      _ ->
        {:noreply, put_flash(socket, :error, "QR code not available")}
    end
  end

  @impl true
  def handle_event("close_qr_modal", _, socket) do
    {:noreply, assign(socket, :show_qr_modal, false)}
  end

  @impl true
  def handle_info(:refresh_bridge_status, socket) do
    bridge_status = Bridge.status()

    # Auto-close QR modal if connected
    socket =
      if bridge_status.connected and socket.assigns.show_qr_modal do
        assign(socket, :show_qr_modal, false)
      else
        socket
      end

    {:noreply, assign(socket, :bridge_status, bridge_status)}
  end

  @impl true
  def handle_info({:import_complete, result}, socket) do
    socket =
      case result do
        {:ok, %{messages: msgs, chat_names_updated: names_updated}} ->
          msg = "Imported #{msgs} messages"
          msg = if names_updated > 0, do: msg <> ", updated #{names_updated} chat names", else: msg
          put_flash(socket, :info, msg)

        {:ok, %{messages: msgs}} ->
          put_flash(socket, :info, "Imported #{msgs} messages")

        {:error, reason} ->
          put_flash(socket, :error, "Import failed: #{inspect(reason)}")
      end

    {:noreply,
     socket
     |> assign(:importing, false)
     |> refresh_all_data()}
  end

  # Fallback for old format (backwards compatibility)
  def handle_info(:import_complete, socket) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> refresh_all_data()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-base-100">
      <!-- Flash Messages -->
      <%= if @flash != %{} do %>
        <div class="toast toast-top toast-end z-50">
          <%= if info = Phoenix.Flash.get(@flash, :info) do %>
            <div class="alert alert-success" phx-click="lv:clear-flash" phx-value-key="info">
              <span>{info}</span>
            </div>
          <% end %>
          <%= if error = Phoenix.Flash.get(@flash, :error) do %>
            <div class="alert alert-error" phx-click="lv:clear-flash" phx-value-key="error">
              <span>{error}</span>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- Header -->
      <header class="navbar bg-base-200 border-b border-base-300 px-4">
        <div class="flex-1">
          <h1 class="text-xl font-bold">PumaBot</h1>
          <span class="ml-4 text-sm text-base-content/60">
            {@stats.whatsapp_messages} WhatsApp · {@stats.claude_messages} Claude
          </span>
          <!-- Bridge status indicator -->
          <div class="ml-4 flex items-center gap-2">
            <%= if @bridge_status.connected do %>
              <span class="badge badge-success badge-sm gap-1">
                <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
                WhatsApp Connected
              </span>
            <% else %>
              <%= if @bridge_status.process_running do %>
                <span class="badge badge-warning badge-sm">Bridge Starting...</span>
              <% else %>
                <span class="badge badge-ghost badge-sm">Bridge Offline</span>
              <% end %>
            <% end %>
          </div>
        </div>
        <div class="flex-none flex items-center gap-2">
          <form phx-change="search" phx-submit="search" class="form-control">
            <div class="input-group">
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search messages..."
                class="input input-bordered input-sm w-64"
                phx-debounce="300"
              />
              <%= if @search_query != "" do %>
                <button type="button" phx-click="clear_search" class="btn btn-sm btn-ghost">
                  ✕
                </button>
              <% end %>
            </div>
          </form>
          <button phx-click="toggle_settings" class={"btn btn-sm btn-ghost #{if @show_settings, do: "btn-active"}"}>
            ⚙️
          </button>
        </div>
      </header>

      <!-- Settings Panel (collapsible) -->
      <%= if @show_settings do %>
        <div class="bg-base-300 border-b border-base-200 p-4">
          <div class="flex items-center gap-4 flex-wrap">
            <!-- WhatsApp Bridge Controls -->
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">WhatsApp Bridge:</span>
              <%= if @bridge_status.process_running do %>
                <button phx-click="stop_bridge" class="btn btn-sm btn-error btn-outline">
                  Stop Bridge
                </button>
              <% else %>
                <button phx-click="start_bridge" class="btn btn-sm btn-primary">
                  Start Bridge
                </button>
              <% end %>
            </div>

            <!-- Import Controls -->
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">Data:</span>
              <button
                phx-click="run_import"
                class="btn btn-sm btn-secondary"
                disabled={@importing or not @bridge_status.connected}
              >
                <%= if @importing do %>
                  <span class="loading loading-spinner loading-xs"></span>
                  Importing...
                <% else %>
                  Import Now
                <% end %>
              </button>
              <button phx-click="refresh_data" class="btn btn-sm btn-ghost">
                Refresh
              </button>
            </div>

            <!-- Status Info -->
            <%= if @bridge_status.connected do %>
              <div class="text-sm text-base-content/60">
                Buffered: {@bridge_status.buffered_messages} messages
              </div>
            <% end %>

            <%= if @bridge_status.has_qr do %>
              <button phx-click="show_qr" class="btn btn-sm btn-warning">
                Show QR Code
              </button>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- QR Code Modal -->
      <%= if @show_qr_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Scan QR Code with WhatsApp</h3>
            <div class="flex justify-center">
              <div id="qr-code-container" phx-hook="QRCode" data-qr={@qr_code} class="bg-white p-4 rounded"></div>
            </div>
            <p class="text-sm text-base-content/60 mt-4 text-center">
              Open WhatsApp on your phone → Settings → Linked Devices → Link a Device
            </p>
            <div class="modal-action">
              <button phx-click="close_qr_modal" class="btn">Close</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_qr_modal"></div>
        </div>
      <% end %>

      <div class="flex-1 flex overflow-hidden">
        <!-- Sidebar -->
        <aside class="w-80 bg-base-200 border-r border-base-300 flex flex-col">
          <!-- Tabs -->
          <div class="tabs tabs-boxed m-2">
            <button
              class={"tab #{if @active_tab == :whatsapp, do: "tab-active"}"}
              phx-click="switch_tab"
              phx-value-tab="whatsapp"
            >
              WhatsApp ({length(@whatsapp_chats)})
            </button>
            <button
              class={"tab #{if @active_tab == :claude, do: "tab-active"}"}
              phx-click="switch_tab"
              phx-value-tab="claude"
            >
              Claude ({length(@claude_sessions)})
            </button>
          </div>

          <!-- Chat List -->
          <div class="flex-1 overflow-y-auto">
            <%= if @search_results do %>
              <.search_results results={@search_results} />
            <% else %>
              <%= if @active_tab == :whatsapp do %>
                <.chat_list
                  chats={@whatsapp_chats}
                  selected={@selected_chat}
                  source={:whatsapp}
                />
              <% else %>
                <.session_list
                  sessions={@claude_sessions}
                  selected={@selected_chat}
                />
              <% end %>
            <% end %>
          </div>
        </aside>

        <!-- Main Content -->
        <main class="flex-1 flex flex-col overflow-hidden">
          <%= if @selected_chat do %>
            <.message_header chat={@selected_chat} message_count={length(@messages)} total_count={@total_message_count} />
            <.message_list messages={@messages} source={@selected_chat.source} />
          <% else %>
            <.empty_state stats={@stats} />
          <% end %>
        </main>
      </div>
    </div>
    """
  end

  # --- Components ---

  defp chat_list(assigns) do
    ~H"""
    <ul class="menu menu-sm p-2">
      <%= for chat <- @chats do %>
        <li id={"chat-#{chat.chat_jid}"}>
          <.link
            patch={~p"/chat/whatsapp/#{URI.encode(chat.chat_jid)}"}
            class={if @selected && @selected.id == chat.chat_jid, do: "active", else: ""}
          >
            <div class="flex flex-col w-full">
              <div class="flex justify-between items-center">
                <span class="font-medium truncate">{chat.display_name}</span>
                <span class="badge badge-sm">{chat.message_count}</span>
              </div>
              <span class="text-xs text-base-content/60">
                {format_date(chat.last_message_at)}
              </span>
            </div>
          </.link>
        </li>
      <% end %>
    </ul>
    """
  end

  defp session_list(assigns) do
    ~H"""
    <ul class="menu menu-sm p-2">
      <%= for session <- @sessions do %>
        <li id={"session-#{session.session_id}"}>
          <.link
            patch={~p"/chat/claude/#{URI.encode(session.session_id)}"}
            class={if @selected && @selected.id == session.session_id, do: "active", else: ""}
          >
            <div class="flex flex-col w-full">
              <div class="flex justify-between items-center">
                <span class="font-medium truncate">{session.display_name}</span>
                <span class="badge badge-sm">{session.message_count}</span>
              </div>
              <span class="text-xs text-base-content/60">
                {format_date(session.last_message_at)}
              </span>
            </div>
          </.link>
        </li>
      <% end %>
    </ul>
    """
  end

  defp search_results(assigns) do
    ~H"""
    <div class="p-2">
      <div class="text-sm text-base-content/60 mb-2">
        {length(@results)} results
      </div>
      <ul class="menu menu-sm">
        <%= for result <- @results do %>
          <li>
            <.link patch={~p"/chat/#{result.source}/#{URI.encode(result.chat_id)}"}>
              <div class="flex flex-col w-full">
                <div class="flex justify-between items-center">
                  <span class="badge badge-xs">{result.source}</span>
                  <span class="text-xs text-base-content/60">{format_date(result.timestamp)}</span>
                </div>
                <span class="text-sm truncate">{truncate(result.content, 80)}</span>
              </div>
            </.link>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp message_header(assigns) do
    ~H"""
    <div class="bg-base-200 border-b border-base-300 px-4 py-3">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="font-semibold">{@chat.name || "Chat"}</h2>
          <span class="text-sm text-base-content/60">
            <%= if @total_count > @message_count do %>
              Showing {@message_count} of {@total_count} messages (most recent)
            <% else %>
              {@message_count} messages
            <% end %>
          </span>
        </div>
        <.link patch={~p"/"} class="btn btn-ghost btn-sm">
          ← Back
        </.link>
      </div>
    </div>
    """
  end

  defp message_list(%{source: :whatsapp} = assigns) do
    # Build lookup maps for quoted messages and reactions
    msg_lookup = Map.new(assigns.messages, fn m -> {m.message_id, m} end)

    # Group reactions by their target message ID
    {reactions, regular_messages} =
      Enum.split_with(assigns.messages, fn m -> m.message_type == :reaction end)

    reaction_map =
      Enum.reduce(reactions, %{}, fn r, acc ->
        # Reaction's target is stored in raw_data -> reaction_target_id or raw_data -> message -> reactionMessage -> key -> id
        target_id = get_reaction_target(r)
        if target_id do
          Map.update(acc, target_id, [r.content], fn existing -> existing ++ [r.content] end)
        else
          acc
        end
      end)

    assigns =
      assigns
      |> assign(:regular_messages, regular_messages)
      |> assign(:msg_lookup, msg_lookup)
      |> assign(:reaction_map, reaction_map)

    ~H"""
    <div id="message-list" class="flex-1 overflow-y-auto p-4 space-y-2">
      <%= for message <- @regular_messages do %>
        <.whatsapp_bubble
          message={message}
          quoted={quoted_message(message, @msg_lookup)}
          reactions={Map.get(@reaction_map, message.message_id, [])}
        />
      <% end %>
    </div>
    """
  end

  defp message_list(assigns) do
    ~H"""
    <div id="message-list" class="flex-1 overflow-y-auto p-4 space-y-2">
      <%= for message <- @messages do %>
        <.message_bubble message={message} source={@source} />
      <% end %>
    </div>
    """
  end

  defp whatsapp_bubble(assigns) do
    sender_id = extract_sender_jid(assigns.message)
    assigns = assign(assigns, :sender_id, sender_id)

    ~H"""
    <div id={"msg-#{@message.id}"} class={"chat #{if @message.is_from_me, do: "chat-end", else: "chat-start"}"}>
      <div class="chat-image avatar">
        <div class="w-8 rounded-full">
          <img src={avatar_url(@sender_id, @message.is_from_me)} alt="" />
        </div>
      </div>
      <div class="chat-header">
        {sender_display_name(@message)}
        <time class="text-xs opacity-50">{format_datetime(@message.timestamp)}</time>
      </div>
      <div class={"chat-bubble #{if @message.is_from_me, do: "chat-bubble-primary", else: ""}"}>
        <%= if @quoted do %>
          <div class="bg-base-300/30 rounded px-2 py-1 mb-1 border-l-2 border-accent text-xs">
            <div class="font-semibold text-accent">{@quoted.sender}</div>
            <div class="opacity-80 truncate max-w-xs">{truncate(@quoted.content, 120)}</div>
          </div>
        <% end %>
        {format_content(@message.content)}
        <%= if @reactions != [] do %>
          <div class="flex gap-1 mt-1">
            <%= for {emoji, count} <- group_reactions(@reactions) do %>
              <span class="badge badge-sm bg-base-300/50 border-0 text-sm">{emoji} {count}</span>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp message_bubble(%{source: :whatsapp} = assigns) do
    sender_id = extract_sender_jid(assigns.message)
    assigns = assign(assigns, :sender_id, sender_id)

    ~H"""
    <div id={"msg-#{@message.id}"} class={"chat #{if @message.is_from_me, do: "chat-end", else: "chat-start"}"}>
      <div class="chat-image avatar">
        <div class="w-8 rounded-full">
          <img src={avatar_url(@sender_id, @message.is_from_me)} alt="" />
        </div>
      </div>
      <div class="chat-header">
        {sender_display_name(@message)}
        <time class="text-xs opacity-50">{format_datetime(@message.timestamp)}</time>
      </div>
      <div class={"chat-bubble #{if @message.is_from_me, do: "chat-bubble-primary", else: ""}"}>
        {format_content(@message.content)}
      </div>
    </div>
    """
  end

  defp message_bubble(%{source: :claude} = assigns) do
    ~H"""
    <div id={"msg-#{@message.id}"} class={"chat #{if @message.role == :user, do: "chat-end", else: "chat-start"}"}>
      <div class="chat-image avatar">
        <div class="w-8 rounded-full">
          <img src={claude_avatar_url(@message.role)} alt="" />
        </div>
      </div>
      <div class="chat-header">
        {if @message.role == :user, do: "You", else: "Claude"}
        <time class="text-xs opacity-50">{format_datetime(@message.timestamp)}</time>
      </div>
      <div class={"chat-bubble #{if @message.role == :user, do: "chat-bubble-primary", else: "chat-bubble-secondary"} max-w-3xl"}>
        <div class="prose prose-sm max-w-none">
          {format_content(@message.content)}
        </div>
      </div>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center">
        <h2 class="text-2xl font-bold mb-4">Welcome to PumaBot</h2>
        <p class="text-base-content/60 mb-4">Select a chat from the sidebar to view messages</p>
        <div class="stats shadow">
          <div class="stat">
            <div class="stat-title">WhatsApp</div>
            <div class="stat-value text-primary">{@stats.whatsapp_messages}</div>
            <div class="stat-desc">{@stats.whatsapp_chats} chats</div>
          </div>
          <div class="stat">
            <div class="stat-title">Claude</div>
            <div class="stat-value text-secondary">{@stats.claude_messages}</div>
            <div class="stat-desc">{@stats.claude_sessions} sessions</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp sender_display_name(message) do
    cond do
      message.is_from_me -> "You"
      message.sender_name && message.sender_name != "" -> message.sender_name
      true -> extract_sender_jid(message) |> format_sender()
    end
  end

  # Try to get the real sender JID, checking raw_data for participant info
  defp extract_sender_jid(message) do
    cond do
      # First check if sender_jid is different from chat_jid (meaning it's the actual sender)
      message.sender_jid && message.sender_jid != message.chat_jid ->
        message.sender_jid

      # Try to get participant from raw_data top level (WhatsApp's format)
      participant = get_in(message.raw_data, ["participant"]) ->
        participant

      # Try nested in key (older format)
      participant = get_in(message.raw_data, ["key", "participant"]) ->
        participant

      # Check for pushName in raw_data
      push_name = get_in(message.raw_data, ["pushName"]) ->
        {:name, push_name}

      # Fall back to sender_jid even if it's the group ID
      message.sender_jid ->
        message.sender_jid

      true ->
        nil
    end
  end

  defp format_sender({:name, name}) when is_binary(name) and name != "", do: name
  defp format_sender(nil), do: "Unknown"
  defp format_sender(jid) when is_binary(jid) do
    # Don't show group JID as sender name
    if String.ends_with?(jid, "@g.us") do
      "Group Member"
    else
      jid
      |> String.replace("@s.whatsapp.net", "")
      |> String.replace("@lid", "")  # WhatsApp's newer LID format
      |> format_phone()
    end
  end
  defp format_sender(_), do: "Unknown"

  defp format_phone(phone) when byte_size(phone) > 10 do
    "+" <> phone
  end
  defp format_phone(phone), do: phone

  defp format_date(nil), do: ""
  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp format_datetime(nil), do: ""
  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, len) when byte_size(str) <= len, do: str
  defp truncate(str, len), do: String.slice(str, 0, len) <> "..."

  defp format_content(nil), do: ""
  defp format_content(content), do: content

  # Generate a unique avatar based on sender ID (locally generated identicon)
  defp avatar_url(nil, _is_me), do: PumaBotWeb.Avatar.generate("unknown")
  defp avatar_url({:name, name}, _is_me), do: PumaBotWeb.Avatar.generate(name)
  defp avatar_url(_sender_id, true), do: PumaBotWeb.Avatar.generate("me")
  defp avatar_url(sender_id, false), do: PumaBotWeb.Avatar.generate(sender_id)

  # Claude conversation avatars
  defp claude_avatar_url(:user), do: PumaBotWeb.Avatar.generate("me")
  defp claude_avatar_url(_role), do: PumaBotWeb.Avatar.generate("claude-assistant")

  # Refresh all data including currently selected chat messages
  defp refresh_all_data(socket) do
    stats = Chats.stats()
    whatsapp_chats = Chats.list_whatsapp_chats()
    claude_sessions = Chats.list_claude_sessions()

    socket =
      socket
      |> assign(:stats, stats)
      |> assign(:whatsapp_chats, whatsapp_chats)
      |> assign(:claude_sessions, claude_sessions)

    # Refresh the currently selected chat's messages if one is selected
    case socket.assigns.selected_chat do
      %{source: :whatsapp, id: chat_jid} ->
        messages = Chats.get_whatsapp_messages(chat_jid, limit: 500)
        total_count = Chats.count_whatsapp_messages(chat_jid)
        chat = Enum.find(whatsapp_chats, &(&1.chat_jid == chat_jid))

        socket
        |> assign(:messages, messages)
        |> assign(:total_message_count, total_count)
        |> assign(:selected_chat, %{source: :whatsapp, id: chat_jid, name: chat && chat.display_name})

      %{source: :claude, id: session_id} ->
        messages = Chats.get_claude_messages(session_id, limit: 500)
        total_count = Chats.count_claude_messages(session_id)
        session = Enum.find(claude_sessions, &(&1.session_id == session_id))

        socket
        |> assign(:messages, messages)
        |> assign(:total_message_count, total_count)
        |> assign(:selected_chat, %{source: :claude, id: session_id, name: session && session.display_name})

      _ ->
        socket
    end
  end

  # Look up the quoted/replied-to message from the message lookup map
  defp quoted_message(message, msg_lookup) do
    quoted_id = message.quoted_message_id

    cond do
      # No quote
      is_nil(quoted_id) or quoted_id == "" ->
        # Also check raw_data for quoted content from the bridge
        quoted_content = get_in(message.raw_data, ["quoted_content"])
        quoted_sender = get_in(message.raw_data, ["quoted_sender"])

        if quoted_content do
          sender_name = if quoted_sender, do: format_sender(quoted_sender), else: "Someone"
          %{sender: sender_name, content: quoted_content}
        else
          nil
        end

      # Found in current message set
      Map.has_key?(msg_lookup, quoted_id) ->
        quoted = Map.get(msg_lookup, quoted_id)
        %{sender: sender_display_name(quoted), content: quoted.content}

      # Quoted message not in current window - check raw_data for inline quote
      true ->
        quoted_content = get_in(message.raw_data, ["quoted_content"])
        quoted_sender = get_in(message.raw_data, ["quoted_sender"])

        if quoted_content do
          sender_name = if quoted_sender, do: format_sender(quoted_sender), else: "Someone"
          %{sender: sender_name, content: quoted_content}
        else
          %{sender: "...", content: "[Original message not in view]"}
        end
    end
  end

  # Get the target message ID for a reaction
  defp get_reaction_target(reaction) do
    # Try bridge-provided field first
    get_in(reaction.raw_data, ["reaction_target_id"]) ||
      # Fall back to Baileys raw structure
      get_in(reaction.raw_data, ["message", "reactionMessage", "key", "id"])
  end

  # Group emoji reactions and count them
  defp group_reactions(reactions) do
    reactions
    |> Enum.filter(fn r -> r != "" and r != nil end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_emoji, count} -> -count end)
  end
end
