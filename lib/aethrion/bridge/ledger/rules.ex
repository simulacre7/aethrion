defmodule Aethrion.Bridge.Ledger.Rules do
  @moduledoc """
  The arithmetic a card states for its status window, worked out by the
  rules instead of the model: what a level costs, what a stat gives, what a
  number may not pass.

  A card writes such things in prose ("Max HP +10 per point of Vigor",
  "100 × 1.15^(Level − 1) = Max EXP", "gain 5 stat points upon leveling
  up"), and a model asked to follow them does so from memory, a little
  differently each time. The model that reads the card
  (`Aethrion.Bridge.AutoCast`) writes them down once in a small language,
  one rule to a line, with the window's own field names:

      HP.max = Vigor * 10
      EXP.max = floor(100 * 1.15 ^ (Level - 1))
      Trust = clamp(Trust, 0, 100)
      when EXP >= EXP.max: Level += 1; EXP -= EXP.max; Stat Point += if(Level % 5 == 0, 15, 5)

  - `Target = expression` always holds: after every change it is worked
    out again. `Field.max` is the second number of a pair such as
    `HP: 30 / 48`; a pair that was full stays full when its maximum moves.
    `Field.before` is what the field was before this turn, for a number
    that may move only so far at a time: `Trust = clamp(Trust,
    Trust.before - 2, Trust.before + 2)`.
  - `when condition: change; change` happens, again and again while the
    condition holds (two levels at once), each change seeing the ones
    before it. One of its changes has to move something the condition
    looks at, or it would never stop.
  - `when Field rises: change; change` happens once for each point the
    field went up this turn (`when Level rises: Stat Point += 5`), whoever
    raised it.
  - An expression has numbers, fields, `+ - * / ^ %`, comparisons, `and`,
    `or`, and `floor`, `ceil`, `round`, `min`, `max`, `clamp(x, low,
    high)`, `if(condition, a, b)`. A number put in a field is cut to a
    whole one.

  Rules are parsed against the fields a window has (`parse/2`): a rule that
  does not parse, or names a field the window lacks, is left out, and the
  model keeps that number as before. `run/2` works the rest out on the
  window's numbers.
  """

  @typedoc "A field's numbers: its value, and the maximum of a pair."
  @type value :: %{now: number(), max: number() | nil}

  @typedoc "A window's numbers, by field name in lower case."
  @type values :: %{String.t() => value()}

  @type target :: {String.t(), :now | :max}
  @type part :: :now | :max | :before
  @type expr ::
          {:num, number()}
          | {:field, String.t(), part()}
          | {:neg, expr()}
          | {:op, atom(), expr(), expr()}
          | {:call, String.t(), [expr()]}
  @type change :: {:set | :add | :sub, target(), expr()}
  @type rule ::
          {:always, target(), expr()}
          | {:when, expr(), [change()]}
          | {:rise, String.t(), [change()]}

  @functions ~w(floor ceil round min max clamp if abs)
  @max_firings 40

  @doc """
  A rule as written, read against the window's field names (as the ledger
  keys them: lower case): `{:ok, rule}`, or `:error`.
  """
  @spec parse(String.t(), [String.t()]) :: {:ok, rule()} | :error
  def parse(text, names) when is_binary(text) do
    names = spellings(names)
    text = text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

    # "change when condition", as some write it, is "when condition: change".
    text =
      case Regex.run(~r/\A(?!when )(.+?) when (.+)\z/u, text) do
        [_all, changes, condition] -> "when #{condition}: #{changes}"
        nil -> text
      end

    with {:ok, tokens} <- lex(text, names, []),
         {:ok, rule} <- rule(tokens) do
      {:ok, rule}
    else
      _error -> :error
    end
  catch
    :error -> :error
  end

  def parse(_other, _names), do: :error

  # -- tokens

  defp lex("", _names, acc), do: {:ok, Enum.reverse(acc)}
  defp lex(" " <> rest, names, acc), do: lex(rest, names, acc)

  defp lex(text, names, acc) do
    cond do
      found = Enum.find(names, fn {spelling, _name} -> named?(text, spelling) end) ->
        {spelling, name} = found
        rest = binary_part(text, byte_size(spelling), byte_size(text) - byte_size(spelling))

        case Regex.run(~r/\A\.(max|maximum|now|current|cur|before|was|previous|prev)\b/u, rest) do
          [suffix, part] ->
            part =
              cond do
                part in ["max", "maximum"] -> :max
                part in ["before", "was", "previous", "prev"] -> :before
                true -> :now
              end

            rest = binary_part(rest, byte_size(suffix), byte_size(rest) - byte_size(suffix))
            lex(rest, names, [{:field, name, part} | acc])

          nil ->
            lex(rest, names, [{:field, name, :now} | acc])
        end

      match = Regex.run(~r/\A\d+(?:\.\d+)?/, text) ->
        [number] = match
        {value, ""} = Float.parse(number)
        lex(after_token(text, number), names, [{:num, value} | acc])

      match = Regex.run(~r/\A(>=|<=|==|!=|\+=|-=|≥|≤|≠|&&|\|\|)/u, text) ->
        [op | _] = match

        token =
          case op do
            "≥" -> ">="
            "≤" -> "<="
            "≠" -> "!="
            "&&" -> "and"
            "||" -> "or"
            op -> op
          end

        lex(after_token(text, op), names, [{:op, token} | acc])

      match = Regex.run(~r/\A[+\-*\/^%(),=><:;×÷−]/u, text) ->
        [op] = match

        token =
          case op do
            "×" -> "*"
            "÷" -> "/"
            "−" -> "-"
            op -> op
          end

        lex(after_token(text, op), names, [{:op, token} | acc])

      match = Regex.run(~r/\A[a-z_]+/, text) ->
        [word] = match

        token =
          cond do
            word in @functions -> {:fun, word}
            word in ["and", "or", "when"] -> {:op, word}
            word == "then" -> {:op, ":"}
            word in ["rises", "rise", "increases", "increase"] -> {:op, "rises"}
            true -> throw(:error)
          end

        lex(after_token(text, word), names, [token | acc])

      true ->
        :error
    end
  end

  # The ways a rule may write each field's name, longest first: as it is,
  # with its spaces written as "_" or "." or left out ("Stat.Point"), and
  # by its first word when no other field begins with it ("Inventory" for
  # "Inventory Load").
  defp spellings(names) do
    exact = Enum.map(names, &{&1, &1})

    joined =
      for name <- names,
          String.contains?(name, " "),
          joint <- ["_", ".", ""],
          spelling = String.replace(name, " ", joint),
          spelling not in names,
          do: {spelling, name}

    firsts =
      for name <- names,
          [first, _rest] <- [String.split(name, " ", parts: 2)],
          first not in names,
          Enum.count(names, &String.starts_with?(&1, first <> " ")) == 1,
          do: {first, name}

    (exact ++ joined ++ firsts)
    |> Enum.uniq_by(fn {spelling, _name} -> spelling end)
    |> Enum.sort_by(fn {spelling, _name} -> -String.length(spelling) end)
  end

  defp after_token(text, token),
    do: binary_part(text, byte_size(token), byte_size(text) - byte_size(token))

  # The text begins with this field's name, and the name ends there.
  defp named?(text, name) do
    String.starts_with?(text, name) and
      not String.match?(
        binary_part(text, byte_size(name), byte_size(text) - byte_size(name)),
        ~r/\A[\p{L}\p{N}_]/u
      )
  end

  # -- grammar

  defp rule([{:op, "when"}, {:field, name, :now}, {:op, "rises"}, {:op, ":"} | tokens]) do
    case changes(tokens, []) do
      [] -> :error
      changes -> {:ok, {:rise, name, changes}}
    end
  end

  defp rule([{:op, "when"} | tokens]) do
    {condition, rest} = expression(tokens)

    case rest do
      [{:op, ":"} | rest] ->
        changes = changes(rest, [])
        watched = mentioned(condition)

        # A rule that leaves what it looks at alone would hold forever.
        if Enum.any?(changes, fn {_kind, {name, _part}, _expr} -> name in watched end),
          do: {:ok, {:when, condition, changes}},
          else: :error

      _other ->
        :error
    end
  end

  defp rule([{:field, name, part}, {:op, "="} | tokens]) when part != :before do
    case expression(tokens) do
      {expr, []} -> {:ok, {:always, {name, part}, expr}}
      _more -> :error
    end
  end

  defp rule(_tokens), do: :error

  defp changes([], acc), do: Enum.reverse(acc)
  defp changes([{:op, ";"} | rest], acc), do: changes(rest, acc)

  defp changes([{:field, name, part}, {:op, op} | tokens], acc)
       when op in ["=", "+=", "-="] and part != :before do
    {expr, rest} = expression(tokens)

    kind =
      case op do
        "=" -> :set
        "+=" -> :add
        "-=" -> :sub
      end

    case rest do
      [] -> Enum.reverse([{kind, {name, part}, expr} | acc])
      [{:op, ";"} | rest] -> changes(rest, [{kind, {name, part}, expr} | acc])
      _other -> throw(:error)
    end
  end

  defp changes(_tokens, _acc), do: throw(:error)

  defp expression(tokens), do: binary(tokens, 0)

  # Binary operators by how tightly they bind; "^" binds to the right.
  @levels [
    ["or"],
    ["and"],
    [">=", "<=", "==", "!=", ">", "<", "="],
    ["+", "-"],
    ["*", "/", "%"],
    ["^"]
  ]

  defp binary(tokens, level) when level >= length(@levels), do: unary(tokens)

  defp binary(tokens, level) do
    {left, rest} = binary(tokens, level + 1)
    more(left, rest, level)
  end

  defp more(left, [{:op, op} | rest] = tokens, level) do
    cond do
      op not in Enum.at(@levels, level) ->
        {left, tokens}

      op == "^" ->
        {right, rest} = binary(rest, level)
        {{:op, :pow, left, right}, rest}

      true ->
        {right, rest} = binary(rest, level + 1)
        more({:op, operator(op), left, right}, rest, level)
    end
  end

  defp more(left, tokens, _level), do: {left, tokens}

  defp operator("or"), do: :or
  defp operator("and"), do: :and
  defp operator(">="), do: :gte
  defp operator("<="), do: :lte
  defp operator("=="), do: :eq
  defp operator("="), do: :eq
  defp operator("!="), do: :neq
  defp operator(">"), do: :gt
  defp operator("<"), do: :lt
  defp operator("+"), do: :plus
  defp operator("-"), do: :minus
  defp operator("*"), do: :times
  defp operator("/"), do: :over
  defp operator("%"), do: :rem

  defp unary([{:op, "-"} | rest]) do
    {expr, rest} = unary(rest)
    {{:neg, expr}, rest}
  end

  defp unary([{:op, "+"} | rest]), do: unary(rest)
  defp unary([{:num, n} | rest]), do: {{:num, n}, rest}
  defp unary([{:field, name, part} | rest]), do: {{:field, name, part}, rest}

  defp unary([{:op, "("} | rest]) do
    case expression(rest) do
      {expr, [{:op, ")"} | rest]} -> {expr, rest}
      _unclosed -> throw(:error)
    end
  end

  defp unary([{:fun, name}, {:op, "("} | rest]) do
    {args, rest} = arguments(rest, [])
    {{:call, name, args}, rest}
  end

  defp unary(_tokens), do: throw(:error)

  defp arguments(tokens, acc) do
    case expression(tokens) do
      {expr, [{:op, ","} | rest]} -> arguments(rest, [expr | acc])
      {expr, [{:op, ")"} | rest]} -> {Enum.reverse([expr | acc]), rest}
      _other -> throw(:error)
    end
  end

  # -- working them out

  @doc """
  The window's numbers with the rules worked out: what always holds, then
  whatever happens, until nothing more does. `before` is the numbers as
  they stood before this turn's changes (for `when Field rises`; without
  it nothing has risen). Rules that would not stop are left undone.
  """
  @spec run(values(), [rule()], values() | nil) :: values()
  def run(values, rules, before \\ nil) do
    counted =
      for {:rise, name, _changes} <- rules, into: %{} do
        {name, (before || values) |> Map.get(name, %{now: nil}) |> Map.fetch!(:now)}
      end

    # Each field with what it was before this turn, for `Field.before`.
    with_before =
      Map.new(values, fn {name, value} ->
        {name, Map.put(value, :was, before && get_in(before, [name, :now]))}
      end)

    case run(with_before, rules, counted, %{}) do
      {:ok, values} -> Map.new(values, fn {name, value} -> {name, Map.delete(value, :was)} end)
      # A rule that does not stop is no rule: the rest are worked out without it.
      {:runaway, rule} -> run(values, List.delete(rules, rule), before)
    end
  end

  defp run(values, rules, counted, fired) do
    values = settle(values, rules)

    risen =
      Enum.find(rules, fn
        {:rise, name, _changes} ->
          is_number(counted[name]) and is_map(values[name]) and values[name].now > counted[name]

        _other ->
          false
      end)

    happening =
      risen ||
        Enum.find(rules, fn
          {:when, condition, _changes} -> truthy?(value(condition, values))
          _other -> false
        end)

    fired = if happening, do: Map.update(fired, happening, 1, &(&1 + 1)), else: fired

    case happening do
      nil ->
        {:ok, values}

      rule when :erlang.map_get(rule, fired) > @max_firings ->
        {:runaway, rule}

      # One point of the rise at a time, the changes seeing that point.
      {:rise, name, changes} ->
        step = counted[name] + 1
        real = values[name].now
        stepped = fire(put_in(values[name].now, step), changes)
        next = if stepped[name].now == step, do: put_in(stepped[name].now, real), else: stepped
        run(next, rules, Map.put(counted, name, step), fired)

      {:when, _condition, changes} = rule ->
        case fire(values, changes) do
          # Nothing moved though the condition holds: it never will.
          ^values -> {:runaway, rule}
          next -> run(next, rules, counted, fired)
        end
    end
  end

  # What always holds, each rule seeing the ones before it.
  defp settle(values, rules) do
    Enum.reduce(rules, values, fn
      {:always, target, expr}, values -> put(values, target, value(expr, values))
      _when, values -> values
    end)
  end

  defp fire(values, changes) do
    Enum.reduce(changes, values, fn {kind, {name, part} = target, expr}, values ->
      case {value(expr, values), value({:field, name, part}, values)} do
        {:none, _was} -> values
        {_n, :none} -> values
        {n, _was} when kind == :set -> put(values, target, n)
        {n, was} when kind == :add -> put(values, target, was + n)
        {n, was} when kind == :sub -> put(values, target, was - n)
      end
    end)
  end

  defp put(values, _target, :none), do: values

  defp put(values, {name, part}, n) do
    n = whole(n)

    case {Map.get(values, name), part} do
      {nil, _part} ->
        values

      {field, :now} ->
        Map.put(values, name, %{field | now: n})

      {%{max: nil}, :max} ->
        values

      # A pair that was full stays full when its maximum moves.
      {%{now: now, max: max} = field, :max} ->
        Map.put(values, name, %{field | max: n, now: if(now == max, do: n, else: now)})
    end
  end

  # A number as a field holds it: whole, cut toward zero (and a float that
  # fell just short of a whole number, such as 100 × 1.15, is that number).
  defp whole(n) when is_integer(n), do: n
  defp whole(n) when n >= 0, do: trunc(Float.floor(n + 1.0e-9))
  defp whole(n), do: trunc(Float.ceil(n - 1.0e-9))

  defp truthy?(:none), do: false
  defp truthy?(n), do: n != 0

  # An expression's value, or `:none` when it cannot be worked out (a field
  # the window lacks, a pair that is none, a division by zero).
  defp value(expr, values) do
    eval(expr, values)
  catch
    :none -> :none
  end

  defp eval({:num, n}, _values), do: n

  defp eval({:field, name, part}, values) do
    case {Map.get(values, name), part} do
      {%{now: now}, :now} -> now
      {%{max: max}, :max} when is_number(max) -> max
      {%{was: was}, :before} when is_number(was) -> was
      _missing -> throw(:none)
    end
  end

  defp eval({:neg, expr}, values), do: -eval(expr, values)

  defp eval({:op, :and, a, b}, values),
    do: flag(eval(a, values) != 0 and eval(b, values) != 0)

  defp eval({:op, :or, a, b}, values),
    do: flag(eval(a, values) != 0 or eval(b, values) != 0)

  defp eval({:op, op, a, b}, values) do
    {a, b} = {eval(a, values), eval(b, values)}

    case op do
      :plus -> a + b
      :minus -> a - b
      :times -> a * b
      :over -> if b == 0, do: throw(:none), else: a / b
      :rem -> if whole(b) == 0, do: throw(:none), else: rem(whole(a), whole(b))
      :pow -> power(a, b)
      :gte -> flag(a >= b)
      :lte -> flag(a <= b)
      :gt -> flag(a > b)
      :lt -> flag(a < b)
      :eq -> flag(a == b)
      :neq -> flag(a != b)
    end
  end

  defp eval({:call, name, args}, values) do
    case {name, Enum.map(args, &eval(&1, values))} do
      {"floor", [x]} -> whole_down(x)
      {"ceil", [x]} -> whole_up(x)
      {"round", [x]} -> round(x)
      {"abs", [x]} -> abs(x)
      {"min", [_one | _more] = xs} -> Enum.min(xs)
      {"max", [_one | _more] = xs} -> Enum.max(xs)
      {"clamp", [x, low, high]} -> x |> max(low) |> min(high)
      {"if", [condition, a, b]} -> if condition != 0, do: a, else: b
      _other -> throw(:none)
    end
  end

  defp power(a, b) do
    :math.pow(a, b)
  rescue
    ArithmeticError -> throw(:none)
  end

  defp flag(true), do: 1
  defp flag(false), do: 0

  defp whole_down(x) when is_integer(x), do: x
  defp whole_down(x), do: trunc(Float.floor(x + 1.0e-9))
  defp whole_up(x) when is_integer(x), do: x
  defp whole_up(x), do: trunc(Float.ceil(x - 1.0e-9))

  @doc """
  The fields a rule works out when something happens (`when ...: Level +=
  1`) and that are not what makes it happen: the model does not raise
  those itself.
  """
  @spec raised([rule()]) :: [String.t()]
  def raised(rules) do
    for rule <- rules,
        {watched, changes} <-
          (case rule do
             {:when, condition, changes} -> [{mentioned(condition), changes}]
             {:rise, name, changes} -> [{[name], changes}]
             _always -> []
           end),
        {:add, {name, :now}, _expr} <- changes,
        name not in watched,
        uniq: true,
        do: name
  end

  @doc """
  The pairs a rule watches for passing their maximum (`when EXP >=
  EXP.max`): a change may put those past it, for the rule to take up.
  """
  @spec watched([rule()]) :: [String.t()]
  def watched(rules) do
    for {:when, condition, _changes} <- rules,
        name <- mentioned(condition),
        uniq: true,
        do: name
  end

  defp mentioned({:field, name, _part}), do: [name]
  defp mentioned({:neg, expr}), do: mentioned(expr)
  defp mentioned({:op, _op, a, b}), do: mentioned(a) ++ mentioned(b)
  defp mentioned({:call, _name, args}), do: Enum.flat_map(args, &mentioned/1)
  defp mentioned(_number), do: []
end
