defmodule Aethrion.Bridge.Ledger.Cells do
  @moduledoc """
  The labelled numbers in a row of a card's status window.

  Some cards keep a table, one row to a person, with several numbers to a
  row, each after its label:

      Hansol | Rank 10 | P 0 (+0) | L 0 | C 0 | I 0 | B2 baths | -

  The row is one field (`Aethrion.Bridge.Ledger.Fields`), named `Hansol`,
  and a model may write it anew. But asked what changed, a model names the
  numbers by their labels (`Hansol: L +1, C +2`), and the card's arithmetic
  speaks of the labels too (`L = clamp(L, 0, 100)`). So the labelled
  numbers of a row are read (`read/1`), moved by a change that names them
  (`change/2`), and written back in their places (`put/2`).
  """

  @typedoc "A labelled number: its label, the number, and where its digits are in the row."
  @type cell :: %{
          label: String.t(),
          number: integer(),
          at: {non_neg_integer(), non_neg_integer()}
        }

  @cell ~r/\A(\s*)(\p{L}[\p{L}\p{N}]{0,11})(\s+)(-?[0-9]+)(?![0-9.,][0-9]|[0-9])/u

  @doc """
  The labelled numbers of a row's value, in order; none unless the row has
  at least two (one label and a number is a sentence as often as a cell).
  """
  @spec read(String.t()) :: [cell()]
  def read(value) do
    cells =
      ~r/[^|│｜]+/u
      |> Regex.scan(value, return: :index)
      |> Enum.flat_map(fn [{start, length}] ->
        case Regex.run(@cell, binary_part(value, start, length), return: :index) do
          [_all, {_lead_at, lead}, {_label_at, label_size}, {_gap_at, gap}, {_at, digits}] ->
            label = binary_part(value, start + lead, label_size)
            at = start + lead + label_size + gap

            [
              %{
                label: label,
                number: value |> binary_part(at, digits) |> String.to_integer(),
                at: {at, digits}
              }
            ]

          nil ->
            []
        end
      end)
      |> Enum.uniq_by(&key(&1.label))

    if length(cells) >= 2, do: cells, else: []
  end

  defp key(label), do: String.downcase(label)

  @doc """
  The row after a change that names its numbers by their labels:
  `{:ok, value, nil}`. A number with a sign moves (`L +1, C: +2`); one
  without is the new value, as the row itself writes it (`L 1`).
  `:rewrite` for a change that is the row written anew, and `:none` for
  one that names no label of the row.
  """
  @spec change(String.t(), String.t()) ::
          {:ok, String.t(), atom() | nil} | :rewrite | :none
  def change(row, change) do
    cells = read(row)
    labels = Map.new(cells, &{key(&1.label), &1})
    bars = fn text -> length(Regex.scan(~r/[|│｜]/u, text)) end

    named =
      for [_all, label, sign, n] <-
            Regex.scan(~r/(\p{L}[\p{L}\p{N}]{0,11})\s*[:：]?\s*([+\-−]?)\s*([0-9]+)/u, change),
          Map.has_key?(labels, key(label)),
          do: {key(label), sign, String.to_integer(n)}

    cond do
      cells == [] ->
        :none

      # As many cells as the row has: the row, written anew.
      bars.(change) >= max(bars.(row) - 1, 1) ->
        :rewrite

      named == [] ->
        :none

      true ->
        # A number with its sign moves; without one it is the number as
        # the row would write it ("L 1"), so the new value.
        numbers =
          for {label, sign, n} <- named, into: %{} do
            case sign do
              "" -> {label, n}
              "+" -> {label, labels[label].number + n}
              _minus -> {label, labels[label].number - n}
            end
          end

        {:ok, put(row, numbers), nil}
    end
  end

  @doc "The row with its labelled numbers set to `numbers` (by label, in lower case)."
  @spec put(String.t(), %{String.t() => integer()}) :: String.t()
  def put(row, numbers) do
    # Later cells first, so the earlier ones' places stay where they are.
    row
    |> read()
    |> Enum.filter(&Map.has_key?(numbers, key(&1.label)))
    |> Enum.sort_by(fn %{at: {at, _size}} -> -at end)
    |> Enum.reduce(row, fn %{label: label, at: {at, size}}, text ->
      binary_part(text, 0, at) <>
        Integer.to_string(numbers[key(label)]) <>
        binary_part(text, at + size, byte_size(text) - at - size)
    end)
  end

  @doc "What moved between two values of a row, for the turn's record: `[\"L 0 → 1\"]`."
  @spec moved(String.t(), String.t()) :: [String.t()]
  def moved(was, now) do
    before = Map.new(read(was), &{key(&1.label), &1.number})

    for %{label: label, number: number} <- read(now),
        Map.has_key?(before, key(label)),
        before[key(label)] != number,
        do: "#{label} #{before[key(label)]} → #{number}"
  end
end
