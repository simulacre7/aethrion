defmodule Aethrion.Output do
  @moduledoc """
  Structured runtime outputs. Applications decide how to perform side effects.
  """

  def relationship_changed(from, to, delta) do
    %{type: :relationship_changed, from: from, to: to, delta: delta}
  end

  def memory_created(memory) do
    %{type: :memory_created, memory: memory}
  end

  def proactive_message(character_id, to, reason, text) do
    %{type: :proactive_message, character_id: character_id, to: to, reason: reason, text: text}
  end
end
