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

  alias Aethrion.Bridge.Ledger.{Cells, Fields, Listing, Rules}

  @tag "<aethrion-ledger"
  @scene "<aethrion-scene"
  @max_changes 40
  @max_value 400

  @typedoc """
  A card's status window: the texts that open and close it, and the
  arithmetic the card states for its numbers (`Aethrion.Bridge.Ledger.Rules`).
  """
  @type spec :: %{
          required(:open) => String.t(),
          required(:close) => String.t(),
          optional(:rules) => [String.t()]
        }

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
      # As the card closes it; or, when that leaves no window (a closing
      # text that also ends the window's heading), to the end of the reply.
      Enum.find_value(closings(spec.close), fn close ->
        spec = %{spec | close: close}

        with stop when is_integer(stop) <- closing(text, start + length, close),
             window = binary_part(text, start, stop - start),
             true <- length(fields(window, spec)) >= 2 do
          {binary_part(text, 0, start), window, binary_part(text, stop, byte_size(text) - stop)}
        else
          _none -> nil
        end
      end)
    end)
  end

  def window(_text, _spec), do: nil

  # The closing texts to try: the card's, and for one that is a single
  # bracket (which may only close the window's heading), none.
  defp closings(close) when close in ["]", ")", "}", ">", "】", "］", "」"], do: [close, ""]
  defp closings(close), do: [close]

  # Where the window that opens before `from` ends.
  defp closing(text, _from, close) when close in [nil, ""],
    do: byte_size(String.trim_trailing(text))

  defp closing(text, from, close) do
    case :binary.match(text, close, scope: {from, byte_size(text) - from}) do
      {stop, length} ->
        stop + length

      # A closing text copied from the card's format with a blank in it
      # ("|UserColor:(R,G,B)]"): the first line that ends as it ends.
      :nomatch ->
        last = String.last(close)

        if last in ["]", ")", "}", ">", "】", "］", "」"] do
          rest = binary_part(text, from, byte_size(text) - from)

          case Regex.run(~r/\A[^\n]*#{Regex.escape(last)}(?=[ \t]*(?:\n|\z))/u, rest,
                 return: :index
               ) do
            [{0, length}] -> from + length
            nil -> nil
          end
        end
    end
  end

  @doc """
  Every window in `text`, in order: a card's own examples of its window,
  say. (`window/2` gives the last one.)
  """
  @spec windows(String.t(), spec()) :: [String.t()]
  def windows(text, spec) do
    case window(text, spec) do
      nil ->
        []

      {before, window, _after} ->
        # Past a window that is the rest of the text, look no further back
        # than its opening.
        windows(String.slice(before, 0, max(String.length(before) - 1, 0)), spec) ++ [window]
    end
  end

  @doc """
  Whether a window's numbers agree with a rule as written (a rule that
  always holds, such as `HP.max = Vigor * 10`): true, false, or nil when
  the window cannot say. For checking what a card's reader wrote against
  the examples the card gives of its window.
  """
  @spec agrees?(String.t(), String.t(), spec() | nil) :: boolean() | nil
  def agrees?(window, rule, spec \\ nil) do
    fields = fields(window, spec)
    figures = for field <- fields, figure = figure(field.value), do: {field, figure}
    values = Map.new(figures, fn {field, {_shape, numbers}} -> {key(field.name), numbers} end)

    case Rules.parse(rule, Map.keys(values)) do
      {:ok, parsed} -> Rules.agrees?(parsed, values)
      :error -> nil
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
  The fields of a window, in order (`Aethrion.Bridge.Ledger.Fields`).
  """
  @spec fields(String.t(), spec() | nil) :: [field()]
  def fields(window, spec \\ nil), do: Fields.read(window, spec)

  defp clean_name(name), do: Fields.clean_name(name)

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
    fields = fields(window, spec)
    by_name = Map.new(fields, &{key(&1.name), &1})
    habits = habits(fields)
    rules = rules(fields, spec)
    {raised, lowered, watched} = {Rules.raised(rules), Rules.lowered(rules), Rules.watched(rules)}

    {edits, applied, refused} =
      Enum.reduce(changes, {%{}, [], []}, fn {name, value}, {edits, applied, refused} ->
        # "Hansol L: +1": a row's labelled number, named with its row.
        {name, value} = celled(by_name, name, value)

        case Map.get(by_name, key(name)) do
          nil ->
            {edits, applied, refused ++ [{name, value, :unknown}]}

          field ->
            # A field named twice: the later change works on the earlier one's result.
            was = Map.get(edits, field.name, field.value)
            # A pair a rule watches may pass its maximum: the rule takes it up.
            habits = Map.put(habits, :open?, key(field.name) in watched)
            {now, problem} = changed(was, value, habits)

            # What a rule raises when something happens is not the model's to raise.
            # Nor is what a rule pays from the model's to lower.
            {now, problem} =
              if (key(field.name) in raised and first(now) > first(was)) or
                   (key(field.name) in lowered and first(now) < first(was)),
                 do: {was, :ruled},
                 else: {now, problem}

            # What the rules say of a person, copied onto the person's
            # row, is no change to the window, and no fault worth a line.
            problem =
              if problem == :unreadable and String.match?(value, ~r/affinity|trust|호감|신뢰/iu),
                do: nil,
                else: problem

            refused = if problem, do: refused ++ [{field.name, value, problem}], else: refused
            applied = Enum.reject(applied, fn {n, _was, _now} -> n == field.name end)

            if now == field.value,
              do: {Map.delete(edits, field.name), applied, refused},
              else:
                {Map.put(edits, field.name, now), applied ++ [{field.name, field.value, now}],
                 refused}
        end
      end)

    {rewrite(window, Map.values(by_name), edits), applied, refused}
  end

  # A change named by a row and one of its labels, as a change to the row.
  defp celled(by_name, name, value) do
    # "Hansol | L: +1", as the row itself is written.
    spaced = name |> String.replace(~r/[|│｜]/u, " ") |> String.trim()

    with false <- Map.has_key?(by_name, key(name)),
         [_all, row, label] <- Regex.run(~r/\A(.+?)\s+(\S+)\z/u, spaced),
         %{value: was} <- Map.get(by_name, key(row)),
         true <-
           Enum.any?(Cells.read(was), &(String.downcase(&1.label) == String.downcase(label))) do
      {row, "#{label} #{value}"}
    else
      _other -> {name, value}
    end
  end

  # The window with the fields in `edits` (by name) given their new values.
  defp rewrite(window, fields, edits) do
    # Later fields first, so the earlier ones' places stay where they are.
    fields
    |> Enum.filter(&Map.has_key?(edits, &1.name))
    |> Enum.sort_by(fn %{at: {start, _length}} -> -start end)
    |> Enum.reduce(window, fn %{name: name, at: {start, length}}, text ->
      binary_part(text, 0, start) <>
        edits[name] <> binary_part(text, start + length, byte_size(text) - start - length)
    end)
  end

  @doc """
  The window with the card's arithmetic worked out (`spec.rules`, see
  `Aethrion.Bridge.Ledger.Rules`), and every pair within its maximum:
  `{window, ruled}`, `ruled` being `[{name, before, after}]` for the fields
  that moved. `before` is the window as it stood before this turn's
  changes, when there was one.
  """
  @spec settle(String.t(), spec() | nil, String.t() | nil) ::
          {String.t(), [{String.t(), String.t(), String.t()}]}
  def settle(window, spec \\ nil, before \\ nil) do
    fields = fields(window, spec)
    figures = for field <- fields, figure = figure(field.value), do: {field, figure}
    values = values(fields)

    # The numbers before this turn's changes, for what rose since.
    before = before && values(fields(before, spec))
    ruled = Rules.run(values, rules(fields, spec), before)

    edits =
      for {field, {shape, was}} <- figures,
          now = Map.fetch!(ruled, key(field.name)),
          {text, problem} = put(shape, now),
          now != was or problem != nil,
          text != field.value,
          into: %{},
          do: {field.name, text}

    # The labelled numbers of rows, written back in their places.
    rows =
      for field <- fields,
          cells = Cells.read(field.value),
          cells != [],
          numbers =
            Map.new(cells, fn cell ->
              {String.downcase(cell.label), ruled[cell_key(field, cell)].now}
            end),
          text = Cells.put(field.value, numbers),
          text != field.value,
          into: %{},
          do: {field.name, text}

    edits = Map.merge(edits, rows)

    {rewrite(window, fields, edits),
     for(
       %{name: name, value: value} <- fields,
       Map.has_key?(edits, name),
       do: {name, value, edits[name]}
     )}
  end

  # A window's numbers as the rules see them: its figures by field name,
  # and the labelled numbers of its rows by "row label".
  defp values(fields) do
    figures =
      for field <- fields, {_shape, numbers} <- [figure(field.value)], into: %{} do
        {key(field.name), numbers}
      end

    cells =
      for field <- fields, cell <- Cells.read(field.value), into: %{} do
        {cell_key(field, cell), %{now: cell.number, max: nil}}
      end

    Map.merge(cells, figures)
  end

  defp cell_key(field, cell), do: key(field.name) <> " " <> String.downcase(cell.label)

  # The card's rules that this window's fields can carry. A rule that
  # speaks of a label of the rows' numbers ("L = clamp(L, 0, 100)") is a
  # rule for each row that has the label.
  defp rules(fields, spec) do
    names = Map.keys(values(fields))
    rows = for field <- fields, cells = Cells.read(field.value), cells != [], do: {field, cells}

    labels =
      for {_field, cells} <- rows, cell <- cells, uniq: true, do: String.downcase(cell.label)

    Enum.flat_map(rule_texts(fields, spec), fn text ->
      case Rules.parse(text, names) do
        {:ok, rule} ->
          [rule]

        :error ->
          case labels != [] && Rules.parse(text, names ++ (labels -- names)) do
            {:ok, rule} -> for_rows(rule, rows, names)
            _error -> []
          end
      end
    end)
  end

  # The rule for each row that has every label the rule speaks of.
  defp for_rows(rule, rows, names) do
    spoken = Rules.names(rule) -- names

    for {field, cells} <- rows,
        held = Enum.map(cells, &String.downcase(&1.label)),
        spoken -- held == [] do
      Rules.rename(rule, fn name ->
        if name in spoken, do: key(field.name) <> " " <> name, else: name
      end)
    end
  end

  # The rules as written: the card's, and a level-up nobody stated.
  defp rule_texts(fields, spec) do
    names = for field <- fields, figure(field.value), do: key(field.name)
    stated = (spec && Map.get(spec, :rules)) || []
    parsed = for text <- stated, {:ok, rule} <- [Rules.parse(text, names)], do: rule
    stated ++ implied(fields, parsed)
  end

  # Experience that fills its bar next to a level is a level gained, on
  # any card: when the card's rules say nothing of it, the bar is not left
  # full with the rest thrown away.
  defp implied(fields, parsed) do
    exp =
      Enum.find(fields, fn field ->
        match?({:pair, _pre, _a, _sep, _b, _post}, number(field.value)) and figure?(field.value) and
          String.match?(field.name, ~r/\A(?:exp|xp|experience|경험치|경험)\.?\z/iu)
      end)

    level =
      Enum.find(fields, fn field ->
        match?({:one, _pre, _a, _post}, number(field.value)) and figure?(field.value) and
          String.match?(field.name, ~r/\A(?:level|lv|lvl|레벨|렙)\.?\z/iu)
      end)

    if exp && level && key(exp.name) not in Rules.watched(parsed),
      do: [
        "when #{exp.name} >= #{exp.name}.max: #{level.name} += 1; #{exp.name} -= #{exp.name}.max"
      ],
      else: []
  end

  # A field's numbers as the rules see them, with the shape to write them
  # back in; nil for a field that holds no figure.
  defp figure(value) do
    if figure?(value) do
      case number(value) do
        {:pair, _pre, a, _sep, b, _post} = pair -> {pair, %{now: a, max: b}}
        {:one, _pre, a, _post} = one -> {one, %{now: a, max: nil}}
      end
    end
  end

  defp put({:pair, _pre, _a, _sep, _b, _post} = pair, %{now: a, max: b}), do: put_pair(pair, a, b)
  defp put({:one, _pre, _a, _post} = one, %{now: a}), do: put_one(one, a)

  # The first number of a value, for telling whether it went up.
  defp first(value) do
    case number(value) do
      {:pair, _pre, a, _sep, _b, _post} -> a
      {:one, _pre, a, _post} -> a
      :text -> 0
    end
  end

  # The value after a change, and what was wrong with the change (nil, or
  # `:clamped` for a number brought back within its bounds, `:missing` for
  # something taken from a list that does not have it).
  defp changed(was, value, habits) do
    value =
      value
      |> String.replace(if(habits.bars?, do: ~r/[\r\n|]/u, else: ~r/[\r\n]/u), " ")
      |> String.trim()

    cond do
      # A row of labelled numbers: the numbers named move; the row written
      # anew replaces it; anything else is not about this row.
      Cells.read(was) != [] ->
        case Cells.change(was, value) do
          {:ok, now, problem} -> {now, problem}
          :rewrite -> {value, nil}
          :none -> {was, :unreadable}
        end

      # "+thing" joins a list, not a figure: a load of "12 / 80" is no bag.
      String.match?(value, ~r/\A[+\-−]\s*[^\d\s]/u) ->
        if figure?(was), do: {was, :unreadable}, else: Listing.change(was, value, habits)

      figure?(was) ->
        counted(was, value, habits)

      list?(was) ->
        Listing.change(was, value, habits)

      true ->
        counted(was, value, habits)
    end
  end

  defp counted(was, value, habits) do
    figure? = figure?(was)

    # "31 / 48 → 14 / 48" or "15 - 15 = 0", as some write a change: what
    # it comes to, said outright.
    {value, outright?} =
      case figure? && String.split(value, ~r/\s*(?:→|->|=>|=)\s*/u) do
        [_before | _more] = parts when length(parts) > 1 -> {List.last(parts), true}
        _one_part -> {value, false}
      end

    habits = Map.put(habits, :outright?, outright?)

    numbered(number(was), delta(value, figure?), value, habits) ||
      worded(was, value, habits, figure?)
  end

  # A number moved or set, or nil when the field or the change is none.
  defp numbered({:pair, _pre, a, _sep, b, _post} = pair, {:move, d}, _value, habits),
    do: put_pair(pair, a + d, b, habits[:open?])

  defp numbered({:pair, _pre, _a, _sep, _b, _post} = pair, {:set_pair, a, b}, value, habits),
    do: put_pair(dressed(pair, value), a, b, habits[:open?])

  defp numbered({:pair, _pre, now, _sep, b, _post} = pair, {:set, a}, value, habits) do
    if unsigned?(value, a, now, habits),
      do: {elem(put_pair(pair, now, b, true), 0), :unsigned},
      else: put_pair(pair, a, b, habits[:open?])
  end

  defp numbered({:one, _pre, a, _post} = one, {:move, d}, _value, _habits),
    do: put_one(one, a + d)

  # "7 / 207" for a number that stands alone: its first.
  defp numbered({:one, _pre, _a, _post} = one, {:set_pair, a, _b}, _value, _habits),
    do: put_one(one, a)

  defp numbered({:one, pre, now, _post} = one, {:set, a}, value, habits) do
    if lead?(pre) and unsigned?(value, a, now, habits),
      do: {elem(put_one(one, now), 0), :unsigned},
      else: put_one(dressed(one, value), a)
  end

  defp numbered(_shape, _delta, _value, _habits), do: nil

  # A number alone says neither which way the figure moves nor that it is
  # the new value: a small model writes "HP: 8" for eight lost, and
  # "Agility: 0" for no change. It is taken as the new value only when
  # said outright ("= 8", "14 → 8") or with words of its own ("8 left",
  # "45 (curious)"); the number as it stands changes nothing either way.
  defp unsigned?(value, new, now, habits) do
    not habits[:outright?] and new != now and
      String.match?(value, ~r/\A\s*-?[\d,.]+\s*(?:%|\p{L}{0,3})\s*\z/u)
  end

  # A change that is words, or a field that is. A figure stays a figure:
  # words with no number in them are not one. A text takes the value as it
  # is said, a list a thing; "+0:45" moves a clock, and is nothing to add
  # to any other text.
  defp worded(was, _value, _habits, true), do: {was, :unreadable}

  defp worded(was, value, habits, false) do
    cond do
      Listing.empty?(was) or not String.match?(value, ~r/\A[+\-−]\s*\d/u) ->
        Listing.change(was, value, habits)

      later = clock(was, value) ->
        {later, nil}

      true ->
        {was, :unreadable}
    end
  end

  # A clock ("05:00", "16:47:09") moved by a length of time ("+0:45",
  # "+30분", "+2 hours"), around midnight; nil when either is not that.
  defp clock(was, value) do
    with [_all, pre, h, m, s, post] <-
           Regex.run(~r/\A(\D*?)(\d{1,2}):(\d{2})(?::(\d{2}))?(\D.*|)\z/us, was),
         {:ok, seconds} <- span(value) do
      now = String.to_integer(h) * 3600 + String.to_integer(m) * 60 + seconds_of(s)
      later = Integer.mod(now + seconds, 86_400)
      pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
      clock = pad.(div(later, 3600)) <> ":" <> pad.(div(rem(later, 3600), 60))
      pre <> clock <> if(s == "", do: "", else: ":" <> pad.(rem(later, 60))) <> post
    else
      _other -> nil
    end
  end

  defp seconds_of(""), do: 0
  defp seconds_of(s), do: String.to_integer(s)

  # A length of time as a change writes it, in seconds.
  defp span(value) do
    sign = if String.match?(value, ~r/\A[\-−]/u), do: -1, else: 1

    cond do
      match = Regex.run(~r/\A[+\-−]\s*(\d+):(\d{2})(?::(\d{2}))?\s*\z/u, value) ->
        [h, m | s] = tl(match)

        {:ok,
         sign *
           (String.to_integer(h) * 3600 + String.to_integer(m) * 60 +
              seconds_of(List.first(s) || ""))}

      match = Regex.run(~r/\A[+\-−]\s*(\d+)\s*(시간|hours?|hrs?|h)\s*\z/iu, value) ->
        {:ok, sign * String.to_integer(Enum.at(match, 1)) * 3600}

      # Minutes, said or not: "+30분", "+30 min", "+30".
      match = Regex.run(~r/\A[+\-−]\s*(\d+)\s*(분|min|minutes?|m|)\s*\D*\z/iu, value) ->
        {:ok, sign * String.to_integer(Enum.at(match, 1)) * 60}

      true ->
        :error
    end
  end

  # A value that is a list (a pair of numbers is not one).
  defp list?(value) do
    not match?({:pair, _pre, _a, _sep, _b, _post}, number(value)) and Listing.list?(value)
  end

  # The number's field as the new value writes it, when the field has
  # words around its number and the new value brings its own ("45 (호기심)"
  # over "30 (경계)", "길드 3층" over "명월탑 1층"); as it was written
  # before, for a number alone or a field that is one. A figure keeps
  # leading the value: words before the number are not taken.
  defp dressed({:pair, was_pre, a, sep, b, {was_post, commas?}} = pair, value) do
    case number(value) do
      {:pair, pre, _a, _sep, _b, {post, _commas?}}
      when (pre != "" or post != "") and (was_pre != "" or was_post != "") ->
        if lead?(was_pre) and not lead?(pre),
          do: pair,
          else: {:pair, pre, a, sep, b, {post, commas?}}

      _same ->
        pair
    end
  end

  defp dressed({:one, was_pre, a, {was_post, commas?}} = one, value) do
    case number(value) do
      {:one, pre, _a, {post, _commas?}}
      when (pre != "" or post != "") and (was_pre != "" or was_post != "") ->
        if lead?(was_pre) and not lead?(pre),
          do: one,
          else: {:one, pre, a, {post, commas?}}

      _same ->
        one
    end
  end

  # What the window's lists look like: the text between their things, and
  # the word for a list with nothing in it.
  defp habits(fields) do
    values = Enum.map(fields, & &1.value)

    %{
      separator: Enum.find_value(values, ", ", &(list?(&1) && Listing.separator(&1))),
      empty: Enum.find(values, "None", &Listing.empty?/1),
      # A window that splits its fields by "|" cannot have one in a value.
      bars?: not Enum.any?(values, &String.contains?(&1, "|"))
    }
  end

  # What a value is made of: `{:pair, pre, current, separator, max, post}`,
  # `{:one, pre, number, post}`, or `:text` (a time, a date, a list).
  defp number(value) do
    cond do
      match =
          Regex.run(
            ~r/\A(\D*?)(-?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)(\s*\/\s*)((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)(\D*)\z/u,
            value
          ) ->
        [_all, pre, a, sep, b, post] = match
        {:pair, pre, int(a), sep, int(b), {post, commas?(a) or commas?(b)}}

      match = Regex.run(~r/\A(\D*?)(-?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)(\D*)\z/u, value) ->
        [_all, pre, a, post] = match
        {:one, pre, int(a), {post, commas?(a)}}

      # A number that leads a row or a line: what follows may hold digits too.
      match =
          Regex.run(
            ~r/\A(-?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)(\s*\/\s*)((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)(\s*[|·(\[].*)\z/us,
            value
          ) ->
        [_all, a, sep, b, post] = match
        {:pair, "", int(a), sep, int(b), {post, commas?(a) or commas?(b)}}

      match =
          Regex.run(~r/\A(-?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)(\s*%?\s*[|·(\[].*)\z/us, value) ->
        [_all, a, post] = match
        {:one, "", int(a), {post, commas?(a)}}

      true ->
        :text
    end
  end

  @number "(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d+)?"
  @moved Regex.compile!("\\A([+\\-−])\\s*(#{@number})\\s*[^\\d\\/]*\\z", "u")
  @pair_set Regex.compile!("\\A\\D*?(-?#{@number})\\s*\\/\\s*(#{@number})\\D*\\z", "u")
  @one_set Regex.compile!("\\A[^\\d+\\-−]*?(#{@number})\\D*\\z", "u")
  @moved_first Regex.compile!("\\A([+\\-−])\\s*(#{@number})(?!\\s*\\/|\\d|,\\d)", "u")
  @pair_within Regex.compile!("(-?#{@number})\\s*\\/\\s*(#{@number})", "u")
  @numbers_within Regex.compile!("(?<![\\d,.])([+\\-−]?)\\s*(#{@number})", "u")

  # What a change asks for: `{:move, by}`, `{:set_pair, now, max}`,
  # `{:set, now}`, or `:text`. For a figure (`loose?`), a change with more
  # words than asked for is read by its number: "-17 (a goblin's club)"
  # moves, "now 31/48 after the potion" sets.
  defp delta(value, loose?) do
    cond do
      match = Regex.run(@moved, value) -> move(match)
      match = Regex.run(@pair_set, value) -> set_pair(match)
      # A number with words around it, and no sign: the new value.
      match = Regex.run(@one_set, value) -> {:set, int(Enum.at(match, 1))}
      loose? -> loose_delta(value)
      true -> :text
    end
  end

  defp loose_delta(value) do
    cond do
      match = Regex.run(@moved_first, value) -> move(match)
      # A figure that leads its own words ("2 · night · room B2"): the new value.
      leading = leading(number(value)) -> leading
      match = Regex.run(@pair_within, value) -> set_pair(match)
      true -> one_among_words(Regex.scan(@numbers_within, value))
    end
  end

  defp leading({:one, "", a, _post}), do: {:set, a}
  defp leading({:pair, "", a, _sep, b, _post}), do: {:set_pair, a, b}
  defp leading(_other), do: nil

  # One number among words: a change when it carries a sign ("ego -2"),
  # else the new value ("level 9 reached"). Several numbers say too much.
  defp one_among_words([[_all, "", n]]), do: {:set, int(n)}
  defp one_among_words([[_all, "+", n]]), do: {:move, int(n)}
  defp one_among_words([[_all, _minus, n]]), do: {:move, -int(n)}
  defp one_among_words(_none_or_several), do: :text

  defp move([_all, "+", n]), do: {:move, int(n)}
  defp move([_all, _minus, n]), do: {:move, -int(n)}

  defp set_pair([_all, a, b]), do: {:set_pair, int(a), int(b)}

  defp put_pair({:pair, pre, _a, sep, _b, {post, commas?}}, a, b, open? \\ false) do
    b = max(b, 0)
    bounded = if open?, do: max(a, 0), else: a |> max(0) |> min(b)

    {pre <> digits(bounded, commas?) <> sep <> digits(b, commas?) <> post,
     if(bounded != a, do: :clamped)}
  end

  defp put_one({:one, pre, _a, {post, commas?}}, a) do
    bounded = if String.match?(post, ~r/\A\s*%/u), do: a |> max(0) |> min(100), else: a
    {pre <> digits(bounded, commas?) <> post, if(bounded != a, do: :clamped)}
  end

  # A number as written: whole, or with a fraction ("12.3").
  defp int(text) do
    text = String.replace(text, ",", "")
    if String.contains?(text, "."), do: String.to_float(text), else: String.to_integer(text)
  end

  defp commas?(text), do: String.contains?(text, ",")

  # A number that has a fraction keeps one.
  defp digits(n, commas?) when is_float(n) do
    [whole, fraction] =
      n |> :erlang.float_to_binary([{:decimals, 2}, :compact]) |> String.split(".")

    sign = if n < 0 and not String.starts_with?(whole, "-"), do: "-", else: ""
    sign <> digits(String.to_integer(whole), commas?) <> "." <> fraction
  end

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

  @doc """
  What the last reply's status block says the ledger did, from the
  messages as the chat app sent them: `{recorded, refused}`, the record
  lines of the latest reply that has a status block, and the changes it
  did not take (as the model wrote them, with why).
  """
  @spec recorded([map()]) :: {[String.t()], [String.t()]}
  def recorded(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value({[], []}, fn
      %{"role" => "assistant", "content" => content} ->
        case Regex.run(
               ~r/<aethrion-turn\b[^>]*>(.*?)<\/aethrion-turn>/s,
               Aethrion.Bridge.text(content)
             ) do
          [_all, turn] ->
            lines =
              for line <- String.split(turn, "\n"),
                  [_all, kind, rest] <- [Regex.run(~r/\A(기록|Ledger|규칙|Rules) · (.*)\z/us, line)],
                  do: {kind, String.slice(rest, 0, 300)}

            {refused, done} =
              Enum.split_with(lines, fn {kind, rest} ->
                kind in ["기록", "Ledger"] and String.match?(rest, ~r/\A[^·→]+: .*\([^()]*\)\s*\z/u)
              end)

            {for({kind, rest} <- done, do: kind <> " · " <> rest),
             for({_kind, rest} <- refused, do: rest)}

          nil ->
            nil
        end

      _other ->
        nil
    end)
  end

  @doc """
  What the note asks of the model once the rules keep the window.
  `recorded` is what the ledger did and did not take last turn
  (`recorded/1`): a small model, seeing the player's last request still in
  the chat, is apt to grant it again, and has no other way to learn that a
  line of its own was not read.
  """
  @spec instruction(String.t(), spec() | nil, {[String.t()], [String.t()]}) :: String.t()
  def instruction(window, spec \\ nil, recorded \\ {[], []}) do
    {done, refused} = recorded

    already =
      case done do
        [] ->
          ""

        lines ->
          " Last turn's changes are in the window already; do not write them again (" <>
            Enum.join(lines, "; ") <> ")."
      end

    already =
      case refused do
        [] ->
          already

        lines ->
          already <>
            " These lines of yours last turn were not taken, for the reason in brackets; if one still holds, write it again in the form asked for: " <>
            Enum.join(lines, "; ") <> "."
      end

    fields = fields(window, spec)
    names = Enum.map_join(fields, ", ", & &1.name)

    lists =
      case Enum.filter(fields, &listing?/1) do
        [] ->
          ""

        [first | _rest] = lists ->
          " For a list (#{Enum.map_join(lists, ", ", & &1.name)}), write only what joins or leaves it, never the whole list: `#{first.name}: +thing × 2` for something gained, `#{first.name}: -thing × 1` for something used or lost."
      end

    rows =
      case Enum.filter(fields, &(Cells.read(&1.value) != [])) do
        [] ->
          ""

        [first | _rest] = rows ->
          label = first.value |> Cells.read() |> hd() |> Map.fetch!(:label)

          " For a row of labelled numbers (#{Enum.map_join(rows, ", ", & &1.name)}), write the numbers that move by their labels, `#{first.name}: #{label} +1`, or write the whole row anew."
      end

    ruled =
      case set_by_rules(fields, spec) do
        [] ->
          ""

        set ->
          " The game's rules set these themselves, so do not write them, only what leads to them: " <>
            Enum.join(set, ", ") <>
            " (" <> Enum.join(rule_texts(fields, spec), " | ") <> ")."
      end

    "The status window is kept by the game's rules and shown by them: do not print it yourself, whatever the card says. Instead, after everything else, write <aethrion-ledger>...</aethrion-ledger> with one line for each field of the window that this reply changes: `Field: +N` or `Field: -N`, always with its sign, for a number that goes up or down (damage taken is `HP: -N`, experience gained `EXP: +N`), `Field: N / M` to set both numbers of a pair, `Field: =N` to set a number outright, or `Field: new text`.#{lists}#{rows} Use the window's field names (#{names}).#{ruled}#{already} Leave out every field that stays as it is, and write the tags with nothing between them when nothing changes. What is listed under This turn and Now (how each character feels) is the rules' own and shown apart from the window: none of it goes in these lines. It is not shown to the player."
  end

  @doc """
  What the note says of the window on a turn that was answered before
  (a reroll): its changes are settled, as facts to narrate.
  """
  @spec settled_instruction([{String.t(), String.t()}]) :: String.t()
  def settled_instruction(changes) do
    facts =
      case changes do
        [] -> "nothing in it changes this turn"
        changes -> Enum.map_join(changes, "; ", fn {name, value} -> "#{name}: #{value}" end)
      end

    "The status window is kept by the game's rules and shown by them: do not print it yourself, whatever the card says, and write no <aethrion-ledger> lines. This turn was played before, and what it does to the window is settled: #{facts}. Narrate so that the reply agrees with that: the same gains, losses, and outcome, told anew."
  end

  # What the card's rules set, as the model is told: "the maximum of HP", "Level".
  defp set_by_rules(fields, spec) do
    names = Map.new(fields, &{key(&1.name), &1.name})

    fields
    |> rules(spec)
    |> Enum.flat_map(fn
      {:always, {name, :max}, _expr} ->
        ["the maximum of #{names[name]}"]

      {:always, {name, _part}, _expr} ->
        # A range or a limit bounds what the model writes; it does not write it for it.
        _ = name
        []

      {:when, condition, changes} ->
        watched = Rules.watched([{:when, condition, changes}])
        for {_kind, {name, _part}, _expr} <- changes, name not in watched, do: names[name]

      {:rise, _name, changes} ->
        for {_kind, {name, _part}, _expr} <- changes, do: names[name]
    end)
    |> Enum.uniq()
  end

  # A field the model is told to treat as a list: counted things, things
  # split by " / " or " · ", or a name that says so.
  defp listing?(%{name: name, value: value}) do
    not figure?(value) and
      ((list?(value) and (Listing.counted?(value) or Listing.separator(value) in [" / ", " · "])) or
         String.match?(
           name,
           ~r/item|inventory|skill|belonging|소지|아이템|인벤|가방|스킬|기술|소유|持ち物|スキル|🎒/iu
         ))
  end

  @doc """
  The lines for this turn's rulings: what the ledger changed, and what it
  refused.
  """
  @spec log([{String.t(), String.t(), String.t()}], [{String.t(), String.t(), atom()}], :ko | :en) ::
          [String.t()]
  def log(applied, refused, locale) do
    label = if locale == :ko, do: "기록", else: "Ledger"

    changes =
      case Enum.flat_map(applied, &shown/1) do
        [] -> []
        shown -> ["#{label} · " <> Enum.join(shown, " · ")]
      end

    changes ++
      for {name, value, reason} <- refused do
        "#{label} · #{name}: #{value} (#{reason(reason, locale)})"
      end
  end

  # A change as the turn's record shows it: a figure before and after, or
  # what joined and left a list; a text said anew is in the window to read.
  defp shown({name, was, now}) do
    cond do
      Cells.read(was) != [] and Cells.read(now) != [] ->
        case Cells.moved(was, now) do
          [] -> []
          moved -> ["#{name} " <> Enum.join(moved, ", ")]
        end

      figure?(was) or figure?(now) ->
        ["#{name} #{brief(was)} → #{brief(now)}"]

      listing?(%{name: name, value: was}) or listing?(%{name: name, value: now}) ->
        case Listing.moved(was, now) do
          [] -> []
          moved -> ["#{name} " <> Enum.join(moved, ", ")]
        end

      true ->
        []
    end
  end

  @reasons %{
    unknown: {"없는 칸", "no such field"},
    clamped: {"한도에 맞춤", "kept within bounds"},
    missing: {"가지고 있지 않음", "not held"},
    ruled: {"규칙이 정함", "set by the rules"},
    unreadable: {"숫자가 아님", "not a number"},
    unsigned: {"+나 -가 없음", "no + or -"}
  }

  defp reason(reason, locale) do
    {ko, en} = Map.fetch!(@reasons, reason)
    if locale == :ko, do: ko, else: en
  end

  # A value that is a figure: a pair, or a number that leads the value
  # ("30 (경계)", "120G", "Lv 5"), not a text with a number in it.
  defp figure?(value) do
    case number(value) do
      {:pair, pre, _a, _sep, _b, _post} -> lead?(pre)
      {:one, pre, _a, _post} -> lead?(pre)
      :text -> false
    end
  end

  # What may stand before a figure: signs and brackets, or a word for a level or a day.
  defp lead?(pre),
    do: String.match?(pre, ~r/\A[^\p{L}\p{N}]*(?:(?:lv|level|레벨|day|no|d)[.\s\-]*)?\z/iu)

  # A figure as the turn's record shows it: without a long tail of words.
  defp brief(value) do
    case number(value) do
      {:pair, pre, a, sep, b, {post, commas?}} ->
        pre <> digits(a, commas?) <> sep <> digits(b, commas?) <> short(post)

      {:one, pre, a, {post, commas?}} ->
        pre <> digits(a, commas?) <> short(post)

      :text ->
        value
    end
    |> String.trim()
    |> String.replace(~r/\A\(([^)]*)\z/us, "\\1")
  end

  defp short(post) do
    cond do
      String.match?(post, ~r/\A\s*%/u) -> "%"
      String.length(post) <= 12 and not String.contains?(post, "|") -> post
      true -> ""
    end
  end

  @doc "The line for what the card's arithmetic moved (`settle/2`), or none."
  @spec rule_log([{String.t(), String.t(), String.t()}], :ko | :en) :: [String.t()]
  def rule_log([], _locale), do: []

  def rule_log(ruled, locale) do
    label = if locale == :ko, do: "규칙", else: "Rules"

    shown =
      Enum.map(ruled, fn {name, was, now} ->
        case Cells.moved(was, now) do
          [] -> "#{name} #{brief(was)} → #{brief(now)}"
          moved -> "#{name} " <> Enum.join(moved, ", ")
        end
      end)

    ["#{label} · " <> Enum.join(shown, " · ")]
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
        {held, _line_start?} when held != "" ->
          # A last line with no line break after it: a window, or the story's.
          window? =
            open != nil and String.starts_with?(String.trim_leading(held), open) and
              (byte_size(open) >= 6 or window_line?(held))

          if not window?, do: emit.(held)

        _held_or_nothing ->
          :ok
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
          :binary.match(rest, "\n") != :nomatch ->
            {line_end, 1} = :binary.match(rest, "\n")
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
