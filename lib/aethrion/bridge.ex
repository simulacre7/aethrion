defmodule Aethrion.Bridge do
  @moduledoc """
  Aethrion behind an OpenAI-compatible chat endpoint (`POST
  /v1/chat/completions`), so a chat app that lets you point it at a custom
  model, RisuAI's "Custom API" or SillyTavern's, gets the rules: what the
  player does is read and applied to the world, and the model narrates with
  the result in front of it.

  Such apps send the whole conversation each time, with no chat id; a
  reroll sends it again without the last reply, an edit sends the edited
  text. So the state is not kept between requests: it is rebuilt from the
  transcript every time, by replaying the player's lines from the cast
  (`replay/3`), and what each line was read as is cached
  (`Aethrion.Bridge.Readings`), so only a new line costs a model call. A
  reroll cannot apply a move twice, and an edit changes the state the way
  the edited line would have.

  For the reply, the app's own prompt (its character card, lorebook, and
  history) goes to the model with a note at the end: what the rules just
  decided and where things stand (`note/3`), as facts not to change. The
  reply carries a status block (`status/2`), `<aethrion-status>...
  </aethrion-status>`, which a display script renders (`priv/risu/`) and
  which is taken out of the history the app sends back.
  """

  alias Aethrion.{Combat, Interpreter, Runtime, State}

  @status ~r/\s*<aethrion-status>.*?<\/aethrion-status>\s*/s
  @start ~r/\[Start a new chat\]/i

  @doc "The text of a message's content (a string, or a list of parts)."
  @spec text(term()) :: String.t()
  def text(content) when is_binary(content), do: content

  def text(parts) when is_list(parts),
    do:
      Enum.map_join(parts, "\n", fn part -> if is_map(part), do: text(part["text"]), else: "" end)

  def text(_content), do: ""

  @doc """
  The messages with our status blocks taken out, and the chat proper: what
  comes after the app's `[Start a new chat]` marker (example dialogues come
  before it), or after the leading system messages.
  """
  @spec transcript([map()]) :: {[map()], [map()]}
  def transcript(messages) do
    messages =
      Enum.map(messages, fn m ->
        %{
          "role" => to_string(m["role"]),
          "content" => m["content"] |> text() |> String.replace(@status, "\n") |> String.trim()
        }
      end)

    start =
      case Enum.find_index(
             Enum.reverse(messages),
             &(&1["role"] == "system" and Regex.match?(@start, &1["content"]))
           ) do
        nil -> Enum.find_index(messages, &(&1["role"] != "system")) || length(messages)
        from_end -> length(messages) - from_end
      end

    {messages, Enum.drop(messages, start)}
  end

  @doc """
  The world after the player's lines in `chat` (user messages, in order),
  replayed from `state`; returns `{before, after, turn}`, where `turn` holds
  the last line's readings and outputs. `read` turns a line into readings
  (`fn state, text -> [reading] end`).
  """
  @spec replay(State.t(), [map()], (State.t(), String.t() -> [map()])) ::
          {State.t(), State.t(), map()}
  def replay(%State{} = state, chat, read) do
    lines = for %{"role" => "user", "content" => text} <- chat, String.trim(text) != "", do: text

    Enum.reduce(lines, {state, state, %{line: nil, readings: [], outputs: []}}, fn line,
                                                                                   {_before,
                                                                                    state, _turn} ->
      readings = read.(state, line)

      {after_line, outputs} =
        Enum.reduce(readings, {state, []}, fn %{event: event}, {state, outputs} ->
          case Runtime.step(state, event) do
            {:ok, step} -> {step.state, outputs ++ step.outputs}
            {:error, _rejected} -> {state, outputs}
          end
        end)

      {state, after_line, %{line: line, readings: readings, outputs: outputs}}
    end)
  end

  @doc """
  The note for the model: what the rules decided this turn, and where things
  stand, as facts to narrate and not to change.
  """
  @spec note(State.t(), State.t(), map(), :ko | :en) :: String.t()
  def note(%State{} = before, %State{} = now, turn, locale \\ :ko) do
    happened = happened(before, now, turn, locale)

    """
    [Aethrion: the game's rules, not the story, decide these. Narrate the next reply so it agrees with them; do not change any number, do not invent hits, heals, or endings beyond these, and do not print a status window: it is shown separately.]
    #{if happened == [], do: "This turn: nothing the rules track changed.", else: "This turn:\n" <> Enum.join(happened, "\n")}
    Now:
    #{Enum.join(standing(now, locale), "\n")}
    """
    |> String.trim()
  end

  defp happened(before, now, %{readings: readings, outputs: outputs}, locale) do
    read =
      for %{as: as, event: event} <- readings, as != :talk do
        "- The player's line was read as #{as}#{target(now, event)}."
      end

    told =
      for output <- outputs, line = told(output, now, locale), line != nil, do: "- " <> line

    read ++ told ++ changes(before, now)
  end

  defp target(state, %{to: to}) when is_binary(to), do: " (#{State.name(state, to)})"
  defp target(state, %{character: c}) when is_binary(c), do: " (#{State.name(state, c)})"
  defp target(_state, _event), do: ""

  defp told(%{type: :combat} = output, state, locale), do: Combat.describe(output, state, locale)

  defp told(%{type: :ending_reached, title: title} = o, _state, _locale),
    do: "Ending reached: #{title}. #{o[:description]}"

  defp told(%{type: :milestone_reached, title: title} = o, _state, _locale),
    do: "Unlocked: #{title}." <> if(o[:text], do: " #{o[:text]}", else: "")

  defp told(_output, _state, _locale), do: nil

  # How the characters' feelings toward the player moved.
  defp changes(before, now) do
    for character <- State.sorted_characters(now),
        was = State.get_relationship(before, character.id, "user"),
        is = State.get_relationship(now, character.id, "user"),
        delta =
          for(
            f <- [:affinity, :trust, :tension],
            Map.get(is, f) != Map.get(was, f),
            do: {f, Map.get(is, f) - Map.get(was, f)}
          ),
        delta != [] do
      "- #{character.name} toward the player: " <>
        Enum.map_join(delta, ", ", fn {f, d} -> "#{f} #{if d > 0, do: "+", else: ""}#{d}" end)
    end
  end

  defp standing(state, locale) do
    people =
      for character <- State.sorted_characters(state),
          rel = State.get_relationship(state, character.id, "user"),
          not State.stat?(state, character.id, "enemy") or
            State.stat(state, character.id, "enemy") == 0 do
        "- #{character.name}: affinity #{rel.affinity}, trust #{rel.trust}, tension #{rel.tension}, " <>
          "#{Aethrion.Rules.Bond.derive(rel, state)}" <> hp(state, character.id)
      end

    fighters =
      for id <- Enum.sort(Map.keys(state.stats)),
          State.stat?(state, id, "hp"),
          not State.character?(state, id) or State.stat(state, id, "enemy") > 0 do
        "- #{State.name(state, id)}#{hp(state, id)}"
      end

    ending =
      case Aethrion.Rules.Ending.reached(state) do
        nil -> []
        ending -> ["- The story has ended: #{ending.title}."]
      end

    _ = locale
    people ++ fighters ++ ending
  end

  defp hp(state, id) do
    if State.stat?(state, id, "hp"),
      do:
        ", hp #{State.stat(state, id, "hp")}/#{State.stat(state, id, "max_hp")}" <>
          if(State.down?(state, id), do: " (down)", else: ""),
      else: ""
  end

  @doc """
  The status block for the reply: short lines a display script turns into a
  status window (`priv/risu/aethrion-status.json`).
  """
  @spec status(State.t(), map(), :ko | :en) :: String.t()
  def status(%State{} = state, turn, locale \\ :ko) do
    words = words(locale)

    people =
      for character <- State.sorted_characters(state),
          State.stat(state, character.id, "enemy") == 0,
          rel = State.get_relationship(state, character.id, "user") do
        "#{character.name} · #{words.affinity} #{rel.affinity} · #{words.trust} #{rel.trust}" <>
          hp_short(state, character.id)
      end

    foes =
      for id <- Enum.sort(Map.keys(state.stats)), State.stat(state, id, "enemy") > 0 do
        "#{State.name(state, id)}" <> hp_short(state, id)
      end

    player =
      if State.stat?(state, "user", "hp"),
        do: ["#{words.you}" <> hp_short(state, "user")],
        else: []

    events =
      for %{type: type} = o <- turn.outputs, type in [:ending_reached, :milestone_reached] do
        if type == :ending_reached, do: "★ #{o.title}", else: "♥ #{o.title}"
      end

    lines = player ++ people ++ foes ++ events

    "<aethrion-status>" <>
      Enum.map_join(lines, "\n", &escape/1) <> "</aethrion-status>"
  end

  defp hp_short(state, id) do
    if State.stat?(state, id, "hp"),
      do: " · HP #{State.stat(state, id, "hp")}/#{State.stat(state, id, "max_hp")}",
      else: ""
  end

  defp words(:ko), do: %{affinity: "호감", trust: "신뢰", you: "나"}
  defp words(_en), do: %{affinity: "affinity", trust: "trust", you: "You"}

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  @doc """
  Reads a line with the interpreter, through `cache` (`get` and `put`
  functions on a key), so a line seen before is not read again.
  """
  def reader(to, opts, cache) do
    fn state, line ->
      key = :crypto.hash(:sha256, [to, 0, line]) |> Base.encode16(case: :lower)

      case cache.get.(key) do
        nil ->
          {:ok, readings, _meta} = Interpreter.read(state, "user", to, line, opts)
          cache.put.(key, readings)
          readings

        readings ->
          readings
      end
    end
  end
end
