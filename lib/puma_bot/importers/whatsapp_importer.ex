defmodule PumaBot.Importers.WhatsAppImporter do
  @moduledoc """
  Imports WhatsApp messages from the Baileys bridge service.

  Connects to the Node.js WhatsApp bridge to fetch new messages
  and stores them in the database for RAG retrieval.

  ## Usage

      # Import all buffered messages
      WhatsAppImporter.import_all()

      # Check connection status
      WhatsAppImporter.status()

      # Count imported messages
      WhatsAppImporter.count_messages()
  """

  alias PumaBot.Data.{WhatsAppMessage, DataSource}
  alias PumaBot.WhatsApp.Client
  alias PumaBot.Repo

  require Logger

  # --- Public API ---

  @doc """
  Returns the current status of the WhatsApp bridge connection.
  """
  @spec status() :: {:ok, map()} | {:error, term()}
  def status do
    Client.status()
  end

  @doc """
  Checks if the WhatsApp bridge is connected and ready.
  """
  @spec connected?() :: boolean()
  def connected? do
    Client.connected?()
  end

  @doc """
  Imports all buffered messages from the WhatsApp bridge.

  ## Options
  - `:with_embeddings` - Generate embeddings during import (default: false)
  - `:user_only` - Only import messages from you to DataSource (default: true)

  Returns {:ok, stats} with import statistics.
  """
  @spec import_all(keyword()) :: {:ok, map()} | {:error, term()}
  def import_all(opts \\ []) do
    with_embeddings = Keyword.get(opts, :with_embeddings, false)
    user_only = Keyword.get(opts, :user_only, true)
    quiet = Keyword.get(opts, :quiet, false)

    case Client.get_buffered_messages() do
      {:ok, messages} when is_list(messages) ->
        unless quiet or length(messages) == 0 do
          Logger.info("Fetched #{length(messages)} messages from WhatsApp bridge")
        end

        stats =
          Enum.reduce(messages, %{messages: 0, errors: 0}, fn msg_data, acc ->
            case import_message(msg_data, with_embeddings, user_only) do
              {:ok, _} ->
                %{acc | messages: acc.messages + 1}

              {:error, reason} ->
                Logger.debug("Failed to import message: #{inspect(reason)}")
                %{acc | errors: acc.errors + 1}
            end
          end)

        # Auto-backfill chat names for any messages missing them
        backfill_stats = sync_chat_names(quiet)

        # Add sessions count and backfill stats for compatibility
        {:ok, stats |> Map.put(:sessions, 1) |> Map.put(:chat_names_updated, backfill_stats)}

      {:error, reason} ->
        Logger.error("Failed to fetch messages from bridge: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Imports messages from a specific chat.

  ## Options
  - `:with_embeddings` - Generate embeddings during import (default: false)
  - `:user_only` - Only import your messages to DataSource (default: true)
  - `:limit` - Maximum messages to fetch (default: 50)
  """
  @spec import_chat(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_chat(chat_jid, opts \\ []) do
    with_embeddings = Keyword.get(opts, :with_embeddings, false)
    user_only = Keyword.get(opts, :user_only, true)
    limit = Keyword.get(opts, :limit, 50)

    case Client.get_messages(chat_jid, limit: limit) do
      {:ok, messages} ->
        stats =
          Enum.reduce(messages, %{messages: 0, errors: 0}, fn msg_data, acc ->
            case import_message(msg_data, with_embeddings, user_only) do
              {:ok, _} ->
                %{acc | messages: acc.messages + 1}

              {:error, reason} ->
                Logger.debug("Failed to import message: #{inspect(reason)}")
                %{acc | errors: acc.errors + 1}
            end
          end)

        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Counts how many WhatsApp messages are stored in the database.
  """
  @spec count_messages() :: non_neg_integer()
  def count_messages do
    Repo.aggregate(WhatsAppMessage, :count)
  end

  @doc """
  Counts how many WhatsApp data sources are stored.
  """
  @spec count_data_sources() :: non_neg_integer()
  def count_data_sources do
    import Ecto.Query

    from(ds in DataSource, where: ds.source_type == :whatsapp)
    |> Repo.aggregate(:count)
  end

  @doc """
  Backfills chat names for existing messages using the bridge's chat list.

  This is useful when messages were imported before chat names were captured,
  or when the bridge has updated chat metadata.

  ## Examples

      iex> WhatsAppImporter.backfill_chat_names()
      {:ok, %{updated: 150}}
  """
  @spec backfill_chat_names() :: {:ok, map()} | {:error, term()}
  def backfill_chat_names do
    import Ecto.Query

    case Client.get_chats() do
      {:ok, chats} when is_list(chats) ->
        # Build a map of jid -> name
        chat_map =
          Enum.reduce(chats, %{}, fn chat, acc ->
            jid = chat["jid"] || chat[:jid]
            name = chat["name"] || chat[:name]
            if jid && name && name != jid do
              Map.put(acc, jid, name)
            else
              acc
            end
          end)

        Logger.info("Backfilling chat names for #{map_size(chat_map)} chats")

        # Update messages for each chat
        updated_count =
          Enum.reduce(chat_map, 0, fn {jid, name}, acc ->
            {count, _} =
              from(m in WhatsAppMessage,
                where: m.chat_jid == ^jid and is_nil(m.chat_name)
              )
              |> Repo.update_all(set: [chat_name: name])

            acc + count
          end)

        Logger.info("Updated #{updated_count} messages with chat names")
        {:ok, %{updated: updated_count, chats: map_size(chat_map)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private Functions ---

  # Syncs chat names from the bridge to any messages missing them
  defp sync_chat_names(quiet) do
    import Ecto.Query

    # Get all unique group JIDs from our database that don't have names
    group_jids_without_names =
      from(m in WhatsAppMessage,
        where: is_nil(m.chat_name) and m.is_group == true,
        select: m.chat_jid,
        distinct: true
      )
      |> Repo.all()

    unless quiet or length(group_jids_without_names) == 0 do
      Logger.info("Found #{length(group_jids_without_names)} groups without names in database")
    end

    # Fetch names from WhatsApp for these JIDs
    chat_map =
      if length(group_jids_without_names) > 0 do
        case Client.fetch_group_names_for_jids(group_jids_without_names) do
          {:ok, %{"results" => results}} ->
            build_chat_map_from_results(results, quiet)

          {:ok, %{results: results}} ->
            build_chat_map_from_results(results, quiet)

          {:error, reason} ->
            unless quiet, do: Logger.warning("Could not fetch group names: #{inspect(reason)}")
            %{}
        end
      else
        %{}
      end

    # Update messages for each chat that we got a name for
    updated_count =
      Enum.reduce(chat_map, 0, fn {jid, name}, acc ->
        {count, _} =
          from(m in WhatsAppMessage,
            where: m.chat_jid == ^jid and is_nil(m.chat_name)
          )
          |> Repo.update_all(set: [chat_name: name])

        acc + count
      end)

    unless quiet or updated_count == 0 do
      Logger.info("Updated #{updated_count} messages with chat names")
    end

    updated_count
  end

  defp build_chat_map_from_results(results, quiet) when is_list(results) do
    successful = Enum.filter(results, fn r ->
      success = r["success"] || r[:success]
      name = r["name"] || r[:name]
      success == true and name != nil
    end)

    unless quiet or length(successful) == 0 do
      Logger.info("Fetched #{length(successful)} group names from WhatsApp")
    end

    Enum.reduce(successful, %{}, fn result, acc ->
      jid = result["jid"] || result[:jid]
      name = result["name"] || result[:name]
      if jid && name, do: Map.put(acc, jid, name), else: acc
    end)
  end

  defp build_chat_map_from_results(_, _), do: %{}

  defp import_message(msg_data, with_embeddings, user_only) do
    attrs = transform_message(msg_data)

    # Insert into whatsapp_messages table
    message_result =
      %WhatsAppMessage{}
      |> WhatsAppMessage.changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:message_id]
      )

    # Also create DataSource entry for RAG
    case message_result do
      {:ok, message} ->
        if should_create_data_source?(attrs, user_only) do
          create_data_source(message, attrs, with_embeddings)
        end

        {:ok, message}

      {:error, _} = error ->
        error
    end
  end

  defp transform_message(data) do
    # Handle both string and atom keys from JSON
    get = fn key ->
      data[key] || data[to_string(key)]
    end

    %{
      message_id: get.(:message_id),
      chat_jid: get.(:chat_jid),
      chat_name: get.(:chat_name),
      sender_jid: get.(:sender_jid),
      sender_name: get.(:push_name),
      content: get.(:content) || "",
      message_type: parse_message_type(get.(:message_type)),
      is_from_me: get.(:is_from_me) || false,
      is_group: is_group_chat?(get.(:chat_jid)),
      quoted_message_id: get.(:quoted_message_id),
      timestamp: parse_timestamp(get.(:timestamp)),
      raw_data: data
    }
  end

  defp parse_message_type(nil), do: :text
  defp parse_message_type("text"), do: :text
  defp parse_message_type("image"), do: :image
  defp parse_message_type("video"), do: :video
  defp parse_message_type("audio"), do: :audio
  defp parse_message_type("document"), do: :document
  defp parse_message_type("sticker"), do: :sticker
  defp parse_message_type("reaction"), do: :reaction
  defp parse_message_type(type) when is_atom(type), do: type
  defp parse_message_type(_), do: :other

  defp is_group_chat?(nil), do: false
  defp is_group_chat?(jid), do: String.ends_with?(jid, "@g.us")

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(%DateTime{} = dt), do: dt
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp should_create_data_source?(attrs, user_only) do
    content = attrs[:content] || ""
    has_content = String.trim(content) != ""
    is_from_me = attrs[:is_from_me] == true

    has_content and (not user_only or is_from_me)
  end

  defp create_data_source(message, attrs, with_embeddings) do
    source_attrs = %{
      source_type: :whatsapp,
      source_id: "whatsapp:#{message.message_id}",
      raw_content: attrs[:content],
      processed_content: attrs[:content],
      source_timestamp: attrs[:timestamp],
      metadata: %{
        message_id: message.message_id,
        chat_jid: attrs[:chat_jid],
        sender_jid: attrs[:sender_jid],
        sender_name: attrs[:sender_name],
        is_from_me: attrs[:is_from_me],
        is_group: attrs[:is_group],
        message_type: Atom.to_string(attrs[:message_type])
      }
    }

    case %DataSource{}
         |> DataSource.changeset(source_attrs)
         |> Repo.insert(on_conflict: :nothing, conflict_target: [:source_type, :source_id]) do
      {:ok, data_source} ->
        if with_embeddings and data_source.id do
          spawn(fn ->
            PumaBot.Embeddings.Generator.embed_data_source(data_source)
          end)
        end

        {:ok, data_source}

      {:error, _} = error ->
        error
    end
  end
end
