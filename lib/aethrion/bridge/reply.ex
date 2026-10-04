defmodule Aethrion.Bridge.Reply do
  @moduledoc """
  The narrating model's reply as the player gets it, for a cast read from a
  card (`Aethrion.Bridge.AutoCast`).

  Such a reply ends with lines the model writes for the rules, not for the
  player: who is with the player (`Aethrion.Bridge.Scene`), and what the
  card's status window changed (`Aethrion.Bridge.Ledger`). They are taken
  out; the scene goes into the status block's tag, and the window is
  written by the ledger from the changes, with the card's arithmetic worked
  out and what the ledger did added to this turn's rulings.

  What a turn does to the window is settled by its first answer. The
  fields it left changed are kept under the turn's id and the story before
  it (in the store the turn's readings are kept in), and a reroll of the
  turn is told the record as facts and gets the same window: the story may
  differ, the numbers do not.

  `plan/3` settles what a turn needs before the model is asked: the window
  as it stood, what the note says about it, and the changes when the turn
  was answered before. `finish/3` makes the reply.
  """

  require Logger

  alias Aethrion.Bridge.{Ledger, Scene}

  @typedoc """
  What is done with a reply: the window as it stood (`ledger`, nil before a
  reply has shown one), the card's window (`spec`, nil for a card that has
  none), whether the turn has a new line of the player's (`line?`; a
  request to continue a reply has none), the language of the record, the
  name the card gives the player, what the turn's first answer settled
  (`settled`), and how to keep that (`keep`).
  """
  @type plan :: %{
          required(:ledger) => String.t() | nil,
          required(:spec) => Ledger.spec() | nil,
          required(:locale) => :ko | :en,
          required(:player) => String.t() | nil,
          optional(:line?) => boolean(),
          optional(:first?) => boolean(),
          optional(:settled) => settled() | nil,
          optional(:keep) => (settled() -> any())
        }

  @typedoc """
  What a turn's first answer settled: the fields it left changed, with
  their values after the rules, and the record's lines.
  """
  @type settled :: %{fields: [{String.t(), String.t()}], lines: [String.t()]}

  @doc """
  The plan for a turn of a card read as `auto` (its `window` and `player`):
  the window as it stood in `chat`, once a reply has shown one, and what
  the turn settled if it was answered before. `turn` has `line?`, `locale`,
  and, for keeping what is settled, the turn's `id` and the `store`.
  """
  @spec plan(map(), [map()], map()) :: plan()
  def plan(auto, chat, %{line?: line?, locale: locale} = turn) do
    spec = auto[:window]
    found = if spec, do: Ledger.current(chat, spec)
    # A window that is mostly prose stays the model's to write.
    ledger = if found && Ledger.keeps?(found, spec), do: found
    key = if ledger && line? && is_binary(turn[:id]) && turn[:store], do: key(turn.id, chat)

    %{
      ledger: ledger,
      spec: spec,
      locale: locale,
      player: auto[:player],
      line?: line?,
      first?: spec != nil and found == nil,
      settled: key && settled(turn.store.get.(key)),
      keep: if(key, do: &turn.store.put.(key, kept(&1)))
    }
  end

  # A turn is the same turn when the line is the same and the story before
  # it is: a turn after a reply that was rerolled is another turn.
  defp key(id, chat) do
    told =
      chat
      |> Enum.reverse()
      |> Enum.find_value("", fn
        %{"role" => "assistant", "content" => content} -> content
        _other -> nil
      end)

    digest = :crypto.hash(:sha256, told) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "ledger:" <> id <> ":" <> digest
  end

  defp kept(%{fields: fields, lines: lines}),
    do: %{"fields" => Enum.map(fields, fn {name, value} -> [name, value] end), "lines" => lines}

  defp settled(%{"fields" => fields, "lines" => lines}) when is_list(fields) and is_list(lines) do
    %{
      fields: for([name, value] <- fields, is_binary(name), is_binary(value), do: {name, value}),
      lines: Enum.filter(lines, &is_binary/1)
    }
  end

  defp settled(_none), do: nil

  @doc """
  What the note asks of the model about the window (`Ledger.instruction/3`),
  or nil while the window is still the model's to print. `messages` are the
  request's, for what the ledger did last turn.
  """
  @spec instruction(plan() | nil, [map()]) :: String.t() | nil
  def instruction(%{ledger: ledger, line?: false}, _messages) when is_binary(ledger),
    do: Ledger.continued_instruction()

  def instruction(%{ledger: ledger, settled: %{} = settled}, _messages) when is_binary(ledger),
    do: Ledger.settled_instruction(settled.lines, settled.fields)

  def instruction(%{ledger: ledger, spec: spec}, messages) when is_binary(ledger),
    do: Ledger.instruction(ledger, spec, Ledger.recorded(messages))

  # No window in the chat yet: the first one is the model's to print, and
  # a small model leaves it out of its first reply one time in eight.
  def instruction(%{ledger: nil, first?: true, spec: %{open: open}} = plan, _messages)
      when is_binary(open) and open != "" do
    if plan[:line?] != false, do: Ledger.first_instruction()
  end

  def instruction(_plan, _messages), do: nil

  @doc """
  The reply as the player gets it, and the status block: `{text, status}`.
  Without a plan (a cast of the server's own) the reply is only trimmed.
  """
  @spec finish(String.t(), String.t() | nil, plan() | nil) :: {String.t(), String.t() | nil}
  def finish(text, status, nil), do: {String.trim(text), status}

  def finish(text, status, %{locale: locale} = plan) do
    {text, scene} = text |> String.replace("\r\n", "\n") |> Scene.take(plan[:player])
    {text, changes, cut_off?} = Ledger.taken(text)
    {text, lines} = window(text, changes, Map.put(plan, :whole?, not cut_off?))

    status = status && status |> Scene.mark(scene) |> Ledger.note(lines, title(locale))
    {text, status}
  end

  defp title(:ko), do: "이번 턴 판정"
  defp title(_en), do: "This turn"

  # The reply with its window as the rules keep it, and the record's lines.
  defp window(text, _changes, %{spec: nil}), do: {String.trim(text), []}

  # The first window is the model's to print; the card's arithmetic is
  # worked out on it all the same.
  defp window(text, _changes, %{ledger: nil, spec: spec, locale: locale}) do
    case Ledger.window(text, spec) do
      {head, printed, tail} ->
        {settled, ruled} = Ledger.settle(printed, spec)
        {String.trim(head <> settled <> tail), Ledger.rule_log(ruled, locale)}

      nil ->
        {String.trim(text), []}
    end
  end

  # A reply continued: the window stands in the part before, and nothing
  # the continuation prints takes its place.
  defp window(text, _changes, %{line?: false, spec: spec}) do
    {text, _printed} = without_window(text, spec)
    {String.trim(text), []}
  end

  # A turn answered before: the window and the record it came to then.
  defp window(text, _changes, %{ledger: window, spec: spec, settled: %{} = settled}) do
    {text, _printed} = without_window(text, spec)
    Logger.info("Aethrion ledger: as the turn's first answer settled it")
    {String.trim(text) <> "\n\n" <> Ledger.put(window, settled.fields, spec), settled.lines}
  end

  defp window(text, changes, %{ledger: window, spec: spec, locale: locale} = plan) do
    # A window the model printed anyway is taken out; without ledger
    # lines, what it changed stands in for them.
    {text, printed} = without_window(text, spec)
    text = Ledger.unmarked(text, spec)
    Logger.debug("Aethrion ledger lines: #{inspect(changes)}")
    {changes, source} = changes(changes, printed, window, spec)
    {kept, applied, refused} = Ledger.apply(window, changes, spec)
    {kept, ruled} = Ledger.settle(kept, spec, window)
    refused = Ledger.unanswered(refused, window, kept, spec)
    # What the story spent and the lines left out: asked about, not changed.
    refused =
      refused ++
        if(source == "nothing from the model",
          do: [],
          else: Ledger.unsaid(text, window, changes, spec)
        )

    {shown, by_rule} = Ledger.net(applied, ruled)
    lines = Ledger.log(shown, refused, locale) ++ Ledger.rule_log(by_rule, locale)

    Logger.info(
      "Aethrion ledger: #{length(applied)} changed, #{length(refused)} refused, " <>
        "#{length(ruled)} by rule, from #{source}"
    )

    # What this answer came to stands for every later answer to the turn.
    # An answer that said nothing of the window (no lines, no window), or
    # whose lines were cut off, has settled nothing: a reroll may say.
    said? = source != "nothing from the model" and plan[:whole?] != false

    if said? and is_function(plan[:keep], 1),
      do: plan.keep.(%{fields: Ledger.differences(window, kept, spec), lines: lines})

    {String.trim(text) <> "\n\n" <> kept, lines}
  end

  defp without_window(text, spec) do
    case Ledger.window(text, spec) do
      {head, printed, tail} -> {head <> tail, printed}
      nil -> {text, nil}
    end
  end

  # The changes to apply, and where they came from (for the log).
  defp changes(changes, printed, _window, _spec) when is_list(changes) do
    {changes,
     "the model's ledger lines" <> if(printed, do: " (it printed a window too)", else: "")}
  end

  defp changes(nil, nil, _window, _spec), do: {[], "nothing from the model"}

  # A window printed where changes were asked for says what each field is
  # now: its values are taken outright.
  defp changes(nil, printed, window, spec) do
    {for({name, value} <- Ledger.differences(window, printed, spec), do: {name, "=" <> value}),
     "a window the model printed"}
  end

  @doc """
  The filter for a reply as it is streamed (`Ledger.filter/2`): the model's
  lines for the rules are held back, and so is the card's window, which
  the finished reply ends with as the rules leave it. Without a plan
  everything is passed on.
  """
  @spec filter((String.t() -> any()), plan() | nil) :: (String.t() -> any())
  def filter(emit, nil), do: emit

  def filter(emit, %{spec: spec}) do
    {on_delta, _flush} = Ledger.filter(emit, spec && spec.open)
    on_delta
  end

  @doc """
  The end of a finished reply that has not gone out yet, given what was
  streamed (`gone`): what the filter held back, as the rules left it. The
  blank lines that went out after the head are not sent again. When what
  went out is not how the finished reply begins (a window the model
  printed slipped past the filter), the finished reply from where the two
  part is sent after it all the same: the story that was held back, and
  the window as the rules keep it. The last window in a reply is the one
  the next turn goes on from.
  """
  @spec unsent(String.t(), String.t()) :: String.t()
  def unsent(text, gone) do
    # (As the finished reply has its line breaks.)
    gone = String.replace(gone, "\r\n", "\n")
    head = String.trim_trailing(gone)

    if String.starts_with?(text, head) do
      rest = binary_part(text, byte_size(head), byte_size(text) - byte_size(head))
      space = binary_part(gone, byte_size(head), byte_size(gone) - byte_size(head))

      cond do
        space == "" -> rest
        String.starts_with?(rest, space) -> String.replace_prefix(rest, space, "")
        String.contains?(space, "\n") -> String.trim_leading(rest)
        # Only blanks went out after the story's last line: what follows
        # (the window) begins a line of its own.
        String.trim(rest) == "" -> ""
        true -> "\n\n" <> String.trim_leading(rest)
      end
    else
      # From where the two part: the story the filter held, and the window.
      common = :binary.longest_common_prefix([text, head])
      # Not from the middle of a letter.
      common =
        Enum.find(common..max(common - 3, 0)//-1, 0, &String.valid?(binary_part(text, 0, &1)))

      # Back to the blank line before that: a window the model printed and
      # the rules keep otherwise is sent whole, not from its first number
      # that differs (the next turn goes on from the last window it finds).
      common =
        case :binary.matches(binary_part(text, 0, common), "\n\n") do
          [] -> common
          blanks -> blanks |> List.last() |> elem(0)
        end

      rest = binary_part(text, common, byte_size(text) - common)

      case String.trim(rest) do
        "" -> ""
        rest -> "\n\n" <> rest
      end
    end
  end
end
