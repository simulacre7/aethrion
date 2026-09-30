defmodule Aethrion.CLI.CommandParser do
  @moduledoc false
  # Parser for the interactive demo command language. See `Aethrion.CLI.Display.help/0`.

  alias Aethrion.Event

  @character_fields %{
    "mood" => :mood,
    "loneliness" => :loneliness,
    "jealousy" => :jealousy,
    "joy" => :joy,
    "stress" => :stress,
    "energy" => :energy
  }

  @relationship_fields %{
    "affinity" => :affinity,
    "trust" => :trust,
    "tension" => :tension,
    "bond" => :bond
  }

  # Every command word, for case, usage lines, and typo suggestions.
  @commands ~w(apologize comfort context digest exit gift help here load memories message opinion quit record report rules save say status tick timeline undo why)

  # `resolve` turns what was typed where a character belongs ("Mina", "미나")
  # into an id; free text is left alone.
  def parse(line, resolve \\ & &1) when is_binary(line) do
    line
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> lower_command()
    |> resolve_names(resolve)
    |> do_parse()
  end

  # "Say Mina hi" is "say Mina hi"; an unknown word is left for the error.
  defp lower_command([command | args]) do
    lower = String.downcase(command)
    if lower in @commands, do: [lower | args], else: [command | args]
  end

  defp lower_command([]), do: []

  @one_name ~w(memories context say)
  @two_names ~w(opinion comfort gift apologize message)

  defp resolve_names([command, target | rest], resolve) when command == "why" do
    target =
      target
      |> String.split("->", parts: 2)
      |> Enum.map_join("->", &resolve_one(&1, resolve))

    [command, target | rest]
  end

  defp resolve_names([command, name | rest], resolve) when command in @one_name,
    do: [command, resolve_one(name, resolve) | rest]

  # Observers only follow text: the tone of a message is not text.
  defp resolve_names(["message", from, to, tone | rest], resolve),
    do: [
      "message",
      resolve_one(from, resolve),
      resolve_one(to, resolve),
      tone | resolve_observers(rest, resolve)
    ]

  defp resolve_names([command, from, to | rest], resolve) when command in @two_names,
    do: [
      command,
      resolve_one(from, resolve),
      resolve_one(to, resolve) | resolve_observers(rest, resolve)
    ]

  defp resolve_names(["here" | names], resolve) when names != ["none"],
    do: ["here" | Enum.map(names, &resolve_list(&1, resolve))]

  defp resolve_names(tokens, _resolve), do: tokens

  # Observers come last: "... observed_by Yuna,Haru".
  defp resolve_observers(tokens, resolve) do
    case Enum.split(tokens, -2) do
      {[_ | _] = words, ["observed_by", names]} ->
        words ++ ["observed_by", resolve_list(names, resolve)]

      _ ->
        tokens
    end
  end

  defp resolve_list(names, resolve),
    do: names |> String.split(",") |> Enum.map_join(",", &resolve_one(&1, resolve))

  defp resolve_one("", _resolve), do: ""
  defp resolve_one(name, resolve), do: resolve.(name)

  defp do_parse([]), do: {:ok, :noop}
  defp do_parse(["help"]), do: {:ok, :help}
  defp do_parse(["quit"]), do: {:ok, :quit}
  defp do_parse(["exit"]), do: {:ok, :quit}
  defp do_parse(["status"]), do: {:ok, :status}
  defp do_parse(["memories"]), do: {:ok, {:memories, nil}}
  defp do_parse(["memories", character]), do: {:ok, {:memories, character}}
  defp do_parse(["why", character]), do: {:ok, {:why, character}}

  defp do_parse(["why", target, field]) do
    case String.split(target, "->", parts: 2) do
      [from, to] when from != "" and to != "" ->
        with {:ok, field} <- field(field, @relationship_fields) do
          {:ok, {:why, {from, to}, field}}
        end

      [character] ->
        with {:ok, field} <- field(field, @character_fields) do
          {:ok, {:why, character, field}}
        end

      _ ->
        {:error, "why expects <character> [field] or <from>-><to> <field>"}
    end
  end

  defp do_parse(["context", character]), do: {:ok, {:context, character}}
  defp do_parse(["opinion", character, other]), do: {:ok, {:opinion, character, other}}
  defp do_parse(["here"]), do: {:ok, {:here, :show}}
  defp do_parse(["here", "none"]), do: {:ok, {:here, []}}
  defp do_parse(["here" | characters]), do: {:ok, {:here, observers(Enum.join(characters, ","))}}
  defp do_parse(["timeline"]), do: {:ok, :timeline}
  defp do_parse(["digest"]), do: {:ok, :digest}
  defp do_parse(["rules"]), do: {:ok, :rules}
  defp do_parse(["undo"]), do: {:ok, :undo}
  defp do_parse(["save", path]), do: {:ok, {:save, path}}
  defp do_parse(["load", path]), do: {:ok, {:load, path}}
  defp do_parse(["record", path]), do: {:ok, {:record, path}}
  defp do_parse(["report", path]), do: {:ok, {:report, path}}

  defp do_parse(["say", to | words]) when words != [] do
    {:ok, {:say, to, Enum.join(words, " ")}}
  end

  defp do_parse(["tick", hours]) do
    case Integer.parse(hours) do
      {hours, ""} when hours > 0 -> {:ok, Event.time_tick("interactive:tick", hours: hours)}
      _ -> {:error, "tick expects a positive integer hour value"}
    end
  end

  defp do_parse(["gift", from, to, item]) do
    {:ok, Event.gift_received(from, to, item, observed_by: [], at: "interactive:gift")}
  end

  defp do_parse(["gift", from, to, item, "observed_by", observers]) do
    {:ok,
     Event.gift_received(from, to, item,
       observed_by: observers(observers),
       at: "interactive:gift"
     )}
  end

  defp do_parse(["apologize", from, to | reason_parts]) when reason_parts != [] do
    {words, observed_by} = trailing_observers(reason_parts)

    {:ok,
     Event.apology_offered(from, to, Enum.join(words, " "),
       observed_by: observed_by,
       at: "interactive:apology"
     )}
  end

  defp do_parse(["message", from, to, tone | words]) when words != [] do
    {words, observed_by} = trailing_observers(words)

    case Enum.find(Event.tones(), &(Atom.to_string(&1) == tone)) do
      nil ->
        {:error, "tone must be one of: #{Enum.map_join(Event.tones(), ", ", &Atom.to_string/1)}"}

      tone ->
        {:ok,
         Event.message_sent(from, to, Enum.join(words, " "),
           tone: tone,
           observed_by: observed_by,
           at: "interactive:message"
         )}
    end
  end

  defp do_parse(["comfort", from, to]) do
    {:ok, Event.comfort_offered(from, to, at: "interactive:comfort")}
  end

  # A known command with the wrong arguments gets its usage line.
  @usage %{
    "say" => "say <character> <text>",
    "message" => "message <from> <to> <tone> <text> [observed_by a,b]",
    "gift" => "gift <from> <to> <item> [observed_by a,b]",
    "apologize" => "apologize <from> <to> <reason> [observed_by a,b]",
    "comfort" => "comfort <from> <to>",
    "tick" => "tick <hours>",
    "memories" => "memories [character]",
    "why" => "why <character> [field] | why <from>-><to> <field>",
    "context" => "context <character>",
    "opinion" => "opinion <character> <other>",
    "save" => "save <path>",
    "load" => "load <path>",
    "record" => "record <path>",
    "report" => "report <path>"
  }

  defp do_parse([command | _args]) when is_map_key(@usage, command) do
    {:error, "usage: #{Map.fetch!(@usage, command)}"}
  end

  # A mistyped or capitalized command gets the one it probably meant.
  defp do_parse([command | args]) do
    lower = String.downcase(command)

    cond do
      lower != command and lower in @commands ->
        do_parse([lower | args])

      lower in @commands ->
        {:error, "#{lower} takes no arguments. Type help for all commands."}

      guess = Enum.max_by(@commands, &String.jaro_distance(&1, lower), fn -> nil end) ->
        if String.jaro_distance(guess, lower) >= 0.8,
          do:
            {:error,
             "unknown command #{command}; did you mean #{guess}? Type help for all commands."},
          else: {:error, "unknown command #{command}. Type help for available commands."}
    end
  end

  # Text followed by "observed_by a,b"; too short to be both, it is all text.
  defp trailing_observers(words) do
    case Enum.split(words, -2) do
      {[_ | _] = text, ["observed_by", observers]} -> {text, observers(observers)}
      _other -> {words, []}
    end
  end

  defp observers(list), do: list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  # Fields map through literal atoms, so input never creates atoms and the
  # lookup never depends on which modules happen to be loaded.
  defp field(name, allowed) do
    case Map.fetch(allowed, name) do
      {:ok, field} ->
        {:ok, field}

      :error ->
        {:error,
         "field must be one of: #{allowed |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}
    end
  end
end
