defmodule PumaBot.Importers.ClaudeImporter do
  @moduledoc """
  Imports Claude Code conversations from ~/.claude/projects/ JSONL files.

  Claude Code stores conversation history as JSONL files, with each line
  containing a message or event. This importer parses these files and
  stores user/assistant messages in the database for RAG retrieval.

  ## Usage

      # List all available projects
      ClaudeImporter.list_projects()

      # Import all conversations
      ClaudeImporter.import_all()

      # Import a specific project
      ClaudeImporter.import_project("/home/user/.claude/projects/-path-to-project")

      # Import a single session file
      ClaudeImporter.import_session("/path/to/session.jsonl")
  """

  alias PumaBot.Data.{ClaudeConversation, DataSource}
  alias PumaBot.Repo

  require Logger

  @claude_projects_dir Path.expand("~/.claude/projects")

  # Message types we care about
  @message_types ["user", "assistant"]

  # --- Public API ---

  @doc """
  Returns the base directory for Claude Code projects.
  """
  def projects_dir, do: @claude_projects_dir

  @doc """
  Lists all project directories in ~/.claude/projects/

  Returns a list of {project_name, full_path} tuples.
  """
  @spec list_projects() :: [{String.t(), String.t()}]
  def list_projects do
    case File.ls(@claude_projects_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn name -> {name, Path.join(@claude_projects_dir, name)} end)
        |> Enum.filter(fn {_, path} -> File.dir?(path) end)
        |> Enum.sort()

      {:error, reason} ->
        Logger.warning("Could not list Claude projects: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Lists all JSONL session files in a project directory.

  Returns full paths to all .jsonl files, including those in subagent directories.

  ## Options
  - `:since` - Only return files modified after this DateTime (default: nil = all files)
  """
  @spec list_sessions(String.t(), keyword()) :: [String.t()]
  def list_sessions(project_path, opts \\ []) do
    since = Keyword.get(opts, :since)

    project_path
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
    |> filter_by_mtime(since)
    |> Enum.sort()
  end

  defp filter_by_mtime(files, nil), do: files

  defp filter_by_mtime(files, since) do
    since_posix = DateTime.to_unix(since)

    Enum.filter(files, fn file ->
      case File.stat(file, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime > since_posix
        _ -> true
      end
    end)
  end

  @doc """
  Imports all Claude Code conversations from all projects.

  ## Options
  - `:with_embeddings` - Generate embeddings during import (default: false)
  - `:user_only` - Only import user messages to DataSource (default: true)
  - `:since` - Only import files modified after this DateTime (default: nil = all)
  - `:quiet` - Suppress info logging (default: false)

  Returns {:ok, stats} with import statistics.
  """
  @spec import_all(keyword()) :: {:ok, map()} | {:error, term()}
  def import_all(opts \\ []) do
    projects = list_projects()
    quiet = Keyword.get(opts, :quiet, false)

    unless quiet do
      Logger.info("Found #{length(projects)} Claude Code projects")
    end

    stats =
      Enum.reduce(projects, %{projects: 0, sessions: 0, messages: 0, errors: 0}, fn {name, path},
                                                                                    acc ->
        unless quiet do
          Logger.info("Importing project: #{name}")
        end

        {:ok, project_stats} = import_project(path, opts)

        %{
          acc
          | projects: acc.projects + 1,
            sessions: acc.sessions + project_stats.sessions,
            messages: acc.messages + project_stats.messages,
            errors: acc.errors + project_stats.errors
        }
      end)

    unless quiet do
      Logger.info(
        "Import complete: #{stats.projects} projects, #{stats.sessions} sessions, #{stats.messages} messages"
      )
    end

    {:ok, stats}
  end

  @doc """
  Imports all sessions from a specific project directory.

  ## Options
  - `:with_embeddings` - Generate embeddings during import (default: false)
  - `:user_only` - Only import user messages to DataSource (default: true)
  - `:since` - Only import files modified after this DateTime (default: nil = all)
  """
  @spec import_project(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_project(project_path, opts \\ []) do
    since = Keyword.get(opts, :since)
    sessions = list_sessions(project_path, since: since)
    Logger.debug("Found #{length(sessions)} session files in #{project_path}")

    stats =
      Enum.reduce(sessions, %{sessions: 0, messages: 0, errors: 0}, fn session_path, acc ->
        case import_session(session_path, opts) do
          {:ok, session_stats} ->
            %{
              acc
              | sessions: acc.sessions + 1,
                messages: acc.messages + session_stats.messages,
                errors: acc.errors + session_stats.errors
            }

          {:error, reason} ->
            Logger.warning("Failed to import session #{session_path}: #{inspect(reason)}")
            %{acc | errors: acc.errors + 1}
        end
      end)

    {:ok, stats}
  end

  @doc """
  Imports a single JSONL session file.

  Parses the file line by line, extracting user and assistant messages,
  and stores them in the database.

  ## Options
  - `:with_embeddings` - Generate embeddings during import (default: false)
  - `:user_only` - Only import user messages to DataSource (default: true)
  """
  @spec import_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_session(session_path, opts \\ []) do
    with_embeddings = Keyword.get(opts, :with_embeddings, false)
    user_only = Keyword.get(opts, :user_only, true)

    # Extract session ID from filename
    session_id = Path.basename(session_path, ".jsonl")

    # Derive project path from the session path
    project_path = derive_project_path(session_path)

    case File.open(session_path, [:read, :utf8]) do
      {:ok, file} ->
        stats =
          file
          |> IO.stream(:line)
          |> Stream.with_index()
          |> Stream.map(fn {line, index} -> parse_line(line, index) end)
          |> Stream.filter(&filter_message/1)
          |> Stream.map(fn msg -> transform_message(msg, session_id, project_path) end)
          |> Enum.reduce(%{messages: 0, errors: 0}, fn msg_attrs, acc ->
            case insert_message(msg_attrs, with_embeddings, user_only) do
              {:ok, _} ->
                %{acc | messages: acc.messages + 1}

              {:error, reason} ->
                Logger.debug("Failed to insert message: #{inspect(reason)}")
                %{acc | errors: acc.errors + 1}
            end
          end)

        File.close(file)
        {:ok, stats}

      {:error, reason} ->
        {:error, {:file_open_failed, reason}}
    end
  end

  @doc """
  Counts how many conversations are stored in the database.
  """
  @spec count_conversations() :: non_neg_integer()
  def count_conversations do
    Repo.aggregate(ClaudeConversation, :count)
  end

  @doc """
  Counts how many Claude Code data sources are stored.
  """
  @spec count_data_sources() :: non_neg_integer()
  def count_data_sources do
    import Ecto.Query

    from(ds in DataSource, where: ds.source_type == :claude_code)
    |> Repo.aggregate(:count)
  end

  # --- Private Functions ---

  defp parse_line(line, index) do
    case Jason.decode(line) do
      {:ok, data} ->
        Map.put(data, "_line_index", index)

      {:error, _} ->
        nil
    end
  end

  defp filter_message(nil), do: false

  defp filter_message(%{"type" => type}) when type in @message_types, do: true
  defp filter_message(_), do: false

  defp transform_message(data, session_id, project_path) do
    %{
      session_id: data["sessionId"] || session_id,
      message_index: data["_line_index"],
      project_path: data["cwd"] || project_path,
      role: parse_role(data["type"]),
      content: extract_content(data),
      tool_calls: extract_tool_calls(data),
      tool_results: [],
      timestamp: parse_timestamp(data["timestamp"]),
      model: get_in(data, ["message", "model"]),
      raw_data: data
    }
  end

  defp parse_role("user"), do: :user
  defp parse_role("assistant"), do: :assistant
  defp parse_role(_), do: :system

  defp extract_content(data) do
    case get_in(data, ["message", "content"]) do
      content when is_list(content) ->
        content
        |> Enum.filter(fn item -> item["type"] == "text" end)
        |> Enum.map(fn item -> item["text"] || "" end)
        |> Enum.join("\n\n")

      content when is_binary(content) ->
        content

      _ ->
        ""
    end
  end

  defp extract_tool_calls(data) do
    case get_in(data, ["message", "content"]) do
      content when is_list(content) ->
        content
        |> Enum.filter(fn item -> item["type"] == "tool_use" end)
        |> Enum.map(fn item ->
          %{
            "id" => item["id"],
            "name" => item["name"],
            "input" => item["input"]
          }
        end)

      _ ->
        []
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp derive_project_path(session_path) do
    # Session files are at: ~/.claude/projects/{project-name}/{session-id}.jsonl
    # or in subagents: ~/.claude/projects/{project-name}/{session-id}/subagents/agent-xxx.jsonl
    session_path
    |> Path.dirname()
    |> String.replace(@claude_projects_dir <> "/", "")
    |> String.split("/")
    |> List.first()
  end

  defp insert_message(attrs, with_embeddings, user_only) do
    # Insert into claude_conversations table
    conversation_result =
      %ClaudeConversation{}
      |> ClaudeConversation.changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:session_id, :message_index]
      )

    # Also create DataSource entry for RAG (for user messages by default)
    case conversation_result do
      {:ok, conversation} ->
        if should_create_data_source?(attrs, user_only) do
          create_data_source(conversation, attrs, with_embeddings)
        end

        {:ok, conversation}

      {:error, _} = error ->
        error
    end
  end

  defp should_create_data_source?(attrs, user_only) do
    content = attrs[:content] || ""
    has_content = String.trim(content) != ""
    is_user = attrs[:role] == :user

    has_content and (not user_only or is_user)
  end

  defp create_data_source(conversation, attrs, with_embeddings) do
    source_attrs = %{
      source_type: :claude_code,
      source_id: "claude:#{conversation.session_id}:#{conversation.message_index}",
      raw_content: attrs[:content],
      processed_content: attrs[:content],
      source_timestamp: attrs[:timestamp],
      metadata: %{
        session_id: conversation.session_id,
        project_path: attrs[:project_path],
        role: Atom.to_string(attrs[:role]),
        model: attrs[:model]
      }
    }

    case %DataSource{}
         |> DataSource.changeset(source_attrs)
         |> Repo.insert(on_conflict: :nothing, conflict_target: [:source_type, :source_id]) do
      {:ok, data_source} ->
        if with_embeddings and data_source.id do
          # Generate embedding asynchronously or inline
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
