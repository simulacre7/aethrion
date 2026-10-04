defmodule Aethrion.AutoCastTest do
  use ExUnit.Case, async: false

  alias Aethrion.{API, State, Worlds}
  alias Aethrion.Bridge.AutoCast

  @card "Write Sera's next reply. Sera is a quiet healer who travels with Kim. Doyun, a shield-bearer, is with them."
  @greeting "세라: 불이 잘 붙었네요. 오늘은 여기서 쉬어요."

  describe "reading a card" do
    test "takes the people from the model's answer, the main one first" do
      answer = """
      Here you go:
      ```json
      {"title": "Campfire", "characters": [
        {"name": "세라", "profile": "조용한 치유사.", "affinity": 30, "trust": 140},
        {"name": "Doyun", "profile": "A shield-bearer.", "affinity": -5},
        {"name": "세라", "profile": "again"},
        {"name": "  "}
      ]}
      ```
      """

      assert {:ok, %{title: "Campfire", characters: [sera, doyun]} = people} =
               AutoCast.people(answer)

      assert sera["name"] == "세라"
      assert doyun["name"] == "Doyun"

      data = AutoCast.cast_data(people, %{prompt: @card, greeting: @greeting})
      assert {:ok, state} = State.parse(data)

      assert [%{name: "세라", greeting: @greeting}, %{name: "Doyun", greeting: ""}] =
               State.sorted_characters(state)

      # What the card says of the start, kept within 0 to 100.
      assert %{"affinity" => 30, "trust" => 100} = hd(data["relationships"])
      assert %{"affinity" => 0, "trust" => 0} = List.last(data["relationships"])
      # The one who greets is the one the player talks to.
      assert API.default_talker(state) == hd(data["characters"])["id"]
    end

    test "a card with no fixed characters starts with no one" do
      assert {:ok, people} = AutoCast.people(~s({"title": "Isekai RPG", "characters": []}))
      data = AutoCast.cast_data(people, %{prompt: "", greeting: nil})
      assert data == %{"characters" => [], "relationships" => []}
      assert {:ok, state} = State.parse(data)
      assert State.sorted_characters(state) == []
    end

    test "takes the card's status window, and the rules that come with a sentence" do
      answer =
        Jason.encode!(%{
          "characters" => [],
          "status_window" => %{
            "open" => " [Status] ",
            "close" => "[Status]",
            "rules" => [
              %{"from" => "Max HP +10 per point of Vigor.", "rule" => "HP.max = Vigor * 10"},
              %{"rule" => "HP.max = Vigor * 10", "from" => "said twice"},
              "HP.max = Vigor * 12",
              %{"rule" => "", "from" => "nothing"}
            ]
          }
        })

      assert {:ok, %{window: window}} = AutoCast.people(answer)

      assert window == %{
               open: "[Status]",
               close: "[Status]",
               rules: [{"HP.max = Vigor * 10", "Max HP +10 per point of Vigor."}]
             }

      assert {:ok, %{window: nil}} =
               AutoCast.people(~s({"characters": [], "status_window": null}))

      # A marker too long to be one is no window.
      long = String.duplicate("=", 80)

      assert {:ok, %{window: nil}} =
               AutoCast.people(
                 Jason.encode!(%{"characters" => [], "status_window" => %{"open" => long}})
               )
    end

    test "a card with a status window is read again, and the surest reading gives the rules" do
      card = %{
        greeting: nil,
        rules: "",
        prompt:
          "Print the status between [Status] lines.\nVigor: Max HP +10 per point.\n" <>
            "Attunement: Max MP +10 per point.\nA level gives 5 stat points."
      }

      reading = fn open, rules ->
        Jason.encode!(%{
          "characters" => [],
          "status_window" => %{
            "open" => open,
            "close" => "[Status]",
            "rules" => for({from, rule} <- rules, do: %{"from" => from, "rule" => rule})
          }
        })
      end

      hp = {"Vigor: Max HP +10 per point.", "HP.max = Vigor * 10"}
      mp = {"Attunement: Max MP +10 per point.", "MP.max = Attunement * 10"}
      gift = {"A level gives 5 stat points.", "when Level rises: Stat Points += 5"}
      made_up = {"Luck doubles gold.", "Gold = Gold * 2"}

      read = fn answers ->
        {:ok, agent} = Agent.start_link(fn -> answers end)
        casts = %{put: fn _key, _value -> :ok end}

        {:ok, %{window: window}} =
          AutoCast.read(card, casts, Aethrion.AutoCastTest.Readers, answers: agent)

        {window, Agent.get(agent, &length/1)}
      end

      # The rules of the reading the card bears out most, then what the
      # others have besides; the third, of another window, is not this one's.
      levels =
        {"A level gives 5 stat points.",
         "when Level rises: Stat_Points += if(Level % 5 == 0, 5, 5)"}

      assert {%{open: "[Status]", rules: rules}, 0} =
               read.([
                 reading.("[Status]", [hp, made_up, levels]),
                 reading.("[Status]", [mp, gift, {elem(hp, 0), "HP.max = (Vigor * 10)"}]),
                 reading.("[Other]", [hp, mp, gift, hp, mp])
               ])

      # (One rule for what a level gives, and one for the maximum of HP,
      # however they are spelled.)
      assert rules == [
               "MP.max = Attunement * 10",
               "when Level rises: Stat Points += 5",
               "HP.max = (Vigor * 10)"
             ]

      # A reading that fails is no loss, and a card with no window is read once.
      assert {%{rules: ["HP.max = Vigor * 10"]}, 0} =
               read.([reading.("[Status]", [hp]), "not json"])

      # A card with no window is read three times as well: one reading may miss a window.
      none = Jason.encode!(%{"characters" => []})
      assert {nil, 0} = read.([none, none, none])
      assert {%{open: "[Status]"}, 0} = read.([none, reading.("[Status]", [hp]), none])

      # The opening text most readings give, or the shorter one that begins it.
      assert {%{open: "[Day", close: ""}, 0} =
               read.(
                 [
                   reading.("[Day N · Time]", []),
                   reading.("[Day", []),
                   reading.("[Day N · Time]", [])
                 ]
                 |> Enum.map(&String.replace(&1, ~s("close":"[Status]"), ~s("close":"")))
               )

      # A mark alone, from one reading, is not the opening the others give.
      mark = fn open ->
        String.replace(reading.(open, []), ~s("close":"[Status]"), ~s("close":""))
      end

      assert {%{open: "◈Time"}, 0} = read.([mark.("◈Time"), mark.("◈Time"), mark.("◈")])

      # A range said in two rules is two rules; a maximum that is a number is
      # a rule when the card says so; a maximum worked out from other numbers
      # is no bound of its own number.
      stated = %{
        card
        | prompt:
            card.prompt <>
              "\nTrust never goes above 100. Trust never goes below 0.\nThe EXP bar is always out of 100 points.\n" <>
              "Example:\n[Status]\n- HP: 150 / 150\n- Base HP: 20\n- Vigor: 13\n[Status]"
      }

      {:ok, agent} =
        Agent.start_link(fn ->
          List.duplicate(
            reading.("[Status]", [
              {"Trust never goes above 100.", "Trust = min(Trust, 100)"},
              {"Trust never goes below 0.", "Trust = max(Trust, 0)"},
              {"The EXP bar is always out of 100 points.", "EXP.max = 100"},
              {"Base HP plus ten a point.", "HP.max = Base HP + Vigor * 10"},
              {"- Vigor: 13", "Vigor = 13"}
            ]),
            3
          )
        end)

      assert {:ok, %{window: %{rules: kept}}} =
               AutoCast.read(
                 stated,
                 %{put: fn _key, _value -> :ok end},
                 Aethrion.AutoCastTest.Readers,
                 answers: agent
               )

      assert kept == [
               "Trust = min(Trust, 100)",
               "Trust = max(Trust, 0)",
               "EXP.max = 100",
               "HP.max = Base HP + Vigor * 10"
             ]

      # A later reading that exits or throws does not take the caller with it.
      casts = %{put: fn _key, _value -> :ok end}
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      first = reading.("[Status]", [hp])

      assert {:ok, %{window: %{rules: ["HP.max = Vigor * 10"]}}} =
               AutoCast.read(card, casts, Aethrion.AutoCastTest.Exits, calls: calls, first: first)

      # Nor is anything left in the caller's mailbox, whatever the first reading does.
      {:ok, raises} = Agent.start_link(fn -> 0 end)

      assert_raise RuntimeError, fn ->
        AutoCast.read(card, casts, Aethrion.AutoCastTest.Raises,
          calls: raises,
          first: first,
          caller: self()
        )
      end

      Process.sleep(50)
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "several rules written on one line are taken apart; a card's example windows decide" do
      card = %{
        greeting: nil,
        rules: "",
        prompt: """
        Print the status between [Status] lines, like this:
        [Status]
        - Level: 8
        - HP: 121 / 130
        - EXP: 23 / 266
        - Vigor: 13
        [Status]
        Vigor: Max HP +10 per point. 100 × (1.15)^(Level − 1) = Max EXP.
        """
      }

      answer =
        Jason.encode!(%{
          "characters" => [],
          "status_window" => %{
            "open" => "[Status]",
            "close" => "[Status]",
            "rules" => [
              # A sentence that is not the card's, for a rule its example bears out.
              %{"from" => "HP: Health Points.", "rule" => "HP.max = Vigor * 10"},
              # A base the card does not have, which its example says so: the rule without it.
              %{
                "from" => "Vigor: Max HP +10 per point.",
                "rule" => "HP.max = 100 + (Vigor * 10)"
              },
              # Where the example begins is no rule; nor is a bound the card does not state,
              # though the example is within it.
              %{"from" => "- Level: 8", "rule" => "Level = 8"},
              %{"from" => "Level stays low.", "rule" => "Level = clamp(Level, 0, 10)"},
              # The card's sentence, for a rule its example contradicts.
              %{"from" => "Vigor: Max HP +10 per point.", "rule" => "HP.max = 10 + Vigor * 10"},
              %{
                "from" => "100 × (1.15)^(Level − 1) = Max EXP.",
                "rule" =>
                  "EXP.max = floor(100 * 1.15 ^ (Level - 1)); when EXP >= EXP.max: Level += 1; EXP -= EXP.max"
              }
            ]
          }
        })

      adapter = Aethrion.AutoCastTest.Reader
      Process.put(:reader_answer, answer)
      casts = %{put: fn _key, _value -> :ok end}

      assert {:ok, %{window: %{rules: rules}}} = AutoCast.read(card, casts, adapter)

      assert rules == [
               "HP.max = Vigor * 10",
               "EXP.max = floor(100 * 1.15 ^ (Level - 1))",
               "when EXP >= EXP.max: Level += 1; EXP -= EXP.max"
             ]
    end

    test "a rule is kept when the card states it, with its numbers where the card has them" do
      card = """
      - EXP: Experience points required to reach the next level. Current EXP = Max EXP → Level Up. 100 × (1.15)^(Level − 1) = Max EXP (truncate decimal points).
      - Vigor (생명력): Max HP +10 per point. HP/SP recovery rate increases.
      - Stat Point: Gain 5 points upon leveling up. Gain an extra 10 points for every level ending in 5 or 0 (a multiple of 5, gaining 15 points in total). A potion costs 100G.
      """

      stated = [
        {"HP.max = Vigor * 10", "Vigor (생명력): Max HP +10 per point."},
        # A sentence the reader shortened is still the card's.
        {"EXP.max = floor(100 * 1.15 ^ (Level - 1))",
         "EXP: Current EXP = Max EXP → Level Up. 100 × (1.15)^(Level − 1) = Max EXP (truncate decimal points)"},
        {"when EXP >= EXP.max: Level += 1; EXP -= EXP.max", "current exp = max exp → level up."},
        {"when Level rises: Stat Point += if(Level % 5 == 0, 15, 5)",
         "Gain 5 points upon leveling up. Gain an extra 10 points for every level ending in 5 or 0 (a multiple of 5, gaining 15 points in total)."}
      ]

      for {rule, from} <- stated, do: assert(AutoCast.stated?(rule, from, card), rule)

      made_up = [
        # A number the sentence does not have, or has only because the reader put it there.
        {"HP.max = 100 + Vigor * 10", "Vigor (생명력): Max HP +10 per point."},
        {"HP.max = 100 + Vigor * 10", "Vigor (생명력): Max HP +10 per point, base 100."},
        # A sentence that is not the card's: the rule itself, or a guess.
        {"when EXP >= EXP.max: Level += 1; EXP -= EXP.max",
         "when EXP >= EXP.max: Level += 1; EXP -= EXP.max"},
        {"when EXP >= 100: Level += 1; EXP -= 100", "EXP requirement increases with each level"},
        {"HP.max = Vigor * 10", ""},
        # A sentence of the card's that says nothing of the rule's fields.
        {"HP.max = Vigor * 10", "A potion costs 100G."},
        {"Stat Point = 0", "HP/SP recovery rate increases."},
        {"HP.max = Stat Point", "Gain 5 points upon leveling up."}
      ]

      for {rule, from} <- made_up, do: refute(AutoCast.stated?(rule, from, card), rule)
    end

    test "the player the card names is not one of its people" do
      answer =
        ~s|{"characters": [{"name": "무명"}, {"name": "기환 (Kihwan)"}], "player": " 기환 "}|

      assert {:ok, %{player: "기환", characters: [%{"name" => "무명"}]}} = AutoCast.people(answer)
      # A name that is none.
      assert {:ok, %{player: nil}} = AutoCast.people(~s({"characters": [], "player": "{{user}}"}))
      assert {:ok, %{player: nil}} = AutoCast.people(~s({"characters": [], "player": null}))
    end

    test "an answer that is not the JSON asked for is refused" do
      assert AutoCast.people("I cannot read this card.") == {:error, :no_characters_read}
      assert AutoCast.people(~s({"characters": "none"})) == {:error, :no_characters_read}
    end

    test "the key is the first message when there is one" do
      with_greeting = %{prompt: "a prompt", greeting: "hello"}
      assert AutoCast.key(with_greeting) == AutoCast.key(%{with_greeting | prompt: "another"})
      refute AutoCast.key(with_greeting) == AutoCast.key(%{with_greeting | greeting: "hi"})

      refute AutoCast.key(%{prompt: "a prompt", greeting: nil}) ==
               AutoCast.key(%{prompt: "another", greeting: nil})
    end
  end

  # Answers what the test put in its process dictionary.
  defmodule Exits do
    # The first reading answers; the later ones exit or throw.
    def chat(_messages, opts) do
      case Agent.get_and_update(opts[:calls], &{&1, &1 + 1}) do
        0 -> {:ok, opts[:first]}
        1 -> exit(:timeout)
        _later -> throw(:oops)
      end
    end
  end

  defmodule Raises do
    # The caller's own reading raises; the others answer.
    def chat(_messages, opts) do
      if self() == opts[:caller], do: raise("no model"), else: {:ok, opts[:first]}
    end
  end

  defmodule Readers do
    # One answer a reading, in turn (the later readings run in tasks).
    def chat(_messages, opts) do
      Agent.get_and_update(opts[:answers], fn
        [answer | rest] -> {{:ok, answer}, rest}
        [] -> {{:error, :no_more}, []}
      end)
    end
  end

  defmodule Reader do
    def chat(_messages, _opts), do: {:ok, Process.get(:reader_answer)}
  end

  # Reads a card when asked to, narrates otherwise; every call is noted.
  defmodule Model do
    @behaviour Aethrion.LLM.Adapter
    @impl true
    def render(_request, _opts), do: {:ok, "..."}
    @impl true
    def complete(_system, _user, _opts), do: {:ok, "(narration)"}

    def chat(messages, opts) do
      Agent.update(Aethrion.AutoCastTest.Calls, &(&1 ++ [messages]))

      cond do
        Enum.any?(messages, &(&1["content"] =~ "FAILING CARD")) ->
          {:error, :boom}

        hd(messages)["content"] =~ "You read a role-play character card" and
            Enum.any?(messages, &(&1["content"] =~ "LEDGER CARD")) ->
          Agent.update(
            Aethrion.AutoCastTest.Calls,
            &(&1 ++ [[%{"content" => "reader model: #{inspect(opts[:model])}"}]])
          )

          {:ok,
           Jason.encode!(%{
             "title" => "Tower",
             "characters" => [],
             "status_window" => %{
               "open" => "[Status]",
               "close" => "[Status]",
               "rules" => [
                 %{"from" => "Max HP +10 per point of Vigor.", "rule" => "HP.max = Vigor * 10"},
                 %{
                   "from" => "Current EXP = Max EXP → Level Up.",
                   "rule" => "when EXP >= EXP.max: Level += 1; EXP -= EXP.max"
                 },
                 %{
                   "from" => "Max HP +10 per point of Vigor.",
                   "rule" => "HP.max = 50 + Vigor * 10"
                 },
                 %{"from" => "not in the card at all", "rule" => "Level = Level + 1"}
               ]
             }
           })}

        Enum.any?(messages, &(&1["content"] =~ "LEDGER CARD")) ->
          {:ok, ledger_narration(messages)}

        hd(messages)["content"] =~ "You read a role-play character card" and
            Enum.any?(messages, &(&1["content"] =~ "NARRATOR CARD")) ->
          {:ok, ~s({"title": "Isekai", "characters": []})}

        Enum.any?(messages, &(&1["content"] =~ "NARRATOR CARD")) ->
          {:ok, narration(messages)}

        hd(messages)["content"] =~ "You read a role-play character card" ->
          {:ok,
           ~s({"title": "Campfire", "characters": [{"name": "세라", "profile": "조용한 치유사.", "affinity": 30, "trust": 20}, {"name": "도윤", "profile": "방패수.", "affinity": 10, "trust": 10}]})}

        true ->
          {:ok, "세라가 고개를 끄덕인다."}
      end
    end

    def stream_chat(messages, opts, on_delta) do
      {:ok, text} = chat(messages, opts)
      # In pieces that cut the scene line's tag in two.
      for piece <- Regex.scan(~r/.{1,7}/su, text), do: on_delta.(hd(piece))
      {:ok, text}
    end

    # A card with a status window: the model prints the first one, then
    # writes what changed, and once prints a window where changes were
    # asked for.
    defp ledger_narration(messages) do
      case Enum.count(messages, &(&1["role"] == "user")) do
        1 ->
          "문이 열린다.\n\n[Status]\n- Level: 1\n- HP: 30 / 30\n- EXP: 90 / 100\n- Vigor: 5\n- Item: 물약 × 2\n[Status]\n<aethrion-scene></aethrion-scene>"

        2 ->
          # Asked again for a turn already answered, it tells it otherwise
          # and would change other numbers.
          if List.last(messages)["content"] =~ "This turn was played before",
            do:
              "이번엔 단칼에 벤다.\n\n<aethrion-ledger>\nHP: -40\nEXP: +900\n</aethrion-ledger>\n<aethrion-scene></aethrion-scene>",
            else:
              "고블린을 벤다.\n\n<aethrion-ledger>\nHP: -12\nEXP: +25\nItem: -물약 × 1\nMana: +1\n</aethrion-ledger>\n<aethrion-scene></aethrion-scene>"

        3 ->
          "곤봉이 어깨를 친다.\n\n[Status]\n- Level: 2\n- HP: 20 / 50\n- EXP: 15 / 100\n- Vigor: 5\n- Item: 물약 × 1\n[Status]"

        _more ->
          # The first answer to this turn says nothing of the window; asked again, it does.
          asked =
            Aethrion.AutoCastTest.Calls
            |> Agent.get(& &1)
            |> Enum.count(fn call -> Enum.count(call, &(&1["role"] == "user")) >= 4 end)

          if asked <= 1,
            do: "숲은 잠잠하다.",
            else: "늑대가 문다.\n\n<aethrion-ledger>\nHP: -5\n</aethrion-ledger>"
      end
    end

    # A narrator: Haruka is there from the first reply, Kenji joins when
    # the player has spoken twice, and then Haruka leaves.
    defp narration(messages) do
      case Enum.count(messages, &(&1["role"] == "user")) do
        1 -> "버스가 멈춘다. 옆자리의 하루카가 고개를 든다.\n<aethrion-scene>\n하루카 | 조용한 도서부원\n</aethrion-scene>"
        2 -> "켄지가 다가온다.\n\n<aethrion-scene>하루카\n- 켄지 | 운동부 주장</aethrion-scene>"
        _more -> "하루카는 먼저 내렸다. <가방>만 남았다.\n<aethrion-scene>켄지</aethrion-scene>"
      end
    end
  end

  describe "the model name aethrion-auto" do
    setup do
      for name <- [Aethrion.Bridge.Readings, Aethrion.Bridge.Checkpoints, Aethrion.Bridge.Casts],
          do: start_supervised!({Aethrion.Bridge.Store, name: name})

      start_supervised!(%{
        id: Aethrion.AutoCastTest.Calls,
        start: {Agent, :start_link, [fn -> [] end, [name: Aethrion.AutoCastTest.Calls]]}
      })

      start_supervised!({Worlds, name: Worlds.Test.AutoCast, world: fn _key -> [] end})
      {:ok, den} = "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> State.parse()

      pid =
        start_supervised!(
          {API,
           worlds: Worlds.Test.AutoCast,
           port: 0,
           locale: :ko,
           cast: den,
           intent: [adapter: Model],
           interpreter: Aethrion.Interpreter.Rules}
        )

      %{base: "http://127.0.0.1:#{API.port(pid)}"}
    end

    defp ask(base, chat, opts \\ []) do
      messages =
        [
          %{"role" => "system", "content" => Keyword.get(opts, :card, @card)},
          %{"role" => "system", "content" => "[Start a new chat]"},
          %{"role" => "assistant", "content" => Keyword.get(opts, :greeting, @greeting)}
        ] ++ chat

      body =
        Jason.encode!(%{
          "model" => Keyword.get(opts, :model, "aethrion-auto"),
          "messages" => messages
        })

      {:ok, {{_v, status, _r}, _headers, answer}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json", body},
          [],
          body_format: :binary
        )

      case Jason.decode!(answer) do
        %{"choices" => [%{"message" => %{"content" => content}}]} -> {status, content}
        error -> {status, error}
      end
    end

    defp calls, do: Agent.get(Aethrion.AutoCastTest.Calls, & &1)
    defp user(line), do: %{"role" => "user", "content" => line}
    defp reply(text), do: %{"role" => "assistant", "content" => text}

    # How many times a card was read: each time is three readings by the model.
    defp card_reads do
      calls = Enum.count(calls(), &(hd(&1)["content"] =~ "You read a role-play character card"))
      assert rem(calls, 3) == 0
      div(calls, 3)
    end

    test "plays the card in the request, read once", %{base: base} do
      {200, first} = ask(base, [user("세라, 고마워. 덕분에 살았어.")])

      # The people are the card's, not the server's cast (a wolf den).
      assert first =~
               ~r/<aethrion-status id="[0-9a-f]+" card="[0-9a-f]{24}">세라 · 호감 3\d \(\+\d\) · 신뢰 2\d \(\+\d\)\n도윤 · 호감 10 · 신뢰 10\n/

      refute first =~ "울프"
      assert card_reads() == 1

      # A reroll: the same numbers, and the card is not read again.
      {200, again} = ask(base, [user("세라, 고마워. 덕분에 살았어.")])
      assert status(again) == status(first)
      assert card_reads() == 1
    end

    test "the chat keeps its cast when the app changes its prompt", %{base: base} do
      line = user("세라, 고마워. 덕분에 살았어.")
      {200, first} = ask(base, [line])

      # A lorebook entry came in, and the app trimmed the first message away:
      # the reply's checkpoint still leads to the cast.
      changed = @card <> "\n\n[Lore: the forest is haunted.]"

      body = %{
        "model" => "aethrion-auto",
        "messages" => [
          %{"role" => "system", "content" => changed},
          line,
          reply(first),
          user("세라, 미안해. 내가 잘못했어.")
        ]
      }

      {:ok, {{_v, 200, _r}, _headers, answer}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json",
           Jason.encode!(body)},
          [],
          body_format: :binary
        )

      assert %{"choices" => [%{"message" => %{"content" => second}}]} = Jason.decode!(answer)
      assert second =~ "세라 · 호감"
      assert card_reads() == 1
    end

    test "leaves the card's own status window to the card", %{base: base} do
      {200, _reply} = ask(base, [user("세라, 고마워.")])
      note = calls() |> List.last() |> List.last() |> Map.fetch!("content")

      assert note =~ "If the card asks for a status window or a format of its own, keep it"
      refute note =~ "do not print a status window"

      # The server's own cast is told as before.
      {200, _reply} = ask(base, [user("다이어 울프를 벤다")], model: "aethrion")
      note = calls() |> List.last() |> List.last() |> Map.fetch!("content")
      assert note =~ "do not print a status window"
    end

    test "without a status block for aethrion-auto-plain", %{base: base} do
      {200, plain} = ask(base, [user("세라, 고마워.")], model: "aethrion-auto-plain")
      assert plain == "세라가 고개를 끄덕인다."
    end

    test "a card the model cannot read is an error, and nothing is kept", %{base: base} do
      {502, error} = ask(base, [user("안녕")], card: "FAILING CARD")
      assert error["error"]["code"] == "model_failed"
      assert error["error"]["message"] =~ "could not read the card"

      # The same first message with a card that can be read: read again.
      {200, _reply} = ask(base, [user("세라, 고마워.")])
      assert card_reads() == 2
    end

    test "the name is matched in any letter case", %{base: base} do
      # A settings field may capitalize what is typed into it.
      {200, reply} = ask(base, [user("세라, 고마워.")], model: "Aethrion-auto")
      assert reply =~ "세라 · 호감"
      refute reply =~ "울프"

      {200, plain} = ask(base, [user("세라, 고마워.")], model: "Aethrion-Auto-Plain")
      assert plain == "세라가 고개를 끄덕인다."
    end

    test "a narrator card: people join as the story brings them in", %{base: base} do
      card = [card: "NARRATOR CARD: an isekai world. You narrate."]
      first = user("주변을 둘러본다. 가장 가까운 사람에게 말을 건다.")
      {200, one} = ask(base, [first], card)

      # No one to track yet; the scene line is taken out of the reply and
      # kept in the status block's tag.
      assert one =~
               ~r/\A버스가 멈춘다. 옆자리의 하루카가 고개를 든다.\n\n<aethrion-status id="[0-9a-f]+" card="[0-9a-f]+" scene="하루카\|조용한 도서부원">/

      refute one =~ "<aethrion-scene"
      refute one =~ "호감"

      # The next line is said to Haruka, who is now in the cast.
      second = user("고마워요, 하루카. 덕분에 살았어요.")
      {200, two} = ask(base, [first, reply(one), second], card)
      assert two =~ ~r/하루카 · 호감 \d+ \(\+\d+\)/
      assert two =~ ~s(scene="하루카;켄지|운동부 주장")

      # A reroll: the same numbers.
      {200, again} = ask(base, [first, reply(one), second], card)
      assert status(again) == status(two)

      # Kenji is there for the third line, and sees it; then Haruka leaves.
      third = user("하루카, 이거 받아요. 선물이에요.")
      {200, three} = ask(base, [first, reply(one), second, reply(two), third], card)
      assert three =~ "켄지 · 호감 0 · 신뢰 0"
      assert three =~ "목격 · 켄지"
      assert three =~ ~s(scene="켄지">)
      assert three =~ "<가방>만 남았다."

      # Haruka is away: she is not listed, and does not see what Kenji is told.
      fourth = user("켄지, 고마워.")

      {200, four} =
        ask(base, [first, reply(one), second, reply(two), third, reply(three), fourth], card)

      assert four =~ ~r/켄지 · 호감 \d+ \(\+\d+\)/
      refute status(four) =~ "하루카"
      assert card_reads() == 1
    end

    test "the scene line is held back from a reply as it is streamed", %{base: base} do
      body =
        Jason.encode!(%{
          "model" => "aethrion-auto",
          "stream" => true,
          "messages" => [
            %{"role" => "system", "content" => "NARRATOR CARD: an isekai world."},
            user("주변을 둘러본다.")
          ]
        })

      {:ok, {{_v, 200, _r}, _headers, events}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json", body},
          [],
          body_format: :binary
        )

      text =
        for "data: " <> data <- String.split(events, "\n\n", trim: true),
            data != "[DONE]",
            %{"choices" => [%{"delta" => %{"content" => content}}]} <- [Jason.decode!(data)],
            into: "",
            do: content

      assert text =~
               ~r/\A버스가 멈춘다. 옆자리의 하루카가 고개를 든다.\s+<aethrion-status id="[0-9a-f]+" card="[0-9a-f]+" scene="하루카\|조용한 도서부원">/

      refute text =~ "<aethrion-scene"
    end

    @ledger_card "LEDGER CARD: a tower. Print the status between [Status] lines. Max HP +10 per point of Vigor. Current EXP = Max EXP → Level Up."

    test "a card's status window is kept by the ledger, with the card's arithmetic", %{base: base} do
      card = [card: @ledger_card]
      first = user("탑에 들어간다.")
      {200, one} = ask(base, [first], card)

      # The first window is the model's, put right by the rule the card
      # states (the two it does not state are not used).
      assert one =~ ~r/\A문이 열린다.\n\n\[Status\]\n- Level: 1\n- HP: 50 \/ 50\n- EXP: 90 \/ 100\n/
      assert one =~ "규칙 · HP 30 / 30 → 50 / 50"
      refute one =~ "<aethrion-scene"

      # From then on the model is asked for what changed, and told the rules.
      second = user("고블린을 벤다.")
      {200, two} = ask(base, [first, reply(one), second], card)
      note = calls() |> List.last() |> List.last() |> Map.fetch!("content")
      assert note =~ "do not print it yourself"
      assert note =~ "(Level, HP, EXP, Vigor, Item)"

      assert note =~
               "the maximum of HP, Level (HP.max = Vigor * 10 | when EXP >= EXP.max: Level += 1; EXP -= EXP.max)."

      assert two =~
               ~r/\A고블린을 벤다.\n\n\[Status\]\n- Level: 2\n- HP: 38 \/ 50\n- EXP: 15 \/ 100\n- Vigor: 5\n- Item: 물약 × 1\n\[Status\]\n\n<aethrion-status /

      refute two =~ "<aethrion-ledger"

      assert two =~
               "기록 · HP 50 / 50 → 38 / 50 · EXP 90 / 100 → 115 / 100 · Item −물약\n기록 · Mana: +1 (없는 칸)\n규칙 · Level 1 → 2 · EXP 115 / 100 → 15 / 100"

      # A reroll tells the turn anew, and its numbers stand: the model is
      # told what the first answer settled, and what it would change now is
      # not taken.
      {200, again} = ask(base, [first, reply(one), second], card)
      note = calls() |> List.last() |> List.last() |> Map.fetch!("content")

      # What the first answer came to, without what was refused of it.
      assert note =~
               "what it does to the window is settled: 기록 · HP 50 / 50 → 38 / 50 · EXP 90 / 100 → 115 / 100 · Item −물약; 규칙 · Level 1 → 2 · EXP 115 / 100 → 15 / 100. Narrate"

      refute note =~ "one line for each field"

      assert again =~
               ~r/\A이번엔 단칼에 벤다.\n\n\[Status\]\n- Level: 2\n- HP: 38 \/ 50\n- EXP: 15 \/ 100\n/

      assert String.replace(again, "이번엔 단칼에 벤다.", "고블린을 벤다.") == two

      # A window printed where changes were asked for: its differences are the changes.
      third = user("버틴다.")
      {200, three} = ask(base, [first, reply(one), second, reply(two), third], card)
      assert three =~ ~r/\A곤봉이 어깨를 친다.\n\n\[Status\]\n- Level: 2\n- HP: 20 \/ 50\n/
      assert length(String.split(three, "[Status]")) == 3
      assert three =~ "기록 · HP 38 / 50 → 20 / 50"

      # An answer that says nothing of the window settles nothing: the
      # window stays, and a reroll may still say what changed.
      chat = [first, reply(one), second, reply(two), third, reply(three), user("숲으로 간다.")]
      {200, four} = ask(base, chat, card)
      assert four =~ ~r/\A숲은 잠잠하다.\n\n\[Status\]\n- Level: 2\n- HP: 20 \/ 50\n/
      {200, again} = ask(base, chat, card)
      assert again =~ ~r/\A늑대가 문다.\n\n\[Status\]\n- Level: 2\n- HP: 15 \/ 50\n/
      # That one settled it.
      {200, third_time} = ask(base, chat, card)
      assert third_time == again
      # The card was read at its first turn only.
      assert card_reads() == 1
    end

    test "the ledger's lines and a window printed anyway are held back from a stream", %{
      base: base
    } do
      card = [card: @ledger_card]
      first = user("탑에 들어간다.")
      {200, one} = ask(base, [first], card)
      second = user("고블린을 벤다.")
      {200, two} = ask(base, [first, reply(one), second], card)

      stream = fn chat ->
        body =
          Jason.encode!(%{
            "model" => "aethrion-auto",
            "stream" => true,
            "messages" =>
              [
                %{"role" => "system", "content" => @ledger_card},
                %{"role" => "system", "content" => "[Start a new chat]"},
                %{"role" => "assistant", "content" => @greeting}
              ] ++ chat
          })

        {:ok, {{_v, 200, _r}, _headers, events}} =
          :httpc.request(
            :post,
            {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json", body},
            [],
            body_format: :binary
          )

        for "data: " <> data <- String.split(events, "\n\n", trim: true),
            data != "[DONE]",
            %{"choices" => [%{"delta" => %{"content" => content}}]} <- [Jason.decode!(data)],
            into: "",
            do: content
      end

      # What is streamed comes to what an unstreamed reply is (the turn
      # was answered once: its numbers stand).
      assert stream.([first, reply(one), second]) ==
               String.replace(two, "고블린을 벤다.", "이번엔 단칼에 벤다.")

      third = user("버틴다.")
      streamed = stream.([first, reply(one), second, reply(two), third])
      assert streamed =~ ~r/\A곤봉이 어깨를 친다.\s+\[Status\]\n- Level: 2\n- HP: 20 \/ 50\n/
      assert length(String.split(streamed, "[Status]")) == 3
    end

    defp call(method, url, body \\ nil) do
      request =
        if body,
          do: {String.to_charlist(url), [], ~c"application/json", Jason.encode!(body)},
          else: {String.to_charlist(url), []}

      {:ok, {{_v, status, _r}, _headers, answer}} =
        :httpc.request(method, request, [], body_format: :binary)

      {status, Jason.decode!(answer)}
    end

    test "what was read from a card can be looked over, set right, and forgotten", %{base: base} do
      card = [card: @ledger_card]
      first = user("탑에 들어간다.")
      {200, one} = ask(base, [first], card)

      {:ok, {{_v, 200, _r}, _headers, page}} =
        :httpc.request(:get, {String.to_charlist(base <> "/cards"), []}, [], body_format: :binary)

      assert page =~ "읽은 카드"

      assert {200, %{"cards" => [read]}} = call(:get, base <> "/casts/cards")

      assert %{
               "key" => key,
               "title" => "Tower",
               "people" => [],
               "window" => %{
                 "open" => "[Status]",
                 "close" => "[Status]",
                 "off" => false,
                 "rules" => [
                   "HP.max = Vigor * 10",
                   "when EXP >= EXP.max: Level += 1; EXP -= EXP.max"
                 ]
               }
             } = read

      assert read["read_at"] =~ ~r/\A\d{4}-\d\d-\d\dT/

      # A rule set right holds from the next turn.
      window = %{"open" => "[Status]", "close" => "[Status]", "rules" => ["HP.max = Vigor * 20"]}

      assert {200, %{"ok" => true}} =
               call(:put, base <> "/casts/cards/" <> key, %{"window" => window})

      second = user("고블린을 벤다.")
      {200, two} = ask(base, [first, reply(one), second], card)
      assert two =~ "- HP: 38 / 100\n"
      assert two =~ "HP 38 / 50 → 38 / 100"

      # With the ledger off, the window is the model's again.
      assert {200, _ok} =
               call(:put, base <> "/casts/cards/" <> key, %{
                 "window" => Map.put(window, "off", true)
               })

      {200, _three} = ask(base, [first, reply(one), second, reply(two), user("버틴다.")], card)
      note = calls() |> List.last() |> List.last() |> Map.fetch!("content")
      assert note =~ "If the card asks for a status window or a format of its own, keep it"

      assert {200, %{"cards" => [%{"window" => %{"off" => true}}]}} =
               call(:get, base <> "/casts/cards")

      # What cannot be kept is refused, and a key nothing was read under is not found.
      assert {400, %{"error" => %{"message" => message}}} =
               call(:put, base <> "/casts/cards/" <> key, %{"window" => %{"open" => ""}})

      assert message =~ "opening text"
      assert {400, _error} = call(:put, base <> "/casts/cards/" <> key, %{})
      assert {404, _error} = call(:delete, base <> "/casts/cards/nothing")

      # Forgotten, the card is read again when it is next played.
      reads = card_reads()
      assert {200, %{"ok" => true}} = call(:delete, base <> "/casts/cards/" <> key)
      assert {200, %{"cards" => []}} = call(:get, base <> "/casts/cards")
      {200, _again} = ask(base, [user("탑에 들어간다.")], card)
      assert card_reads() == reads + 1
      # Read once more and kept: listed again, and not read a third time.
      assert {200, %{"cards" => [%{"title" => "Tower"}]}} = call(:get, base <> "/casts/cards")
      {200, _again} = ask(base, [user("탑에 들어간다.")], card)
      assert card_reads() == reads + 1
    end

    test "another model may read the card, while the server's narrates", %{base: base} do
      reader = fn ->
        Enum.find_value(calls(), &(hd(&1)["content"] =~ "reader model" && hd(&1)["content"]))
      end

      {200, _reply} = ask(base, [user("탑에 들어간다.")], card: @ledger_card)
      assert reader.() == "reader model: nil"

      {:ok, den} = "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> State.parse()

      pid =
        start_supervised!(
          {API,
           worlds: Worlds.Test.AutoCast,
           port: 0,
           locale: :ko,
           cast: den,
           intent: [adapter: Model],
           card_opts: [model: "a-stronger-one"],
           interpreter: Aethrion.Interpreter.Rules},
          id: :with_card_model
        )

      Agent.update(Aethrion.AutoCastTest.Calls, fn _calls -> [] end)
      other = "http://127.0.0.1:#{API.port(pid)}"
      # Another first message: another card to read.
      {200, _reply} =
        ask(other, [user("탑에 들어간다.")], card: @ledger_card, greeting: "다른 시작.")

      assert reader.() == ~s(reader model: "a-stronger-one")
    end

    test "is listed among the models", %{base: base} do
      {:ok, {{_v, 200, _r}, _headers, body}} =
        :httpc.request(:get, {String.to_charlist(base <> "/v1/models"), []}, [],
          body_format: :binary
        )

      ids = for %{"id" => id} <- Jason.decode!(body)["data"], do: id
      assert "aethrion-auto" in ids
      assert "aethrion-auto-plain" in ids
    end

    defp status(reply) do
      [_all, status] = Regex.run(~r/(<aethrion-status.*<\/aethrion-status>)/s, reply)
      status
    end
  end
end
