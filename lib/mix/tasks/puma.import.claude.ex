defmodule Mix.Tasks.Puma.Import.Claude do
  @moduledoc """
  Imports Claude Code conversations from ~/.claude/projects/

  This task parses JSONL conversation files and stores them in the database
  for RAG retrieval. User messages are also stored in the unified data_sources
  table for embedding and similarity search.

  ## Usage

      # Import all projects
      mix puma.import.claude

      # Import a specific project (by name or full path)
      mix puma.import.claude --project puma-bot
      mix puma.import.claude --project /home/user/.claude/projects/-path-to-project

      # Import a single session file
      mix puma.import.claude --session /path/to/session.jsonl

      # Generate embeddings during import (requires Ollama running)
      mix puma.import.claude --with-embeddings

      # Include assistant messages in data sources (not just user messages)
      mix puma.import.claude --include-assistant

      # List available projects without importing
      mix puma.import.claude --list

  ## Options

    * `--project` - Import only the specified project
    * `--session` - Import only the specified session file
    * `--with-embeddings` - Generate embeddings during import
    * `--include-assistant` - Store assistant messages in data_sources too
    * `--list` - List available projects and exit
    * `--dry-run` - Show what would be imported without actually importing
  """

  use Mix.Task

  alias PumaBot.Importers.ClaudeImporter

  @shortdoc "Import Claude Code conversations for RAG"

  @switches [
    project: :string,
    session: :string,
    with_embeddings: :boolean,
    include_assistant: :boolean,
    list: :boolean,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} = OptionParser.parse(args, switches: @switches)

    # Start the application (needed for Repo)
    Mix.Task.run("app.start")

    cond do
      opts[:list] ->
        list_projects()

      opts[:dry_run] ->
        dry_run(opts)

      opts[:session] ->
        import_session(opts[:session], opts)

      opts[:project] ->
        import_project(opts[:project], opts)

      true ->
        import_all(opts)
    end
  end

  defp list_projects do
    Mix.shell().info("")
    Mix.shell().info("Claude Code Projects")
    Mix.shell().info("====================")
    Mix.shell().info("")

    projects = ClaudeImporter.list_projects()

    if Enum.empty?(projects) do
      Mix.shell().info("No projects found in #{ClaudeImporter.projects_dir()}")
    else
      Mix.shell().info("Found #{length(projects)} projects:\n")

      Enum.each(projects, fn {name, path} ->
        sessions = ClaudeImporter.list_sessions(path)
        Mix.shell().info("  #{name}")
        Mix.shell().info("    Sessions: #{length(sessions)}")
      end)
    end

    Mix.shell().info("")
  end

  defp dry_run(opts) do
    Mix.shell().info("")
    Mix.shell().info("Dry Run - No changes will be made")
    Mix.shell().info("==================================")
    Mix.shell().info("")

    projects = ClaudeImporter.list_projects()

    total_sessions =
      Enum.reduce(projects, 0, fn {name, path}, count ->
        sessions = ClaudeImporter.list_sessions(path)
        Mix.shell().info("#{name}: #{length(sessions)} sessions")
        count + length(sessions)
      end)

    Mix.shell().info("")
    Mix.shell().info("Would import #{length(projects)} projects with #{total_sessions} sessions")
    Mix.shell().info("Options: #{inspect(opts)}")
    Mix.shell().info("")
  end

  defp import_session(session_path, opts) do
    import_opts = build_import_opts(opts)

    Mix.shell().info("")
    Mix.shell().info("Importing session: #{session_path}")

    case ClaudeImporter.import_session(session_path, import_opts) do
      {:ok, stats} ->
        Mix.shell().info("  Imported #{stats.messages} messages (#{stats.errors} errors)")

      {:error, reason} ->
        Mix.shell().error("  Failed: #{inspect(reason)}")
    end

    print_summary()
  end

  defp import_project(project_input, opts) do
    import_opts = build_import_opts(opts)

    # Allow both project name and full path
    project_path = resolve_project_path(project_input)

    Mix.shell().info("")
    Mix.shell().info("Importing project: #{project_path}")

    {:ok, stats} = ClaudeImporter.import_project(project_path, import_opts)

    Mix.shell().info(
      "  Imported #{stats.sessions} sessions, #{stats.messages} messages (#{stats.errors} errors)"
    )

    print_summary()
  end

  defp import_all(opts) do
    import_opts = build_import_opts(opts)

    Mix.shell().info("")
    Mix.shell().info("Importing all Claude Code conversations")
    Mix.shell().info("========================================")
    Mix.shell().info("")

    {:ok, stats} = ClaudeImporter.import_all(import_opts)

    Mix.shell().info("")
    Mix.shell().info("Import complete!")
    Mix.shell().info("  Projects: #{stats.projects}")
    Mix.shell().info("  Sessions: #{stats.sessions}")
    Mix.shell().info("  Messages: #{stats.messages}")
    Mix.shell().info("  Errors: #{stats.errors}")

    print_summary()
  end

  defp build_import_opts(opts) do
    [
      with_embeddings: opts[:with_embeddings] || false,
      user_only: not (opts[:include_assistant] || false)
    ]
  end

  defp resolve_project_path(input) do
    if File.dir?(input) do
      input
    else
      # Treat as project name, look it up
      projects = ClaudeImporter.list_projects()

      case Enum.find(projects, fn {name, _path} ->
             name == input or String.contains?(name, input)
           end) do
        {_name, path} -> path
        nil -> input
      end
    end
  end

  defp print_summary do
    Mix.shell().info("")
    Mix.shell().info("Database Summary")
    Mix.shell().info("----------------")
    Mix.shell().info("  Conversations: #{ClaudeImporter.count_conversations()}")
    Mix.shell().info("  Data sources:  #{ClaudeImporter.count_data_sources()}")
    Mix.shell().info("")
  end
end
