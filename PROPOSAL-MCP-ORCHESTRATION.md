# Proposal: HTTP MCP Server & Claude Code Orchestration

## Overview

Add two major capabilities to PumaBot:

1. **HTTP MCP Server** -- A Hermes MCP tool server that Claude Code connects to over HTTP, providing compile/test/run/docs tools so Claude Code can autonomously test and debug without asking the user to run commands.

2. **Claude Code Orchestrator** -- A terminal session manager that spawns multiple Claude Code CLI instances via PTYs, monitors their output, sends them tasks, and renders them in a LiveView grid dashboard using xterm.js.

Both components integrate with PumaBot's existing embeddings, data source pipeline, and LiveView UI.

---

## Architecture

```
PumaBot Application (OTP Supervision Tree)
|
+-- Existing Services
|   +-- PumaBot.Repo
|   +-- PumaBot.WhatsApp.Bridge
|   +-- PumaBot.ImportDaemon
|   +-- PumaBotWeb.Endpoint
|
+-- New: MCP Server
|   +-- PumaBot.MCP.Supervisor           (Supervisor)
|   +-- PumaBot.MCP.Server               (Hermes MCP GenServer)
|   +-- PumaBot.MCP.ToolRegistry         (tool definitions)
|
+-- New: Claude Code Orchestrator
    +-- PumaBot.Terminal.SessionSupervisor  (DynamicSupervisor)
    +-- PumaBot.Terminal.Session            (GenServer per PTY, like WhatsApp.Bridge)
    +-- PumaBot.Terminal.Orchestrator       (decision engine GenServer)
```

### Supervision Tree Addition

```elixir
# In PumaBot.Application.start/2, add:
children = [
  # ... existing children ...

  # MCP Server (Hermes MCP over HTTP)
  {PumaBot.MCP.Supervisor, []},

  # Terminal session management
  {PumaBot.Terminal.SessionSupervisor, []},

  # Orchestrator (optional, can be started manually)
  {PumaBot.Terminal.Orchestrator, []},
]
```

---

## Component 1: HTTP MCP Server

### Purpose

Provide tools that any Claude Code instance can call over HTTP. When Claude Code encounters a compile error or needs to run tests, it calls the MCP server directly instead of asking the user.

### Library

`hermes_mcp ~> 0.14` -- most mature Elixir MCP implementation, native HTTP transport support.

### Module Structure

```
lib/puma_bot/mcp/
  supervisor.ex          # Supervises the Hermes MCP server process
  server.ex              # Hermes.Server implementation, registers tools
  tools/
    compile.ex           # mix compile, returns structured errors/warnings
    test.ex              # mix test with path/tag filters
    run.ex               # mix run, captures output with timeout
    format.ex            # mix format --check-formatted
    lint.ex              # mix credo
    type_check.ex        # mix dialyzer
    docs_lookup.ex       # RAG search using existing Embeddings.Retriever
    project_info.ex      # Returns project structure, deps, config
```

### Tool Definitions

#### compile

Runs `mix compile` in a target project directory. Returns structured output.

```
Input:
  project_path: string (required) -- absolute path to mix project
  warnings_as_errors: boolean (optional, default false)

Output:
  status: "ok" | "error"
  errors: [{file, line, message}, ...]
  warnings: [{file, line, message}, ...]
  modules_compiled: integer
```

#### test

Runs `mix test` with optional filters.

```
Input:
  project_path: string (required)
  path: string (optional) -- specific test file or directory
  tags: [string] (optional) -- e.g. ["unit", "integration"]
  seed: integer (optional) -- for reproducibility
  max_failures: integer (optional, default 10)

Output:
  status: "passed" | "failed"
  passed: integer
  failed: integer
  excluded: integer
  duration_ms: integer
  failures: [{test_name, file, line, message, stacktrace}, ...]
```

#### run

Executes a mix command or script, captures output with timeout.

```
Input:
  project_path: string (required)
  command: string (required) -- e.g. "run lib/my_script.exs" or "ecto.migrate"
  timeout_ms: integer (optional, default 30000)
  env: map (optional) -- environment variables

Output:
  status: "ok" | "error" | "timeout"
  exit_code: integer
  stdout: string
  stderr: string
  duration_ms: integer
```

#### docs_lookup

Uses PumaBot's existing `Embeddings.Retriever` to search indexed documentation. Also searches local hex package docs and library source code.

