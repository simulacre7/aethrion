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

  def parse(line) when is_binary(line) do
    line
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> do_parse()
  end

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

  defp do_parse(_tokens) do
    {:error, "unknown command. Type help for available commands."}
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
