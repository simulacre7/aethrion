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
  The value of `key` for `rule` (a rule module, or the id of a rule in the
  default pipeline) in `state`: the override if present, otherwise the rule's
  default.
  """
  @spec get(State.t(), module() | atom(), atom()) :: integer()
  def get(%State{tuning: tuning}, rule, key) when is_atom(rule) do
    rule =
      resolve(rule) || raise ArgumentError, "unknown rule #{inspect(rule)}"

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
  @spec put(State.t(), module() | atom(), atom(), integer()) :: State.t()
  def put(%State{} = state, rule, key, value) when is_integer(value) do
    module = resolve(rule)

    cond do
      is_nil(module) ->
        raise ArgumentError,
              "unknown rule #{inspect(rule)}; built-in rules can be named by id, " <>
                "others by their module (Tuning.put(state, MyRule, #{inspect(key)}, value))"

      not Keyword.has_key?(module.params(), key) ->
        raise ArgumentError,
              "#{inspect(module)} has no parameter #{inspect(key)}; " <>
                "it has #{inspect(Keyword.keys(module.params()))}"

      true ->
        :ok
    end

    tuning = Map.update(state.tuning, module.id(), %{key => value}, &Map.put(&1, key, value))
    %{state | tuning: tuning}
  end

  @doc "Every parameter of `rule` (a module), as the world tunes it: `%{key => value}`."
  @spec all(State.t(), module()) :: %{atom() => integer()}
  def all(%State{} = state, rule) when is_atom(rule),
    do: Map.new(rule.params(), fn {key, _default} -> {key, get(state, rule, key)} end)

  @doc """
  All rule parameters, as `[{rule_id, [{key, default, current}]}]`. Options:
  `pipeline:` (default `Aethrion.Pipeline.default/0`).
  """
  @spec describe(State.t(), keyword()) :: [{atom(), [{atom(), integer(), integer()}]}]
  def describe(%State{} = state, opts \\ []) do
    opts
    |> Keyword.get(:pipeline, Pipeline.default())
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
  rules in `pipeline:` (default `Aethrion.Pipeline.default/0`). Returns
  `{:ok, tuning}` or `{:error, %Aethrion.Error{code: :invalid_tuning}}`.
  """
  @spec from_data(term(), keyword()) :: {:ok, t()} | {:error, Aethrion.Error.t()}
  def from_data(data, opts \\ [])

  def from_data(nil, _opts), do: {:ok, %{}}

  def from_data(data, opts) when is_map(data) do
    pipeline = Keyword.get(opts, :pipeline, Pipeline.default())
    known = Map.new(rules(pipeline), &{Atom.to_string(&1.id()), &1})

    Enum.reduce_while(data, {:ok, %{}}, fn {rule_name, params}, {:ok, acc} ->
      with {:ok, rule} <- fetch_rule(known, rule_name),
           {:ok, parsed} <- parse_params(rule, params) do
        {:cont, {:ok, Map.put(acc, rule.id(), parsed)}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def from_data(other, _opts), do: invalid("tuning must be an object", %{tuning: other})

  defp fetch_rule(known, name) do
    case Map.fetch(known, name) do
      {:ok, rule} ->
        {:ok, rule}

      :error ->
        invalid(
          "unknown rule #{inspect(name)}; known rules: #{known |> Map.keys() |> Enum.sort() |> Enum.join(", ")}",
          %{rule: name}
        )
    end
  end

  defp parse_params(rule, params) when is_map(params) do
    declared = Map.new(rule.params(), fn {key, _default} -> {Atom.to_string(key), key} end)

    Enum.reduce_while(params, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case {Map.fetch(declared, name), value} do
        {{:ok, key}, value} when is_integer(value) ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        # 8.0 in JSON means 8.
        {{:ok, key}, value} when is_float(value) and value == trunc(value) ->
          {:cont, {:ok, Map.put(acc, key, trunc(value))}}

        {{:ok, _key}, value} ->
          {:halt,
           invalid("#{rule.id()}.#{name} must be an integer", %{
             rule: rule.id(),
             parameter: name,
             value: value
           })}

        {:error, _value} ->
          {:halt,
           invalid(
             "unknown parameter #{rule.id()}.#{name}; #{rule.id()} has #{declared |> Map.keys() |> Enum.sort() |> Enum.join(", ")}",
             %{rule: rule.id(), parameter: name}
           )}
      end
    end)
  end

  defp parse_params(rule, params),
    do:
      invalid("parameters for #{rule.id()} must be an object", %{rule: rule.id(), value: params})

  defp invalid(message, details),
    do: {:error, Aethrion.Error.new(:invalid_tuning, message, details)}

  defp rules(%Pipeline{} = pipeline) do
    pipeline.event_rules
    |> Map.values()
    |> List.flatten()
    |> Enum.concat(pipeline.reactive_rules)
    |> Enum.uniq()
  end

  defp resolve(rule) when is_atom(rule) do
    if Code.ensure_loaded?(rule) and function_exported?(rule, :params, 0),
      do: rule,
      else: Enum.find(rules(Pipeline.default()), &(&1.id() == rule))
  end
end