```
Input:
  query: string (required) -- error message, module name, or concept
  source_types: [string] (optional) -- filter to specific doc sources
  limit: integer (optional, default 5)

Output:
  results: [{
    content: string,
    source: string,
    file_path: string | null,
    similarity: float
  }, ...]
```

#### project_info

Returns project metadata so Claude Code understands what it's working with.

```
Input:
  project_path: string (required)

Output:
  app_name: string
  elixir_version: string
  deps: [{name, version, hex?}, ...]
  contexts: [module_name, ...]
  test_files: [path, ...]
```

### MCP Server Implementation

```elixir
defmodule PumaBot.MCP.Server do
  use Hermes.Server,
    name: "puma-bot-mcp",
    version: "1.0.0",
    capabilities: [:tools]

  @impl true
  def init(_client_info, frame) do
    {:ok, frame
      |> register_tool("compile", PumaBot.MCP.Tools.Compile.definition())
      |> register_tool("test", PumaBot.MCP.Tools.Test.definition())
      |> register_tool("run", PumaBot.MCP.Tools.Run.definition())
      |> register_tool("format", PumaBot.MCP.Tools.Format.definition())
      |> register_tool("lint", PumaBot.MCP.Tools.Lint.definition())
      |> register_tool("type_check", PumaBot.MCP.Tools.TypeCheck.definition())
      |> register_tool("docs_lookup", PumaBot.MCP.Tools.DocsLookup.definition())
      |> register_tool("project_info", PumaBot.MCP.Tools.ProjectInfo.definition())}
  end

  @impl true
  def handle_tool(tool_name, args, frame) do
    module = tool_module(tool_name)
    result = module.execute(args)

    # Broadcast tool execution to LiveView dashboard for visibility
    Phoenix.PubSub.broadcast(
      PumaBot.PubSub,
      "mcp:tool_calls",
      {:tool_called, tool_name, args, result}
    )

    {:reply, Jason.encode!(result), frame}
  end

  defp tool_module("compile"), do: PumaBot.MCP.Tools.Compile
  defp tool_module("test"), do: PumaBot.MCP.Tools.Test
  defp tool_module("run"), do: PumaBot.MCP.Tools.Run
  defp tool_module("format"), do: PumaBot.MCP.Tools.Format
  defp tool_module("lint"), do: PumaBot.MCP.Tools.Lint
  defp tool_module("type_check"), do: PumaBot.MCP.Tools.TypeCheck
  defp tool_module("docs_lookup"), do: PumaBot.MCP.Tools.DocsLookup
  defp tool_module("project_info"), do: PumaBot.MCP.Tools.ProjectInfo
end
```

### Tool Implementation Pattern

Each tool module follows the same contract:

```elixir
defmodule PumaBot.MCP.Tools.Compile do
  @behaviour PumaBot.MCP.Tool

  @impl true
  def definition do
    %{
      description: "Compile an Elixir/Mix project and return structured errors and warnings",
      input_schema: %{
        type: "object",
        properties: %{
          project_path: %{type: "string", description: "Absolute path to mix project root"},
          warnings_as_errors: %{type: "boolean", description: "Treat warnings as errors"}
        },
        required: ["project_path"]
      }
    }
  end

  @impl true
  def execute(%{"project_path" => path} = args) do
    warnings_flag = if args["warnings_as_errors"], do: ["--warnings-as-errors"], else: []
    mix_args = ["compile", "--force" | warnings_flag]

    {output, exit_code} = System.cmd("mix", mix_args,
      cd: path,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "dev"}]
    )

    %{
      status: if(exit_code == 0, do: "ok", else: "error"),
      exit_code: exit_code,
      output: output,
      errors: parse_errors(output),
      warnings: parse_warnings(output)
    }
  end

  defp parse_errors(output) do
    # Parse "** (CompileError) file.ex:line: message" patterns
    Regex.scan(~r/\*\* \((\w+)\) (.+):(\d+):?\s*(.+)/, output)
    |> Enum.map(fn [_, type, file, line, msg] ->
      %{type: type, file: file, line: String.to_integer(line), message: msg}
    end)
  end

  defp parse_warnings(output) do
    Regex.scan(~r/warning: (.+)\n\s+(.+):(\d+)/, output)
    |> Enum.map(fn [_, msg, file, line] ->
      %{file: file, line: String.to_integer(line), message: msg}
    end)
  end
end
```

