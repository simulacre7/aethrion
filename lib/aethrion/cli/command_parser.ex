defmodule Aethrion.CLI.CommandParser do
  @moduledoc """
  Parser for the interactive demo command language.
  """

  alias Aethrion.Event

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
  defp do_parse(["memories"]), do: {:ok, :memories}

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
    observed_by =
      observers
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    {:ok, Event.gift_received(from, to, item, observed_by: observed_by, at: "interactive:gift")}
  end

  defp do_parse(_tokens) do
    {:error, "unknown command. Type help for available commands."}
  end
end
