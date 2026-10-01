defmodule Aethrion.Bridge do
  @moduledoc """
  Aethrion behind an OpenAI-compatible chat endpoint (`POST
  /v1/chat/completions`), so a chat app that lets you point it at a custom
  model, RisuAI's "Custom API" or SillyTavern's, gets the rules: what the
  player does is read and applied to the world, and the model narrates with
  the result in front of it.

  Such apps send the whole conversation each time, with no chat id; a
  reroll sends it again without the last reply, an edit sends the edited
  text. So the state follows the transcript: it is rebuilt every time by
  replaying the player's lines (`replay/4`), and what each line was read as
  is cached (`Aethrion.Bridge.Readings`), so only a new line costs a model
  call. A reroll cannot apply a move twice, and an edit changes the state
  the way the edited line would have. Each reply's status block carries a
  checkpoint id; the world after that turn is kept under it
  (`Aethrion.Bridge.Checkpoints`), and a replay starts from the latest
  checkpoint whose turns still match the transcript, so a chat the app has
  trimmed to fit its context goes on from where it was, and a long one is
  not replayed from the start.

  For the reply, the app's own prompt (its character card, lorebook, and
  history) goes to the model with a note at the end: what the rules just
  decided and where things stand (`note/3`), as facts not to change. The
  reply carries a status block (`status/3`), `<aethrion-status id="...">...
  </aethrion-status>`, which a display script renders (`priv/risu/`) and
  which is taken out of the history the app sends back.
  """

  alias Aethrion.{Combat, Interpreter, Runtime, State}

  @status ~r/\s*<aethrion-status[^>]*>.*?<\/aethrion-status>\s*/s
  @checkpoint ~r/<aethrion-status id="([0-9a-f]{8,64})"/
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
  before it), or after the leading system messages. In the chat proper, a
  reply that carried a status block keeps its checkpoint id as
  `"checkpoint"`.
  """
  @spec transcript([map()]) :: {[map()], [map()]}
  def transcript(messages) do
    chat =
      Enum.map(messages, fn m ->
        content = text(m["content"])

        %{
          "role" => to_string(m["role"]),
          "content" => content |> String.replace(@status, "\n") |> String.trim(),
          "checkpoint" =>
            case Regex.run(@checkpoint, content) do
              [_, id] -> id
              nil -> nil
            end
        }
      end)

    start =
      case Enum.find_index(
             Enum.reverse(chat),
             &(&1["role"] == "system" and Regex.match?(@start, &1["content"]))
           ) do
        nil -> Enum.find_index(chat, &(&1["role"] != "system")) || length(chat)
        from_end -> length(chat) - from_end
      end

    {Enum.map(chat, &Map.delete(&1, "checkpoint")), Enum.drop(chat, start)}
  end

  @doc """
  The world after the player's lines in `chat` (user messages, in order),
  replayed from `state`; returns `{before, after, turn}`. `turn` is the
  player's lines no reply has answered yet (usually one): their `readings`
  and `outputs`, the last `line` (nil when every line has its reply, as in
  a request to continue a reply), and the checkpoint `id` of the world
  after them; `before` is the world before them. `read` turns a line into
  readings (`fn state, line, prev -> [reading] end`, `prev` being the
  checkpoint id of the world it is read in).

  Options: `:to`, the character the player talks to; `:checkpoints`
  (`%{get: fun, put: fun}`, see `Aethrion.Bridge.Store`), which keeps the
  world after each line under an id chaining the cast, the character, and
  every line so far; `:max_lines`, the most lines one call may replay
  (more is `{:error, :too_many_lines}`). The replay starts after the latest
  reply whose checkpoint comes from this cast and whose chain matches the
  lines still in the chat, so an edited line is replayed with everything
  after it, and lines the app left out are not lost.
  """
  @spec replay(State.t(), [map()], (State.t(), String.t(), String.t() -> [map()]), keyword()) ::
          {State.t(), State.t(), map()} | {:error, :too_many_lines}
  def replay(%State{} = state, chat, read, opts \\ []) do
    to = Keyword.get(opts, :to, "")
    checkpoints = Keyword.get(opts, :checkpoints)
    root = root(state)
    turns = turns(chat)

    {pending, from, id} =
      case base(state, turns, root, to, checkpoints) do
        {index, id, %{state: saved}} -> {Enum.drop(turns, index + 1), with_lore(saved, state), id}
        nil -> {turns, state, root}
      end

    if length(pending) > Keyword.get(opts, :max_lines, :infinity) do
      {:error, :too_many_lines}
    else
      # This turn is the lines after the last reply.
      replied = Enum.find_index(Enum.reverse(pending), & &1.replied)
      {answered, unanswered} = Enum.split(pending, length(pending) - (replied || length(pending)))
      put = &if(checkpoints, do: checkpoints.put.(&1, checkpoint(&2, &3, &4, root)))

      {now, id} =
        Enum.reduce(answered, {from, id}, fn
          %{line: nil}, acc ->
            acc

          %{line: line}, {state, prev} ->
            {state, _readings, _outputs} = play(state, line, prev, read)
            id = checkpoint_id(prev, to, line)
            put.(id, prev, line, state)
            {state, id}
        end)

      turn = %{line: nil, readings: [], outputs: [], id: id}

      {after_all, turn} =
        Enum.reduce(unanswered, {now, turn}, fn %{line: line}, {state, turn} ->
          {state, readings, outputs} = play(state, line, turn.id, read)
          id = checkpoint_id(turn.id, to, line)
          put.(id, turn.id, line, state)

          {state,
           %{
             line: line,
             readings: turn.readings ++ readings,
             outputs: turn.outputs ++ outputs,
             id: id
           }}
        end)

      {now, after_all, turn}
    end
  end

  defp play(state, line, prev, read) do
    readings = read.(state, line, prev)

    {after_line, outputs} =
      Enum.reduce(readings, {state, []}, fn %{event: event}, {state, outputs} ->
        case Runtime.step(state, event) do
          {:ok, step} -> {step.state, outputs ++ step.outputs}
          {:error, _rejected} -> {state, outputs}
        end
      end)

    {after_line, readings, outputs}
  end

  # The cast's lore is the same in every world of the cast: it is left out
  # of checkpoints and put back from the cast.
  defp checkpoint(prev, line, state, root),
    do: %{prev: prev, line: digest(line), root: root, state: with_lore(state, nil)}

  defp with_lore(%State{story: %{} = story} = state, cast) do
    lore = if cast, do: Map.get(cast.story || %{}, :lore, []), else: []
    if Map.has_key?(story, :lore), do: %{state | story: Map.put(story, :lore, lore)}, else: state
  end

  defp with_lore(state, _cast), do: state

  # The player's lines, each with whether a reply came after it and that
  # reply's checkpoint id. A chat the app trimmed may begin with a reply: it
  # is kept, with no line, for its checkpoint.
  defp turns(chat) do
    chat
    |> Enum.reduce([], fn
      %{"role" => "user", "content" => text}, turns ->
        if String.trim(text) == "",
          do: turns,
          else: [%{line: text, id: nil, replied: false} | turns]

      %{"role" => "assistant"} = reply, [%{replied: false} = turn | turns] ->
        [%{turn | id: reply["checkpoint"], replied: true} | turns]

      %{"role" => "assistant", "checkpoint" => id}, [] when is_binary(id) ->
        [%{line: nil, id: id, replied: true}]

      _other, turns ->
        turns
    end)
    |> Enum.reverse()
  end

  # Where the replay starts: `{index, id, checkpoint}`, the world after turn
  # `index` (-1: before the first turn), or nil for the cast.
  defp base(_state, _turns, _root, _to, nil), do: nil

  defp base(state, turns, root, to, checkpoints) do
    get = fn id ->
      case checkpoints.get.(id) do
        %{root: ^root} = saved -> saved
        _other -> nil
      end
    end

    characters = Enum.map(State.sorted_characters(state), & &1.id)

    marked(turns, get) || edited_first(turns, root, get) ||
      computed(turns, root, to, characters, get)
  end

  # The latest reply whose checkpoint chain matches the lines up to it.
  defp marked(turns, get) do
    turns
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%{id: nil}, _index} ->
        nil

      {%{id: id}, index} ->
        saved = get.(id)
        if saved && chain?(Enum.take(turns, index + 1), id, get), do: {index, id, saved}
    end)
  end

  # A trimmed chat whose first turn was edited: the world before its lines,
  # walking back from its reply's checkpoint one line at a time.
  defp edited_first(turns, root, get) do
    with index when is_integer(index) <- Enum.find_index(turns, &is_binary(&1.id)),
         lines = Enum.take(turns, index + 1),
         true <- Enum.all?(lines, &is_binary(&1.line)),
         id when is_binary(id) and id != root <-
           back(Enum.at(turns, index).id, length(lines), get),
         %{} = saved <- get.(id) do
      {-1, id, saved}
    else
      _other -> nil
    end
  end

  defp back(id, 0, _get), do: id

  defp back(id, steps, get) do
    case get.(id) do
      %{prev: prev} -> back(prev, steps - 1, get)
      nil -> nil
    end
  end

  # A chat whose replies carry no ids (`aethrion-plain`), from its start:
  # the ids follow from the lines and whom each was said to, so the
  # checkpoints can still be found.
  # Only up to the last reply: the lines after it are this turn's, and are
  # always replayed.
  defp computed(turns, root, to, characters, get) do
    answered =
      length(turns) - (turns |> Enum.reverse() |> Enum.find_index(& &1.replied) || length(turns))

    turns
    |> Enum.take(answered)
    |> Enum.with_index()
    |> Enum.reduce_while({root, nil}, fn
      {%{line: line}, index}, {prev, found} when is_binary(line) ->
        digest = digest(line)

        [to | characters]
        |> Enum.find_value(fn to ->
          id = checkpoint_id(prev, to, line)

          case get.(id) do
            %{line: ^digest} = saved -> {id, saved}
            _missing -> nil
          end
        end)
        |> case do
          {id, saved} -> {:cont, {id, {index, id, saved}}}
          nil -> {:halt, {prev, found}}
        end

      _turn, acc ->
        {:halt, acc}
    end)
    |> elem(1)
  end

  # Walks the chain back from `id` over the lines still in the chat (the
  # earliest may have been trimmed away): each line must be the one kept,
  # and each reply's id the one the chain gives.
  defp chain?(turns, id, get) do
    turns
    |> Enum.reverse()
    |> Enum.reduce_while(id, fn %{line: line, id: seen}, id ->
      case get.(id) do
        %{line: kept, prev: prev} when seen in [nil, id] ->
          if line == nil or kept == digest(line), do: {:cont, prev}, else: {:halt, false}

        _other ->
          {:halt, false}
      end
    end)
    |> is_binary()
  end

  defp checkpoint_id(prev, to, line),
    do: [prev, 0, to, 0, line] |> sha() |> binary_part(0, 24)

  defp digest(line), do: :crypto.hash(:sha256, line)

  # The chain starts from the cast; a checkpoint keeps its root, so another
  # cast's checkpoints are never used.
  defp root(state),
    do:
      state
      |> State.to_data()
      |> :erlang.term_to_binary([:deterministic])
      |> sha()
      |> binary_part(0, 24)

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

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
  status window (`priv/risu/aethrion-status.json`), opened with the turn's
  checkpoint id.
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

    open = if turn[:id], do: ~s(<aethrion-status id="#{turn.id}">), else: "<aethrion-status>"
    open <> Enum.map_join(lines, "\n", &escape/1) <> "</aethrion-status>"
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
  functions on a key), so a line seen before in the same world is not read
  again. The key holds the interpreter, the character, the line, and the
  checkpoint of the world it is read in (`prev`); a reading the rules gave
  in place of a failing interpreter is not kept.
  """
  def reader(to, opts, cache) do
    interpreter = Keyword.get(opts, :interpreter, Interpreter.Rules)

    fn state, line, prev ->
      key =
        :crypto.hash(:sha256, [inspect(interpreter), 0, prev, 0, to, 0, line])
        |> Base.encode16(case: :lower)

      case cache.get.(key) do
        nil ->
          {:ok, readings, meta} = Interpreter.read(state, "user", to, line, opts)
          if meta.status == :ok, do: cache.put.(key, readings)
          readings

        readings ->
          readings
      end
    end
  end
end
