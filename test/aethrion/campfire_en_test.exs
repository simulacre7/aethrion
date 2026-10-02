defmodule Aethrion.CampfireEnTest do
  # The English campfire cast is the Korean one in English: the same
  # numbers, so the same play reaches the same state.
  use ExUnit.Case, async: true

  alias Aethrion.{Bridge, State}

  defp cast(file) do
    {:ok, state} = "priv/casts/#{file}" |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  test "has the Korean cast's numbers, in English" do
    ko = cast("campfire.json")
    en = cast("campfire_en.json")

    assert en.relationships == ko.relationships
    assert en.stats == ko.stats
    assert Map.keys(en.characters) == Map.keys(ko.characters)
    assert Enum.map(en.story.endings, & &1.id) == Enum.map(ko.story.endings, & &1.id)

    for {id, character} <- en.characters do
      refute character.name =~ ~r/\p{Hangul}/u, "#{id} has a Korean name"
      refute character.profile =~ ~r/\p{Hangul}/u, "#{id} has a Korean profile"
    end
  end

  test "a gift seen by Doyun plays out in English" do
    read =
      Bridge.reader(
        [interpreter: Aethrion.Interpreter.Rules],
        %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}
      )

    messages = [%{"role" => "user", "content" => "Sera, I got you a necklace. It's a gift"}]
    {_all, chat} = Bridge.transcript(messages)
    {before, now, turn} = Bridge.replay(cast("campfire_en.json"), chat, read, to: "sera")
    status = Bridge.status(now, turn, :en, before)

    assert status =~ ~r/Sera · affinity \d+ \(\+\d+\)/
    assert status =~ "Doyun → Sera · tension +"
  end
end
