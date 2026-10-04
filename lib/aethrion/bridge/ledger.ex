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
  @max_openings 60
  # How many blank lines a window with no closing text may run over.
  @max_blanks 60
  @max_window 12_000
  @max_replies 6
  # An opening text this long at the start of a line is the window's ("[Day", "```").
  @sure_opening 3
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
    openings =
      text
      |> :binary.matches(open)
      |> Enum.reverse()
      # A short opening text ("[") may stand in many places: the last ones.
      |> Enum.take(@max_openings)

    # As the card closes it, at any of its openings; or, when that leaves
    # no window (a closing text that also ends the window's heading), to
    # the end of the block.
    Enum.find_value(closings(spec.close), fn close ->
      found(text, openings, %{spec | close: close})
    end)
  end

  def window(_text, _spec), do: nil

  defp found(text, openings, spec) do
    # A window with no closing text is a block of lines, and begins one:
    # "HP:" in "Enemy HP: 12/20" opens nothing.
    openings =
      if spec.close in [nil, ""],
        do: Enum.filter(openings, &begins_line?(text, &1)),
        else: openings

    Enum.find_value(openings, fn {start, length} ->
      with stop when is_integer(stop) <- closing(text, {start, start + length}, spec),
           window = binary_part(text, start, stop - start),
           true <- byte_size(window) <= @max_window,
           true <- length(fields(window, spec)) >= 2 do
        {binary_part(text, 0, start), window, binary_part(text, stop, byte_size(text) - stop)}
      else
        _none -> nil
      end
    end)
  end

  # Whether the text at `start` begins its line, after a bullet or a mark at most.
  defp begins_line?(text, {start, _length}) do
    from = max(start - 16, 0)
    before = text |> binary_part(from, start - from) |> String.replace_invalid("")

    String.match?(before, ~r/(?:\A|\n)[ \t\-*•◈▶▪·>]*\z/u) and
      (from == 0 or String.contains?(before, "\n"))
  end

  # The closing texts to try: the card's, and for one that is a single
  # bracket (which may only close the window's heading), none.
  defp closings(close) when close in ["]", ")", "}", ">", "】", "］", "」"], do: [close, ""]
  defp closings(close), do: [close]

  # Where the window that opens at `start` (its opening text ending at
  # `from`) ends.
  defp closing(text, {start, from}, %{close: close} = spec) when close in [nil, ""],
    do: open_ended(text, start, from, spec)

  defp closing(text, {_start, from}, %{close: close}), do: closing(text, from, close)

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

  # A window with no closing text is a block of lines. It ends at a blank
  # line, unless what comes after goes on as the window does: its lines
  # led by the same mark ("◈"), or the window has had no two fields yet
  # (a heading, a blank line, then its lines). A plain `Name: value` after
  # a blank line may as well be someone speaking, and is the story's.
  defp open_ended(text, start, from, spec) do
    # No further than a window may reach, and no more blank lines than a
    # window may have: a story of short paragraphs is not read through.
    reach = min(byte_size(text), start + @max_window + 2)

    stops =
      ~r/\n[ \t]*\n/
      |> Regex.scan(binary_part(text, 0, reach), offset: from, return: :index)
      |> Enum.take(@max_blanks)
      |> Enum.map(fn [{stop, length}] -> {stop, stop + length} end)

    final =
      if reach < byte_size(text) or length(stops) == @max_blanks,
        do: nil,
        else: byte_size(String.trim_trailing(text))

    Enum.find_value(stops, final, fn {stop, next} ->
      so_far = binary_part(text, start, stop - start)
      lead = so_far |> String.split("\n") |> List.last() |> lead()

      following =
        text |> binary_part(next, min(byte_size(text) - next, 400)) |> String.split("\n") |> hd()

      goes_on? =
        length(fields(so_far, spec)) < 2 or (lead != "" and lead(following) == lead)

      if not goes_on?, do: stop
    end)
  end

  # The mark a line is led by ("◈", "-", "📍"), or "" for a line that begins with words.
  defp lead(line) do
    case Regex.run(~r/\A\s*([^\p{L}\p{N}\s\[\](){}<>|:：=#"'`]{1,4})/u, line) do
      [_all, mark] -> mark
      nil -> ""
    end
  end

  @doc """
  Every window in `text`, in order: a card's own examples of its window,
  say. (`window/2` gives the last one.)
  """
  @spec windows(String.t(), spec()) :: [String.t()]
  def windows(text, spec), do: windows(text, spec, 6)

  # The last few: a card full of examples is not read through for them.
  defp windows(_text, _spec, 0), do: []

  defp windows(text, spec, left) do
    case window(text, spec) do
      nil ->
        []

      {before, window, _after} ->
        # Past a window that is the rest of the text, look no further back
        # than its opening.
        before = binary_part(before, 0, max(byte_size(before) - 1, 0))
        windows(String.replace_invalid(before, ""), spec, left - 1) ++ [window]
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
    figures = for field <- fields, figure = figure(field), do: {field, figure}
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
    |> Enum.filter(&(&1["role"] == "assistant"))
    # A chat that has had no window for this long has none to go on from.
    |> Enum.take(@max_replies)
    |> Enum.find_value(fn
      %{"role" => "assistant", "content" => content} when is_binary(content) ->
        # A chat app may send its line breaks as CR LF.
        case window(String.replace(content, "\r\n", "\n"), spec) do
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

  @opened ~r/<aethrion-ledger\b[^>\n]*(\/>|>|(?=\n)|\z)/i
  @closed ~r/<\/aethrion-ledger\s*(?:>|\z)/i
  # A tag the reply was cut off in, or a closing tag written wrongly.
  @torn ~r/[ \t]*<\/?aeth[a-z\-]*\s*\z|^[ \t]*<\/[a-z\-]*ledger[a-z\-]*>?[ \t]*$\n?/im
  @change ~r/\A\s*(?:[-*•]\s*)?([^:：]{1,40}?)\s*[:：]\s*(\S.*)\z/u
  # A change written as the window writes its fields, `TIME=09:47`: the
  # value said outright, unless it has a sign (`HP=+5`).
  @assigned ~r/\A\s*(?:[-*•]\s*)?([\p{L}\p{N}_][\p{L}\p{N}_ ]{0,23}?)[ \t]*=[ \t]*(?=([+\-−]?))(\S.*)\z/u

  @doc """
  The reply without its ledger lines, and the changes they name:
  `[{name, value}]`, or nil when the model wrote none. Every block of
  lines is taken, however the tag is cased. A block that is not closed
  (cut off, or closed wrongly) ends where its lines stop reading as
  changes: the story after it stays in the reply.
  """
  @spec take(String.t()) :: {String.t(), [{String.t(), String.t()}] | nil}
  def take(text), do: take(text, [], nil)

  defp take(text, kept, changes) do
    case Regex.run(@opened, text, return: :index) do
      nil ->
        {(kept ++ [text]) |> Enum.join() |> String.replace(@torn, "") |> String.trim(),
         changes && Enum.take(changes, @max_changes)}

      [{start, length} | _ending] ->
        head = binary_part(text, 0, start)
        rest = binary_part(text, start + length, byte_size(text) - start - length)

        # A tag that closes itself has no lines.
        {lines, rest} =
          if String.ends_with?(binary_part(text, start, length), "/>"),
            do: {"", String.replace_prefix(rest, "\n", "")},
            else: block(rest)

        take(rest, kept ++ [head], (changes || []) ++ changes(lines))
    end
  end

  # A block's lines, and the reply after it.
  defp block(rest) do
    case Regex.run(@closed, rest, return: :index) do
      [{stop, length}] ->
        {binary_part(rest, 0, stop),
         binary_part(rest, stop + length, byte_size(rest) - stop - length)}

      # Not closed: the lines that read as changes, up to the first that does not.
      nil ->
        # (A blank line ends them: what follows it is the story, though a
        # line of it may read "Name: words".)
        {blanks, rest} = rest |> String.split("\n") |> Enum.split_while(&(String.trim(&1) == ""))
        {lines, story} = Enum.split_while(rest, &(change(&1) != nil))
        _ = blanks
        {Enum.join(lines, "\n"), Enum.join(story, "\n")}
    end
  end

  defp changes(lines), do: lines |> String.split("\n") |> Enum.flat_map(&line_changes/1)

  # A line's changes: one, or several on a line when every piece between
  # its bars is a change of its own ("BELL: 4 | HEARD: 2").
  defp line_changes(line) when byte_size(line) > 1_200, do: []

  defp line_changes(line) do
    pieces = line |> String.split(~r/[|│｜]/u, trim: true) |> Enum.map(&change/1)

    if length(pieces) >= 2 and Enum.all?(pieces),
      do: pieces,
      else: List.wrap(change(line))
  end

  # One line of a block as a change, or nil. A line too long to be one is none.
  defp change(line) when byte_size(line) > 1_200, do: nil

  defp change(line) do
    line = String.trim_trailing(line)

    case Regex.run(@assigned, line) || Regex.run(@change, line) do
      [_all, name, value] ->
        {clean_name(name), value |> unmarked_value() |> String.slice(0, @max_value)}

      [_all, name, "", value] ->
        {clean_name(name), String.slice("=" <> value, 0, @max_value)}

      [_all, name, _sign, value] ->
        {clean_name(name), String.slice(value, 0, @max_value)}

      nil ->
        nil
    end
  end

  # "**Location:** the east gate": the marks of bold around the name.
  defp unmarked_value(value) do
    case String.replace(value, ~r/\A[*_`]+\s*/u, "") do
      "" -> value
      plain -> plain
    end
  end

  @doc "Whether the reply's ledger lines were cut off (a block that is opened and not closed)."
  @spec cut_off?(String.t()) :: boolean()
  def cut_off?(text) do
    # As `take/1` reads them: a tag that closes itself opens nothing.
    opened =
      @opened
      |> Regex.scan(text)
      |> Enum.count(fn [all | _ending] -> not String.ends_with?(all, "/>") end)

    opened > length(Regex.scan(@closed, text))
  end

  @doc """
  The window with the fields named given exactly these values (a field
  the window lacks is left out). For writing back what a turn settled.
  """
  @spec put(String.t(), [{String.t(), String.t()}], spec() | nil) :: String.t()
  def put(window, values, spec \\ nil) do
    fields = fields(window, spec)
    by_key = Map.new(fields, &{key(&1.name), &1.name})

    edits =
      for {name, value} <- values, held = by_key[key(name)], into: %{} do
        {held, value |> String.replace(~r/[\r\n]/u, " ") |> String.slice(0, 2_000)}
      end

    rewrite(window, fields, edits)
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
    rules = rules(fields, spec)

    book = %{
      fields: fields,
      by_name: by_name,
      # The first field of a name as the window writes it ("💙 HP", beside "❤️ HP").
      as_written:
        fields |> Enum.reverse() |> Map.new(&{written(Map.get(&1, :written, &1.name)), &1}),
      habits:
        Map.merge(habits(fields), %{close: (spec && spec.close) || "", open: spec && spec.open}),
      rules: rules,
      watched: Rules.watched(rules),
      sets: %{raised: Rules.raised(rules), lowered: Rules.lowered(rules)}
    }

    {edits, applied, refused} =
      Enum.reduce(changes, {%{}, [], []}, fn {name, value}, {edits, applied, refused} = so_far ->
        case named(book, name, value) do
          :nothing ->
            so_far

          {:unknown, name, value} ->
            {edits, applied, refused ++ [{name, value, :unknown}]}

          {field, value} ->
            # A field named twice: the later change works on the earlier one's result.
            was = Map.get(edits, field.name, field.value)
            {now, problem} = one(book, field, was, value)
            refused = if problem, do: refused ++ [{field.name, value, problem}], else: refused
            applied = Enum.reject(applied, fn {n, _was, _now} -> n == field.name end)

            if now == field.value,
              do: {Map.delete(edits, field.name), applied, refused},
              else:
                {Map.put(edits, field.name, now), applied ++ [{field.name, field.value, now}],
                 refused}
        end
      end)

    sound(window, fields, spec, edits, applied, refused)
  end

  # The window with the edits made, as long as it still reads as the
  # fields it had: an edit that would make a field vanish, or two of one
  # ("Mood: " left empty, a place written "Seoul: the station" beside its
  # mark), is refused and the rest are made.
  defp sound(window, fields, spec, edits, applied, refused) do
    names = Enum.map(fields, & &1.name)

    reads? = fn edits ->
      Enum.map(fields(rewrite(window, fields, edits), spec), & &1.name) == names
    end

    if reads?.(edits) do
      {rewrite(window, fields, edits), applied, refused}
    else
      {kept, broken} = Enum.split_with(edits, fn {name, now} -> reads?.(%{name => now}) end)
      broken = Map.new(broken)

      {rewrite(window, fields, Map.new(kept)),
       Enum.reject(applied, fn {name, _was, _now} -> is_map_key(broken, name) end),
       refused ++ for({name, now} <- broken, do: {name, now, :unreadable})}
    end
  end

  defp written(name),
    do: name |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  # The field a change names, and the change as that field takes it:
  # `{field, value}`, `{:unknown, name, value}`, or `:nothing` for what is
  # no change to the window and no fault worth a line.
  defp named(book, name, value) do
    # "Hansol L: +1": a row's labelled number, named with its row.
    {name, value} = celled(book.by_name, name, value)
    {name, value} = itemed(book.fields, book.by_name, name, value)
    {name, value} = maxed(book.by_name, book.rules, name, value)
    field = Map.get(book.as_written, written(name)) || Map.get(book.by_name, key(name))

    cond do
      # A maximum that a rule sets: the rule's.
      value == :ruled ->
        :nothing

      field != nil ->
        {field, value}

      # What the rules say of a person (affinity, trust), written under
      # the person's name: the rules' own.
      String.match?(value, ~r/\A\s*(?:affinity|trust|호감|신뢰)/iu) or
          String.match?(name, ~r/\A\s*(?:affinity|trust|호감도?|신뢰도?)\s*[-_ :]/iu) ->
        :nothing

      true ->
        {:unknown, name, value}
    end
  end

  # One field's value after a change, and what was wrong with the change.
  defp one(book, field, was, value) do
    habits =
      Map.merge(book.habits, %{
        # A pair a rule watches may pass its maximum: the rule takes it up.
        open?: key(field.name) in book.watched,
        dated?: dated?(field),
        placed?: placed?(field),
        timed?: timed?(field.name)
      })

    case parted(was, value, field) do
      :unreadable -> {was, :unreadable}
      value -> was |> changed(value, habits) |> judged(was, value, key(field.name), book.sets)
    end
  end

  # A heading of several parts ("[Day 1 · night · the keep]") written with
  # fewer: the parts it leaves out stay as they were. One word for a
  # heading of several parts says nothing of which part it is.
  defp parted(was, value, %{heading?: true, name: name}) do
    # Written as the window shows it ("[Day 2 · morning]"): without the
    # brackets and the name, which stand around the value already.
    value =
      value
      |> String.trim()
      |> String.replace(~r/\A[\[【［「]\s*|\s*[\]】］」]\z/u, "")
      |> String.replace(~r/\A#{Regex.escape(name)}(?![\p{L}\p{N}])[ \t.:]*/iu, "")

    {parts, said} = {String.split(was, " · "), String.split(value, " · ")}

    cond do
      length(parts) < 2 or String.match?(value, ~r/\A\s*[+\-−=]|→|->/u) -> value
      length(said) >= length(parts) -> value
      length(said) >= 2 -> Enum.join(said ++ Enum.drop(parts, length(said)), " · ")
      String.match?(value, ~r/\A\s*[0-9]/u) -> value
      true -> :unreadable
    end
  end

  defp parted(_was, value, _field), do: value

  # A change as the rules let it stand. What a rule raises when something
  # happens is not the model's to raise, nor what a rule pays from the
  # model's to lower. And what the rules say of a person, copied onto the
  # person's row, is no change to the window and no fault worth a line.
  defp judged({now, problem}, was, value, key, %{raised: raised, lowered: lowered}) do
    cond do
      (key in raised and first(now) > first(was)) or (key in lowered and first(now) < first(was)) ->
        {was, :ruled}

      problem == :unreadable and String.match?(value, ~r/affinity|trust|호감|신뢰/iu) ->
        {now, nil}

      true ->
        {now, problem}
    end
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

  # "Potion: -1": a thing of a list named as if it were a field, as a
  # change to the list that holds it.
  defp itemed(fields, by_name, name, value) do
    holds? = fn field ->
      listing?(field) and Enum.any?(Listing.items(field.value), &(key(&1.name) == key(name)))
    end

    with false <- Map.has_key?(by_name, key(name)),
         [_all, sign, n] <- Regex.run(~r/\A\s*([+\-−])\s*([0-9]{1,6})\s*(?:개|병|ea)?\s*\z/u, value),
         [list] <- Enum.filter(fields, holds?) do
      {list.name, "#{sign}#{name} × #{n}"}
    else
      _other -> {name, value}
    end
  end

  # "HP.max: +10", as the rules write a pair's maximum: a change to the
  # pair, or `:ruled` when a rule sets that maximum.
  defp maxed(by_name, rules, name, value) do
    with false <- Map.has_key?(by_name, key(name)),
         [_all, base] <- Regex.run(~r/\A(.+?)\s*\.\s*max(?:imum)?\z/iu, name),
         %{value: was} <- Map.get(by_name, key(base)),
         {:pair, _pre, a, _sep, b, _post} <- number(was) do
      if {key(base), :max} in for({:always, target, _expr} <- rules, do: target),
        do: {base, :ruled},
        else: new_maximum(name, value, base, trunc(a), trunc(b))
    else
      _other -> {name, value}
    end
  end

  defp new_maximum(name, value, base, now, max) do
    said = String.replace(value, ~r/\A\s*=\s*/u, "")
    {said, _outright?} = come_to_number(Integer.to_string(max), said)

    case delta(said, true) do
      {:move, by} -> {base, "=#{now} / #{trunc(max + by)}"}
      {:set, to} -> {base, "=#{now} / #{trunc(to)}"}
      {:set_pair, _now, to} -> {base, "=#{now} / #{trunc(to)}"}
      :text -> {name, value}
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
    figures = for field <- fields, figure = figure(field), do: {field, figure}
    values = values(fields)

    # The numbers before this turn's changes, for what rose since.
    before = before && values(fields(before, spec))
    ruled = Rules.run(values, rules(fields, spec), before)

    edits =
      for {field, {shape, was}} <- figures,
          now = Map.fetch!(ruled, key(field.name)),
          # A pair a change put past its maximum for a rule to take up, and
          # no rule did: back within the maximum it was within before.
          shape = within(shape, before && before[key(field.name)]),
          {text, problem} = shaped(shape, now),
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

  # The shape of a pair that was within its maximum before this turn, so
  # that it is kept there now (`put_pair/4` looks at how the pair stood).
  defp within({:pair, pre, _a, sep, _b, post}, %{now: was, max: max})
       when is_number(max) and was <= max,
       do: {:pair, pre, was, sep, max, post}

  defp within(shape, _before), do: shape

  # A window's numbers as the rules see them: its figures by field name,
  # and the labelled numbers of its rows by "row label".
  defp values(fields) do
    figures =
      for field <- fields, {_shape, numbers} <- [figure(field)], into: %{} do
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

    fields
    |> rule_texts(spec)
    |> Enum.flat_map(fn text ->
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
    # A rule written twice (in two spellings of a field, say) is one rule.
    |> Enum.uniq()
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
    names = for field <- fields, figure(field), do: key(field.name)
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
  # A value with a day of the week in brackets, after a number, is a
  # date: "5/31 (Sat)", "10월 14일 (월요일)". The word in the brackets is
  # the day and no more: "(일반)" is a grade, "(Sunny)" the weather.
  defp weekday?(value) do
    String.match?(
      value,
      ~r/[0-9][^()]{0,6}\(\s*(?:[월화수목금토일](?:요일)?|[月火水木金土日](?:曜日?)?|mon|tue|wed|thu|fri|sat|sun|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\.?\s*\)/iu
    )
  end

  defp figure(%{name: name, value: value}),
    do: if(dated?(%{name: name, value: value}), do: nil, else: figure(value))

  defp figure(value) do
    if figure?(value) do
      case number(value) do
        {:pair, _pre, a, _sep, b, _post} = pair -> {pair, %{now: a, max: b}}
        {:one, _pre, a, _post} = one -> {one, %{now: a, max: nil}}
      end
    end
  end

  defp shaped({:pair, _pre, _a, _sep, _b, _post} = pair, %{now: a, max: b}),
    do: put_pair(pair, a, b)

  defp shaped({:one, _pre, _a, _post} = one, %{now: a}), do: put_one(one, a)

  # The first number of a value, for telling whether it went up.
  defp first(value) do
    case number(value) do
      {:pair, _pre, a, _sep, _b, _post} -> a
      {:one, _pre, a, _post} -> a
      :text -> 0
    end
  end

  @stand_ins [
    "new text",
    "the new text",
    "+n",
    "-n",
    "=n",
    "n / m",
    "n/m",
    "thing",
    "+thing",
    "-thing",
    "the east gate"
  ]

  # The value after a change, and what was wrong with the change (nil, or
  # `:clamped` for a number brought back within its bounds, `:missing` for
  # something taken from a list that does not have it).
  defp changed(was, value, habits) do
    {value, habits} = said(value, habits)
    value = come_to(was, value, habits)

    cond do
      # What is left of a change that was only marks ("|", "new text:").
      value == "" ->
        {was, :unreadable}

      nothing?(value) and habits[:outright?] != true ->
        {was, nil}

      # A date is said anew, whatever numbers it holds; it is not moved by one.
      habits[:dated?] ->
        if String.match?(value, ~r/\A[+\-−]\s*[0-9]/u), do: {was, :unreadable}, else: {value, nil}

      Cells.read(was) != [] ->
        celled_row(was, value)

      # A row of cells ("Affection 30 | cheerful | the lobby"): its one
      # labelled number by its label, the row written anew, or nothing.
      String.match?(was, ~r/[|│｜]/u) and not figure?(was) ->
        celled_row(was, value)

      habits[:placed?] and not figure?(was) ->
        placed(was, value)

      true ->
        worded_or_counted(was, value, habits)
    end
  end

  # "morning → night", as some write a change of words: what it comes to.
  # (A figure and a row of numbers read their own arrows, and a value that
  # had an arrow in it keeps the one it is given.)
  defp come_to(was, value, habits) do
    # ("+ring → -ring" is a list's own; "+20 minutes → 14:40" comes to a time.)
    own? =
      (figure?(was) and not habits[:dated?]) or Cells.read(was) != [] or list?(was) or
        String.match?(was, ~r/→|->|=>/u) or
        (String.match?(value, ~r/\A[+\-−]/u) and
           not String.match?(arrived(value), ~r/\A[0-9]{1,2}:[0-9]{2}/u))

    # Where and when move on, whatever they moved from; other words are
    # a change only from what they were ("calm → tense" for "calm"), and
    # else may be words with an arrow of their own.
    moves? =
      habits[:dated?] == true or habits[:placed?] == true or habits[:timed?] == true or
        same_words?(hd(String.split(value, ~r/\s*(?:→|->|=>)\s*/u)), was)

    if own? or not moves?, do: value, else: arrived(value)
  end

  defp same_words?(a, b) do
    plain = &(&1 |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim())
    plain.(a) == plain.(b)
  end

  # A place is where one is now, however it is written ("Seoul / an
  # alley"): said anew, not a list for places to pile up in.
  defp placed(was, value) do
    if String.match?(value, ~r/\A(?:[\-−]\s*\S|\+\s*[0-9])/u),
      do: {was, :unreadable},
      else: {value |> String.replace(~r/\A\+\s*/u, "") |> arrived(), nil}
  end

  # "the alley → the van", as some write a move: where it ends.
  defp arrived(value) do
    value
    |> String.split(~r/\s*(?:→|->|=>)\s*/u)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> List.last() || value
  end

  # A field that says when the scene is.
  defp timed?(name),
    do:
      dated_name?(name) or
        String.match?(
          name,
          ~r/(?<![\p{L}])(?:time|clock|hour|day|turn)(?![\p{L}])|시간|시각|일차|時間|時刻|⏰|🕐|📅/iu
        )

  # A field that says where the scene is.
  defp placed?(%{name: name, value: value}) do
    String.match?(name, ~r/(?<![\p{L}])(?:location|place)(?![\p{L}])|위치|장소|현재지|場所|位置|📍/iu) or
      (String.match?(name, ~r/(?<![\p{L}])(?:where|area|zone|scene)(?![\p{L}])|지역/iu) and
         not list?(value))
  end

  # A change's value as it may be written into the window, and whether it
  # was said outright ("=20:30", "= 45", for any field).
  defp said(value, habits) do
    value =
      value
      |> String.replace(if(habits.bars?, do: ~r/[\r\n|│｜]/u, else: ~r/[\r\n]/u), " ")
      |> String.trim()
      # A stand-in of the note's, copied before the value ("new text: the inn").
      |> String.replace(~r/\A(?:the )?new (?:text|words|value)\s*[:：]\s*/iu, "")

    {value, habits} =
      case Regex.run(~r/\A=\s*(\S.*)\z/us, value) do
        [_all, said] -> {said, Map.put(habits, :outright?, true)}
        nil -> {value, habits}
      end

    {value |> unclosing(habits[:close]) |> unopening(habits[:open]), habits}
  end

  # A value cannot close the window it is in: "calm [for now]" in a window
  # that ends with "]" is written with round brackets, and any other
  # closing text is left out.
  defp unclosing(value, close) when close in [nil, ""], do: value
  defp unclosing(value, "]"), do: value |> String.replace("[", "(") |> String.replace("]", ")")
  defp unclosing(value, close), do: value |> String.replace(close, " ") |> String.trim()

  # Nor open another: the next window would begin inside the value.
  defp unopening(value, open) when is_binary(open) and byte_size(open) >= 2,
    do: value |> String.replace(open, " ") |> String.trim()

  defp unopening(value, _short_or_none), do: value

  # The note's own stand-ins copied as they stand, and "±0" or "+0", said
  # to say that nothing changes, are no change.
  defp nothing?(value) do
    String.downcase(value) in @stand_ins or
      String.match?(value, ~r/\A\s*(?:±|\+\/?-|[+\-−])\s*0+\s*\z/u)
  end

  # A row of labelled numbers: the numbers named move; the row written
  # anew replaces it; anything else is not about this row.
  defp celled_row(was, value) do
    case Cells.change(was, value) do
      {:ok, now, problem} ->
        {now, problem}

      :rewrite ->
        {value, nil}

      # A row with no labelled numbers is written anew with its cells.
      :none ->
        if Cells.labelled(was) == [] and String.match?(value, ~r/[|│｜]/u),
          do: {value, nil},
          else: {was, :unreadable}
    end
  end

  defp worded_or_counted(was, value, habits) do
    cond do
      # A text or a list said outright is what it is said to be.
      habits[:outright?] == true and not figure?(was) ->
        {value, nil}

      # "+thing" joins a list, not a figure: a load of "12 / 80" is no bag.
      String.match?(value, ~r/\A[+\-−]\s*[^\p{Nd}\s]/u) ->
        if figure?(was), do: {was, :unreadable}, else: Listing.change(was, value, habits)

      figure?(was) ->
        counted(was, value, habits)

      # A time among other words ("Sun., 02:15, (Autumn)") moved by a
      # length of time, or its clock said anew: the words stay.
      clocked = clock(was, value) || reclocked(was, value) ->
        {clocked, nil}

      list?(was) ->
        Listing.change(was, value, habits)

      true ->
        counted(was, value, habits)
    end
  end

  defp counted(was, value, habits) do
    figure? = figure?(was)
    {value, outright?} = if figure?, do: come_to_number(was, value), else: {value, false}

    habits = Map.put(habits, :outright?, outright? or habits[:outright?] == true)

    # Said outright, a number with a sign is the number, not a move by it.
    # ("Karma: =-7" is minus seven; "… → anxious, ego -2" is still a move.)
    alone? = String.match?(value, ~r/\A\s*[+\-−]\s*[0-9][0-9,.]*\s*[^0-9\s]{0,4}\s*\z/u)

    delta =
      case {delta(value, figure?), habits.outright? and alone?} do
        {{:move, d}, true} -> {:set, d}
        {delta, _outright?} -> delta
      end

    numbered(number(was), delta, value, habits) || worded(was, value, habits, figure?)
  end

  # "31 / 48 → 14 / 48" or "15 - 15 = 0", as some write a change to a
  # figure: what it comes to, and whether that is said outright.
  defp come_to_number(was, value) do
    cond do
      # "+5 -15", "-15 +9 = -6": several moves, and what they come to.
      match =
          Regex.run(~r/\A\s*((?:[+\-−]\s*[0-9][0-9,]*\s*){2,})(?:=\s*(.*))?\z/us, value) ->
        several(match)

      match = Regex.run(~r/\A.*(?:→|->|=>)\s*(\S.*)\z/us, value) ->
        arrowed(value, List.last(match))

      # "42 + 8", "36 + 25 / 50": the number it stands at, and what is added to it.
      match =
          Regex.run(
            ~r/\A\s*(-?[0-9][0-9,]*)\s*([+\-−])\s*([0-9][0-9,]*)\s*(?:\/\s*[0-9][0-9,]*\s*)?\z/u,
            value
          ) ->
        [_all, from, sign, by] = match
        if int(from) == first(was), do: {sign <> by, false}, else: {value, false}

      # "15 - 15 = 0": a sum, with what it comes to after the sign.
      match =
          Regex.run(~r/\A.*=\s*(-?[0-9][0-9,.]*(?:\s*\/\s*[0-9][0-9,.]*)?)\s*\z/us, value) ->
        {List.last(match), true}

      true ->
        {value, false}
    end
  end

  # What follows the last arrow, said outright; or, when that is no number
  # ("+150 (90 → 240); so → Level 7, EXP resets"), the move the change
  # leads with.
  defp arrowed(value, last) do
    lead = Regex.run(~r/\A\s*([+\-−])\s*([0-9][0-9,]*)(?![0-9,.]|\s*\/)/u, value)

    if lead != nil and delta(last, true) == :text,
      do: {Enum.at(lead, 1) <> Enum.at(lead, 2), false},
      else: {last, true}
  end

  # Several moves in one change: the number they are said to come to, when
  # one is said plainly ("= 34"); else their sum.
  defp several([_all, moves | result]) do
    sum =
      ~r/([+\-−])\s*([0-9][0-9,]*)/u
      |> Regex.scan(moves)
      |> Enum.reduce(0, fn [_all, sign, n], sum ->
        if sign == "+", do: sum + int(n), else: sum - int(n)
      end)

    case result do
      [result] ->
        if String.match?(result, ~r/\A[0-9][0-9,]*(?:\s*\/\s*[0-9][0-9,]*)?\s*\z/u),
          do: {result, true},
          else: {signed(sum), false}

      [] ->
        {signed(sum), false}
    end
  end

  defp signed(n) when n < 0, do: Integer.to_string(n)
  defp signed(n), do: "+" <> Integer.to_string(n)

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

  # (A number that stands alone and is given a greater one has grown to
  # it: "Level: 11" after level 10, "Gold: 50" after 42. A lesser one may
  # be what is left or what was lost, and "0" is said for no change.)
  defp numbered({:one, pre, now, _post} = one, {:set, a}, value, habits) do
    if lead?(pre) and a < now and unsigned?(value, a, now, habits),
      do: {elem(put_one(one, now), 0), :unsigned},
      else: put_one(dressed(one, value), a)
  end

  defp numbered(_shape, _delta, _value, _habits), do: nil

  # A number alone says neither which way the figure moves nor that it is
  # the new value: a small model writes "HP: 8" for eight lost, and
  # "Agility: 0" for no change. It is taken as the new value only when
  # said outright ("= 8", "14 → 8"), with words of its own ("8 left",
  # "45 (curious)"), or when it is the next count; the number as it
  # stands changes nothing either way.
  defp unsigned?(value, new, now, habits) do
    # One more than it was is a count going on ("Day: 2" after day 1):
    # the new value and the smallest change agree.
    not habits[:outright?] and new != now and new != now + 1 and
      String.match?(value, ~r/\A\s*-?[0-9,.]+\s*(?:%|\p{L}{0,3})\s*\z/u)
  end

  # A change that is words, or a field that is. A figure stays a figure:
  # words with no number in them are not one. A text takes the value as it
  # is said, a list a thing; "+0:45" moves a clock, and is nothing to add
  # to any other text.
  defp worded(was, _value, _habits, true), do: {was, :unreadable}

  defp worded(was, value, habits, false) do
    cond do
      Listing.empty?(was) or not String.match?(value, ~r/\A[+\-−]\s*\p{Nd}/u) ->
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
           Regex.run(~r/\A([^0-9]*?)([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?([^0-9].*|)\z/us, was),
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

  # A value with one clock in it, given a clock alone: that clock, in its place.
  defp reclocked(was, value) do
    clock = ~r/(?<![0-9:])[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?![0-9:])/u

    with true <- String.match?(value, ~r/\A[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?\z/u),
         [[{at, size}]] <- Regex.scan(clock, was, return: :index),
         true <- size < byte_size(was) do
      binary_part(was, 0, at) <> value <> binary_part(was, at + size, byte_size(was) - at - size)
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
      match = Regex.run(~r/\A[+\-−]\s*([0-9]+):([0-9]{2})(?::([0-9]{2}))?\s*\z/u, value) ->
        [h, m | s] = tl(match)

        {:ok,
         sign *
           (String.to_integer(h) * 3600 + String.to_integer(m) * 60 +
              seconds_of(List.first(s) || ""))}

      match = Regex.run(~r/\A[+\-−]\s*([0-9]+)\s*(시간|hours?|hrs?|h)\s*\z/iu, value) ->
        {:ok, sign * String.to_integer(Enum.at(match, 1)) * 3600}

      # Minutes, said or not: "+30분", "+30 min", "+30".
      match = Regex.run(~r/\A[+\-−]\s*([0-9]+)\s*(분|min|minutes?|m|)\s*[^0-9]*\z/iu, value) ->
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
  # words around its number and the new value brings words after its own
  # ("45 (호기심)" over "30 (경계)", "길드 3층" over "명월탑 1층", a row
  # written anew); as it was written before, for a number alone or a field
  # that is one. A figure keeps leading the value: words before the number
  # are not taken.
  defp dressed({:pair, was_pre, a, sep, b, {was_post, commas?}} = pair, value) do
    case number(value) do
      {:pair, pre, _a, _sep, _b, {post, _commas?}}
      when post != "" and (was_pre != "" or was_post != "") ->
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
      when post != "" and (was_pre != "" or was_post != "") ->
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
      empty: Enum.find(values, "None", &Listing.none?/1),
      # A window that splits its fields by "|" cannot have one in a value.
      bars?: not Enum.any?(values, &String.contains?(&1, "|"))
    }
  end

  # What a value is made of: `{:pair, pre, current, separator, max, post}`,
  # `{:one, pre, number, post}`, or `:text` (a time, a date, a list).
  defp number(value) do
    # A run of digits too long to be a figure (an id, a serial) is text.
    if String.match?(value, ~r/[0-9]{16}/), do: :text, else: figure_of(value)
  end

  defp figure_of(value) do
    cond do
      match =
          Regex.run(
            ~r/\A([^0-9]*?)(-?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(\s*\/\s*)((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)([^0-9]*)\z/u,
            value
          ) ->
        [_all, pre, a, sep, b, post] = match
        {:pair, pre, int(a), sep, int(b), {post, commas?(a) or commas?(b)}}

      # "12 kg / 80 kg", "50% / 100%": the same unit after both numbers.
      match =
          Regex.run(
            ~r/\A([^0-9]*?)(-?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(\s*(\p{L}{1,3}|%)\s*\/\s*)((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(\s*\4)\s*\z/u,
            value
          ) ->
        [_all, pre, a, sep, _unit, b, post] = match
        {:pair, pre, int(a), sep, int(b), {post, commas?(a) or commas?(b)}}

      match =
          Regex.run(
            ~r/\A([^0-9]*?)(-?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)([^0-9]*)\z/u,
            value
          ) ->
        [_all, pre, a, post] = match
        {:one, pre, int(a), {post, commas?(a)}}

      # A number that leads a row or a line: what follows may hold digits too.
      match =
          Regex.run(
            ~r/\A(-?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(\s*\/\s*)((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(\s*[|·(\[].*)\z/us,
            value
          ) ->
        [_all, a, sep, b, post] = match
        {:pair, "", int(a), sep, int(b), {post, commas?(a) or commas?(b)}}

      match =
          Regex.run(
            ~r/\A(-?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(\s*%?\s*[|·(\[].*)\z/us,
            value
          ) ->
        [_all, a, post] = match
        {:one, "", int(a), {post, commas?(a)}}

      true ->
        :text
    end
  end

  @number "(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\\.[0-9]+)?"
  @moved Regex.compile!("\\A([+\\-−])\\s*(#{@number})\\s*[^0-9\\/]*\\z", "u")
  # "+25 / 50": a move, written before the maximum it is kept within.
  @moved_pair Regex.compile!(
                "\\A([+\\-−])\\s*(#{@number})\\s*\\/\\s*#{@number}[^0-9]*\\z",
                "u"
              )
  @pair_set Regex.compile!("\\A[^0-9]*?(-?#{@number})\\s*\\/\\s*(#{@number})[^0-9]*\\z", "u")
  @one_set Regex.compile!("\\A[^0-9+\\-−]*?(#{@number})[^0-9]*\\z", "u")
  @moved_first Regex.compile!("\\A([+\\-−])\\s*(#{@number})(?!\\s*\\/|[0-9]|,[0-9])", "u")
  @pair_within Regex.compile!("(-?#{@number})\\s*\\/\\s*(#{@number})", "u")
  @numbers_within Regex.compile!("(?<![0-9,.])([+\\-−]?)\\s*(#{@number})", "u")

  # What a change asks for: `{:move, by}`, `{:set_pair, now, max}`,
  # `{:set, now}`, or `:text`. For a figure (`loose?`), a change with more
  # words than asked for is read by its number: "-17 (a goblin's club)"
  # moves, "now 31/48 after the potion" sets.
  defp delta(value, loose?) do
    cond do
      String.match?(value, ~r/[0-9]{16}/) -> :text
      match = Regex.run(@moved, value) -> move(match)
      match = Regex.run(@moved_pair, value) -> move(match)
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

  # A pair is kept within its maximum, and a percentage within 0 to 100,
  # when it was so before: "12/5 (Fri)" is no current and maximum, and a
  # bonus of 150% is no share of a whole.
  defp put_pair({:pair, pre, was_a, sep, was_b, {post, commas?}}, a, b, open? \\ false) do
    b = max(b, 0)

    bounded =
      cond do
        was_a > was_b -> a
        open? -> max(a, min(was_a, 0))
        true -> a |> max(min(was_a, 0)) |> min(b)
      end

    {pre <> digits(bounded, commas?) <> sep <> digits(b, commas?) <> post,
     if(bounded != a, do: :clamped)}
  end

  defp put_one({:one, pre, was, {post, commas?}}, a) do
    bounded =
      if String.match?(post, ~r/\A\s*%/u) and was >= 0 and was <= 100,
        do: a |> max(0) |> min(100),
        else: a

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

    # "-0.2": the whole part alone has lost the sign.
    sign = if n < 0, do: "-", else: ""
    sign <> digits(abs(String.to_integer(whole)), commas?) <> "." <> fraction
  end

  defp digits(n, false), do: Integer.to_string(n)

  defp digits(n, true) do
    sign = if n < 0, do: "-", else: ""

    grouped =
      n
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/([0-9]{3})(?=[0-9])/, "\\1,")
      |> String.reverse()

    sign <> grouped
  end

  defp key(name), do: Fields.key(name)

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
              Enum.split_with(lines, fn {kind, rest} -> refusal?(kind <> " · " <> rest) end)

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
    fields = fields(window, spec)
    names = Enum.map_join(fields, ", ", & &1.name)

    "The status window is kept by the game's rules and shown by them: do not print it yourself, whatever the card says. Instead, after everything else, write <aethrion-ledger>...</aethrion-ledger> with one line for each field of the window that this reply changes: `Field: +N` or `Field: -N`, always with its sign, for a number that goes up or down (damage taken is `HP: -N`, experience gained `EXP: +N`), `Field: N / M` to set both numbers of a pair, `Field: =N` to set a number outright, or the field's new words as they should read (a place moved to is `Location: the east gate`, in the story's language).#{lists_note(fields)}#{rows_note(fields)} Use the window's field names (#{names}).#{headings_note(fields)}#{scene_note(fields)}#{ruled_note(fields, spec)}#{already_note(recorded)} Leave out every field that stays as it is, and write the tags with nothing between them when nothing changes. What is listed under This turn and Now (how each character feels) is the rules' own and shown apart from the window: none of it goes in these lines. It is not shown to the player."
  end

  # Last turn's record, so that it is not written twice, and what was not
  # taken of it.
  defp already_note({done, refused}) do
    done =
      if done == [],
        do: "",
        else:
          " Last turn's changes are in the window already; do not write them again (" <>
            Enum.join(done, "; ") <> ")."

    if refused == [],
      do: done,
      else:
        done <>
          " These lines of yours last turn were not taken, for the reason in brackets; if one still holds, write it again in the form asked for: " <>
          Enum.join(refused, "; ") <> "."
  end

  defp lists_note(fields) do
    case Enum.filter(fields, &listing?/1) do
      [] ->
        ""

      [first | _rest] = lists ->
        " For a list (#{Enum.map_join(lists, ", ", & &1.name)}), write only what joins or leaves it, never the whole list: `#{first.name}: +thing × 2` for something gained, `#{first.name}: -thing × 1` for something used or lost."
    end
  end

  defp rows_note(fields) do
    case Enum.filter(fields, &(Cells.read(&1.value) != [])) do
      [] ->
        ""

      [first | _rest] = rows ->
        label = first.value |> Cells.read() |> hd() |> Map.fetch!(:label)

        " For a row of labelled numbers (#{Enum.map_join(rows, ", ", & &1.name)}), write the numbers that move by their labels, `#{first.name}: #{label} +1`, or write the whole row anew."
    end
  end

  defp ruled_note(fields, spec) do
    case set_by_rules(fields, spec) do
      [] ->
        ""

      set ->
        " The game's rules set these themselves, so do not write them, only what leads to them: " <>
          Enum.join(set, ", ") <>
          " (" <> Enum.join(rule_texts(fields, spec), " | ") <> ")."
    end
  end

  defp headings_note(fields) do
    for %{heading?: true, name: name, value: value} <- fields,
        length(String.split(value, " · ")) >= 2,
        into: "",
        do:
          " #{name} is a heading of several parts (now `#{String.slice(value, 0, 80)}`): when one of them changes, write all of it as it should read, `#{name}: ...` with every part."
  end

  # When and where: a model that no longer prints the window forgets them first.
  defp scene_note(fields) do
    case Enum.filter(fields, &(placed?(&1) or timed?(&1.name) or &1[:heading?] == true)) do
      [] ->
        ""

      moving ->
        " Time passes and places change as the story goes: when this reply moves either, say so (#{Enum.map_join(moving, ", ", & &1.name)})."
    end
  end

  @doc """
  What the note says of the window on a turn that was answered before
  (a reroll): what the turn does to the window is settled, as facts to
  narrate. `lines` are the record's lines of the first answer, and
  `fields` the fields it left changed.
  """
  @spec settled_instruction([String.t()], [{String.t(), String.t()}]) :: String.t()
  def settled_instruction(lines, fields \\ []) do
    # What was refused then is no fact of the turn. A field the record
    # does not speak of (a place, a mood) is said as it came to stand.
    lines = Enum.reject(lines, &refusal?/1)
    said = Enum.join(lines, " ")

    words =
      for {name, value} <- fields,
          not String.contains?(said, name <> " "),
          do: "#{name}: #{value}"

    facts =
      case lines ++ words do
        [] -> "nothing in it changes this turn"
        facts -> Enum.join(facts, "; ")
      end

    "The status window is kept by the game's rules and shown by them: do not print it yourself, whatever the card says, and write no <aethrion-ledger> lines. This turn was played before, and what it does to the window is settled: #{facts}. Narrate so that the reply agrees with that: the same gains, losses, and outcome, told anew."
  end

  # A record line for a change that was not taken: "기록 · Mana: +1 (없는 칸)".
  defp refusal?(line),
    do: String.match?(line, ~r/\A(?:기록|Ledger) · [^·→]+: .*\([^()]*\)\s*\z/u)

  @doc "What the note says of the window when a reply is only continued."
  @spec continued_instruction() :: String.t()
  def continued_instruction do
    "The status window is kept by the game's rules and stands in the reply you are continuing: do not print it again, whatever the card says, and write no <aethrion-ledger> lines. Nothing in it changes in this continuation."
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
    |> Enum.reject(&(&1 == nil or &1 == "the maximum of "))
    |> Enum.uniq()
  end

  # A field the model is told to treat as a list: counted things, things
  # split by " / " or " · ", or a name that says so.
  defp listing?(%{name: name, value: value}) do
    not figure?(value) and not placed?(%{name: name, value: value}) and
      ((list?(value) and (Listing.counted?(value) or Listing.separator(value) in [" / ", " · "])) or
         String.match?(
           name,
           ~r/item|inventory|skill|belonging|소지|아이템|인벤|가방|스킬|기술|소유|持ち物|スキル|🎒/iu
         ))
  end

  @doc """
  The turn's record without what came to nothing: a change that a rule
  then put back ("EXP 337 / 351 → 337 / 385" and "EXP 337 / 385 → 337 /
  351") is a line of neither. `{applied, ruled}` as they are shown.
  """
  @spec net([{String.t(), String.t(), String.t()}], [{String.t(), String.t(), String.t()}]) ::
          {[{String.t(), String.t(), String.t()}], [{String.t(), String.t(), String.t()}]}
  def net(applied, ruled) do
    undone =
      for {name, was, _now} <- applied,
          {^name, _from, back} <- ruled,
          back == was,
          do: name

    reject = fn changes -> Enum.reject(changes, fn {name, _was, _now} -> name in undone end) end
    {reject.(applied), reject.(ruled)}
  end

  @doc """
  The reply without lines that are only the window's opening or closing
  text: a marker the model left in its story would pair with the window's
  own, for whatever draws the window.
  """
  @spec unmarked(String.t(), spec() | nil) :: String.t()
  def unmarked(text, nil), do: text

  def unmarked(text, spec) do
    markers =
      for marker <- [spec.open, spec.close],
          marker = String.trim(marker),
          byte_size(marker) >= 4,
          do: marker

    if markers == [],
      do: text,
      else:
        text
        |> String.split("\n")
        |> Enum.reject(&(String.trim(&1) in markers))
        |> Enum.join("\n")
  end

  @doc """
  The refusals that still say something once the rules have run. A change
  left to a rule (`:ruled`) that named what the rule then gave ("Stat
  Point: =0" for points the rule took in payment) was right, and is no
  refusal worth a line. `before` and `settled` are the window before the
  turn and after its rules.
  """
  @spec unanswered([{String.t(), String.t(), atom()}], String.t(), String.t(), spec() | nil) ::
          [{String.t(), String.t(), atom()}]
  def unanswered(refused, before, settled, spec \\ nil) do
    was = Map.new(fields(before, spec), &{key(&1.name), first(&1.value)})
    now = Map.new(fields(settled, spec), &{key(&1.name), first(&1.value)})

    Enum.reject(refused, fn
      {name, value, :ruled} ->
        case delta(String.replace(value, ~r/\A\s*=\s*/u, ""), true) do
          {:move, by} -> is_map_key(was, key(name)) and now[key(name)] == was[key(name)] + by
          {:set, to} -> now[key(name)] == to
          {:set_pair, to, _max} -> now[key(name)] == to
          :text -> false
        end

      _other ->
        false
    end)
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
        named(name, Cells.moved(was, now))

      # (A figure whose words changed and whose number did not shows no line.)
      figure?(was) or figure?(now) ->
        if brief(was) == brief(now), do: [], else: ["#{name} #{brief(was)} → #{brief(now)}"]

      listing?(%{name: name, value: was}) or listing?(%{name: name, value: now}) ->
        named(name, Listing.moved(was, now))

      true ->
        []
    end
  end

  defp named(_name, []), do: []
  defp named(name, moved), do: ["#{name} " <> Enum.join(moved, ", ")]

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

  # A field that holds a date ("12/5 (Fri)", "2025.01.01"): its numbers
  # are no figures, however they are written.
  defp dated_name?(name) do
    String.match?(name, ~r/(?<![\p{L}])(?:date|birthday|today)(?![\p{L}])/iu) or
      String.match?(name, ~r/날짜|생일|기념일|오늘|日付|日期|(?<![\p{L}])일자(?![\p{L}])/u)
  end

  # By its name, unless its value is one plain number ("Today's Earnings:
  # 120G", "Date Count: 3"); or by its value (`weekday?/1`).
  defp dated?(%{name: name, value: value}) do
    (dated_name?(name) and
       not String.match?(value, ~r/\A\s*\D{0,3}[0-9][0-9,.]*\s*[\p{L}%]{0,3}\s*\z/u)) or
      weekday?(value)
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
              (byte_size(open) >= @sure_opening or window_line?(held))

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
          byte_size(open) >= @sure_opening ->
            :held

          # A short one ("["): the line decides, once it is whole.
          :binary.match(rest, "\n") != :nomatch ->
            {line_end, 1} = :binary.match(rest, "\n")
            line = binary_part(rest, 0, line_end + 1)

            if window_line?(line) do
              :held
            else
              # The story's line: past its opening text, it is passed on as
              # any other (a tag on it stops the stream there).
              out(emit, open)

              pass(
                binary_part(rest, byte_size(open), byte_size(rest) - byte_size(open)),
                false,
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

        # At a line's start still when only blanks have gone out on the line.
        line_start? =
          cond do
            passed == "" -> line_start?
            String.contains?(passed, "\n") -> String.match?(passed, ~r/\n[ \t]*\z/)
            true -> line_start? and String.match?(passed, ~r/\A[ \t]*\z/)
          end

        {keep, line_start?}
    end
  end

  defp out(_emit, ""), do: :ok
  defp out(emit, text), do: emit.(text)

  # Where the reply's own end begins: the first tag, or the window's
  # opening text at the start of a line, whichever comes first.
  defp stop(text, line_start?, open) do
    lowered = lowered(text)

    tag =
      [@scene, @tag]
      |> Enum.flat_map(fn tag ->
        case :binary.match(lowered, tag) do
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
      # At the text's own start only when that is a line's start; after a
      # line break anywhere, the first character included.
      if all > 0 or line_start? or binary_part(text, 0, 1) == "\n", do: at
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

  # The end of the text that is the beginning of the tag, in any case.
  defp prefix_tail(text, tag) do
    1..(byte_size(tag) - 1)
    |> Enum.reverse()
    |> Enum.find_value("", fn n ->
      if byte_size(text) >= n do
        ending = binary_part(text, byte_size(text) - n, n)
        if lowered(ending) == binary_part(tag, 0, n), do: ending
      end
    end)
  end

  # ASCII letters lowered, so every place in the text stays where it is.
  defp lowered(text),
    do: for(<<c <- text>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)
end
