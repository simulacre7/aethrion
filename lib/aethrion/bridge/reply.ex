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

  A turn's changes are settled by its first answer. They are kept under
  the turn's id (in the store the turn's readings are kept in), and a
  reroll of the turn is told them as facts and gets the same window: the
  story may differ, the numbers do not.

  `plan/3` settles what a turn needs before the model is asked: the window
  as it stood, what the note says about it, and the changes when the turn
  was answered before. `finish/3` makes the reply.
  """

  require Logger

  alias Aethrion.Bridge.{Ledger, Scene}

  @typedoc """
  What is done with a reply: the window as it stood (`ledger`, nil before a
  reply has shown one), the card's window (`spec`, nil for a card that has
  none), the language of the record, and the name the card gives the player.
  """
  @type plan :: %{
          required(:ledger) => String.t() | nil,
          required(:spec) => Ledger.spec() | nil,
          required(:locale) => :ko | :en,
          required(:player) => String.t() | nil,
          optional(:settled) => [{String.t(), String.t()}] | nil,
          optional(:keep) => ([{String.t(), String.t()}] -> any())
        }

  @doc """
  The plan for a turn of a card read as `auto` (its `window` and `player`):
  the window as it stood in `chat`, once a reply has shown one. A request
  to continue a reply (`line?` false) leaves the window alone.
  """
  @spec plan(map(), [map()], map()) :: plan()
  def plan(auto, chat, %{line?: line?, locale: locale} = turn) do
    spec = auto[:window]
    ledger = if spec && line?, do: Ledger.current(chat, spec)
    key = if ledger && is_binary(turn[:id]) && turn[:store], do: "ledger:" <> turn.id

    %{
      ledger: ledger,
      spec: spec,
      locale: locale,
      player: auto[:player],
      # What this turn changed when it was first answered, if it was.
      settled: key && settled(turn.store.get.(key)),
      keep:
        if(key, do: &turn.store.put.(key, %{"changes" => Enum.map(&1, fn {n, v} -> [n, v] end)}))
    }
  end

  defp settled(%{"changes" => changes}) when is_list(changes) do
    for [name, value] <- changes, is_binary(name), is_binary(value), do: {name, value}
  end

  defp settled(_none), do: nil

  @doc """
  What the note asks of the model about the window (`Ledger.instruction/3`),
  or nil while the window is still the model's to print. `messages` are the
  request's, for what the ledger did last turn.
  """
  @spec instruction(plan() | nil, [map()]) :: String.t() | nil
  def instruction(%{ledger: ledger, settled: settled}, _messages)
      when is_binary(ledger) and is_list(settled),
      do: Ledger.settled_instruction(settled)

  def instruction(%{ledger: ledger, spec: spec}, messages) when is_binary(ledger),
    do: Ledger.instruction(ledger, spec, Ledger.recorded(messages))

  def instruction(_plan, _messages), do: nil

  @doc """
  The reply as the player gets it, and the status block: `{text, status}`.
  Without a plan (a cast of the server's own) the reply is only trimmed.
  """
  @spec finish(String.t(), String.t() | nil, plan() | nil) :: {String.t(), String.t() | nil}
  def finish(text, status, nil), do: {String.trim(text), status}

  def finish(text, status, %{locale: locale} = plan) do
    {text, scene} = Scene.take(text, plan[:player])
    {text, changes} = Ledger.take(text)
    {text, lines} = window(text, changes, plan)

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

  defp window(text, changes, %{ledger: window, spec: spec, locale: locale} = plan) do
    # A window the model printed anyway is taken out; without ledger
    # lines, what it changed stands in for them.
    {text, printed} =
      case Ledger.window(text, spec) do
        {head, printed, tail} -> {head <> tail, printed}
        nil -> {text, nil}
      end

    {changes, source} =
      case plan[:settled] do
        nil -> changes(changes, printed, window, spec)
        settled -> {settled, "the turn's first answer"}
      end

    # The first answer's changes stand for every later answer to the turn.
    if plan[:settled] == nil and is_function(plan[:keep], 1), do: plan.keep.(changes)

    {kept, applied, refused} = Ledger.apply(window, changes, spec)
    {kept, ruled} = Ledger.settle(kept, spec, window)

    Logger.info(
      "Aethrion ledger: #{length(applied)} changed, #{length(refused)} refused, " <>
        "#{length(ruled)} by rule, from #{source}"
    )

    {String.trim(text) <> "\n\n" <> kept,
     Ledger.log(applied, refused, locale) ++ Ledger.rule_log(ruled, locale)}
  end

  # The changes to apply, and where they came from (for the log).
  defp changes(changes, printed, _window, _spec) when is_list(changes) do
    {changes,
     "the model's ledger lines" <> if(printed, do: " (it printed a window too)", else: "")}
  end

  defp changes(nil, nil, _window, _spec), do: {[], "nothing from the model"}

  defp changes(nil, printed, window, spec),
    do: {Ledger.differences(window, printed, spec), "a window the model printed"}

  @doc """
  The filter for a reply as it is streamed (`Ledger.filter/2`): the model's
  lines for the rules are held back, and so is a window the ledger keeps.
  Without a plan everything is passed on.
  """
  @spec filter((String.t() -> any()), plan() | nil) :: (String.t() -> any())
  def filter(emit, nil), do: emit

  def filter(emit, %{ledger: ledger, spec: spec}) do
    {on_delta, _flush} = Ledger.filter(emit, if(ledger, do: spec.open))
    on_delta
  end

  @doc """
  The end of a finished reply that has not gone out yet, given what was
  streamed (`gone`): what the filter held back, as the rules left it. The
  blank lines that went out after the head are not sent again.
  """
  @spec unsent(String.t(), String.t()) :: String.t()
  def unsent(text, gone) do
    head = String.trim_trailing(gone)

    if String.starts_with?(text, head) do
      rest = binary_part(text, byte_size(head), byte_size(text) - byte_size(head))
      space = binary_part(gone, byte_size(head), byte_size(gone) - byte_size(head))

      cond do
        space == "" -> rest
        String.starts_with?(rest, space) -> String.replace_prefix(rest, space, "")
        true -> String.trim_leading(rest)
      end
    else
      ""
    end
  end
end
