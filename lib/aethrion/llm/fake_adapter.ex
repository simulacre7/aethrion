defmodule Aethrion.LLM.FakeAdapter do
  @moduledoc """
  Deterministic expression adapter used by tests and demos.

  It does not read or mutate runtime state. It only turns a known reason into a
  stable line of dialogue.
  """

  def proactive_message("yuna", :jealous) do
    "You seemed really happy with Mina earlier. I guess I was just wondering if you forgot about me."
  end

  def proactive_message(character_id, reason) do
    "#{character_id} has something to say about #{reason}."
  end
end
