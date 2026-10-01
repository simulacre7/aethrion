# mix run examples/chat_app.exs
#
# The shape of a chat app: a world per user under Aethrion.Worlds, lines
# phrased by a model that sees the conversation, and a restart that keeps
# both the world and what was said. A stand-in model is used here so the
# example runs without an API key; swap in Aethrion.LLM.Anthropic for a real
# one.

defmodule StandInModel do
  @moduledoc false
  # Plays the model: answers with the stance the rules chose, and shows that
  # it can see how long the thread is.
  @behaviour Aethrion.LLM.Adapter

  @impl true
  def render(request, _opts) do
    seen = length(request.conversation)
    {:ok, "#{request.fallback_text} (a model's line, #{seen} earlier turns in view)"}
  end
end

alias Aethrion.{Conversation, Worlds}

data = Path.join(System.tmp_dir!(), "aethrion-chat-app-#{System.unique_integer([:positive])}")
File.mkdir_p!(data)

start = fn ->
  Worlds.start_link(
    name: ChatApp.Worlds,
    idle_after: :timer.minutes(30),
    world: fn user_id ->
      [
        initial_state: Aethrion.Runtime.demo_state(),
        journal: Path.join(data, "#{user_id}.jsonl"),
        expression: [adapter: StandInModel, timeout: 5_000]
      ]
    end
  )
end

{:ok, worlds} = start.()

# A chat process subscribes to its user's world and shows lines as they come.
:ok = Worlds.subscribe(ChatApp.Worlds, "alice")

say = fn user, text ->
  {:ok, state} = Worlds.get_state(ChatApp.Worlds, user)
  {:ok, event, _meta} = Aethrion.Intent.interpret(state, text, to: "mina")
  {:ok, _step} = Worlds.step(ChatApp.Worlds, user, event)

  receive do
    {:aethrion, {ChatApp.Worlds, ^user}, {:expressed, %{type: :reply} = line}} ->
      IO.puts("  #{user} > Mina: #{text}\n  Mina: #{line.text}")
  after
    5_000 -> IO.puts("  (no reply)")
  end
end

IO.puts("== Alice chats with Mina")
say.("alice", "Good morning! Did you sleep well?")
say.("alice", "What are you reading these days?")
say.("alice", "Thank you, that was lovely.")

IO.puts("\n== Bob has his own world")
:ok = Worlds.subscribe(ChatApp.Worlds, "bob")
say.("bob", "Hi Mina, nice to meet you.")
{:ok, alice} = Worlds.get_state(ChatApp.Worlds, "alice")
{:ok, bob} = Worlds.get_state(ChatApp.Worlds, "bob")
IO.puts("  turns kept: alice #{length(Conversation.recent(alice, "mina", "user"))}, bob #{length(Conversation.recent(bob, "mina", "user"))}")

IO.puts("\n== The app restarts")
Process.unlink(worlds)
ref = Process.monitor(worlds)
Process.exit(worlds, :shutdown)
receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
{:ok, _worlds} = start.()

{:ok, restored} = Worlds.get_state(ChatApp.Worlds, "alice")
IO.puts("  alice's world came back: #{restored == alice}")

for turn <- Conversation.recent(restored, "mina", "user") do
  who = if turn.from == "user", do: "Alice", else: "Mina"
  IO.puts("  #{who}: #{turn.text}")
end

File.rm_rf!(data)
