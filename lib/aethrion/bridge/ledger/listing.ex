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

  @doc "The text between a list's things, or nil for a value that is one thing."
  @spec separator(String.t()) :: String.t() | nil
  def separator(value) do
    {_wrap, inner} = unwrap(value)
    Enum.find(@separators, &(length(String.split(inner, &1)) >= 2))
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
      separator = separator(value) -> inner |> String.split(separator) |> Enum.map(&item/1)
      true -> [item(inner)]
    end
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
        separator -> String.split(inner, separator)
      end

    parts != [] and Enum.all?(parts, &String.match?(&1, ~r/\A\s*"[^"]*"\s*\z/u))
  end

  # One thing as a list writes it.
  defp item(text) do
    text = text |> String.trim() |> String.replace(~r/\A"(.*)"\z/us, "\\1")

    cond do
      match = Regex.run(~r/\A(.+?)(\s*[×xX\*]\s*)(\d+)(개|ea|)\z/u, text) ->
        [_all, name, mark, count, unit] = match
        %{name: String.trim(name), count: String.to_integer(count), style: {mark, unit}}

      match = Regex.run(~r/\A(.+?)(\s+)(\d+)(개)\z/u, text) ->
        [_all, name, mark, count, unit] = match
        %{name: String.trim(name), count: String.to_integer(count), style: {mark, unit}}

      match = Regex.run(~r/\A(.+?)(\s*\()(\d+)(\))\z/u, text) ->
        [_all, name, mark, count, unit] = match
        %{name: String.trim(name), count: String.to_integer(count), style: {mark, unit}}

      match = Regex.run(~r/\A(\d{1,3}(?:,\d{3})+|\d+)(\s*)(\p{L}{1,8})\z/u, text) ->
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

    case item(text) do
      %{count: nil} ->
        cond do
          match = Regex.run(~r/\A(.+?)(\s*[×xX\*]\s*)(\d+)(개|ea|)\s+\D*\z/u, text) ->
            [_all, name, mark, count, unit] = match
            %{name: String.trim(name), count: String.to_integer(count), style: {mark, unit}}

          match = Regex.run(~r/\A(\d+)\s*(?:개의?|[×xX])?\s+(\D.*)\z/u, text) ->
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

    cond do
      String.match?(value, ~r/\A[+\-−]/u) ->
        {items, problem} =
          value
          |> steps(separator(was))
          |> Enum.reduce({items, nil}, fn {sign, item}, {items, problem} ->
            case move(items, sign, item) do
              {:ok, items} -> {items, problem}
              {problem, items} -> {items, problem}
            end
          end)

        {written(items, was, habits), problem}

      # One counted thing where the whole list was asked for: the rest stays.
      length(items) >= 2 and Enum.any?(items, & &1.count) and separator(value) == nil and
        not empty?(value) and changed_item(value).count != nil ->
        new = changed_item(value)

        items =
          cond do
            gained?(value) ->
              elem(move(items, :plus, new), 1)

            Enum.any?(items, &same?(&1, new)) ->
              Enum.map(items, &if(same?(&1, new), do: %{&1 | count: new.count}, else: &1))

            true ->
              items ++ [new]
          end

        {written(items, was, habits), nil}

      true ->
        {value, nil}
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
      |> String.split(separator || ", ")
      |> Enum.flat_map(&String.split(&1, ~r/\s*[,\/·]\s*(?=[+\-−]\s*\S)/u))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_reduce(:plus, fn part, sign ->
        case Regex.run(~r/\A([+\-−])\s*(.*)\z/us, part) do
          [_all, "+", rest] -> {{:plus, changed_item(rest)}, :plus}
          [_all, _minus, rest] -> {{:minus, changed_item(rest)}, :minus}
          nil -> {{sign, changed_item(part)}, sign}
        end
      end)

    Enum.reject(steps, fn {_sign, item} -> item.name == "" end)
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

      true ->
        {:ok, items ++ [new]}
    end
  end

  defp move(items, :minus, gone) do
    case Enum.find(items, &same?(&1, gone)) do
      nil ->
        {:missing, items}

      # An amount stays in the list at nothing.
      %{style: {:amount, _space}, count: count} = held ->
        left = count - (gone.count || count)
        items = Enum.map(items, &if(same?(&1, held), do: %{&1 | count: max(left, 0)}, else: &1))
        if left < 0, do: {:clamped, items}, else: {:ok, items}

      held ->
        left = (held.count || 1) - (gone.count || held.count || 1)

        {:ok,
         Enum.flat_map(items, fn item ->
           cond do
             not same?(item, held) -> [item]
             left <= 0 -> []
             true -> [%{item | count: left}]
           end
         end)}
    end
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
