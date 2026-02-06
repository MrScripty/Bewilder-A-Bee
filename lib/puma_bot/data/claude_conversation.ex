defmodule PumaBot.Data.ClaudeConversation do
  @moduledoc """
  Schema for Claude Code conversation messages.

  Stores conversations imported from ~/.claude/projects/ JSONL files.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: binary(),
          session_id: String.t(),
          message_index: integer(),
          project_path: String.t() | nil,
          role: atom(),
          content: String.t(),
          tool_calls: [map()],
          tool_results: [map()],
          timestamp: DateTime.t(),
          model: String.t() | nil,
          raw_data: map(),
          data_source_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @roles [:user, :assistant, :system]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "claude_conversations" do
    field :session_id, :string
    field :message_index, :integer
    field :project_path, :string
    field :role, Ecto.Enum, values: @roles
    field :content, :string
    field :tool_calls, {:array, :map}, default: []
    field :tool_results, {:array, :map}, default: []
    field :timestamp, :utc_datetime
    field :model, :string
    field :raw_data, :map, default: %{}

    # Link to the unified data source (once processed with embedding)
    belongs_to :data_source, PumaBot.Data.DataSource

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid roles.
  """
  def roles, do: @roles

  @doc """
  Creates a changeset for a Claude conversation message.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :session_id,
      :message_index,
      :project_path,
      :role,
      :content,
      :tool_calls,
      :tool_results,
      :timestamp,
      :model,
      :raw_data,
      :data_source_id
    ])
    |> validate_required([:session_id, :message_index, :role])
    |> unique_constraint([:session_id, :message_index],
      name: :claude_conversations_session_id_message_index_index
    )
  end
end