### Tool Behaviour

```elixir
defmodule PumaBot.MCP.Tool do
  @callback definition() :: map()
  @callback execute(args :: map()) :: map()
end
```

### Claude Code Registration

Once the MCP server is running (on the PumaBot Phoenix port or a dedicated port):

```bash
# Register with Claude Code (user-scoped, available everywhere)
claude mcp add --transport http puma-bot-mcp http://localhost:4000/mcp

# Or project-scoped via .mcp.json in any project:
# {
#   "mcpServers": {
#     "puma-bot-mcp": {
#       "type": "http",
#       "url": "http://localhost:4000/mcp"
#     }
#   }
# }
```

### Router Addition

The MCP HTTP endpoint can be mounted alongside the existing Phoenix routes:

```elixir
# In router.ex -- Hermes MCP handles its own Plug pipeline
# Exact integration depends on Hermes MCP's Plug adapter
scope "/mcp", PumaBotWeb do
  pipe_through :api
  # Hermes MCP Plug adapter mounts here
  forward "/", PumaBot.MCP.Plug
end
```

### Security

Since this runs locally on your machine:

- Bind to `localhost` only (already the Phoenix default in dev)
- No authentication needed for local-only access
- Restrict `project_path` arguments to a configurable allowlist of directories to prevent arbitrary command execution outside your projects
- Timeout all tool executions (default 30s, configurable per tool)

---

## Component 2: Terminal Session Manager

### Purpose

Spawn and manage multiple Claude Code CLI sessions as PTY (pseudo-terminal) processes. Each session is a GenServer that holds a PTY handle, reads output, and can receive input. Follows the same pattern as `PumaBot.WhatsApp.Bridge`.

### Module Structure

```
lib/puma_bot/terminal/
  session_supervisor.ex    # DynamicSupervisor for session GenServers
  session.ex               # GenServer per Claude Code PTY session
  output_parser.ex         # Parse Claude Code terminal output into events
  orchestrator.ex          # Decision engine (Component 3)
```

### Session Supervisor

```elixir
defmodule PumaBot.Terminal.SessionSupervisor do
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(opts) do
    spec = {PumaBot.Terminal.Session, opts}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_session(session_id) do
    case Registry.lookup(PumaBot.Terminal.Registry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  def list_sessions do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> GenServer.call(pid, :status) end)
  end
end
```

### Session GenServer

Each session manages one Claude Code CLI process via a PTY.

