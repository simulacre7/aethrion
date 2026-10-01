defmodule Mix.Tasks.Aethrion.Card do
  @shortdoc "Reads a character card (PNG, JSON, CHARX) into a cast"
  @moduledoc """
  Turns a character card (V1, V2, or V3; a PNG, JSON, or CHARX file, as
  RisuAI, SillyTavern, and others share them) into a cast, or adds it to
  one (`Aethrion.Card`):

      mix aethrion.card lumi.png --out priv/casts/lumi.json
      mix aethrion.card lumi.png --into priv/casts/cafe.json
      mix aethrion.card 서윤.charx --player 선생님 --id seoyun --out casts/seoyun.json

  Options: `--out FILE` (default: print the cast), `--into FILE` (add the
  character, its relationship, and its lore to a cast; written back to
  `--out`, or to the same file), `--player NAME` (what the card's
  `{{user}}` becomes; default `user`), `--id ID` (the character's id).

  Cards hold no game numbers: relationships start neutral, and stats,
  endings, and bond stories are added in the cast (the editor at `/editor`).
  """

  use Mix.Task

  @switches [out: :string, into: :string, player: :string, id: :string]

  @impl Mix.Task
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: @switches)

    file =
      case files do
        [file] ->
          file

        _other ->
          Mix.raise(
            "usage: mix aethrion.card CARD [--out FILE] [--into CAST] [--player NAME] [--id ID]"
          )
      end

    data =
      case file |> File.read!() |> Aethrion.Card.read() do
        {:ok, data} -> data
        {:error, reason} -> Mix.raise("#{file} is not a character card (#{inspect(reason)})")
      end

    {cast, notes} =
      Aethrion.Card.to_cast(
        data,
        Keyword.take(opts, [:player, :id]) |> Enum.reject(&is_nil(elem(&1, 1)))
      )

    cast = if into = opts[:into], do: Aethrion.Card.merge(read_json!(into), cast), else: cast

    case Aethrion.State.parse(cast) do
      {:ok, _state} -> :ok
      {:error, error} -> Mix.raise("the result is not a valid cast: #{error.message}")
    end

    json = Jason.encode!(cast, pretty: true) <> "\n"

    case opts[:out] || opts[:into] do
      nil ->
        IO.write(json)

      out ->
        File.write!(out, json)
        Mix.shell().info("wrote #{out}")
    end

    for note <- notes, do: Mix.shell().info("note: #{note}")
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
