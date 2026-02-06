defmodule PumaBot.Chats do
  @moduledoc """
  Context for browsing chat data from WhatsApp and Claude Code.
  """

  import Ecto.Query
  alias PumaBot.Repo
  alias PumaBot.Data.{WhatsAppMessage, ClaudeConversation}

  # --- WhatsApp Chats ---

  @doc """
  Lists all WhatsApp chats with message counts and last message time.
  """
  def list_whatsapp_chats do
    from(m in WhatsAppMessage,
      group_by: [m.chat_jid],
      select: %{
        chat_jid: m.chat_jid,
        chat_name: max(m.chat_name),
        is_group: fragment("bool_or(?)", m.is_group),
        message_count: count(m.id),
        last_message_at: max(m.timestamp)
      },
      order_by: [desc: max(m.timestamp)]
    )
    |> Repo.all()
    |> Enum.map(fn chat ->
      # Extract a readable name from the JID if no chat_name
      name = chat.chat_name || extract_name_from_jid(chat.chat_jid)
      Map.put(chat, :display_name, name)
    end)
  end

  @doc """
  Gets messages for a specific WhatsApp chat.
  """
  def get_whatsapp_messages(chat_jid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    from(m in WhatsAppMessage,
      where: m.chat_jid == ^chat_jid,
      order_by: [desc: m.timestamp],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Counts total messages in a WhatsApp chat.
  """
  def count_whatsapp_messages(chat_jid) do
    from(m in WhatsAppMessage, where: m.chat_jid == ^chat_jid)
    |> Repo.aggregate(:count)
  end

  # --- Claude Conversations ---

  @doc """
  Lists all Claude Code sessions with message counts and metadata.
  """
  def list_claude_sessions do
    from(c in ClaudeConversation,
      group_by: [c.session_id],
      select: %{
        session_id: c.session_id,
        project_path: max(c.project_path),
        message_count: count(c.id),
        first_message_at: min(c.timestamp),
        last_message_at: max(c.timestamp)
      },
      order_by: [desc: max(c.timestamp)]
    )
    |> Repo.all()
    |> Enum.map(fn session ->
      # Create a display name from project path or session ID
      name = session_display_name(session)
      Map.put(session, :display_name, name)
    end)
  end

  @doc """
  Gets messages for a specific Claude session.
  """
  def get_claude_messages(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    offset = Keyword.get(opts, :offset, 0)

    from(c in ClaudeConversation,
      where: c.session_id == ^session_id,
      order_by: [desc: c.message_index],
      limit: ^limit,
      offset: ^offset
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Counts total messages in a Claude session.
  """
  def count_claude_messages(session_id) do
    from(c in ClaudeConversation, where: c.session_id == ^session_id)
    |> Repo.aggregate(:count)
  end

  # --- Search ---

  @doc """
  Searches across all messages (WhatsApp and Claude).
  """
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    search_term = "%#{query}%"

    whatsapp_results =
      from(m in WhatsAppMessage,
        where: ilike(m.content, ^search_term),
        order_by: [desc: m.timestamp],
        limit: ^limit,
        select: %{
          id: m.id,
          source: "whatsapp",
          chat_id: m.chat_jid,
          content: m.content,
          timestamp: m.timestamp,
          sender: m.sender_name
        }
      )
      |> Repo.all()

    claude_results =
      from(c in ClaudeConversation,
        where: ilike(c.content, ^search_term),
        order_by: [desc: c.timestamp],
        limit: ^limit,
        select: %{
          id: c.id,
          source: "claude",
          chat_id: c.session_id,
          content: c.content,
          timestamp: c.timestamp,
          sender: c.role
        }
      )
      |> Repo.all()

    (whatsapp_results ++ claude_results)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # --- Stats ---

  @doc """
  Returns overall statistics.
  """
  def stats do
    %{
      whatsapp_messages: Repo.aggregate(WhatsAppMessage, :count),
      whatsapp_chats: Repo.aggregate(
        from(m in WhatsAppMessage, select: m.chat_jid, distinct: true),
        :count
      ),
      claude_messages: Repo.aggregate(ClaudeConversation, :count),
      claude_sessions: Repo.aggregate(
        from(c in ClaudeConversation, select: c.session_id, distinct: true),
        :count
      )
    }
  end

  # --- Private Helpers ---

  defp extract_name_from_jid(nil), do: "Unknown"
  defp extract_name_from_jid(jid) do
    cond do
      String.ends_with?(jid, "@g.us") ->
        # Group - use the JID prefix
        jid |> String.replace("@g.us", "") |> String.slice(0, 20)

      String.ends_with?(jid, "@s.whatsapp.net") ->
        # Individual - show phone number
        jid |> String.replace("@s.whatsapp.net", "")

      true ->
        jid |> String.slice(0, 20)
    end
  end

  defp session_display_name(%{project_path: nil, session_id: id}) do
    String.slice(id, 0, 12) <> "..."
  end

  defp session_display_name(%{project_path: path}) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-2)
    |> Enum.join("/")
  end

  defp session_display_name(_), do: "Unknown Session"
end