```elixir
defmodule PumaBot.Terminal.Session do
  use GenServer, restart: :temporary
  require Logger

  defstruct [
    :id,              # unique session identifier (UUID)
    :pty,             # PTY port/handle
    :os_pid,          # OS process ID
    :project_path,    # working directory
    :status,          # :idle | :running | :waiting_input | :completed | :error
    :task,            # current task description
    :output_buffer,   # rolling buffer of terminal output
    :created_at,
    :started_at
  ]

  # --- Public API ---

  def start_link(opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    GenServer.start_link(__MODULE__, Keyword.put(opts, :id, id),
      name: {:via, Registry, {PumaBot.Terminal.Registry, id}})
  end

  @doc "Send a task/prompt to the Claude Code session"
  def send_input(session_id, text) do
    call(session_id, {:send_input, text})
  end

  @doc "Send raw keystrokes (e.g. Ctrl+C)"
  def send_key(session_id, key) do
    call(session_id, {:send_key, key})
  end

  @doc "Get current session status and recent output"
  def status(session_id) do
    call(session_id, :status)
  end

  @doc "Get full output buffer"
  def get_output(session_id) do
    call(session_id, :get_output)
  end

  @doc "Stop this session and kill the Claude Code process"
  def stop(session_id) do
    call(session_id, :stop)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    project_path = Keyword.get(opts, :project_path, File.cwd!())
    task = Keyword.get(opts, :task)

    state = %__MODULE__{
      id: id,
      project_path: project_path,
      status: :idle,
      task: task,
      output_buffer: [],
      created_at: DateTime.utc_now()
    }

    # If a task was provided, start Claude Code immediately
    state = if task do
      start_claude(state, task)
    else
      state
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      id: state.id,
      status: state.status,
      project_path: state.project_path,
      task: state.task,
      os_pid: state.os_pid,
      created_at: state.created_at,
      started_at: state.started_at,
      output_lines: length(state.output_buffer)
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_output, _from, state) do
    {:reply, Enum.reverse(state.output_buffer), state}
  end

  @impl true
  def handle_call({:send_input, text}, _from, state) do
    case state.pty do
      nil ->
        # No PTY yet, start Claude Code with this as the task
        state = start_claude(state, text)
        {:reply, :ok, state}
      pty ->
        # Write to existing PTY
        ExPTY.write(pty, text <> "\n")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:send_key, :ctrl_c}, _from, %{pty: pty} = state) when not is_nil(pty) do
    ExPTY.write(pty, <<3>>)  # Ctrl+C = ETX
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    state = kill_process(state)
    {:reply, :ok, %{state | status: :completed}}
  end

  # PTY output arrives as messages
  @impl true
  def handle_info({:pty_data, data}, state) do
    # Buffer output
    lines = String.split(data, "\n")
    state = %{state | output_buffer: Enum.reverse(lines) ++ state.output_buffer}

    # Broadcast raw output to LiveView terminal via PubSub
    Phoenix.PubSub.broadcast(
      PumaBot.PubSub,
      "terminal:#{state.id}",
      {:terminal_output, state.id, data}
    )

    # Parse for status changes
    state = PumaBot.Terminal.OutputParser.update_status(state, data)

    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_exit, exit_code}, state) do
    Logger.info("[Session #{state.id}] Claude Code exited with code #{exit_code}")

    Phoenix.PubSub.broadcast(
      PumaBot.PubSub,
      "terminal:#{state.id}",
      {:terminal_exit, state.id, exit_code}
    )

    # Notify orchestrator
    Phoenix.PubSub.broadcast(
      PumaBot.PubSub,
      "orchestrator:events",
      {:session_completed, state.id, exit_code}
    )

    {:noreply, %{state | status: :completed, pty: nil, os_pid: nil}}
  end

  # --- Private ---

  defp start_claude(state, task) do
    claude_path = System.find_executable("claude") || "/usr/local/bin/claude"

    # Start Claude Code in non-interactive print mode for scripted use,
    # or interactive mode if we want to send follow-up input
    args = ["--print", "--output-format", "text", task]

    {:ok, pty} = ExPTY.spawn(claude_path, args,
      cd: state.project_path,
      env: %{
        "TERM" => "xterm-256color",
        "COLUMNS" => "200",
        "LINES" => "50"
      }
    )

    os_pid = ExPTY.os_pid(pty)
    Logger.info("[Session #{state.id}] Started Claude Code (PID #{os_pid}) in #{state.project_path}")

    %{state |
      pty: pty,
      os_pid: os_pid,
      status: :running,
      task: task,
      started_at: DateTime.utc_now()
    }
  end

  defp kill_process(%{os_pid: nil} = state), do: state
  defp kill_process(%{pty: pty, os_pid: os_pid} = state) do
    Logger.info("[Session #{state.id}] Killing Claude Code (PID #{os_pid})")
    ExPTY.kill(pty)
    %{state | pty: nil, os_pid: nil}
  end

  defp call(session_id, message) do
    case Registry.lookup(PumaBot.Terminal.Registry, session_id) do
      [{pid, _}] -> GenServer.call(pid, message)
      [] -> {:error, :not_found}
    end
  end
end
```

### Output Parser

Parses Claude Code's terminal output to detect state changes.

```elixir
defmodule PumaBot.Terminal.OutputParser do
  @moduledoc """
  Parses Claude Code CLI output to detect status changes, tool calls,
  questions, completions, and errors.
  """

  def update_status(state, data) do
    cond do
      # Claude is waiting for user input
      String.contains?(data, "> ") and String.ends_with?(String.trim(data), ">") ->
        %{state | status: :waiting_input}

      # Claude finished its task
      String.contains?(data, "Task completed") or String.contains?(data, "Done.") ->
        %{state | status: :completed}

      # Error state
      String.contains?(data, "Error:") or String.contains?(data, "error") ->
        %{state | status: :error}

      true ->
        state
    end
  end

  @doc "Extract structured events from raw output"
  def parse_events(data) do
    # Returns list of events detected in this output chunk
    events = []

    events = if String.contains?(data, "tool/") do
      [{:tool_call, extract_tool_name(data)} | events]
    else
      events
    end

    events = if Regex.match?(~r/\d+ passed.*\d+ failed/, data) do
      [{:test_results, parse_test_summary(data)} | events]
    else
      events
    end

    Enum.reverse(events)
  end

  defp extract_tool_name(data) do
    case Regex.run(~r/tool\/(\w+)/, data) do
      [_, name] -> name
      _ -> "unknown"
    end
  end

  defp parse_test_summary(data) do
    case Regex.run(~r/(\d+) passed.*?(\d+) failed/, data) do
      [_, passed, failed] ->
        %{passed: String.to_integer(passed), failed: String.to_integer(failed)}
      _ ->
        %{}
    end
  end
end
```

