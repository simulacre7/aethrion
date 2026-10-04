defmodule Aethrion.Bridge.Ledger.Fields do
  @moduledoc """
  The fields of a card's status window, each line read as what it looks
  like. Cards write their windows in many shapes, and a field is whatever
  has a name and a value that can be put back in its place:

  - `Name: value` or `NAME=value` (after a bullet or a mark such as `◈`),
    the value being the rest of the line;
  - several of those on one line, split by `|` (or `│`), with a piece that
    has no name (a line of thought at the end of a one-line window) named
    `Note`, `Note 2`, and so on;
  - a row of a table, `Name | 62 | calm | a thought`: the first cell names
    it, the rest is its value;
  - a line led by a symbol, `📍 the beach`: the symbol names it;
  - a heading with something to say, `[Day 3/30 · noon]` or
    `━━ RECORD No.4 ━━`: its words name it, and what follows them is its
    value;
  - any other line of words, a note.

  Two fields of one name are told apart by a number (`HP`, `HP 2`).

  The window's own markers (`spec`) are no fields, except an opening text
  that is a heading or the first field's name.
  """

  @typedoc """
  A field: its name, its value, and where the value is in the window. A
  heading says that it is one (`heading?`), and a field named apart from
  another has the name the window writes (`written`).
  """
  @type field :: %{
          required(:name) => String.t(),
          required(:value) => String.t(),
          required(:at) => {non_neg_integer(), non_neg_integer()},
          optional(:heading?) => true,
          optional(:written) => String.t(),
          optional(:note?) => true
        }

  @doc "The fields of `window`, in order. `spec` has the window's opening and closing text."
  @spec read(String.t(), map() | nil) :: [field()]
  def read(window, spec \\ nil) do
    open = (spec && spec.open) || ""
    close = (spec && spec.close) || ""
    {heading, from} = heading(window, open)

    to =
      if close != "" and String.ends_with?(window, close) and
           byte_size(window) - byte_size(close) >= from,
         do: byte_size(window) - byte_size(close),
         else: byte_size(window)

    fields =
      heading ++
        (~r/[^\n]+/u
         |> Regex.scan(binary_part(window, from, to - from), return: :index)
         |> Enum.flat_map(fn [{start, length}] -> line(window, from + start, length) end))

    # Free text counts only next to named values: a window, not a paragraph.
    if Enum.count(fields, & &1.name) >= 2,
      do: fields |> name_notes() |> apart(),
      else: Enum.filter(fields, & &1.name)
  end

  @doc """
  A field's name as it is looked up: in lower case, its spaces single, and
  without the marks before it ("❤️ HP" is "hp"), unless it is all marks.
  """
  @spec key(String.t()) :: String.t()
  def key(name) do
    key = name |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

    case String.replace(key, ~r/\A[^\p{L}\p{N}]+/u, "") do
      "" -> key
      bare -> bare
    end
  end

  @doc "A field's name as written, without the marks around it."
  @spec clean_name(String.t()) :: String.t()
  def clean_name(name),
    do: name |> String.replace(~r/[\[\]\*`_]/u, "") |> String.trim()

  # Two fields that would be looked up as one (two people's HP, "❤️ HP"
  # and "HP") are told apart: the later ones are "HP 2", "HP 3", or the
  # next number no field has.
  defp apart(fields) do
    taken = MapSet.new(fields, &key(&1.name))

    {fields, _state} =
      Enum.map_reduce(fields, {MapSet.new(), taken, %{}}, fn field, {seen, taken, next} ->
        own = key(field.name)

        if MapSet.member?(seen, own) do
          {name, n} = next_name(field.name, taken, Map.get(next, own, 2))
          field = field |> Map.put(:written, field.name) |> Map.put(:name, name)

          {field,
           {MapSet.put(seen, key(name)), MapSet.put(taken, key(name)), Map.put(next, own, n + 1)}}
        else
          {field, {MapSet.put(seen, own), taken, next}}
        end
      end)

    fields
  end

  # The name with the next number no field has, from `n` on.
  defp next_name(name, taken, n) do
    numbered = "#{name} #{n}"

    if MapSet.member?(taken, key(numbered)) and n < 100_000,
      do: next_name(name, taken, n + 1),
      else: {numbered, n}
  end

  # The field the opening text makes, and where the rest of the window
  # begins. An opening text that names the first field ("[Date:", "◈무공"
  # before ": 120") is left for the first line to read. One with more on
  # its line ("[Day" before " 3/30 · noon]", "━━ RECORD No." before
  # "4 ━━") is a heading: its words name a field, the rest of the line is
  # the value. Otherwise it is a marker, and the window begins after it.
  defp heading(window, open) do
    cond do
      open == "" or not String.starts_with?(window, open) ->
        {[], 0}

      names_first?(window, open) ->
        {[], 0}

      true ->
        after_open = binary_part(window, byte_size(open), byte_size(window) - byte_size(open))
        [rest] = Regex.run(~r/\A[^\n]*/u, after_open)
        name = open |> String.replace(~r/\A[^\p{L}\p{N}]+|[^\p{L}\p{N}]+\z/u, "") |> clean_name()

        # The value: the rest of the line, without the bracket that closes it,
        # nor the rule drawn after it ("4 ━━").
        value =
          rest
          |> String.trim()
          |> String.replace(~r/\s*[\]】］」]\z/u, "")
          |> String.replace(~r/\s+[━─═=\-–—*~_\s]+\z/u, "")
          |> String.replace(~r/\s*[\]】］」]\z/u, "")

        lead = byte_size(rest) - byte_size(String.trim_leading(rest))

        cond do
          # An opening text that is only a mark leads the first line when
          # that is a field ("📍 the beach"), and else stands in a title
          # ("*** Status ***"), which is no field.
          name == "" and not String.match?(open, ~r/[\[\]<>(){}]/u) ->
            if marked(window, 0, byte_size(open) + byte_size(rest)) ||
                 named(window, 0, byte_size(open) + byte_size(rest)),
               do: {[], 0},
               else: {[], byte_size(open) + byte_size(rest)}

          name != "" and String.match?(value, ~r/[\p{L}\p{N}]/u) ->
            {[
               %{
                 name: name,
                 value: value,
                 at: {byte_size(open) + lead, byte_size(value)},
                 heading?: true
               }
             ], byte_size(open) + byte_size(rest)}

          true ->
            {[], byte_size(open)}
        end
    end
  end

  defp names_first?(window, open) do
    after_open = String.replace_prefix(window, open, "")

    String.contains?(open, [":", "：", "=", "|", "│"]) or
      String.match?(after_open, ~r/\A[ \t]*[:：=]/u)
  end

  @max_line 2_000

  # The fields of one line of the window. A line too long to be a field is
  # none.
  defp line(_window, _start, length) when length > @max_line, do: []

  defp line(window, start, length) do
    # Without the blanks around it: a line of spaces is not gone through
    # for a name.
    {start, length} = trimmed(window, start, length)
    text = binary_part(window, start, length)

    cells =
      ~r/[^|│｜]+/u
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{at, size}] -> trimmed(window, start + at, size) end)
      |> Enum.reject(fn {_at, size} -> size == 0 end)

    cond do
      length == 0 -> []
      several = several(window, cells) -> several
      row = row(window, cells, start + length) -> [row]
      joined = joined(window, text, start) -> joined
      true -> List.wrap(alone(window, text, start, length))
    end
  end

  # The fields of a line that joins them with "&" ("Item: a sword &
  # Currency: 3 silver"): two at least, each with its name. A piece with
  # no name belongs to the value before it ("Item: sword & shield").
  defp joined(window, text, start) do
    pieces =
      ~r/[^&]+/u
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{at, size}] -> {start + at, size} end)
      |> Enum.reduce([], fn {at, size}, acc ->
        case {named(window, at, size), acc} do
          {nil, [{before, _size} | rest]} -> [{before, at + size - before} | rest]
          {_field, acc} -> [{at, size} | acc]
        end
      end)
      |> Enum.reverse()
      |> Enum.map(fn {at, size} -> trimmed(window, at, size) end)

    fields = Enum.map(pieces, fn {at, size} -> named(window, at, size) end)
    if length(fields) >= 2 and Enum.all?(fields), do: fields
  end

  # The fields of a line that holds several, between bars; nil for a line
  # that is one field, or a row.
  defp several(window, cells) do
    named = Enum.map(cells, fn {at, size} -> named(window, at, size) end)
    marked = Enum.map(cells, fn {at, size} -> marked(window, at, size) end)
    either = Enum.zip_with(named, marked, &(&1 || &2))

    cond do
      # "Trust: 3% | Anger: 5% | a thought": each piece is a field.
      Enum.count(named, & &1) >= 2 -> pieces(window, cells, named)
      # "⏰ 14:30 | 📍 the school | ❤️ 30": each piece led by its mark.
      length(cells) >= 2 and Enum.all?(either) -> pieces(window, cells, either)
      true -> nil
    end
  end

  # A line that is one field, or a note, or nothing.
  defp alone(window, text, start, length) do
    # "[Day 3 · 14:30]": a heading, before its colon is read as a name's.
    heading =
      (String.starts_with?(text, "[") and String.ends_with?(text, "]")) &&
        headed(window, start, length)

    heading || named(window, start, length) || marked(window, start, length) ||
      headed(window, start, length) || free(text, start)
  end

  defp pieces(window, cells, fields) do
    cells
    |> Enum.zip(fields)
    # (Between bars a piece with no name is a note, however short.)
    |> Enum.map(fn {{at, size}, field} -> field || free(binary_part(window, at, size), at, 2) end)
    |> Enum.reject(&is_nil/1)
  end

  # A span of the window without the spaces and tabs at its ends.
  defp trimmed(window, start, length) do
    text = binary_part(window, start, length)
    lead = byte_size(text) - byte_size(String.replace(text, ~r/\A[ \t\r]+/, ""))
    kept = text |> String.replace(~r/\A[ \t\r]+/, "") |> String.replace(~r/[ \t\r]+\z/, "")
    {start + lead, byte_size(kept)}
  end

  @named ~r/\A(\s*(?:[-*•◈▶▪·\[]\s*)?)([^:：=\n]{1,40}?)\s*[:：]\s*(.*?)\s*\z/us
  @assigned ~r/\A(\s*(?:[-*•◈▶▪·\[]\s*)?)([\p{L}\p{N}_]{1,24})[ \t]*=[ \t]*(.*?)\s*\z/us

  # `Name: value` or `NAME=value`, after a bullet or a mark.
  defp named(window, start, length) do
    text = binary_part(window, start, length)

    case Regex.run(@named, text, return: :index) || Regex.run(@assigned, text, return: :index) do
      [_all, {lead_at, lead_length}, {name_at, name_length}, {value_at, value_length}] ->
        name = text |> binary_part(name_at, name_length) |> clean_name()
        lead = binary_part(text, lead_at, lead_length)

        # "[rating: 51]": the bracket the line opened with closes after
        # the value, and is no part of it.
        value_length = unbracketed(lead, binary_part(text, value_at, value_length))
        value = binary_part(text, value_at, value_length)

        # ("⏰ 09:47" names nothing with its colon, which stands between
        # digits: that is a clock. "Player 2: 12 / 20" is a field.)
        clock? = String.match?(text, ~r/\A[^:：=\n]*[0-9][:：][0-9]{2}(?![0-9])/u)

        if name != "" and value_length > 0 and not clock?,
          do: %{name: name, value: value, at: {start + value_at, value_length}}

      nil ->
        nil
    end
  end

  # The length of a value without the bracket that closes its line, when
  # the line opened with one and the value closes more than it opens.
  defp unbracketed(lead, value) do
    count = fn mark -> length(String.split(value, mark)) - 1 end

    if String.contains?(lead, "[") and String.ends_with?(value, "]") and
         count.("]") > count.("["),
       do: value |> binary_part(0, byte_size(value) - 1) |> String.trim_trailing() |> byte_size(),
       else: byte_size(value)
  end

  # A row of a table: a short name in the first cell, and the rest of the
  # line as its value, when that begins with a number ("Tyler | 62 | calm")
  # or has at least two more cells ("Hansol | Rank 10 | P 0 | the baths").
  defp row(window, [{name_at, name_size}, {second_at, second_size} | more], line_end) do
    name = window |> binary_part(name_at, name_size) |> clean_name()
    second = binary_part(window, second_at, second_size)

    if String.match?(name, ~r/\A\p{L}[^:：=]{0,23}\z/u) and
         (String.match?(second, ~r/\A\s*-?[0-9]/u) or more != []) do
      lead = byte_size(second) - byte_size(String.trim_leading(second))
      from = second_at + lead
      value = window |> binary_part(from, line_end - from) |> String.trim_trailing()
      %{name: name, value: value, at: {from, byte_size(value)}}
    end
  end

  defp row(_window, _cells, _line_end), do: nil

  # A line led by a symbol ("📍 the beach"): the symbol names it.
  defp marked(window, start, length) do
    text = binary_part(window, start, length)

    case Regex.run(
           ~r/\A\s*([^\p{L}\p{N}\s\[\](){}<>|:：\-=#*`_~.,'"!?━─]{1,4})[ \t]+(\S.*?)\s*\z/us,
           text,
           return: :index
         ) do
      [_all, {name_at, name_length}, {value_at, value_length}] ->
        %{
          name: binary_part(text, name_at, name_length),
          value: binary_part(text, value_at, value_length),
          at: {start + value_at, value_length}
        }

      nil ->
        nil
    end
  end

  # A heading in brackets with something to say ("[Day 3/30 · noon]"),
  # further down the window.
  defp headed(window, start, length) do
    text = binary_part(window, start, length)

    case Regex.run(
           ~r/\A\s*\[\s*(\p{L}[\p{L}\p{N}_]{0,19})[ \t]+([^\]\n]*[\p{L}\p{N}][^\]\n]*?)\s*\]\s*\z/us,
           text,
           return: :index
         ) do
      [_all, {name_at, name_length}, {value_at, value_length}] ->
        value = binary_part(text, value_at, value_length)

        # Words alone are a part's title ("[Player Character]"), which
        # says nothing that changes.
        if String.match?(value, ~r/[0-9·•|\/:：,~\-–—]/u),
          do: %{
            name: binary_part(text, name_at, name_length),
            value: value,
            at: {start + value_at, value_length},
            heading?: true
          }

      nil ->
        nil
    end
  end

  # Free text between the markers: kept as a note when it reads as a
  # sentence, not when it is a rule of dashes or a heading.
  defp free(text, start, least \\ 12) do
    case Regex.run(~r/\A(\s*)(.*?)(\s*)\z/us, text, return: :index) do
      [_all, _lead, {at, length}, _tail] when length >= least ->
        value = binary_part(text, at, length)

        if String.match?(value, ~r/\p{L}.*\p{L}/us) and not String.match?(value, ~r/\A[\[<#=]/u),
          do: %{name: nil, value: value, at: {start + at, length}}

      _other ->
        nil
    end
  end

  defp name_notes(fields) do
    {named, _count} =
      Enum.map_reduce(fields, 0, fn
        %{name: nil} = field, 0 ->
          {field |> Map.put(:name, "Note") |> Map.put(:note?, true), 1}

        %{name: nil} = field, n ->
          {field |> Map.put(:name, "Note #{n + 1}") |> Map.put(:note?, true), n + 1}

        field, n ->
          {field, n}
      end)

    named
  end
end
