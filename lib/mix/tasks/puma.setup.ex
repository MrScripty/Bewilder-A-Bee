defmodule Mix.Tasks.Puma.Setup do
  @moduledoc """
  Sets up the database for PumaBot.

  Prerequisites (handled by launcher.sh):
  - PostgreSQL must be running
  - Database user must exist

  This task will:
  1. Create the database
  2. Enable pgvector extension
  3. Run migrations

  Usage:
      ./launcher.sh setup    # Full setup including PostgreSQL
      mix puma.setup         # Database setup only (postgres must be running)
  """

  use Mix.Task

  @shortdoc "Sets up database for PumaBot (use ./launcher.sh setup for full setup)"

  @impl Mix.Task
  def run(args) do
    # Check if called with --check-prereqs flag (used by launcher.sh)
    if "--check-prereqs" in args do
      check_prerequisites()
    else
      run_setup()
    end
  end

  defp run_setup do
    Mix.shell().info("🐆 PumaBot Database Setup")
    Mix.shell().info("=========================")

    with :ok <- verify_postgres_running(),
         :ok <- verify_postgres_user(),
         :ok <- create_database(),
         :ok <- enable_pgvector(),
         :ok <- run_migrations() do
      Mix.shell().info("")
      Mix.shell().info("✅ Database setup complete!")
    else
      {:error, reason} ->
        Mix.shell().error("")
        Mix.shell().error("❌ Setup failed: #{reason}")
        exit({:shutdown, 1})
    end
  end

  defp check_prerequisites do
    postgres_ok = postgres_running?()
    user_ok = user_exists?()

    results = %{
      postgres_running: postgres_ok,
      user_exists: user_ok
    }

    # Output as parseable format for launcher.sh
    IO.puts("PREREQ_CHECK:#{inspect(results)}")

    unless postgres_ok and user_ok do
      exit({:shutdown, 1})
    end
  end

  defp verify_postgres_running do
    Mix.shell().info("")
    Mix.shell().info("📊 Checking PostgreSQL...")

    if postgres_running?() do
      Mix.shell().info("   ✓ PostgreSQL is running")
      :ok
    else
      {:error, """
      PostgreSQL is not running.

      Please run: ./launcher.sh setup
      Or manually: sudo systemctl enable --now postgresql
      """}
    end
  end

  defp verify_postgres_user do
    Mix.shell().info("")
    Mix.shell().info("👤 Checking database user...")

    username = current_username()

    if user_exists?() do
      Mix.shell().info("   ✓ User '#{username}' exists")
      :ok
    else
      {:error, """
      Database user '#{username}' does not exist.

      Please run: ./launcher.sh setup
      Or manually: sudo -u postgres createuser -s #{username}
      """}
    end
  end

  defp create_database do
    Mix.shell().info("")
    Mix.shell().info("🗄️  Creating database...")

    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)

    try do
      Mix.Task.run("ecto.create", ["--quiet"])
      Mix.shell().info("   ✓ Database created")
      :ok
    rescue
      e in Mix.Error ->
        if String.contains?(Exception.message(e), "already exists") do
          Mix.shell().info("   ✓ Database already exists")
          :ok
        else
          {:error, "Failed to create database: #{Exception.message(e)}"}
        end

      e ->
        {:error, "Failed to create database: #{inspect(e)}"}
    end
  end

  defp enable_pgvector do
    Mix.shell().info("")
    Mix.shell().info("🔢 Enabling pgvector extension...")

    config = Application.get_env(:puma_bot, PumaBot.Repo)

    case Postgrex.start_link(config) do
      {:ok, conn} ->
        result =
          case Postgrex.query(conn, "CREATE EXTENSION IF NOT EXISTS vector", []) do
            {:ok, _} ->
              Mix.shell().info("   ✓ pgvector extension enabled")
              :ok

            {:error, %Postgrex.Error{postgres: %{code: :undefined_file}}} ->
              {:error, """
              pgvector extension is not installed.

              Please run: ./launcher.sh setup
              Or manually: sudo apt install postgresql-16-pgvector
              """}

            {:error, error} ->
              {:error, "Failed to enable pgvector: #{inspect(error)}"}
          end

        GenServer.stop(conn)
        result

      {:error, error} ->
        {:error, "Failed to connect to database: #{inspect(error)}"}
    end
  end

  defp run_migrations do
    Mix.shell().info("")
    Mix.shell().info("📋 Running migrations...")

    try do
      Mix.Task.run("ecto.migrate")
      Mix.shell().info("   ✓ Migrations complete")
      :ok
    rescue
      e ->
        {:error, "Migration failed: #{Exception.message(e)}"}
    end
  end

  # --- Helpers ---

  defp postgres_running? do
    case System.cmd("systemctl", ["is-active", "postgresql"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp user_exists? do
    username = current_username()

    case System.cmd("psql", ["-U", username, "-d", "postgres", "-c", "SELECT 1"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp current_username do
    System.get_env("USER") || System.get_env("USERNAME") || "postgres"
  end
end