### Registry

Add to supervision tree for session name lookup:

```elixir
# In PumaBot.Application
{Registry, keys: :unique, name: PumaBot.Terminal.Registry}
```

---

## Component 3: Orchestrator Agent

### Purpose

The orchestrator is a GenServer that manages the lifecycle of terminal sessions, assigns tasks, monitors results, and decides what to do next. It listens for session events via PubSub and can be controlled from the LiveView UI.

### Module

```elixir
defmodule PumaBot.Terminal.Orchestrator do
  use GenServer
  require Logger

  defstruct [
    :mode,             # :manual | :auto
    :task_queue,       # list of pending tasks
    :active_sessions,  # map of session_id => task info
    :max_concurrent,   # max parallel sessions
    :project_path,     # default project path
    :history           # completed task log
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queue a task for execution"
  def queue_task(task_description, opts \\ []) do
    GenServer.call(__MODULE__, {:queue_task, task_description, opts})
  end

  @doc "Queue multiple tasks"
  def queue_tasks(tasks) do
    GenServer.call(__MODULE__, {:queue_tasks, tasks})
  end

  @doc "Get orchestrator status"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Set operating mode"
  def set_mode(mode) when mode in [:manual, :auto] do
    GenServer.cast(__MODULE__, {:set_mode, mode})
  end

  @doc "Set max concurrent sessions"
  def set_concurrency(n) when is_integer(n) and n > 0 do
    GenServer.cast(__MODULE__, {:set_concurrency, n})
  end

  @doc "Cancel all queued tasks"
  def clear_queue do
    GenServer.cast(__MODULE__, :clear_queue)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    # Subscribe to session lifecycle events
    Phoenix.PubSub.subscribe(PumaBot.PubSub, "orchestrator:events")

    state = %__MODULE__{
      mode: Keyword.get(opts, :mode, :manual),
      task_queue: [],
      active_sessions: %{},
      max_concurrent: Keyword.get(opts, :max_concurrent, 3),
      project_path: Keyword.get(opts, :project_path, File.cwd!()),
      history: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:queue_task, description, opts}, _from, state) do
    task = %{
      id: Ecto.UUID.generate(),
      description: description,
      project_path: Keyword.get(opts, :project_path, state.project_path),
      queued_at: DateTime.utc_now()
    }

    state = %{state | task_queue: state.task_queue ++ [task]}

    # In auto mode, try to start immediately
    state = maybe_start_next(state)

    {:reply, {:ok, task.id}, state}
  end

  @impl true
  def handle_call({:queue_tasks, tasks}, _from, state) do
    new_tasks = Enum.map(tasks, fn {desc, opts} ->
      %{
        id: Ecto.UUID.generate(),
        description: desc,
        project_path: Keyword.get(opts, :project_path, state.project_path),
        queued_at: DateTime.utc_now()
      }
    end)

    state = %{state | task_queue: state.task_queue ++ new_tasks}
    state = maybe_start_next(state)

    ids = Enum.map(new_tasks, & &1.id)
    {:reply, {:ok, ids}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      mode: state.mode,
      queued: length(state.task_queue),
      active: map_size(state.active_sessions),
      max_concurrent: state.max_concurrent,
      completed: length(state.history),
      queue: state.task_queue,
      sessions: state.active_sessions
    }
    {:reply, status, state}
  end

  @impl true
  def handle_cast({:set_mode, mode}, state) do
    state = %{state | mode: mode}
    state = maybe_start_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_concurrency, n}, state) do
    state = %{state | max_concurrent: n}
    state = maybe_start_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear_queue, state) do
    {:noreply, %{state | task_queue: []}}
  end

  # Session completed event from PubSub
  @impl true
  def handle_info({:session_completed, session_id, exit_code}, state) do
    case Map.pop(state.active_sessions, session_id) do
      {nil, _} ->
        {:noreply, state}

      {task_info, active_sessions} ->
        entry = Map.merge(task_info, %{
          completed_at: DateTime.utc_now(),
          exit_code: exit_code
        })

        Logger.info("[Orchestrator] Session #{session_id} completed (exit #{exit_code}): #{task_info.description}")

        # Broadcast to LiveView
        Phoenix.PubSub.broadcast(
          PumaBot.PubSub,
          "orchestrator:status",
          {:task_completed, entry}
        )

        state = %{state |
          active_sessions: active_sessions,
          history: [entry | state.history]
        }

        # Start next task if available
        state = maybe_start_next(state)

        {:noreply, state}
    end
  end

  # --- Private ---

  defp maybe_start_next(%{mode: :manual} = state), do: state
  defp maybe_start_next(%{task_queue: []} = state), do: state
  defp maybe_start_next(state) do
    if map_size(state.active_sessions) < state.max_concurrent do
      [task | rest] = state.task_queue

      case PumaBot.Terminal.SessionSupervisor.start_session(
        project_path: task.project_path,
        task: task.description
      ) do
        {:ok, _pid} ->
          # The session registers itself via Registry, we track by task id
          session_id = task.id

          active = Map.put(state.active_sessions, session_id, %{
            description: task.description,
            project_path: task.project_path,
            started_at: DateTime.utc_now()
          })

          state = %{state | task_queue: rest, active_sessions: active}

          # Try to start more if slots available
          maybe_start_next(state)

        {:error, reason} ->
          Logger.error("[Orchestrator] Failed to start session: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end
end
```

