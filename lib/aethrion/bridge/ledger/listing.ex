defmodule Aethrion.Bridge.Ledger.Listing do
  @moduledoc """
  The lists in a card's status window (things carried, skills known, who is
  in the party, coins of several kinds), changed one thing at a time.

  A model asked what changed in a list tends to write the change ("+ two
  mana stones") and, asked for the list, to forget half of it. So the
  ledger keeps the list and takes changes to it (`change/3`):

  - `+thing` joins it and `-thing` leaves it, with a count when there are
    several (`+마정석 × 2`, `-회복의 물약 × 1`, `+2 mana stones`); something
    the list already has is counted up or down in the way the list writes
    its counts (`× 3`, `x3`, `3개`, `(3)`);
  - an amount (`5G` in `0G, 0S, 0C`) is added to the amount of its kind,
    and does not go below nothing;
  - anything else replaces the value, except that a list of counted things
    given one counted thing keeps the rest.

  A list is written back as it was written: its separator (`" / "`,
  `", "`, `" · "`), its brackets and quotes (`["a", "b"]`), and the word it
  uses when empty.
  """

  @separators [" / ", ", ", " · ", "、", " ・ "]
  @empty [
    "none",
    "없음",
    "-",
    "–",
    "—",
    "n/a",
    "nil",
    "x",
    "無",
    "なし",
    "無し",
    "없다",
    "(없음)",
    "(none)",
    "[]"
  ]

  @typedoc """
  One thing of a list: its name, how many (nil when it carries no count),
  and how the count is written: `{mark, unit}` around the number after the
  name, or `{:amount, space}` for a number before its kind.
  """
  @type item :: %{
          name: String.t(),
          count: integer() | nil,
          style: {String.t(), String.t()} | {:amount, String.t()} | nil
        }

  @typedoc "What a window's lists look like when one cannot tell from the list itself."
  @type habits :: %{
          required(:separator) => String.t(),
          required(:empty) => String.t(),
          optional(atom()) => term()
        }

  @doc "Whether a value says a list has nothing in it."
  @spec empty?(String.t()) :: boolean()
  def empty?(value) do
    value = String.downcase(String.trim(value))

    # The word for nothing, or for not known yet ("확인 중", "???").
    value in @empty or String.match?(value, ~r/\A(?:확인 중.*|미정|불명|알 수 없음|unknown|tbd|\?+)\z/u)
  end

  @doc "Whether a value is a word for nothing, as a window writes an empty list."
  @spec none?(String.t()) :: boolean()
  def none?(value), do: String.downcase(String.trim(value)) in (@empty -- ["x"])

  @doc "The text between a list's things, or nil for a value that is one thing."
  @spec separator(String.t()) :: String.t() | nil
  def separator(value) do
    {_wrap, inner} = unwrap(value)
    Enum.find(@separators, &(length(apart(inner, &1)) >= 2))
  end

  @doc """
  Whether a value is a list: several things, or one that is counted. (A
  pair of numbers, `48 / 48`, is the caller's to tell apart.)
  """
  @spec list?(String.t()) :: boolean()
  def list?(value) do
    separator(value) != nil or
      case items(value) do
        [%{count: count}] -> count != nil
        _other -> false
      end
  end

  @doc "Whether a value is a list of counted things, such as an inventory."
  @spec counted?(String.t()) :: boolean()
  def counted?(value), do: Enum.any?(items(value), & &1.count)

  @doc "The things in a value."
  @spec items(String.t()) :: [item()]
  def items(value) do
    {_wrap, inner} = unwrap(value)

    cond do
      empty?(value) or String.trim(inner) == "" -> []
      separator = separator(value) -> inner |> apart(separator) |> Enum.map(&item/1)
      true -> [item(inner)]
    end
  end

  # The things of a list, split where its separator stands outside
  # brackets: "Kit (flint, matches), Guidebook" is two things.
  defp apart(text, separator) do
    text
    |> String.split(separator)
    |> Enum.reduce([], fn
      piece, [last | rest] = pieces ->
        if unclosed?(last), do: [last <> separator <> piece | rest], else: [piece | pieces]

      piece, [] ->
        [piece]
    end)
    |> Enum.reverse()
  end

  defp unclosed?(text) do
    count = fn marks -> length(Regex.scan(marks, text)) end
    count.(~r/[(（]/u) > count.(~r/[)）]/u)
  end

  # A list in brackets: `["a", "b"]`.
  defp unwrap(value) do
    case Regex.run(~r/\A(\s*\[)(.*)(\]\s*)\z/us, value) do
      [_all, open, inner, close] -> {{open, close}, inner}
      nil -> {nil, value}
    end
  end

  defp quoted?(value) do
    {_wrap, inner} = unwrap(value)

    parts =
      case separator(value) do
        nil -> [inner]
        separator -> apart(inner, separator)
      end

    parts != [] and Enum.all?(parts, &String.match?(&1, ~r/\A\s*"[^"]*"\s*\z/u))
  end

  # One thing as a list writes it.
  defp item(text) do
    text = text |> String.trim() |> String.replace(~r/\A"(.*)"\z/us, "\\1")

    cond do
      match = Regex.run(~r/\A(.+?)(\s*[×xX\*]\s*)([0-9]+)(개|ea|)\z/u, text) ->
        [_all, name, mark, count, unit] = match
        %{name: String.trim(name), count: String.to_integer(count), style: {mark, unit}}

      match = Regex.run(~r/\A(.+?)(\s+)([0-9]+)(개)\z/u, text) ->
        [_all, name, mark, count, unit] = match
        %{name: String.trim(name), count: String.to_integer(count), style: {mark, unit}}

      match = Regex.run(~r/\A(.+?)(\s*\()([0-9]+)(\))\z/u, text) ->
        [_all, name, mark, count, unit] = match
        %{name: String.trim(name), count: String.to_integer(count), style: {mark, unit}}

      match = Regex.run(~r/\A([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(\s*)(\p{L}{1,8})\z/u, text) ->
        [_all, count, space, kind] = match

        %{
          name: kind,
          count: count |> String.replace(",", "") |> String.to_integer(),
          style: {:amount, space}
        }

      true ->
        %{name: text, count: nil, style: nil}
    end
  end

  # One thing as a change writes it: also "× 2 추가 획득" and "2 마정석".
  defp changed_item(text) do
    text = String.trim(text)

    # "2S (now 2S)", "1C (the bet)": an amount, with a remark on it.
    text =
      with [_all, bare] <- Regex.run(~r/\A([0-9][0-9,]*\p{L}{1,3})\s*\([^()]*\)\z/us, text),
           %{style: {:amount, _space}} <- item(bare) do
        bare
      else
        _other -> text
      end

    case item(text) do
      %{count: nil} ->
        cond do
          match = Regex.run(~r/\A(.+?)(\s*[×xX\*]\s*)([0-9]+)(개|ea|)\s+[^0-9]*\z/u, text) ->
            [_all, name, mark, count, unit] = match
            %{name: String.trim(name), count: String.to_integer(count), style: {mark, unit}}

          match = Regex.run(~r/\A([0-9]+)\s*(?:개의?|[×xX])?\s+([^0-9].*)\z/u, text) ->
            [_all, count, name] = match
            %{name: String.trim(name), count: String.to_integer(count), style: nil}

          true ->
            %{name: text, count: nil, style: nil}
        end

      item ->
        item
    end
  end

  @doc """
  The value after a change, and what was wrong with the change: nil,
  `:missing` for something taken from a list that does not have it, or
  `:clamped` for an amount that would have gone below nothing.
  """
  @spec change(String.t(), String.t(), habits()) :: {String.t(), atom() | nil}
  def change(was, value, habits) do
    items = items(was)

    # "+ring → -ring (given away)", as some write a change: what it comes to.
    value =
      case String.split(value, ~r/\s*(?:→|->|=>)\s*(?=[+\-−])/u) do
        [_one] -> value
        parts -> List.last(parts)
      end

    cond do
      String.match?(value, ~r/\A[+\-−]/u) ->
        {items, problem} = value |> steps(separator(was)) |> Enum.reduce({items, nil}, &step/2)
        {written(items, was, habits), problem}

      renamed = renamed(items, value) ->
        {written(renamed, was, habits), nil}

      steps = worded_steps(value, separator(was)) ->
        {items, problem} = Enum.reduce(steps, {items, nil}, &step/2)
        {written(items, was, habits), problem}

      one_of_many?(items, value) ->
        {written(one(items, value), was, habits), nil}

      # A list of counted things is not said anew in a word ("same",
      # "±0"): that would be everything lost. An empty list says so.
      length(items) >= 2 and Enum.any?(items, & &1.count) and separator(value) == nil and
          not empty?(value) ->
        {was, :unreadable}

      true ->
        {value, nil}
    end
  end

  # "Slash → Slash II": a thing of the list under a new name, the rest as it was.
  defp renamed(items, value) do
    with [old, new] <- String.split(value, ~r/\s*(?:→|->|=>)\s*/u),
         true <- String.trim(new) != "",
         held when held != nil <- Enum.find(items, &same?(&1, changed_item(old))) do
      new = changed_item(new)

      Enum.map(items, fn item ->
        if item == held,
          do: %{
            held
            | name: new.name,
              count: new.count || held.count,
              style: held.style || new.style
          },
          else: item
      end)
    else
      _other -> nil
    end
  end

  @gained ~r/\s+(?:추가\s*)?(?:획득|얻\S*|입수|added|gained|obtained|acquired)\s*\z/iu
  @used ~r/\s+(?:사용|소모|소비|잃\S*|판매|used|lost|sold|consumed|spent)\s*\z/iu

  # "Potion × 1 used, mana stone × 5 gained": every thing with the word
  # for what became of it, and no signs.
  defp worded_steps(value, separator) do
    parts =
      value
      |> apart(separator || ", ")
      |> Enum.flat_map(&apart(&1, ", "))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    steps =
      Enum.map(parts, fn part ->
        cond do
          String.match?(part, @gained) -> {:plus, changed_item(String.replace(part, @gained, ""))}
          String.match?(part, @used) -> {:minus, changed_item(String.replace(part, @used, ""))}
          true -> nil
        end
      end)

    if steps != [] and Enum.all?(steps), do: steps
  end

  defp step({sign, item}, {items, problem}) do
    case move(items, sign, item) do
      {:ok, items} -> {items, problem}
      {problem, items} -> {items, problem}
    end
  end

  # One counted thing where the whole list of counted things was asked for.
  defp one_of_many?(items, value) do
    length(items) >= 2 and Enum.any?(items, & &1.count) and separator(value) == nil and
      not empty?(value) and changed_item(value).count != nil
  end

  # The list with that one thing gained, or counted anew: the rest stays.
  defp one(items, value) do
    new = changed_item(value)

    cond do
      gained?(value) ->
        elem(move(items, :plus, new), 1)

      Enum.any?(items, &same?(&1, new)) ->
        Enum.map(items, &if(same?(&1, new), do: %{&1 | count: new.count}, else: &1))

      true ->
        items ++ [new]
    end
  end

  defp same?(a, b), do: key(a.name) == key(b.name)

  defp key(name), do: name |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  # A change written with words for getting something ("× 2 추가 획득").
  defp gained?(value),
    do: String.match?(value, ~r/추가|획득|얻|입수|added|gained|obtained|acquired|more\b/iu)

  # "+A × 2, -B" as steps: each thing with its own sign, or the one before it.
  defp steps(value, separator) do
    {steps, _sign} =
      value
      |> apart(separator || ", ")
      |> Enum.flat_map(fn part ->
        # (Not within brackets: "+Kit (flint, +matches)" is one thing.)
        if unclosed?(hd(String.split(part, ~r/\s*[,;\/·]\s*(?=[+\-−]\s*\S)/u))),
          do: [part],
          else: String.split(part, ~r/\s*[,;\/·]\s*(?=[+\-−]\s*\S)/u)
      end)
      # "+potion × 1 -rat fur × 1": nothing between them but a space. (A
      # sign before a number is a thing's own: "sword +1".)
      |> Enum.flat_map(&String.split(&1, ~r/\s+(?=[+\-−][^\p{Nd}\s+\-−])/u))
      |> Enum.flat_map(&counted_parts/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_reduce(:plus, fn part, sign ->
        case Regex.run(~r/\A([+\-−])\s*(.*)\z/us, part) do
          [_all, "+", rest] -> {{:plus, changed_item(rest)}, :plus}
          [_all, _minus, rest] -> {{:minus, changed_item(rest)}, :minus}
          # With no sign of its own, the word for it, or the sign before.
          nil -> {{said_sign(part, sign), changed_item(part)}, sign}
        end
      end)

    Enum.reject(steps, fn {_sign, item} -> item.name == "" end)
  end

  # "-hive × 5 slain, mana stone × 5 gained", in a list that splits its
  # things otherwise: each counted thing is a part.
  defp counted_parts(part) do
    pieces = String.split(part, ~r/,\s+/u)

    if length(pieces) >= 2 and
         Enum.all?(pieces, &String.match?(&1, ~r/\A\s*[+\-−]|[×xX\*]\s*[0-9]+|[0-9]+\s*개/u)),
       do: pieces,
       else: [part]
  end

  defp said_sign(part, sign) do
    cond do
      gained?(part) -> :plus
      String.match?(part, ~r/사용|소모|소비|잃|판매|used|lost|sold|consumed|spent/iu) -> :minus
      true -> sign
    end
  end

  defp move(items, :plus, new) do
    cond do
      # A list that counts nothing (quests, companions) has a thing or
      # has it not: joining twice is joining once.
      Enum.any?(items, &same?(&1, new)) and new.count == nil and
          not Enum.any?(items, & &1.count) ->
        {:ok, items}

      Enum.any?(items, &same?(&1, new)) ->
        counted_up(items, new)

      # A list that counts every thing counts the new one as well.
      new.count == nil and items != [] and Enum.all?(items, &marked?/1) ->
        {:ok, items ++ [%{new | count: 1, style: style(items)}]}

      true ->
        {:ok, items ++ [new]}
    end
  end

  defp move(items, :minus, gone) do
    case Enum.find(items, &same?(&1, gone)) do
      nil -> without_remark(items, gone)
      # An amount is spent by a number: "-G" says none.
      %{style: {:amount, _space}} when gone.count == nil -> {:missing, items}
      %{style: {:amount, _space}} = held -> spend(items, held, gone)
      held -> take_away(items, held, gone)
    end
  end

  # A thing with its count after it ("rope × 1"), not an amount ("5G").
  defp marked?(%{count: count, style: {mark, _unit}}), do: count != nil and is_binary(mark)
  defp marked?(_item), do: false

  # "-rope (used for the trap)": the thing without the remark on it.
  defp without_remark(items, gone) do
    case Regex.run(~r/\A(.+?)\s*\([^()]*\)\z/us, gone.name) do
      [_all, name] -> move(items, :minus, %{gone | name: name})
      nil -> {:missing, items}
    end
  end

  # An amount stays in the list at nothing.
  defp spend(items, %{count: count} = held, gone) do
    left = count - (gone.count || count)
    items = Enum.map(items, &if(same?(&1, held), do: %{&1 | count: max(left, 0)}, else: &1))
    if left < 0, do: {:clamped, items}, else: {:ok, items}
  end

  # One of a thing leaves unless a count says more, as one joins: "-potion"
  # from "potion × 3" leaves two. More than there are leaves none, and
  # is said to be more than was held.
  defp take_away(items, held, gone) do
    left = (held.count || 1) - (gone.count || 1)

    items =
      Enum.flat_map(items, fn item ->
        cond do
          not same?(item, held) -> [item]
          left <= 0 -> []
          true -> [%{item | count: left}]
        end
      end)

    if left < 0, do: {:clamped, items}, else: {:ok, items}
  end

  defp counted_up(items, new) do
    {:ok,
     Enum.map(items, fn item ->
       if same?(item, new),
         do: %{
           item
           | count: (item.count || 1) + (new.count || 1),
             style: item.style || new.style || style(items)
         },
         else: item
     end)}
  end

  # How the list's other things write a count.
  defp style(items) do
    Enum.find_value(items, {" × ", ""}, fn
      %{style: {mark, unit}} when is_binary(mark) -> {mark, unit}
      _other -> nil
    end)
  end

  # The list as the value before it was written.
  defp written(items, was, habits) do
    {wrap, _inner} = unwrap(was)
    quoted? = quoted?(was)
    separator = separator(was) || habits.separator

    text =
      Enum.map_join(items, separator, fn item ->
        text =
          case item do
            %{count: nil, name: name} -> name
            %{style: {:amount, space}, name: name, count: count} -> "#{count}#{space}#{name}"
            %{style: {mark, unit}, name: name, count: count} -> "#{name}#{mark}#{count}#{unit}"
            %{style: nil, name: name, count: count} -> "#{name} × #{count}"
          end

        if quoted?, do: ~s("#{text}"), else: text
      end)

    case {wrap, items} do
      {{open, close}, _items} -> open <> text <> close
      {nil, []} -> habits.empty
      {nil, _items} -> text
    end
  end

  @doc """
  What joined a list and what left it, for the turn's record: `["+마정석 ×
  2", "−물약"]`. Nothing for a value written anew (no thing in common).
  """
  @spec moved(String.t(), String.t()) :: [String.t()]
  def moved(was, now) do
    {before, after_} = {items(was), items(now)}

    count = fn items, name ->
      Enum.find_value(items, 0, &if(key(&1.name) == key(name), do: &1.count || 1))
    end

    things = Enum.uniq_by(before ++ after_, &key(&1.name))

    kept? =
      before == [] or after_ == [] or
        Enum.any?(before, fn b -> Enum.any?(after_, &same?(&1, b)) end)

    if kept? do
      Enum.flat_map(things, fn %{name: name, style: style} ->
        d = count.(after_, name) - count.(before, name)
        sign = if d > 0, do: "+", else: "−"

        case {d, style} do
          {0, _style} -> []
          {d, {:amount, space}} -> ["#{sign}#{abs(d)}#{space}#{name}"]
          {d, _style} when abs(d) > 1 -> ["#{sign}#{name} × #{abs(d)}"]
          {_d, _style} -> ["#{sign}#{name}"]
        end
      end)
    else
      []
    end
  end
end
