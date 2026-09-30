defmodule Aethrion.ReportTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Report, Scenario}

  defp result(path \\ hd(Scenario.bundled())) do
    {:ok, scenario} = Scenario.load(path)
    {:ok, result} = Scenario.run(scenario)
    result
  end

  test "renders a self-contained report with every section" do
    html = Report.html(result())

    assert html =~ "<!doctype html>"
    assert html =~ "<title>The flower · Aethrion</title>"

    for heading <- ["Cast", "How they felt", "Relationships", "Timeline", "Expectations"] do
      assert html =~ "<h2>#{heading}</h2>"
    end

    assert html =~ "You looked happy with Mina earlier."
    assert html =~ "caused by e3"
    assert html =~ "mood neutral -&gt; jealous by mood in e1: the user gives Mina a flower"
    assert html =~ "10/10"
    refute html =~ ~r/<(script|link)[^>]+src=/
  end

  test "cards list what a character has come to believe, apart from single memories" do
    html =
      Report.html(
        result(Enum.find(Scenario.bundled(), &String.ends_with?(&1, "08_old_friends.json")))
      )

    assert html =~
             ~s(Has come to believe</p><ul class="memories"><li><span class="memory-kind">firsthand</span>user has been warm to mina 3 times.)

    refute html =~ ~r/Remembers most<\/p><ul class="memories">(?:(?!<\/ul>).)*impression/s
  end

  test "character lines can be rendered in Korean" do
    html = Report.html(result(), locale: :ko)

    assert html =~ ~s(<html lang="ko">)
    assert html =~ "<h2>등장인물</h2>"
    assert html =~ "네가 Mina에게 꽃을 준다 (Yuna 목격)"
    refute html =~ "<h2>Cast</h2>"
    assert html =~ ~s(<blockquote lang="ko">아까 Mina랑 있을 때 즐거워 보이더라.)
    # Speech bubbles change; the rule log stays as the rules wrote it.
    refute html =~ "<blockquote>You looked happy with Mina earlier."
    assert Report.html(result()) =~ "<blockquote>You looked happy with Mina earlier."
  end

  test "bond changes are listed in order per relationship" do
    html =
      Report.html(
        result(Enum.find(Scenario.bundled(), &String.ends_with?(&1, "13_slowly_closer.json")))
      )

    assert html =~ "<h3 class=\"sub\">Bond changes</h3>"

    assert html =~
             ~r{Haru → You: neutral → <strong>friendly</strong> <span class="cause">e\d+</span> → <strong>close</strong> <span class="cause">e\d+</span></li>}

    refute Report.html(result()) =~ "Bond changes"
  end

  test "the digest keeps net changes when it is shortened" do
    # A week of gifts to Mina in front of Yuna: more happens than fits.
    events =
      for day <- 1..7,
          event <- [
            %{
              "type" => "gift_received",
              "from" => "user",
              "to" => "mina",
              "item" => "flower #{day}",
              "observed_by" => ["yuna"]
            },
            %{"type" => "time_tick", "hours" => 26}
          ],
          do: event

    {:ok, scenario} =
      Scenario.from_data(%{"name" => "A week of flowers", "world" => "demo", "events" => events})

    {:ok, result} = Scenario.run(scenario)
    html = Report.html(result)

    assert html =~ ~s(<li class="more">…and)
    assert html =~ ~s[<li class="bond">Yuna cooled toward Mina (now strained).</li>]
    assert html =~ ~s[<li class="scene">Haru and Yuna spent time together 6 times.</li>]
  end

  test "reports open with a digest of what happened" do
    html = Report.html(result())

    assert html =~
             ~s(<h2>In short</h2><ul class="digest"><li class="message">Yuna reached out to you)

    assert Report.html(result(), locale: :ko) =~
             ~s(<ul class="digest" lang="ko"><li class="message">Yuna가 너에게 먼저 연락했다)
  end

  test "reports are deterministic" do
    assert Report.html(result()) == Report.html(result())
  end

  test "untrusted text is escaped" do
    {:ok, scenario} =
      Scenario.from_data(%{
        "name" => "<script>alert(1)</script>",
        "description" => "\"quoted\" & <b>bold</b>",
        "events" => [
          %{
            "type" => "message_sent",
            "from" => "user",
            "to" => "mina",
            "text" => "<img src=x onerror=alert(1)>",
            "tone" => "warm"
          }
        ]
      })

    {:ok, result} = Scenario.run(scenario)
    html = Report.html(result)

    refute html =~ "<script>alert(1)</script>"
    refute html =~ "<img src=x"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "&quot;quoted&quot; &amp; &lt;b&gt;bold&lt;/b&gt;"
  end

  test "every bundled scenario renders" do
    for path <- Scenario.bundled() do
      assert Report.html(result(path)) =~ "</html>"
    end
  end

  test "large worlds focus per-character sections on the most active characters" do
    characters = for i <- 1..20, do: %{"id" => "c#{i}", "name" => "C#{i}"}

    {:ok, scenario} =
      Scenario.from_data(%{
        "world" => %{"characters" => characters},
        "events" => [
          %{
            "type" => "gift_received",
            "from" => "user",
            "to" => "c7",
            "item" => "x",
            "observed_by" => ["c3"]
          },
          %{"type" => "time_tick", "hours" => 1}
        ]
      })

    {:ok, result} = Scenario.run(scenario)
    html = Report.html(result)

    assert html =~ "This world has 20 characters"
    assert html =~ "<h3>C7</h3>"
    assert html =~ "<h3>C3</h3>"
    assert length(Regex.scan(~r/<article class="card">/, html)) == 12
  end
end