### Orchestrator Modes

- **Manual** -- tasks are queued but only started when the user clicks "Start" in the UI or calls `Orchestrator.start_next/0`. Lets you review before launching.
- **Auto** -- tasks start automatically up to `max_concurrent` limit. New tasks start as sessions complete. Fully autonomous pipeline.

---

## Component 4: Terminal Dashboard UI

### Purpose

A LiveView page showing a grid of Claude Code terminal sessions rendered with xterm.js. Each cell shows a live terminal, session status, and controls (stop, send input, detach).

### Routes

```elixir
# In router.ex
scope "/", PumaBotWeb do
  pipe_through :browser

  # Existing
  live "/", ChatBrowserLive, :index
  live "/chat/:source/:id", ChatBrowserLive, :show

  # New
  live "/terminals", TerminalDashboardLive, :index
end
```

### LiveView

```
lib/puma_bot_web/live/
  terminal_dashboard_live.ex     # Main grid view
```

### Dashboard Features

- **Grid layout** -- CSS grid of terminal panels, configurable columns (1x1, 2x2, 3x2, etc.)
- **Live terminal rendering** -- each cell embeds xterm.js connected via Phoenix Channel
- **Session controls** per panel:
  - Stop session (kill Claude Code process)
  - Send text input (type into Claude Code)
  - Fullscreen a single panel
  - Scroll output history
- **Orchestrator controls** in a sidebar/toolbar:
  - Task queue display (pending, active, completed)
  - Add new task (text input)
  - Start/stop auto mode
  - Set concurrency limit
  - Clear queue
- **MCP tool call log** -- live feed of MCP tool invocations across all sessions
- **Status indicators** per session: idle (grey), running (blue), waiting input (yellow), error (red), completed (green)

### Phoenix Channel for Terminal Streaming

```elixir
defmodule PumaBotWeb.TerminalChannel do
  use Phoenix.Channel

  @impl true
  def join("terminal:" <> session_id, _params, socket) do
    # Subscribe to this session's output
    Phoenix.PubSub.subscribe(PumaBot.PubSub, "terminal:#{session_id}")

    # Send buffered output history
    case PumaBot.Terminal.Session.get_output(session_id) do
      {:error, :not_found} ->
        {:error, %{reason: "session not found"}}
      lines ->
        {:ok, %{history: Enum.join(lines, "\n")}, assign(socket, :session_id, session_id)}
    end
  end

  # Forward PTY output to xterm.js
  @impl true
  def handle_info({:terminal_output, _id, data}, socket) do
    push(socket, "output", %{data: data})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:terminal_exit, _id, code}, socket) do
    push(socket, "exit", %{code: code})
    {:noreply, socket}
  end

  # Receive input from xterm.js
  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    PumaBot.Terminal.Session.send_input(socket.assigns.session_id, data)
    {:noreply, socket}
  end
end
```

### JavaScript: xterm.js Integration

