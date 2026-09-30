defmodule Aethrion.Tuning do
  @moduledoc """
  Rule parameters as data.

  Every rule declares its numbers (`use Aethrion.Rule, params: [...]`). A world
  can override any of them in `state.tuning`, so two worlds can run the same
  rules with a different temperament (a gossipy village, a reserved office)
  without code:

      state = Aethrion.Tuning.put(state, :autonomy, :trust_threshold, 15)

  In JSON (persistence and scenarios) tuning is a map of rule id to parameter
  overrides:

      "tuning": {"autonomy": {"trust_threshold": 15}, "proactive": {"cooldown_hours": 8}}

  Only parameters a known rule declares are accepted, so untrusted JSON cannot
  create atoms or invent parameters.
  """

  alias Aethrion.{Pipeline, State}

  @type t :: %{optional(atom()) => %{optional(atom()) => integer()}}

  @doc """
  The value of `key` for `rule` (a module) in `state`: the override if present,
  otherwise the rule's default.
  """
  def get(%State{tuning: tuning}, rule, key) when is_atom(rule) do
    defaults = rule.params()
    rule_id = rule.id()

    unless Keyword.has_key?(defaults, key) do
      raise ArgumentError, "#{inspect(rule)} does not declare parameter #{inspect(key)}"
    end

    case tuning do
      %{^rule_id => %{^key => value}} -> value
      _ -> Keyword.fetch!(defaults, key)
    end
  end

  @doc """
  Overrides a parameter. `rule` may be a rule id or module from the default
  pipeline, or any rule module.
  """
  def put(%State{} = state, rule, key, value) when is_integer(value) do
    module = resolve(rule)

    unless module && Keyword.has_key?(module.params(), key) do
      raise ArgumentError, "unknown rule parameter #{inspect(rule)}.#{inspect(key)}"
    end

    tuning = Map.update(state.tuning, module.id(), %{key => value}, &Map.put(&1, key, value))
    %{state | tuning: tuning}
  end

  @doc """
  All rule parameters in `pipeline`, as `[{rule_id, [{key, default, current}]}]`.
  """
  def describe(%State{} = state, pipeline \\ Pipeline.default()) do
    pipeline
    |> rules()
    |> Enum.filter(&(&1.params() != []))
    |> Enum.map(fn rule ->
      {rule.id(),
       Enum.map(rule.params(), fn {key, default} -> {key, default, get(state, rule, key)} end)}
    end)
  end

  @doc false
  def to_data(tuning) do
    Map.new(tuning, fn {rule_id, params} ->
      {Atom.to_string(rule_id),
       Map.new(params, fn {key, value} -> {Atom.to_string(key), value} end)}
    end)
  end

  @doc """
  Parses JSON-style tuning (`%{"rule" => %{"param" => integer}}`) against the
  rules in `pipeline`. Returns `{:ok, tuning}` or `{:error, reason}`.
  """
  def from_data(data, pipeline \\ Pipeline.default())

  def from_data(nil, _pipeline), do: {:ok, %{}}

  def from_data(data, pipeline) when is_map(data) do
    known = Map.new(rules(pipeline), &{Atom.to_string(&1.id()), &1})

    Enum.reduce_while(data, {:ok, %{}}, fn {rule_name, params}, {:ok, acc} ->
      with {:ok, rule} <- fetch_rule(known, rule_name),
           {:ok, parsed} <- parse_params(rule, params) do
        {:cont, {:ok, Map.put(acc, rule.id(), parsed)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def from_data(other, _pipeline), do: {:error, {:invalid_tuning, other}}

  defp fetch_rule(known, name) do
    case Map.fetch(known, name) do
      {:ok, rule} -> {:ok, rule}
      :error -> {:error, {:unknown_rule, name}}
    end
  end

  defp parse_params(rule, params) when is_map(params) do
    declared = Map.new(rule.params(), fn {key, _default} -> {Atom.to_string(key), key} end)

    Enum.reduce_while(params, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case {Map.fetch(declared, name), value} do
        {{:ok, key}, value} when is_integer(value) -> {:cont, {:ok, Map.put(acc, key, value)}}
        {{:ok, _key}, value} -> {:halt, {:error, {:invalid_value, "#{rule.id()}.#{name}", value}}}
        {:error, _value} -> {:halt, {:error, {:unknown_parameter, "#{rule.id()}.#{name}"}}}
      end
    end)
  end

  defp parse_params(rule, params), do: {:error, {:invalid_params, rule.id(), params}}

  defp rules(%Pipeline{} = pipeline) do
    pipeline.event_rules
    |> Map.values()
    |> List.flatten()
    |> Enum.concat(pipeline.reactive_rules)
    |> Enum.uniq()
  end

  defp resolve(rule) when is_atom(rule) do
    cond do
      Code.ensure_loaded?(rule) and function_exported?(rule, :params, 0) -> rule
      true -> Enum.find(rules(Pipeline.default()), &(&1.id() == rule))
    end
  end
end
