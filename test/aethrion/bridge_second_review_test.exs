defmodule Aethrion.BridgeSecondReviewTest do
  # Regressions from a second review of the chat-app bridge.
  use ExUnit.Case, async: false

  alias Aethrion.{API, Bridge, State, Worlds}
  alias Aethrion.Bridge.Store

  defmodule Narrator do
    @behaviour Aethrion.LLM.Adapter
    @impl true
    def render(_request, _opts), do: {:ok, "..."}
    @impl true
    def complete(_system, _user, _opts), do: {:ok, "(narration)"}
    def chat(_messages, _opts), do: {:ok, "늑대가 으르렁거린다."}
  end

  # A model that times out on its first reading, then reads the line as a
  # guard.
  defmodule Recovering do
    @behaviour Aethrion.Interpreter

    @impl true
    def interpret(request, _opts) do
      if Agent.get_and_update(__MODULE__, &{&1, &1 + 1}) == 0,
        do: {:error, :timeout},
        else: {:ok, [%{as: :combat, confidence: 0.9, event: Aethrion.Event.defend(request.from)}]}
    end
  end

  defp den do
    {:ok, state} = "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  describe "4. what the bridge keeps survives a restart of the VM" do
    @describetag :tmp_dir

    test "readings and checkpoints written by one VM are read by a fresh one", %{tmp_dir: dir} do
      readings = Path.join(dir, "readings.jsonl")
      checkpoints = Path.join(dir, "checkpoints.jsonl")
      start_supervised!({Store, name: Aethrion.Bridge.Readings, path: readings})
      start_supervised!({Store, name: Aethrion.Bridge.Checkpoints, path: checkpoints})

      chat = [
        %{"role" => "user", "content" => "다이어 울프에게 롱소드를 휘두른다"},
        %{"role" => "assistant", "content" => "…"},
        %{"role" => "user", "content" => "세라, 고마워"}
      ]

      read =
        Bridge.reader(
          "sera",
          [interpreter: Aethrion.Interpreter.Rules],
          Store.cache(Aethrion.Bridge.Readings)
        )

      Bridge.replay(den(), chat, read,
        to: "sera",
        checkpoints: Store.cache(Aethrion.Bridge.Checkpoints)
      )

      _ = :sys.get_state(Aethrion.Bridge.Readings)
      _ = :sys.get_state(Aethrion.Bridge.Checkpoints)

      kept =
        {:ets.info(Aethrion.Bridge.Readings, :size),
         :ets.info(Aethrion.Bridge.Checkpoints, :size)}

      assert kept == {2, 2}

      # A fresh VM loads modules as they are first used: nothing of the
      # interpreter, the events, or the state is loaded yet.
      script = """
      {:ok, _} = Aethrion.Bridge.Store.start_link(name: Aethrion.Bridge.Readings, path: #{inspect(readings)})
      {:ok, _} = Aethrion.Bridge.Store.start_link(name: Aethrion.Bridge.Checkpoints, path: #{inspect(checkpoints)})
      IO.puts(:ets.info(Aethrion.Bridge.Readings, :size))
      IO.puts(:ets.info(Aethrion.Bridge.Checkpoints, :size))
      # And they read back: readings as events, checkpoints as worlds.
      readings = for {_k, v} <- :ets.tab2list(Aethrion.Bridge.Readings), do: Aethrion.Bridge.readings_from_data(v)
      IO.inspect(Enum.map(readings, fn r -> Enum.map(r, & &1.event.type) end) |> Enum.sort())
      worlds = for {_k, v} <- :ets.tab2list(Aethrion.Bridge.Checkpoints), do: elem(Aethrion.State.parse(v["state"]), 0)
      IO.inspect(worlds)
      """

      paths = Enum.flat_map(Path.wildcard("_build/test/lib/*/ebin"), &["-pa", &1])
      {out, 0} = System.cmd("elixir", paths ++ ["-e", script], stderr_to_stdout: true)
      assert out == "2\n2\n[[:attack], [:message_sent]]\n[:ok, :ok]\n"
    end
  end

  describe "5. a turn that was answered stays as it was" do
    setup do
      start_supervised!(%{
        id: Recovering,
        start: {Agent, :start_link, [fn -> 0 end, [name: Recovering]]}
      })

      start_supervised!({Store, name: Aethrion.Bridge.Readings})
      start_supervised!({Store, name: Aethrion.Bridge.Checkpoints})
      start_supervised!({Worlds, name: Worlds.Test.SecondReview, world: fn _key -> [] end})

      pid =
        start_supervised!(
          {API,
           worlds: Worlds.Test.SecondReview,
           port: 0,
           locale: :ko,
           cast: den(),
           intent: [adapter: Narrator],
           interpreter: Recovering}
        )

      %{base: "http://127.0.0.1:#{API.port(pid)}"}
    end

    defp reply(base, messages) do
      {:ok, {{_v, 200, _r}, _h, body}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json",
           Jason.encode!(%{"model" => "aethrion:sera", "messages" => messages})},
          [],
          body_format: :binary
        )

      %{"choices" => [%{"message" => %{"content" => content}}]} = Jason.decode!(body)
      [block] = Regex.run(~r/<aethrion-status[^>]*>.*<\/aethrion-status>/s, content)
      block
    end

    test "a reroll after the model recovered gets the same world and checkpoint", %{base: base} do
      line = [%{"role" => "user", "content" => "기회를 노리며 자세를 낮춘다"}]
      # The model timed out: the rules read it, and the reply went out.
      first = reply(base, line)
      # The same request again: the model would read it differently now.
      assert reply(base, line) == first
    end
  end
end
