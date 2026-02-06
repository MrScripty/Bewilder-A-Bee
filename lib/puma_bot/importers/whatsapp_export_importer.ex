defmodule PumaBot.Importers.WhatsAppExportImporter do
  @moduledoc """
  Imports WhatsApp messages from exported .txt files.

  WhatsApp's built-in export feature creates text files with messages in formats like:
  - `[1/15/24, 10:30:15 AM] John Doe: Hello!`
  - `15/01/2024, 10:30 - John Doe: Hello!`
  - `[2024-01-15, 10:30:15] John Doe: Hello!`

  ## Usage

      # Import a single export file
      WhatsAppExportImporter.import_file("/path/to/WhatsApp Chat.txt")

      # Import all exports from a directory
      WhatsAppExportImporter.import_directory("/path/to/exports/")

      # Import with options
      WhatsAppExportImporter.import_file(path, with_embeddings: true)
  """

  alias PumaBot.Data.{WhatsAppMessage, DataSource}
  alias PumaBot.Repo

  require Logger

  # Regex patterns for different WhatsApp export formats
  # Format 1: [M/D/YY, H:MM:SS AM/PM] Sender: Message
  @pattern_us ~r/^\[(\d{1,2}\/\d{1,2}\/\d{2,4}),\s*(\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?)\]\s*([^:]+):\s*(.*)$/i

  # Format 2: DD/MM/YYYY, HH:MM - Sender: Message
  @pattern_eu ~r/^(\d{1,2}\/\d{1,2}\/\d{2,4}),\s*(\d{1,2}:\d{2}(?::\d{2})?)\s*-\s*([^:]+):\s*(.*)$/i

  # Format 3: [YYYY-MM-DD, HH:MM:SS] Sender: Message
  @pattern_iso ~r/^\[(\d{4}-\d{2}-\d{2}),\s*(\d{2}:\d{2}(?::\d{2})?)\]\s*([^:]+):\s*(.*)$/i

  # System messages to skip
  @system_patterns [
    ~r/Messages and calls are end-to-end encrypted/i,
    ~r/created group/i,
    ~r/added you/i,
    ~r/changed the subject/i,
    ~r/changed this group's icon/i,
    ~r/left$/i,
    ~r/removed \w+$/i,
    ~r/changed the group description/i,
    ~r/\<Media omitted\>/i
  ]

  # --- Public API ---

  @doc """
  Imports messages from a WhatsApp export text file.

  ## Options
  - `:with_embeddings` - Generate embeddings during import (default: false)
  - `:user_only` - Only import your messages to DataSource (default: true)
  - `:my_name` - Your name as it appears in the export (for is_from_me detection)
  - `:chat_name` - Override chat name (default: derived from filename)

  ## Examples

      WhatsAppExportImporter.import_file("WhatsApp Chat with John.txt", my_name: "Jeremy")
  """
  @spec import_file(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_file(file_path, opts \\ []) do
    with_embeddings = Keyword.get(opts, :with_embeddings, false)
    user_only = Keyword.get(opts, :user_only, true)
    my_name = Keyword.get(opts, :my_name)
    chat_name = Keyword.get(opts, :chat_name) || derive_chat_name(file_path)

    case File.read(file_path) do
      {:ok, content} ->
        Logger.info("Importing WhatsApp export: #{file_path}")

        stats =
          content
          |> String.split("\n")
          |> parse_messages(chat_name)
          |> Enum.reduce(%{messages: 0, skipped: 0, errors: 0}, fn msg, acc ->
            msg = maybe_set_from_me(msg, my_name)

            case import_message(msg, with_embeddings, user_only) do
              {:ok, _} ->
                %{acc | messages: acc.messages + 1}

              {:skipped, _} ->
                %{acc | skipped: acc.skipped + 1}

              {:error, reason} ->
                Logger.debug("Failed to import message: #{inspect(reason)}")
                %{acc | errors: acc.errors + 1}
            end
          end)

        Logger.info("Imported #{stats.messages} messages (#{stats.skipped} skipped, #{stats.errors} errors)")
        {:ok, Map.put(stats, :sessions, 1)}

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  @doc """
  Imports all .txt files from a directory.

  ## Options
  Same as `import_file/2`.
  """
  @spec import_directory(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_directory(dir_path, opts \\ []) do
    case File.ls(dir_path) do
      {:ok, files} ->
        txt_files =
          files
          |> Enum.filter(&String.ends_with?(&1, ".txt"))
          |> Enum.map(&Path.join(dir_path, &1))

        Logger.info("Found #{length(txt_files)} export files in #{dir_path}")

        stats =
          Enum.reduce(txt_files, %{files: 0, messages: 0, skipped: 0, errors: 0}, fn file, acc ->
            case import_file(file, opts) do
              {:ok, file_stats} ->
                %{
                  acc
                  | files: acc.files + 1,
                    messages: acc.messages + file_stats.messages,
                    skipped: acc.skipped + file_stats.skipped,
                    errors: acc.errors + file_stats.errors
                }

              {:error, reason} ->
                Logger.warning("Failed to import #{file}: #{inspect(reason)}")
                %{acc | errors: acc.errors + 1}
            end
          end)

        {:ok, Map.put(stats, :sessions, stats.files)}

      {:error, reason} ->
        {:error, {:dir_read_failed, reason}}
    end
  end

  @doc """
  Lists export files in a directory.
  """
  @spec list_exports(String.t()) :: [String.t()]
  def list_exports(dir_path) do
    case File.ls(dir_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".txt"))
        |> Enum.map(&Path.join(dir_path, &1))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  # --- Private Functions ---

  defp parse_messages(lines, chat_name) do
    lines
    |> Enum.reduce({[], nil}, fn line, {messages, current} ->
      case parse_line(line) do
        {:ok, parsed} ->
          # New message - save current if exists
          msg = build_message(parsed, chat_name)
          messages = if current, do: [current | messages], else: messages
          {messages, msg}

        :continuation when current != nil ->
          # Continuation of previous message
          updated = %{current | content: current.content <> "\n" <> String.trim(line)}
          {messages, updated}

        _ ->
          {messages, current}
      end
    end)
    |> then(fn {messages, current} ->
      # Don't forget the last message
      if current, do: [current | messages], else: messages
    end)
    |> Enum.reverse()
    |> Enum.reject(&system_message?/1)
  end

  defp parse_line(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        :empty

      match = Regex.run(@pattern_us, line) ->
        [_, date, time, sender, content] = match
        {:ok, %{date: date, time: time, sender: sender, content: content, format: :us}}

      match = Regex.run(@pattern_eu, line) ->
        [_, date, time, sender, content] = match
        {:ok, %{date: date, time: time, sender: sender, content: content, format: :eu}}

      match = Regex.run(@pattern_iso, line) ->
        [_, date, time, sender, content] = match
        {:ok, %{date: date, time: time, sender: sender, content: content, format: :iso}}

      true ->
        :continuation
    end
  end

  defp build_message(parsed, chat_name) do
    timestamp = parse_timestamp(parsed.date, parsed.time, parsed.format)
    message_id = generate_message_id(chat_name, timestamp, parsed.sender)

    %{
      message_id: message_id,
      chat_jid: "export:#{slugify(chat_name)}",
      chat_name: chat_name,
      sender_jid: "export:#{slugify(parsed.sender)}",
      sender_name: parsed.sender,
      content: parsed.content,
      message_type: detect_message_type(parsed.content),
      is_from_me: false,
      is_group: String.contains?(chat_name, "group") or String.contains?(chat_name, "Group"),
      timestamp: timestamp,
      raw_data: %{source: "whatsapp_export", original: parsed}
    }
  end

  defp parse_timestamp(date_str, time_str, format) do
    # Parse date components based on format
    {year, month, day} = parse_date(date_str, format)
    {hour, minute, second} = parse_time(time_str)

    case NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> DateTime.utc_now()
    end
  rescue
    _ -> DateTime.utc_now()
  end

  defp parse_date(date_str, format) do
    parts = String.split(date_str, ~r/[\/\-]/)
    |> Enum.map(&String.to_integer/1)

    case {format, parts} do
      {:us, [m, d, y]} -> {normalize_year(y), m, d}
      {:eu, [d, m, y]} -> {normalize_year(y), m, d}
      {:iso, [y, m, d]} -> {normalize_year(y), m, d}
      _ -> {2024, 1, 1}
    end
  end

  defp normalize_year(y) when y < 100, do: 2000 + y
  defp normalize_year(y), do: y

  defp parse_time(time_str) do
    # Handle AM/PM
    is_pm = String.contains?(String.downcase(time_str), "pm")
    is_am = String.contains?(String.downcase(time_str), "am")

    # Extract numbers
    parts = Regex.scan(~r/\d+/, time_str)
    |> List.flatten()
    |> Enum.map(&String.to_integer/1)

    case parts do
      [h, m, s] ->
        hour = convert_12h(h, is_am, is_pm)
        {hour, m, s}
      [h, m] ->
        hour = convert_12h(h, is_am, is_pm)
        {hour, m, 0}
      _ ->
        {0, 0, 0}
    end
  end

  defp convert_12h(hour, true, false) when hour == 12, do: 0
  defp convert_12h(hour, true, false), do: hour
  defp convert_12h(hour, false, true) when hour == 12, do: 12
  defp convert_12h(hour, false, true), do: hour + 12
  defp convert_12h(hour, _, _), do: hour

  defp generate_message_id(chat_name, timestamp, sender) do
    hash_input = "#{chat_name}:#{DateTime.to_unix(timestamp)}:#{sender}"
    :crypto.hash(:sha256, hash_input) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp detect_message_type(content) do
    cond do
      String.contains?(content, "<Media omitted>") -> :other
      String.contains?(content, "image omitted") -> :image
      String.contains?(content, "video omitted") -> :video
      String.contains?(content, "audio omitted") -> :audio
      String.contains?(content, "document omitted") -> :document
      String.contains?(content, "sticker omitted") -> :sticker
      true -> :text
    end
  end

  defp system_message?(msg) do
    Enum.any?(@system_patterns, fn pattern ->
      Regex.match?(pattern, msg.content)
    end)
  end

  defp maybe_set_from_me(msg, nil), do: msg
  defp maybe_set_from_me(msg, my_name) do
    is_me = String.downcase(msg.sender_name) == String.downcase(my_name)
    %{msg | is_from_me: is_me}
  end

  defp derive_chat_name(file_path) do
    file_path
    |> Path.basename(".txt")
    |> String.replace(~r/^WhatsApp Chat (with |-)?\s*/i, "")
    |> String.trim()
  end

  defp import_message(attrs, with_embeddings, user_only) do
    # Skip empty content
    if String.trim(attrs.content) == "" do
      {:skipped, :empty_content}
    else
      # Insert into whatsapp_messages table
      message_result =
        %WhatsAppMessage{}
        |> WhatsAppMessage.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:message_id])

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
  end

  defp should_create_data_source?(attrs, user_only) do
    content = attrs.content || ""
    has_content = String.trim(content) != ""
    is_from_me = attrs.is_from_me == true

    has_content and (not user_only or is_from_me)
  end

  defp create_data_source(message, attrs, with_embeddings) do
    source_attrs = %{
      source_type: :whatsapp,
      source_id: "whatsapp:export:#{message.message_id}",
      raw_content: attrs.content,
      processed_content: attrs.content,
      source_timestamp: attrs.timestamp,
      metadata: %{
        message_id: message.message_id,
        chat_name: attrs.chat_name,
        sender_name: attrs.sender_name,
        is_from_me: attrs.is_from_me,
        is_group: attrs.is_group,
        source: "whatsapp_export"
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
