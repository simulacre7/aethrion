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