```
assets/js/terminal_hook.js
```

```javascript
import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"

const TerminalHook = {
  mounted() {
    const sessionId = this.el.dataset.sessionId

    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
      theme: {
        background: "#1e1e2e",
        foreground: "#cdd6f4",
        cursor: "#f5e0dc"
      }
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(this.el)
    this.fitAddon.fit()

    // Join the Phoenix channel for this session
    this.channel = window.liveSocket.socket.channel(`terminal:${sessionId}`, {})

    this.channel.on("output", ({ data }) => {
      this.term.write(data)
    })

    this.channel.on("exit", ({ code }) => {
      this.term.write(`\r\n\x1b[33m--- Process exited with code ${code} ---\x1b[0m\r\n`)
    })

    this.channel.join()
      .receive("ok", ({ history }) => {
        if (history) this.term.write(history)
      })

    // Send user keystrokes to Claude Code
    this.term.onData((data) => {
      this.channel.push("input", { data })
    })

    // Resize handling
    new ResizeObserver(() => this.fitAddon.fit()).observe(this.el)
  },

  destroyed() {
    if (this.channel) this.channel.leave()
    if (this.term) this.term.dispose()
  }
}

export default TerminalHook
```

Register in `app.js`:

```javascript
import TerminalHook from "./terminal_hook"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { TerminalHook },
  // ...
})
```

### NPM Dependencies

```bash
cd assets && npm install @xterm/xterm @xterm/addon-fit
```

---

## Integration with Existing Systems

### Embeddings / RAG

The MCP `docs_lookup` tool calls the existing `PumaBot.Embeddings.Retriever.search/2` directly. No new embedding infrastructure needed.

To expand RAG coverage for library documentation:

1. Add a new source type `:hex_docs` to `DataSource.source_type` enum
2. Create `PumaBot.Importers.HexDocsImporter` that:
   - Scans a project's `deps/` directory
   - Reads module docs from compiled `.beam` files via `Code.fetch_docs/1`
   - Indexes function docs, typespecs, and README content
   - Stores in `DataSource` with embeddings for semantic search
3. Optionally index source code files from deps for linking

### Data Pipeline

Terminal session output feeds into the existing data pipeline:

- When a session completes, its full output can be stored as a `ClaudeConversation` record (if using `--output-format json`)
- Tool call results from the MCP server can be stored as `DataSource` entries for future RAG retrieval
- This means past compile errors, test failures, and their solutions become searchable context

### PubSub Topics

All new components communicate via the existing `PumaBot.PubSub`:

| Topic | Events | Publisher | Subscriber |
|-------|--------|-----------|------------|
| `terminal:{id}` | `:terminal_output`, `:terminal_exit` | Session | Channel, LiveView |
| `orchestrator:events` | `:session_completed` | Session | Orchestrator |
| `orchestrator:status` | `:task_completed`, `:queue_changed` | Orchestrator | LiveView |
| `mcp:tool_calls` | `:tool_called` | MCP Server | LiveView |

---

## New Dependencies

```elixir
# In mix.exs deps/0
{:hermes_mcp, "~> 0.14"},    # MCP server framework
{:ex_pty, "~> 0.2"},          # PTY management for terminal sessions
```

Note: `ex_pty` availability needs verification. If not available on hex.pm, alternatives:

- Use Erlang `Port.open/2` with `{:spawn, "script -qc 'claude ...' /dev/null"}` to get PTY-like behavior
- Use a NIF wrapper around `forkpty(3)` / `openpty(3)`
- Use the `pty` Rust NIF package if available

The Erlang port approach is the fallback and follows the same pattern as `WhatsApp.Bridge` -- it already works in the codebase.

### NPM (assets/)

```json
{
  "@xterm/xterm": "^5.5",
  "@xterm/addon-fit": "^0.10"
}
```

---

## Database Changes

### New Migration: hex_docs source type

```elixir
# Add :hex_docs to the data_sources source_type enum
alter table(:data_sources) do
  # Extend the source_type check constraint to include :hex_docs
end
```

### New Migration: terminal_sessions table (optional)

If we want to persist session history beyond in-memory GenServer state:

```sql
CREATE TABLE terminal_sessions (
  id UUID PRIMARY KEY,
  project_path TEXT NOT NULL,
  task TEXT,
  status VARCHAR(20) NOT NULL,       -- idle, running, completed, error
  exit_code INTEGER,
  started_at TIMESTAMP,
  completed_at TIMESTAMP,
  output_log TEXT,                    -- full terminal output (compressed)
  inserted_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);
```

This is optional for Phase 1 -- sessions can live entirely in memory initially.

---

## Configuration

```elixir
# config/config.exs
config :puma_bot, PumaBot.MCP,
  port: 4040,                              # or mount on main Phoenix port
  allowed_project_paths: [                  # security allowlist
    "/media/jeremy/OrangeCream/Linux Software/"
  ]

config :puma_bot, PumaBot.Terminal,
  max_sessions: 6,                         # hard cap on concurrent PTYs
  default_project_path: "/media/jeremy/OrangeCream/Linux Software/",
  claude_path: "claude",                   # or absolute path
  session_timeout: :timer.minutes(30)      # auto-kill stale sessions
```

---

## Implementation Phases

### Phase 1: MCP Server (standalone, testable independently)

1. Add `hermes_mcp` dependency
2. Implement `PumaBot.MCP.Tool` behaviour
3. Implement `compile`, `test`, and `docs_lookup` tools
4. Mount MCP HTTP endpoint in Phoenix router
5. Register with Claude Code via `claude mcp add`
6. Test: ask Claude Code to "compile this project" and verify it calls the MCP tool

**Validation**: Claude Code discovers your tools, calls them, and uses the results to iterate without asking you to run commands.

### Phase 2: Terminal Session Manager

1. Evaluate PTY options (ex_pty vs Erlang port fallback)
2. Implement `Session` GenServer with PTY lifecycle
3. Implement `SessionSupervisor` (DynamicSupervisor)
4. Add Registry for session lookup
5. Implement `OutputParser` basics
6. Test: spawn a Claude Code session programmatically, read its output, send it input

**Validation**: Can start/stop Claude Code from IEx, read its output stream, and write to its stdin.

### Phase 3: Terminal Dashboard UI

1. Install xterm.js npm packages
2. Implement `TerminalChannel` for PTY-to-browser streaming
3. Implement `TerminalDashboardLive` with grid layout
4. Add TerminalHook JS for xterm.js rendering
5. Wire up session controls (start, stop, input)
6. Add nav link from existing ChatBrowserLive

**Validation**: Open `/terminals` in browser, see a grid of live Claude Code terminals, type into them, watch output stream in real time.

### Phase 4: Orchestrator

1. Implement `Orchestrator` GenServer with task queue
2. Add manual mode (queue + explicit start)
3. Add auto mode (start on queue, fill to concurrency limit)
4. Wire orchestrator controls into dashboard UI
5. Add MCP tool call log panel

**Validation**: Queue 5 tasks, set concurrency to 2, watch them execute in pairs, results stream to dashboard.

### Phase 5: Polish & Integration

1. Hex docs importer for expanded RAG coverage
2. Session output persistence to database
3. Session output fed into ClaudeConversation pipeline
4. Grid layout presets (1x1, 2x2, 3x2, custom)
5. Session search/filter in dashboard
6. Keyboard shortcuts for terminal focus cycling

---

## Open Questions

1. **PTY library**: `ex_pty` needs to be verified as available and maintained. Fallback is Erlang ports (already proven in `WhatsApp.Bridge`), but ports don't provide full PTY semantics (no ANSI escape handling, no window resize signals). Need to evaluate whether full PTY is required or if port-based output capture is sufficient.

2. **Claude Code output format**: Should sessions use `--print` mode (scripted, one-shot) or interactive mode? `--print` is simpler to parse but doesn't allow follow-up. Interactive mode gives full control but output parsing is harder due to ANSI escape codes and terminal control sequences.

3. **MCP endpoint mounting**: Should the MCP server run on the same port as Phoenix (4000) or a separate port? Same port is simpler but adds load to the main endpoint. Separate port isolates MCP traffic.

4. **Hermes MCP Plug integration**: Need to verify exactly how Hermes MCP exposes its HTTP transport as a Plug. The API for mounting into an existing Phoenix router needs to be confirmed against the library docs.

5. **Session output storage**: Storing full terminal output (with ANSI codes) can be large. Should we strip ANSI before storage? Store both raw and stripped? Compress?

6. **Orchestrator decision logic**: Phase 4 covers the mechanical orchestrator (queue + dispatch). More advanced logic (retry on failure, break down failing tasks, escalate to user) is a separate design exercise.
