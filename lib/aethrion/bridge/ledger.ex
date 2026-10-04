defmodule Aethrion.Bridge.Ledger do
  @moduledoc """
  A card's own status window, kept by the rules instead of the model, for a
  cast read from a card (`Aethrion.Bridge.AutoCast`).

  Many cards ask the model to print a status window with every reply: the
  player's level, HP, money, the date. A strong model keeps such a window
  right for a long time; a small one loses it within a few turns (levels
  that differ on every reroll, damage never taken off, points spent and not
  added). So the window is taken off the model's hands:

  - The window as it stood is read from the last reply in the chat
    (`current/2`): the text between the card's markers (`spec`, read with
    the card), with its fields (`fields/1`: `Name: value`, one to a line or
    split by `|`).
  - The note asks the model not to print the window, and to end its reply
    with what changed (`instruction/2`):

        <aethrion-ledger>
        HP: -12
        EXP: +18
        Location: 명월탑 1층
        </aethrion-ledger>

  - Those changes are taken out of the reply (`take/1`) and applied to the
    window (`apply/3`): a number goes up or down by what was said, a pair
    such as `96 / 140` stays within its maximum, a percentage within 0 to
    100, and a field nobody named stays as it was. The window is written
    back in the card's own format, so the card's display scripts still
    draw it.

  Nothing is kept on the server for this: the window in the last reply is
  the ledger, so a reroll starts again from the window before it, and a
  chat the app has trimmed still has its latest window.
  """

  @tag "<aethrion-ledger"
  @scene "<aethrion-scene"
  @max_changes 40
  @max_value 400

  @typedoc "The texts that open and close a card's status window."
  @type spec :: %{open: String.t(), close: String.t()}

  @typedoc "A field of a window: its name, its value, and where the value is."
  @type field :: %{
          name: String.t(),
          value: String.t(),
          at: {non_neg_integer(), non_neg_integer()}
        }

  @doc """
  The last status window in `text`: `{before, window, after}`, the window
  with its markers, or nil when there is none with at least two fields. A
  window with no closing text (`close: ""`) runs to the end of the text.
  """
  @spec window(String.t(), spec()) :: {String.t(), String.t(), String.t()} | nil
  def window(text, %{open: open} = spec) when is_binary(open) and open != "" do
    text
    |> :binary.matches(open)
    |> Enum.reverse()
    |> Enum.find_value(fn {start, length} ->
      with stop when is_integer(stop) <- closing(text, start + length, spec.close),
           window = binary_part(text, start, stop - start),
           true <- length(fields(window, spec)) >= 2 do
        {binary_part(text, 0, start), window, binary_part(text, stop, byte_size(text) - stop)}
      else
        _none -> nil
      end
    end)
  end

  def window(_text, _spec), do: nil

  # Where the window that opens before `from` ends.
  defp closing(text, _from, close) when close in [nil, ""],
    do: byte_size(String.trim_trailing(text))

  defp closing(text, from, close) do
    case :binary.match(text, close, scope: {from, byte_size(text) - from}) do
      {stop, length} -> stop + length
      :nomatch -> nil
    end
  end

  @doc "The window as it stood: the one in the last reply of the chat that has one."
  @spec current([map()], spec() | nil) :: String.t() | nil
  def current(_chat, nil), do: nil

  def current(chat, spec) do
    chat
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "assistant", "content" => content} ->
        case window(content, spec) do
          {_before, window, _after} -> window
          nil -> nil
        end

      _other ->
        nil
    end)
  end

  @doc """
  The fields of a window, in order: `Name: value` pieces, one to a line or
  split by `|`. A piece with no name (a line of thought at the end of a
  one-line window) is named `Note`, `Note 2`, and so on. The window's own
  markers (`spec`) are no fields.
  """
  @spec fields(String.t(), spec() | nil) :: [field()]
  def fields(window, spec \\ nil) do
    {from, to} = body(window, spec)

    fields =
      ~r/[^\n|]+/u
      |> Regex.scan(binary_part(window, from, to - from), return: :index)
      |> Enum.map(fn [{start, length}] -> piece(window, from + start, length) end)
      |> Enum.reject(&is_nil/1)

    # Free text counts only next to named values: a window, not a paragraph.
    if Enum.count(fields, & &1.name) >= 2,
      do: name_notes(fields),
      else: Enum.filter(fields, & &1.name)
  end

  # The part of the window between its markers. An opening text that names
  # the first field ("[Date:") is kept: the name is read from it.
  defp body(window, spec) do
    open = (spec && spec.open) || ""
    close = (spec && spec.close) || ""

    from =
      if open != "" and String.starts_with?(window, open) and
           not String.contains?(open, [":", "："]),
         do: byte_size(open),
         else: 0

    to =
      if close != "" and String.ends_with?(window, close) and
           byte_size(window) - byte_size(close) >= from,
         do: byte_size(window) - byte_size(close),
         else: byte_size(window)

    {from, to}
  end

  # One piece of the window: a named value, or free text.
  defp piece(window, start, length) do
    text = binary_part(window, start, length)

    case Regex.run(~r/\A(\s*(?:[-*•◈▶▪·]\s*)?)([^:：\n]{1,40}?)\s*[:：]\s*(.*?)\s*\z/us, text,
           return: :index
         ) do
      [_all, _lead, {name_at, name_length}, {value_at, value_length}] ->
        name = text |> binary_part(name_at, name_length) |> clean_name()

        if name == "" or value_length == 0,
          do: nil,
          else: %{
            name: name,
            value: binary_part(text, value_at, value_length),
            at: {start + value_at, value_length}
          }

      nil ->
        free(text, start)
    end
  end

  # Free text between the markers: kept as a note when it reads as a
  # sentence, not when it is a rule of dashes or a heading.
  defp free(text, start) do
    case Regex.run(~r/\A(\s*)(.*?)(\s*)\z/us, text, return: :index) do
      [_all, _lead, {at, length}, _tail] when length >= 12 ->
        value = binary_part(text, at, length)

        if String.match?(value, ~r/\p{L}.*\p{L}/us) and not String.match?(value, ~r/\A[\[<#=]/u),
          do: %{name: nil, value: value, at: {start + at, length}}

      _other ->
        nil
    end
  end

  defp clean_name(name),
    do: name |> String.replace(~r/[\[\]\*`_]/u, "") |> String.trim()

  defp name_notes(fields) do
    {named, _count} =
      Enum.map_reduce(fields, 0, fn
        %{name: nil} = field, 0 -> {%{field | name: "Note"}, 1}
        %{name: nil} = field, n -> {%{field | name: "Note #{n + 1}"}, n + 1}
        field, n -> {field, n}
      end)

    named
  end

  @doc """
  The reply without its ledger lines, and the changes they name:
  `[{name, value}]`, or nil when the model wrote none.
  """
  @spec take(String.t()) :: {String.t(), [{String.t(), String.t()}] | nil}
  def take(text) do
    case Regex.run(~r/<aethrion-ledger\b[^>]*>(.*?)(?:<\/aethrion-ledger>|\z)/s, text,
           return: :index
         ) do
      [{start, length}, {from, size}] ->
        rest =
          binary_part(text, 0, start) <>
            binary_part(text, start + length, byte_size(text) - start - length)

        changes =
          text
          |> binary_part(from, size)
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            case Regex.run(~r/\A\s*(?:[-*•]\s*)?([^:：]{1,40}?)\s*[:：]\s*(.+?)\s*\z/u, line) do
              [_all, name, value] -> [{clean_name(name), String.slice(value, 0, @max_value)}]
              nil -> []
            end
          end)
          |> Enum.take(@max_changes)

        {String.trim(rest), changes}

      nil ->
        {text, nil}
    end
  end

  @doc """
  The changes a window the model printed anyway makes to the window as it
  stood: the fields whose values differ, as changes for `apply/3`. For a
  model that did not write ledger lines.
  """
  @spec differences(String.t(), String.t(), spec() | nil) :: [{String.t(), String.t()}]
  def differences(before, printed, spec \\ nil) do
    was = Map.new(fields(before, spec), &{key(&1.name), &1.value})

    for field <- fields(printed, spec),
        Map.has_key?(was, key(field.name)),
        was[key(field.name)] != field.value,
        do: {field.name, field.value}
  end

  @doc """
  Applies the changes to the window: `{window, applied, refused}`.
  `applied` is `[{name, before, after}]` for the fields that changed, and
  `refused` `[{name, value, reason}]` for a field the window does not
  have (`:unknown`) or a number put out of its bounds and brought back
  (`:clamped`).

  A value of `+N` or `-N` moves the field's number (the current one of a
  pair); `N / M` sets a pair; anything else replaces the value, keeping a
  number's unit and thousands separators as they were.
  """
  @spec apply(String.t(), [{String.t(), String.t()}], spec() | nil) ::
          {String.t(), [{String.t(), String.t(), String.t()}], [{String.t(), String.t(), atom()}]}
  def apply(window, changes, spec \\ nil) do
    by_name = Map.new(fields(window, spec), &{key(&1.name), &1})

    {edits, applied, refused} =
      Enum.reduce(changes, {%{}, [], []}, fn {name, value}, {edits, applied, refused} ->
        case Map.get(by_name, key(name)) do
          nil ->
            {edits, applied, refused ++ [{name, value, :unknown}]}

          field ->
            # A field named twice: the later change works on the earlier one's result.
            was = Map.get(edits, field.name, field.value)
            {now, clamped?} = changed(was, value)
            refused = if clamped?, do: refused ++ [{field.name, value, :clamped}], else: refused
            applied = Enum.reject(applied, fn {n, _was, _now} -> n == field.name end)

            if now == field.value,
              do: {Map.delete(edits, field.name), applied, refused},
              else:
                {Map.put(edits, field.name, now), applied ++ [{field.name, field.value, now}],
                 refused}
        end
      end)

    # Later fields first, so the earlier ones' places stay where they are.
    rewritten =
      by_name
      |> Map.values()
      |> Enum.filter(&Map.has_key?(edits, &1.name))
      |> Enum.sort_by(fn %{at: {start, _length}} -> -start end)
      |> Enum.reduce(window, fn %{name: name, at: {start, length}}, text ->
        binary_part(text, 0, start) <>
          edits[name] <> binary_part(text, start + length, byte_size(text) - start - length)
      end)

    {rewritten, applied, refused}
  end

  # The value after a change, and whether a bound brought it back.
  defp changed(was, value) do
    value = value |> String.replace(~r/[\r\n|]/u, " ") |> String.trim()

    case {number(was), delta(value)} do
      {{:pair, _pre, a, _sep, b, _post} = pair, {:move, d}} ->
        put_pair(pair, a + d, b)

      {{:pair, _pre, _a, _sep, _b, _post} = pair, {:set_pair, a, b}} ->
        put_pair(pair, a, b)

      {{:pair, _pre, _a, _sep, b, _post} = pair, {:set, a}} ->
        put_pair(pair, a, b)

      {{:one, _pre, a, _post} = one, {:move, d}} ->
        put_one(one, a + d)

      {{:one, _pre, _a, _post} = one, {:set, a}} ->
        put_one(one, a)

      # A number field given text (or a pair), or a text field: the value as it is said.
      {_was, {:move, _d}} ->
        {was, false}

      {_was, _text} ->
        {value, false}
    end
  end

  # What a value is made of: `{:pair, pre, current, separator, max, post}`,
  # `{:one, pre, number, post}`, or `:text` (a time, a date, a list).
  defp number(value) do
    cond do
      match = Regex.run(~r/\A(\D*?)(-?\d[\d,]*)(\s*\/\s*)(\d[\d,]*)(\D*)\z/u, value) ->
        [_all, pre, a, sep, b, post] = match
        {:pair, pre, int(a), sep, int(b), {post, commas?(a) or commas?(b)}}

      match = Regex.run(~r/\A(\D*?)(-?\d[\d,]*)(\D*)\z/u, value) ->
        [_all, pre, a, post] = match
        {:one, pre, int(a), {post, commas?(a)}}

      true ->
        :text
    end
  end

  # What a change asks for.
  defp delta(value) do
    cond do
      match = Regex.run(~r/\A([+\-−])\s*(\d[\d,]*)\s*[^\d\/]*\z/u, value) ->
        [_all, sign, n] = match
        {:move, if(sign == "+", do: int(n), else: -int(n))}

      match = Regex.run(~r/\A\D*?(-?\d[\d,]*)\s*\/\s*(\d[\d,]*)\D*\z/u, value) ->
        [_all, a, b] = match
        {:set_pair, int(a), int(b)}

      match = Regex.run(~r/\A\D*?(-?\d[\d,]*)\D*\z/u, value) ->
        [_all, a] = match
        {:set, int(a)}

      true ->
        :text
    end
  end

  defp put_pair({:pair, pre, _a, sep, _b, {post, commas?}}, a, b) do
    b = max(b, 0)
    bounded = a |> max(0) |> min(b)
    {pre <> digits(bounded, commas?) <> sep <> digits(b, commas?) <> post, bounded != a}
  end

  defp put_one({:one, pre, _a, {post, commas?}}, a) do
    bounded = if String.contains?(post, "%"), do: a |> max(0) |> min(100), else: a
    {pre <> digits(bounded, commas?) <> post, bounded != a}
  end

  defp int(text), do: text |> String.replace(",", "") |> String.to_integer()
  defp commas?(text), do: String.contains?(text, ",")

  defp digits(n, false), do: Integer.to_string(n)

  defp digits(n, true) do
    sign = if n < 0, do: "-", else: ""

    grouped =
      n
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    sign <> grouped
  end

  defp key(name), do: name |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  @doc "What the note asks of the model once the rules keep the window."
  @spec instruction(String.t(), spec() | nil) :: String.t()
  def instruction(window, spec \\ nil) do
    names = window |> fields(spec) |> Enum.map_join(", ", & &1.name)

    "The status window is kept by the game's rules and shown by them: do not print it yourself, whatever the card says. Instead, after everything else, write <aethrion-ledger>...</aethrion-ledger> with one line for each field of the window that this reply changes: `Field: +N` or `Field: -N` for a number that goes up or down (damage taken is `HP: -N`), `Field: N / M` to set both numbers of a pair, or `Field: new text`. Use the window's field names (#{names}). Leave out every field that stays as it is, and write the tags with nothing between them when nothing changes. It is not shown to the player."
  end

  @doc """
  The lines for this turn's rulings: what the ledger changed, and what it
  refused.
  """
  @spec log([{String.t(), String.t(), String.t()}], [{String.t(), String.t(), atom()}], :ko | :en) ::
          [String.t()]
  def log(applied, refused, locale) do
    {changed, kept, unknown, clamped} =
      if locale == :ko,
        do: {"기록", "→", "없는 칸", "한도에 맞춤"},
        else: {"Ledger", "→", "no such field", "kept within bounds"}

    changes =
      case Enum.filter(applied, fn {_name, was, now} ->
             number(was) != :text or number(now) != :text
           end) do
        [] ->
          []

        numbers ->
          [
            "#{changed} · " <>
              Enum.map_join(numbers, " · ", fn {n, was, now} -> "#{n} #{was} #{kept} #{now}" end)
          ]
      end

    changes ++
      for {name, value, reason} <- refused do
        "#{changed} · #{name}: #{value} (#{if reason == :unknown, do: unknown, else: clamped})"
      end
  end

  @doc """
  The status block with the ledger's lines added to this turn's rulings
  (a rulings section is opened when the block has none).
  """
  @spec note(String.t(), [String.t()], String.t()) :: String.t()
  def note(status, [], _title), do: status

  def note(status, lines, title) do
    text = lines |> Enum.map_join("\n", &escape/1)

    cond do
      String.contains?(status, "</aethrion-turn>") ->
        String.replace(status, "</aethrion-turn>", "\n" <> text <> "</aethrion-turn>",
          global: false
        )

      String.contains?(status, "</aethrion-status>") ->
        String.replace(
          status,
          "</aethrion-status>",
          ~s(\n<aethrion-turn title="#{title}">) <> text <> "</aethrion-turn></aethrion-status>",
          global: false
        )

      true ->
        status
    end
  end

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  @doc """
  A filter for a reply as it is streamed: `{on_delta, flush}`. `on_delta`
  passes each piece on to `emit` up to where the model's own lines for the
  rules begin (the scene line, the ledger lines) or where it starts to
  print the status window after all (`open`, the window's opening text at
  the start of a line; nil when the card has none). From there on nothing
  is passed: the server writes the end of the reply itself. `flush` passes
  on what was held back and turned out to be none of those. Both are
  called from one process.
  """
  @spec filter((String.t() -> any()), String.t() | nil) :: {(String.t() -> any()), (-> any())}
  def filter(emit, open \\ nil) do
    key = {__MODULE__, make_ref()}
    open = if is_binary(open) and open != "", do: open

    on_delta = fn delta ->
      case Process.get(key, {"", true}) do
        :held -> :ok
        {held, line_start?} -> Process.put(key, pass(held <> delta, line_start?, open, emit))
      end
    end

    flush = fn ->
      case Process.delete(key) do
        {held, _line_start?} when held != "" -> emit.(held)
        _held_or_nothing -> :ok
      end
    end

    {on_delta, flush}
  end

  # Passes on what is safe of `text` (which starts at a line's start when
  # `line_start?`), and gives what is next: `:held`, or `{held, line_start?}`.
  defp pass(text, line_start?, open, emit) do
    case stop(text, line_start?, open) do
      {:tag, at} ->
        out(emit, binary_part(text, 0, at))
        :held

      {:open, at} ->
        out(emit, binary_part(text, 0, at))
        rest = binary_part(text, at, byte_size(text) - at)

        cond do
          # A marker long enough to be no accident: the window begins.
          byte_size(open) >= 6 ->
            :held

          # A short one ("["): the line decides, once it is whole.
          match = :binary.match(rest, "\n") ->
            {line_end, 1} = match
            line = binary_part(rest, 0, line_end + 1)

            if window_line?(line) do
              :held
            else
              out(emit, line)

              pass(
                binary_part(rest, line_end + 1, byte_size(rest) - line_end - 1),
                true,
                open,
                emit
              )
            end

          true ->
            {rest, true}
        end

      nil ->
        keep = tail(text, line_start?, open)
        passed = binary_part(text, 0, byte_size(text) - byte_size(keep))
        out(emit, passed)

        line_start? =
          cond do
            passed == "" -> line_start?
            keep == "" -> String.ends_with?(passed, "\n")
            true -> String.ends_with?(passed, "\n")
          end

        {keep, line_start?}
    end
  end

  defp out(_emit, ""), do: :ok
  defp out(emit, text), do: emit.(text)

  # Where the reply's own end begins: the first tag, or the window's
  # opening text at the start of a line, whichever comes first.
  defp stop(text, line_start?, open) do
    tag =
      [@scene, @tag]
      |> Enum.flat_map(fn tag ->
        case :binary.match(text, tag) do
          {at, _length} -> [at]
          :nomatch -> []
        end
      end)
      |> Enum.min(fn -> nil end)

    opened = open && opening(text, line_start?, open)

    cond do
      opened != nil and (tag == nil or opened < tag) -> {:open, opened}
      tag != nil -> {:tag, tag}
      true -> nil
    end
  end

  # The first place `open` stands at the start of a line (after spaces).
  defp opening(text, line_start?, open) do
    pattern = Regex.compile!("(?:\\A|\\n)[ \\t]*(" <> Regex.escape(open) <> ")", "u")

    pattern
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(fn [{all, _length}, {at, _open_length}] ->
      if all > 0 or line_start?, do: at
    end)
  end

  # A line that reads as a one-line window: named values, split by "|".
  defp window_line?(line), do: length(Regex.scan(~r/[^:|\n]+:\s*[^|\n]+/u, line)) >= 2

  # The end of the text that may be the beginning of a tag, or of the
  # window's opening at the start of a line.
  defp tail(text, line_start?, open) do
    tag_tail =
      [@scene, @tag]
      |> Enum.map(&prefix_tail(text, &1))
      |> Enum.max_by(&byte_size/1)

    line_tail =
      if open do
        # The last line so far, when it has only begun and may yet open the window.
        {from, at_line_start?} =
          case :binary.matches(text, "\n") do
            [] -> {0, line_start?}
            newlines -> {elem(List.last(newlines), 0) + 1, true}
          end

        line = binary_part(text, from, byte_size(text) - from)
        trimmed = String.trim_leading(line, " ") |> String.trim_leading("\t")

        if at_line_start? and trimmed != "" and byte_size(trimmed) < byte_size(open) and
             String.starts_with?(open, trimmed),
           do: line,
           else: ""
      else
        ""
      end

    if byte_size(line_tail) > byte_size(tag_tail), do: line_tail, else: tag_tail
  end

  defp prefix_tail(text, tag) do
    1..(byte_size(tag) - 1)
    |> Enum.reverse()
    |> Enum.find_value("", fn n ->
      if byte_size(text) >= n and
           binary_part(text, byte_size(text) - n, n) == binary_part(tag, 0, n),
         do: binary_part(tag, 0, n)
    end)
  end
end
