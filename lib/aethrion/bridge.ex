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

  alias Aethrion.{Combat, Event, Interpreter, Memories, Runtime, State}

  @status ~r/\s*<aethrion-status[^>]*>.*?<\/aethrion-status>\s*/s
  @checkpoint ~r/<aethrion-status id="([0-9a-f]{8,64})"/
  @start ~r/\[Start a new chat\]/i
  # What the player does that the characters there see.
  @witnessed [:message_sent, :gift_received, :apology_offered]
  @between_max 8

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
  `"checkpoint"`, and the scene it named (`Aethrion.Bridge.Scene`) as
  `"scene"`.
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
            end,
          "scene" => Aethrion.Bridge.Scene.marked(content)
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

    {Enum.map(chat, &Map.drop(&1, ["checkpoint", "scene"])), Enum.drop(chat, start)}
  end

  @doc """
  The world after the player's lines in `chat` (user messages, in order),
  replayed from `state`; returns `{before, after, turn}`. `turn` is the
  player's lines no reply has answered yet (usually one): their `readings`
  and `outputs`, the last `line` (nil when every line has its reply, as in
  a request to continue a reply), and the checkpoint `id` of the world
  after them; `before` is the world before them; `scenes`, for each line in
  order, who was there to see it (`seen_by`), who was not (`away`), and
  who came back as its hours passed (`back`); and `between`, how the
  characters' feelings toward each other moved (`[{from, to, field,
  delta}]`). `read`
  turns a line into readings (`fn state, line, prev, to -> [reading] end`,
  `prev` being the checkpoint id of the world it is read in and `to` whom
  the player is talking to).

  Each line is said to whoever the player last called by name, or gave or
  apologized to, starting with `:to`; the characters there (not foes, not
  down, not `"away"`) see what the player says, gives, and apologizes; and
  when the story has `turn_hours`, that much time passes after each line,
  so the characters away come back and word gets around.

  Options: `:to`, the character the player talks to at first; `:checkpoints`
  (`%{get: fun, put: fun}`, see `Aethrion.Bridge.Store`), which keeps the
  world after each line under an id chaining the cast, the character, and
  every line so far; `:max_lines`, the most lines one call may replay
  (more is `{:error, :too_many_lines}`); `:scenes` (default false), for a
  cast read from a card: each line is read in the scene the reply before it
  named (`Aethrion.Bridge.Scene`), so people the story brought in join the
  cast and those not there are away. The replay starts after the latest
  reply whose checkpoint comes from this cast and whose chain matches the
  lines still in the chat, so an edited line is replayed with everything
  after it, and lines the app left out are not lost.
  """
  @spec replay(
          State.t(),
          [map()],
          (State.t(), String.t(), String.t(), String.t() -> [map()]),
          keyword()
        ) ::
          {State.t(), State.t(), map()} | {:error, :too_many_lines}
  def replay(%State{} = state, chat, read, opts \\ []) do
    to = Keyword.get(opts, :to, "")
    checkpoints = opts |> Keyword.get(:checkpoints) |> as_json()
    root = root(state)
    turns = turns(chat, Keyword.get(opts, :scenes, false))

    {pending, from, id, talking} =
      with {index, id, %{state: {:data, data}} = checkpoint} <-
             base(state, turns, root, to, checkpoints),
           {:ok, saved} <- State.parse(data) do
        {Enum.drop(turns, index + 1), with_story(saved, state), id,
         Map.get(checkpoint, :talking) || to}
      else
        _none -> {turns, state, root, to}
      end

    if length(pending) > Keyword.get(opts, :max_lines, :infinity) do
      {:error, :too_many_lines}
    else
      # This turn is the lines after the last reply.
      replied = Enum.find_index(Enum.reverse(pending), & &1.replied)
      {answered, unanswered} = Enum.split(pending, length(pending) - (replied || length(pending)))

      put =
        &if(checkpoints, do: checkpoints.put.(&1, checkpoint(&2, &3, &4, &5, root)))

      {now, id, talking} =
        Enum.reduce(answered, {from, id, talking}, fn
          %{line: nil}, acc ->
            acc

          %{line: _line} = turn, {state, prev, talking} ->
            played = line_step(state, turn, prev, talking, read, put)
            {played.state, played.id, played.talking}
        end)

      turn = %{line: nil, readings: [], outputs: [], id: id, scenes: []}

      {after_all, turn, _talking} =
        Enum.reduce(unanswered, {now, turn, talking}, fn %{line: line} = said,
                                                         {state, turn, talking} ->
          played = line_step(state, said, turn.id, talking, read, put)

          {played.state,
           %{
             line: line,
             readings: turn.readings ++ played.readings,
             outputs: turn.outputs ++ played.outputs,
             id: played.id,
             scenes: turn.scenes ++ [played.scene]
           }, played.talking}
        end)

      {now, after_all, Map.put(turn, :between, between(after_all, turn.outputs))}
    end
  end

  # One line of the player's: read as said to whoever they are talking to,
  # seen by whoever is there, then the turn's hours pass. Who they talk to
  # next is whoever the line called.
  defp line_step(state, %{line: line} = said, prev, talking, read, put) do
    {state, chain, talking} = in_scene(state, Map.get(said, :scene), prev, talking)
    # With no one in the cast yet there is nothing to read the line as.
    readings = if people(state) == [], do: [], else: read.(state, line, chain, talking)
    seen_by = present(state)

    {after_line, outputs, refused} =
      Enum.reduce(readings, {state, [], []}, fn %{event: event}, {state, outputs, refused} ->
        case Runtime.step(state, witnessed(event, seen_by)) do
          {:ok, step} -> {step.state, outputs ++ step.outputs, refused}
          {:error, error} -> {state, outputs, refused ++ [error.message]}
        end
      end)

    {after_line, outputs} = pass_time(after_line, outputs)
    id = checkpoint_id(chain, talking, line)
    talking = addressee(after_line, readings) || talking
    put.(id, prev, line, after_line, talking)

    away = for c <- people(state), State.stat(state, c.id, "away") > 0, do: c.id
    targets = for %{event: %{type: type} = event} <- readings, type in @witnessed, do: event.to

    %{
      state: after_line,
      readings: readings,
      outputs: outputs,
      id: id,
      talking: talking,
      scene: %{
        line: line,
        targets: targets,
        seen_by: seen_by -- targets,
        # Words to someone away reach them from afar.
        away: away -- targets,
        back: Enum.filter(away, &(State.stat(after_line, &1, "away") == 0)),
        refused: refused
      }
    }
  end

  # The scene the reply before a line named: its people are there (someone
  # new joins the cast), the others away. The chain of ids takes the scene
  # in, so a line after a rerolled reply is not mistaken for the same line
  # after the first one. The player talks to someone who is there.
  defp in_scene(state, nil, prev, talking), do: {state, prev, talking}

  defp in_scene(state, scene, prev, talking) do
    state = Aethrion.Bridge.Scene.enter(state, scene)
    here = present(state)

    chain =
      [prev, 0, "scene", 0, :erlang.term_to_binary(scene, [:deterministic])]
      |> sha()
      |> binary_part(0, 24)

    {state, chain, if(talking in here, do: talking, else: List.first(here) || talking)}
  end

  # The characters in the story who are not foes.
  defp people(state),
    do: Enum.filter(State.sorted_characters(state), &(State.stat(state, &1.id, "enemy") == 0))

  # Who sees what the player does: the characters there, standing, awake.
  defp present(state) do
    for c <- people(state),
        c.state.active?,
        State.stat(state, c.id, "away") == 0,
        not State.down?(state, c.id),
        do: c.id
  end

  defp witnessed(%{type: type} = event, seen_by) when type in @witnessed do
    if Map.get(event, :observed_by, []) != [],
      do: event,
      else: Map.put(event, :observed_by, Enum.reject(seen_by, &(&1 in [event.from, event.to])))
  end

  defp witnessed(event, _seen_by), do: event

  defp pass_time(%State{story: story} = state, outputs) do
    case story && Map.get(story, :turn_hours) do
      hours when is_integer(hours) ->
        case Runtime.step(state, Event.time_tick("hour #{state.clock + hours}", hours: hours)) do
          {:ok, step} -> {step.state, outputs ++ step.outputs}
          {:error, _rejected} -> {state, outputs}
        end

      nil ->
        {state, outputs}
    end
  end

  # Whom the line spoke to, gave to, or apologized to.
  defp addressee(state, readings) do
    readings
    |> Enum.reverse()
    |> Enum.find_value(fn %{event: event} ->
      to = Map.get(event, :to)

      if event.type in @witnessed and is_binary(to) and State.character?(state, to) and
           State.stat(state, to, "enemy") == 0,
         do: to
    end)
  end

  # How the characters' feelings toward each other moved this turn (not
  # toward the player), from what the rules changed: `[{from, to, field,
  # delta}]`, largest first, at most `@between_max`. Time's own easing of
  # tension is no event, so it is not among them.
  defp between(state, outputs) do
    ids = MapSet.new(people(state), & &1.id)

    for %{type: :relationship_changed, from: from, to: to, delta: delta} <- outputs,
        from in ids and to in ids,
        {field, d} <- delta,
        field in [:affinity, :trust, :tension],
        reduce: %{} do
      acc -> Map.update(acc, {from, to, field}, d, &(&1 + d))
    end
    |> Enum.reject(fn {_key, d} -> d == 0 end)
    |> Enum.map(fn {{from, to, field}, d} -> {from, to, field, d} end)
    |> Enum.sort_by(fn {from, to, field, d} -> {-abs(d), from, to, field} end)
    |> Enum.take(@between_max)
  end

  # The story (endings, lore, activities) is the cast's, the same in every
  # world of it: it is left out of checkpoints and put back from the cast.
  defp with_story(state, nil), do: %{state | story: %{}}
  defp with_story(state, %State{story: story}), do: %{state | story: story}

  defp checkpoint(prev, line, state, talking, root),
    do: %{
      prev: prev,
      line: digest(line),
      root: root,
      talking: talking,
      state: with_story(state, nil)
    }

  # Checkpoints are kept as JSON (`Aethrion.Bridge.Store`); the world in one
  # is read back only when a replay starts from it.
  defp as_json(nil), do: nil

  defp as_json(%{get: get, put: put}) do
    %{
      get: fn id ->
        case get.(id) do
          %{"prev" => prev, "line" => line, "root" => root, "state" => data} = kept ->
            %{prev: prev, line: line, root: root, talking: kept["talking"], state: {:data, data}}

          _none ->
            nil
        end
      end,
      put: fn id, checkpoint ->
        put.(id, %{
          "prev" => checkpoint.prev,
          "line" => checkpoint.line,
          "root" => checkpoint.root,
          "talking" => checkpoint.talking,
          "state" => State.to_data(checkpoint.state)
        })
      end
    }
  end

  # The player's lines, each with whether a reply came after it and that
  # reply's checkpoint id. A chat the app trimmed may begin with a reply: it
  # is kept, with no line, for its checkpoint.
  defp turns(chat, scenes?) do
    {turns, _scene} =
      Enum.reduce(chat, {[], nil}, fn
        %{"role" => "user", "content" => text}, {turns, scene} ->
          if String.trim(text) == "",
            do: {turns, scene},
            else: {[%{line: text, id: nil, replied: false, scene: scene} | turns], nil}

        %{"role" => "assistant"} = reply, {[%{replied: false} = turn | turns], _scene} ->
          {[%{turn | id: reply["checkpoint"], replied: true} | turns], scenes? && reply["scene"]}

        %{"role" => "assistant", "checkpoint" => id} = reply, {[], _scene} when is_binary(id) ->
          {[%{line: nil, id: id, replied: true}], scenes? && reply["scene"]}

        _other, acc ->
          acc
      end)

    turns
    |> Enum.map(fn
      %{scene: false} = turn -> %{turn | scene: nil}
      turn -> turn
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
  # walking back from its reply's checkpoint one line at a time. Only edits
  # in place are taken that way: a deleted line would land the walk in a
  # world that already holds the first line, which is refused. (A line
  # edited into the one before it looks the same, and replays from the
  # cast.)
  defp edited_first(turns, root, get) do
    with index when is_integer(index) <- Enum.find_index(turns, &is_binary(&1.id)),
         lines = Enum.take(turns, index + 1),
         true <- Enum.all?(lines, &is_binary(&1.line)),
         {id, changed} when is_binary(id) and id != root and changed > 0 <-
           back(Enum.at(turns, index).id, Enum.reverse(lines), 0, get),
         first = digest(hd(lines).line),
         %{line: before} = saved when before != first <- get.(id) do
      {-1, id, saved}
    else
      _other -> nil
    end
  end

  # Back over the lines, counting those that differ from what was kept.
  defp back(id, [], changed, _get), do: {id, changed}

  defp back(id, [%{line: line} | lines], changed, get) do
    case get.(id) do
      %{prev: prev, line: kept} ->
        back(prev, lines, changed + if(kept == digest(line), do: 0, else: 1), get)

      nil ->
        nil
    end
  end

  # A chat whose replies carry no ids (`aethrion-plain`), from its start:
  # the ids follow from the lines and whom each was said to, so the
  # checkpoints can still be found. Another chat may have begun with the
  # same words to someone else, so the longest chain wins (the character
  # asked for first among equals). Only up to the last reply: the lines
  # after it are this turn's, and are always replayed.
  defp computed(turns, root, to, characters, get) do
    answered =
      length(turns) -
        (turns |> Enum.reverse() |> Enum.find_index(& &1.replied) || length(turns))

    turns
    |> Enum.take(answered)
    |> Enum.with_index()
    |> longest(root, Enum.uniq([to | characters]), get, nil)
  end

  defp longest([{%{line: line}, index} | rest], prev, tos, get, found) when is_binary(line) do
    digest = digest(line)

    tos
    |> Enum.flat_map(fn to ->
      id = checkpoint_id(prev, to, line)

      case get.(id) do
        %{line: ^digest} = saved -> [longest(rest, id, tos, get, {index, id, saved})]
        _missing -> []
      end
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> found end)
  end

  defp longest(_turns, _prev, _tos, _get, found), do: found

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

  defp digest(line), do: :crypto.hash(:sha256, line) |> Base.encode64()

  # The chain starts from the cast; a checkpoint keeps its root, so another
  # cast's checkpoints are never used.
  @doc false
  def root(state),
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

  Options: `:card_status` (default false). A card the rules were not made
  for (`Aethrion.Bridge.AutoCast`) may print a status window of its own;
  with `card_status: true` the note leaves it to the card, and asks only
  that what the rules track shows the rules' numbers there. `:scene`
  (default false): the note says who is away, and asks the model to end its
  reply with who is with the player (`Aethrion.Bridge.Scene`).
  """
  @spec note(State.t(), State.t(), map(), :ko | :en, keyword()) :: String.t()
  def note(%State{} = before, %State{} = now, turn, locale \\ :ko, opts \\ []) do
    happened = happened(before, now, turn, locale)

    window =
      if Keyword.get(opts, :card_status, false),
        do:
          "and do not invent hits, heals, or endings beyond these. If the card asks for a status window or a format of its own, keep it as the card says; where it shows something listed here (how a character feels about the player), it shows these numbers, fitted to the card's scale. A separate window shows these rules' numbers, so do not print them a second time on your own.",
        else:
          "do not invent hits, heals, or endings beyond these, and do not print a status window: it is shown separately."

    scene? = Keyword.get(opts, :scene, false)
    standing = standing(now, locale, scene?)

    """
    [Aethrion: the game's rules, not the story, decide these. Narrate the next reply so it agrees with them; do not change any number, #{window}#{if scene?, do: " " <> Aethrion.Bridge.Scene.instruction()}]
    #{if happened == [], do: "This turn: nothing the rules track changed.", else: "This turn:\n" <> Enum.join(happened, "\n")}
    Now:
    #{if standing == [], do: "- No one the rules know of yet.", else: Enum.join(standing, "\n")}
    """
    |> String.trim()
  end

  defp happened(before, now, %{readings: readings, outputs: outputs} = turn, locale) do
    read =
      for %{as: as, event: event} <- readings, as != :talk do
        "- The player's line was read as #{as}#{target(now, event)}."
      end

    told =
      for output <- outputs, line = told(output, now, locale), line != nil, do: "- " <> line

    read ++
      scenes(now, turn) ++
      told ++
      changes(before, now) ++
      between_lines(now, turn) ++
      moods(before, now) ++
      remembered(before, now)
  end

  # What each character remembers about the player from before this turn,
  # so the narration can recall it: what they lived through, saw, or heard,
  # and the impressions faded memories left. The memories hold ids; the
  # note names people.
  defp remembered(before, now) do
    for c <- people(now),
        known = MapSet.new(Memories.for_character(before, c.id, include_faded: true), & &1.id),
        memories =
          now
          |> Memories.relevant(c.id, focus: ["user"], limit: 3)
          |> Enum.filter(&(&1.id in known and "user" in &1.related_characters)),
        memories != [] do
      "- #{c.name} remembers: " <> Enum.map_join(memories, "; ", &recalled(now, &1))
    end
  end

  defp recalled(state, memory) do
    how =
      if memory.source,
        do: "heard from #{State.name(state, memory.source)}",
        else: to_string(memory.kind)

    hours = max(state.clock - memory.created_tick, 0)
    age = if hours == 0, do: "", else: ", #{hours} hours ago"
    "#{named(state, String.trim(memory.content))} (#{how}#{age})"
  end

  # Line by line: who saw the player's words and gifts, who was not there
  # to, and who came back after it. With several lines, each says which.
  defp scenes(state, turn) do
    scenes = Map.get(turn, :scenes, [])
    names = &Enum.map_join(&1, ", ", fn id -> State.name(state, id) end)

    Enum.flat_map(scenes, fn scene ->
      witnessed =
        if(scene.targets != [] and scene.seen_by != [],
          do: ["Seen by: #{names.(scene.seen_by)}."],
          else: []
        ) ++
          if scene.targets != [] and scene.away != [],
            do: ["Not there, and does not know: #{names.(scene.away)}."],
            else: []

      said =
        cond do
          witnessed == [] -> []
          length(scenes) == 1 -> Enum.map(witnessed, &("- " <> &1))
          true -> ["- \"#{quoted(scene.line)}\": " <> Enum.join(witnessed, " ")]
        end

      refused =
        for reason <- Map.get(scene, :refused, []),
            do: "- Did not happen: #{named(state, reason)}."

      said ++ refused ++ for(id <- scene.back, do: "- #{State.name(state, id)} is back.")
    end)
  end

  # A line as a short quote on one line of the note.
  defp quoted(line) do
    line = line |> String.replace(~r/\s+/u, " ") |> String.replace("\"", "'") |> String.trim()
    if String.length(line) > 40, do: String.slice(line, 0, 40) <> "…", else: line
  end

  # The rules' reasons name ids ("sera is away"); the note names people.
  defp named(state, reason) do
    state
    |> State.sorted_characters()
    |> Enum.reduce(String.trim_trailing(reason, "."), fn c, text ->
      String.replace(text, ~r/\b#{Regex.escape(c.id)}\b/, c.name)
    end)
    |> String.replace(~r/\buser\b/, "the player")
  end

  defp between_lines(state, turn) do
    turn
    |> Map.get(:between, [])
    |> Enum.group_by(fn {from, to, _field, _delta} -> {from, to} end)
    |> Enum.sort()
    |> Enum.map(fn {{from, to}, changes} ->
      "- #{State.name(state, from)} toward #{State.name(state, to)}: " <>
        Enum.map_join(changes, ", ", fn {_from, _to, f, d} ->
          "#{f} #{if d > 0, do: "+", else: ""}#{d}"
        end)
    end)
  end

  # How each character's feelings moved this turn, and their mood where it
  # ended up different.
  defp moods(before, now) do
    for c <- people(now),
        was = State.character(before, c.id),
        was != nil,
        feelings =
          for(
            f <- [:jealousy, :loneliness, :joy, :stress],
            d = Map.get(c.state, f) - Map.get(was.state, f),
            # Not the drift of each passing hour.
            abs(d) >= 5,
            do: "#{f} #{if d > 0, do: "+", else: ""}#{d}"
          ),
        mood = if(c.state.mood != was.state.mood, do: ["now #{c.state.mood}"], else: []),
        feelings ++ mood != [] do
      "- #{c.name} feels: " <> Enum.join(feelings ++ mood, ", ")
    end
  end

  defp target(state, %{to: to}) when is_binary(to), do: " (#{State.name(state, to)})"
  defp target(state, %{character: c}) when is_binary(c), do: " (#{State.name(state, c)})"
  defp target(_state, _event), do: ""

  defp told(%{type: :combat} = output, state, locale), do: Combat.describe(output, state, locale)

  defp told(%{type: :ending_reached, title: title} = o, _state, _locale),
    do: "Ending reached: #{title}. #{o[:description]}"

  defp told(%{type: :milestone_reached, title: title} = o, _state, _locale),
    do: "Unlocked: #{title}." <> if(o[:text], do: " #{o[:text]}", else: "")

  defp told(%{type: :character_interaction, kind: :gossip} = o, state, _locale) do
    {teller, listener} = {State.name(state, o.character_id), State.name(state, o.to)}

    # Someone away hears it from afar; they are not back yet.
    if State.stat(state, o.to, "away") > 0,
      do:
        "#{teller} sent word of it to #{listener}, who is still away and not back yet; now #{listener} knows.",
      else: "#{teller} told #{listener} about it, in private; now #{listener} knows."
  end

  defp told(%{type: :character_interaction, kind: :comfort} = o, state, _locale),
    do: "#{State.name(state, o.character_id)} comforted #{State.name(state, o.to)}."

  defp told(%{type: :character_interaction, kind: :together} = o, state, _locale),
    do: "#{State.name(state, o.character_id)} and #{State.name(state, o.to)} spent time together."

  defp told(%{type: :proactive_message} = o, state, _locale),
    do:
      "#{State.name(state, o.character_id)} reaches out to #{if o.to == "user", do: "the player", else: State.name(state, o.to)} (#{o.reason}): \"#{o.text}\""

  defp told(_output, _state, _locale), do: nil

  # How the characters' feelings toward the player moved.
  defp changes(before, now) do
    for character <- people(now),
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

  defp standing(state, locale, scene?) do
    people =
      for character <- State.sorted_characters(state),
          rel = State.get_relationship(state, character.id, "user"),
          not State.stat?(state, character.id, "enemy") or
            State.stat(state, character.id, "enemy") == 0 do
        "- #{character.name}: affinity #{rel.affinity}, trust #{rel.trust}, tension #{rel.tension}, " <>
          "#{Aethrion.Rules.Bond.derive(rel, state)}" <>
          hp(state, character.id) <>
          if(scene? and State.stat(state, character.id, "away") > 0,
            do: " (not with the player)",
            else: ""
          )
      end

    fighters =
      for id <- Enum.sort(Map.keys(state.stats)),
          State.stat?(state, id, "hp"),
          not State.character?(state, id) or State.stat(state, id, "enemy") > 0 do
        "- #{if id == "user", do: "the player", else: State.name(state, id)}#{hp(state, id)}"
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
  @spec status(State.t(), map(), :ko | :en, State.t() | nil, keyword()) :: String.t()
  def status(%State{} = state, turn, locale \\ :ko, before \\ nil, opts \\ []) do
    words = words(locale)

    lines =
      day(state, locale) ++
        player_line(state, before, words) ++
        people_lines(state, before, words, locale, Keyword.get(opts, :scene, false)) ++
        foe_lines(state, before) ++ between_status(state, turn, words) ++ story_events(turn)

    open = if turn[:id], do: ~s(<aethrion-status id="#{turn.id}">), else: "<aethrion-status>"

    open <>
      Enum.map_join(lines, "\n", &escape/1) <>
      turn_section(state, turn, locale) <> "</aethrion-status>"
  end

  defp player_line(state, before, words) do
    if State.stat?(state, "user", "hp"),
      do: ["#{words.you}" <> hp_short(state, "user", before)],
      else: []
  end

  # In a scene (`Aethrion.Bridge.Scene`), only who is there, or whose
  # feelings moved this turn: a story that has met many people would
  # otherwise list them all.
  defp people_lines(state, before, words, locale, scene?) do
    for character <- State.sorted_characters(state),
        State.stat(state, character.id, "enemy") == 0,
        rel = State.get_relationship(state, character.id, "user"),
        shown?(state, before, character.id, rel, scene?) do
      was = before && State.get_relationship(before, character.id, "user")

      "#{character.name} · #{words.affinity} #{rel.affinity}#{change(was && was.affinity, rel.affinity)}" <>
        " · #{words.trust} #{rel.trust}#{change(was && was.trust, rel.trust)}" <>
        hp_short(state, character.id, before) <> watched(state, character.id, before, locale)
    end
  end

  defp shown?(_state, _before, _id, _rel, false), do: true

  defp shown?(state, before, id, rel, true) do
    was = before && State.get_relationship(before, id, "user")

    State.stat(state, id, "away") == 0 or
      (was != nil and {was.affinity, was.trust} != {rel.affinity, rel.trust})
  end

  defp foe_lines(state, before) do
    for id <- Enum.sort(Map.keys(state.stats)), State.stat(state, id, "enemy") > 0 do
      "#{State.name(state, id)}" <> hp_short(state, id, before)
    end
  end

  defp between_status(state, turn, words) do
    turn
    |> Map.get(:between, [])
    |> Enum.group_by(fn {from, to, _field, _delta} -> {from, to} end)
    |> Enum.sort()
    |> Enum.map(fn {{from, to}, changes} ->
      "#{State.name(state, from)} → #{State.name(state, to)} · " <>
        Enum.map_join(changes, " · ", fn {_from, _to, f, d} ->
          "#{Map.fetch!(words, f)} #{if d > 0, do: "+", else: ""}#{d}"
        end)
    end)
  end

  defp story_events(turn) do
    for %{type: type} = o <- turn.outputs, type in [:ending_reached, :milestone_reached] do
      if type == :ending_reached, do: "★ #{o.title}", else: "♥ #{o.title}"
    end
  end

  # What the rules decided this turn, with the dice: the proof that the
  # numbers are computed. Display scripts fold it away.
  defp turn_section(state, turn, locale) do
    case turn_log(state, turn, locale) do
      [] ->
        ""

      log ->
        title = if locale == :ko, do: "이번 턴 판정", else: "This turn"

        ~s(\n<aethrion-turn title="#{title}">) <>
          Enum.map_join(log, "\n", &escape/1) <> "</aethrion-turn>"
    end
  end

  # How each line was read, who saw it, and what the rules did: dice,
  # gossip, comfort.
  defp turn_log(state, turn, locale) do
    read =
      for %{as: as, event: event} <- Map.get(turn, :readings, []),
          line = reading(state, as, event, locale),
          line != nil,
          do: line

    seen =
      for scene <- Map.get(turn, :scenes, []),
          scene.targets != [],
          line <- witnesses(state, scene, locale),
          do: line

    done =
      for output <- Map.get(turn, :outputs, []),
          line = logged(output, state, locale),
          line != nil,
          do: line

    read ++ seen ++ done
  end

  @tones_ko %{warm: "따뜻하게", neutral: "보통", cold: "차갑게", hostile: "적대적으로"}

  defp reading(state, :talk, %{to: to, tone: tone}, :ko) when is_binary(to),
    do: "읽기 · #{State.name(state, to)}에게 하는 말 (#{Map.get(@tones_ko, tone, tone)})"

  defp reading(state, :talk, %{to: to, tone: tone}, _en) when is_binary(to),
    do: "Read · talk to #{State.name(state, to)} (#{tone})"

  defp reading(state, :gift, %{to: to, item: item}, :ko),
    do: "읽기 · #{State.name(state, to)}에게 선물: #{item}"

  defp reading(state, :gift, %{to: to, item: item}, _en),
    do: "Read · a gift for #{State.name(state, to)}: #{item}"

  defp reading(_state, :activity, %{activity: activity}, :ko), do: "읽기 · 활동: #{activity}"
  defp reading(_state, :activity, %{activity: activity}, _en), do: "Read · activity: #{activity}"

  defp reading(state, :combat, %{type: type} = event, locale) do
    move = %{
      attack: {"공격", "attack"},
      defend: {"방어", "guard"},
      heal: {"치유", "heal"},
      flee: {"도망", "flee"}
    }

    {ko, en} = Map.get(move, type, {to_string(type), to_string(type)})
    at = if is_binary(event[:to]), do: State.name(state, event[:to])

    if locale == :ko,
      do: "읽기 · #{ko}" <> if(at, do: " → #{at}", else: ""),
      else: "Read · #{en}" <> if(at, do: " → #{at}", else: "")
  end

  defp reading(_state, _as, _event, _locale), do: nil

  defp witnesses(state, scene, locale) do
    names = &Enum.map_join(&1, ", ", fn id -> State.name(state, id) end)

    case locale do
      :ko ->
        if(scene.seen_by != [], do: ["목격 · #{names.(scene.seen_by)}"], else: []) ++
          if(scene.away != [], do: ["모름 · #{names.(scene.away)} (자리에 없음)"], else: [])

      _en ->
        if(scene.seen_by != [], do: ["Seen by · #{names.(scene.seen_by)}"], else: []) ++
          if(scene.away != [], do: ["Not there · #{names.(scene.away)}"], else: [])
    end
  end

  defp logged(%{type: :combat} = output, state, locale),
    do: Combat.describe(output, state, locale)

  defp logged(%{type: :character_interaction, kind: :gossip} = o, state, :ko),
    do: "소문 · #{State.name(state, o.character_id)} → #{State.name(state, o.to)}"

  defp logged(%{type: :character_interaction, kind: :comfort} = o, state, :ko),
    do: "위로 · #{State.name(state, o.character_id)} → #{State.name(state, o.to)}"

  defp logged(%{type: :character_interaction, kind: kind} = o, state, _en)
       when kind in [:gossip, :comfort],
       do: "#{kind} · #{State.name(state, o.character_id)} → #{State.name(state, o.to)}"

  defp logged(_output, _state, _locale), do: nil

  defp hp_short(state, id, before) do
    if State.stat?(state, id, "hp") do
      hp = State.stat(state, id, "hp")
      was = if before && State.stat?(before, id, "hp"), do: State.stat(before, id, "hp")
      " · HP #{hp}/#{State.stat(state, id, "max_hp")}#{change(was, hp)}"
    else
      ""
    end
  end

  # The other numbers that matter for someone: stats the cast names in its
  # labels or its story's conditions watch ("그림 실력 24"), and feelings the
  # conditions watch ("스트레스 30"). HP has its own place.
  defp watched(state, id, before, locale) do
    story = state.story
    labels = Map.get(story, :labels, %{})
    watch = Aethrion.Story.watched(story)
    stats = Map.get(state.stats, id, %{})

    shown =
      for {name, value} <- Enum.sort(stats),
          name not in ["hp", "max_hp"],
          Map.has_key?(labels, name) or {id, name} in watch.stats,
          value != 0 or {id, name} in watch.stats,
          do: {Map.get(labels, name, name), value, before && State.stat(before, id, name)}

    feelings =
      for {^id, field} <- watch.fields,
          now = feeling(state, id, field),
          now != nil,
          do:
            {Map.get(labels, field, Aethrion.Story.field_name(field, locale)), now,
             before && feeling(before, id, field)}

    Enum.map_join(shown ++ feelings, "", fn {label, now, was} ->
      " · #{label} #{now}#{change(was, now)}"
    end)
  end

  defp feeling(state, id, field) do
    case Map.get(state.characters, id) do
      nil -> nil
      character -> Map.get(character.state, String.to_existing_atom(field))
    end
  end

  # A story with a deadline counts days, the way a raising sim does.
  defp day(%State{story: %{deadline: deadline}} = state, locale) when is_integer(deadline) do
    passed = div(state.clock, 24)
    total = div(deadline, 24)
    if locale == :ko, do: ["#{passed}일째 / #{total}일"], else: ["Day #{passed} of #{total}"]
  end

  defp day(_state, _locale), do: []

  # What this turn changed, next to the number: "50 (+10)".
  defp change(nil, _now), do: ""
  defp change(was, was), do: ""
  defp change(was, now) when now > was, do: " (+#{now - was})"
  defp change(was, now), do: " (#{now - was})"

  defp words(:ko), do: %{affinity: "호감", trust: "신뢰", tension: "긴장", you: "나"}
  defp words(_en), do: %{affinity: "affinity", trust: "trust", tension: "tension", you: "You"}

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
  checkpoint of the world it is read in (`prev`). What is kept is JSON
  (the event as `Aethrion.Event.to_data/1` writes it), so it comes back in
  a fresh VM; a kept reading that does not read back is read again. A
  reading the rules gave in place of a failing interpreter is kept like any
  other: a chat app's server keeps a turn's readings only once its reply
  has gone out (`Aethrion.Bridge.Store.staged/1`), and a turn that was
  answered must replay the same.
  """
  def reader(opts, cache) do
    interpreter = Keyword.get(opts, :interpreter, Interpreter.Rules)

    fn state, line, prev, to ->
      key =
        :crypto.hash(:sha256, [inspect(interpreter), 0, prev, 0, to, 0, line])
        |> Base.encode16(case: :lower)

      case key |> cache.get.() |> from_json() do
        nil ->
          {:ok, readings, _meta} = Interpreter.read(state, "user", to, line, opts)
          cache.put.(key, to_json(readings))
          readings

        readings ->
          readings
      end
    end
  end

  @as ~w(combat activity gift talk)a

  defp to_json(readings),
    do:
      Enum.map(readings, fn %{as: as, confidence: confidence, event: event} ->
        %{"as" => Atom.to_string(as), "confidence" => confidence, "event" => Event.to_data(event)}
      end)

  @doc false
  # Readings as the reader keeps them, read back; nil when they do not read.
  def readings_from_data(data), do: from_json(data)

  defp from_json(readings) when is_list(readings) do
    Enum.reduce_while(readings, [], fn reading, acc ->
      with %{"as" => as, "confidence" => confidence, "event" => data} <- reading,
           as when is_atom(as) <- Enum.find(@as, &(Atom.to_string(&1) == as)),
           {:ok, event} <- Event.from_data(data) do
        {:cont, acc ++ [%{as: as, confidence: confidence, event: event}]}
      else
        _other -> {:halt, nil}
      end
    end)
  end

  defp from_json(_none), do: nil
end
