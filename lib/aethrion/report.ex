defmodule Aethrion.Report do
  @moduledoc """
  Renders a scenario run as a self-contained HTML report.

      {:ok, scenario} = Aethrion.Scenario.load("priv/scenarios/01_the_flower.json")
      {:ok, result} = Aethrion.Scenario.run(scenario)
      File.write!("report.html", Aethrion.Report.html(result))

  The report has no external assets: styles, charts (inline SVG), and the small
  hover script are embedded, and it follows the viewer's light or dark theme.
  It shows the cast, how each character's feelings moved after every host
  event, the final relationship graph, the full timeline with cascaded events
  and dialogue, and the scenario's expectations.

  The same scenario always produces the same report.
  """

  alias Aethrion.{Event, Output, Scenario, State}
  alias Aethrion.Rules.Bond

  @metrics [
    {:loneliness, "Loneliness", "--series-1"},
    {:jealousy, "Jealousy", "--series-2"},
    {:joy, "Joy", "--series-3"},
    {:stress, "Stress", "--series-4"}
  ]

  @doc """
  Returns the report HTML for a `Aethrion.Scenario.Result`.

  Options:

  - `:locale` - `:ko` writes the report in Korean: headings, notes, event
    descriptions, and every character line (from
    `Aethrion.Expression.Templates.Ko`), and memories from their data.
    What authors wrote (scenario names, descriptions, profiles) stays as
    written, and so do the rule logs, which are for developers. Defaults to
    `:en`.
  """
  @spec html(Scenario.Result.t(), keyword()) :: iodata()
  def html(%Scenario.Result{} = result, opts \\ []) do
    locale = opts |> Keyword.get(:locale, :en) |> supported_locale!()
    result = localize(result, locale)
    t = translator(locale)
    scenario = result.scenario

    snapshots = [
      {t.("start"), scenario.state}
      | Enum.map(result.steps, &{t.({:short_label, &1.event}), &1.state})
    ]

    # Large worlds: per-character sections show the most active characters.
    focus = focus_ids(result)
    view = &focus_state(&1, focus)
    focused = %{result | state: view.(result.state)}

    [
      "<!doctype html>\n<html lang=\"#{if locale == :ko, do: "ko", else: "en"}\">\n<head>\n<meta charset=\"utf-8\">\n",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
      "<title>",
      esc(scenario.name),
      " · Aethrion</title>\n<style>",
      css(),
      "</style>\n</head>\n<body>\n<main class=\"viz-root\">\n",
      header(result, t),
      in_short(result, locale, t),
      focus_note(result.state, focus, t),
      cast(focused, view.(scenario.state), t),
      feelings(focused.state, snapshots, t),
      relationships(view.(scenario.state), focused.state, result.outputs, t),
      timeline(result, t),
      branches(focused, t),
      checks(result, t),
      "<footer>",
      esc(t.({:footer, version()})),
      "</footer>\n",
      "</main>\n<div class=\"tooltip\" role=\"status\" hidden></div>\n<script>",
      script(),
      "</script>\n</body>\n</html>\n"
    ]
    |> IO.iodata_to_binary()
  end

  ## In short

  # The shared timeline as a digest: what a reader should know first.
  defp in_short(result, locale, t) do
    # Net bond and mood changes always stay; events fill the rest.
    {net, events} =
      result.outputs
      |> Aethrion.Digest.of(result.state, locale: locale)
      |> Enum.split_with(&(&1.kind in [:bond, :mood]))

    shown = Enum.take(events, max(12 - length(net), 4))
    hidden = length(events) - length(shown)

    more =
      cond do
        hidden == 0 -> []
        locale == :ko -> [%{kind: :more, text: "…외 #{hidden}건"}]
        true -> [%{kind: :more, text: "…and #{hidden} more"}]
      end

    case shown ++ more ++ net do
      [] ->
        ""

      items ->
        lang = if locale == :ko, do: " lang=\"ko\"", else: ""

        [
          "<section><h2>",
          t.("In short"),
          "</h2><ul class=\"digest\"",
          lang,
          ">",
          Enum.map(
            items,
            &["<li class=\"", Atom.to_string(&1.kind), "\">", esc(&1.text), "</li>"]
          ),
          "</ul></section>\n"
        ]
    end
  end

  ## Focus

  @max_characters 12

  # The most active characters by number of traced changes, then by id.
  defp focus_ids(%Scenario.Result{state: state} = result) do
    if map_size(state.characters) <= @max_characters do
      nil
    else
      counts =
        (result.steps ++ Enum.flat_map(result.branches, & &1.steps))
        |> Enum.flat_map(& &1.trace)
        |> Enum.frequencies_by(& &1.subject)

      state
      |> State.sorted_characters()
      |> Enum.sort_by(&{-Map.get(counts, &1.id, 0), &1.id})
      |> Enum.take(@max_characters)
      |> MapSet.new(& &1.id)
    end
  end

  defp focus_state(state, nil), do: state

  defp focus_state(%State{} = state, focus) do
    keep? = fn id -> MapSet.member?(focus, id) or not Map.has_key?(state.characters, id) end

    %{
      state
      | characters:
          Map.filter(state.characters, fn {id, _character} -> MapSet.member?(focus, id) end),
        relationships:
          Map.filter(state.relationships, fn {{from, to}, _relationship} ->
            keep?.(from) and keep?.(to)
          end)
    }
  end

  defp focus_note(_state, nil, _t), do: ""

  defp focus_note(%State{} = state, focus, t) do
    [
      "<p class=\"note focus-note\">",
      esc(t.({:focus, map_size(state.characters), MapSet.size(focus)})),
      "</p>\n"
    ]
  end

  ## Sections

  defp header(result, t) do
    steps = result.steps ++ Enum.flat_map(result.branches, & &1.steps)
    outputs = result.outputs ++ Enum.flat_map(result.branches, & &1.outputs)
    checks = Scenario.all_checks(result)
    passed = Enum.count(checks, & &1.passed?)

    stats =
      [
        {length(steps), "host events"},
        {Enum.sum(Enum.map(steps, &length(&1.events))), "events processed"},
        {Enum.count(outputs, &Output.expressive?/1), "lines & scenes"}
      ] ++
        if(result.branches == [], do: [], else: [{length(result.branches), "branches"}]) ++
        [{"#{passed}/#{length(checks)}", "expectations met"}]

    stats = Enum.map(stats, fn {value, label} -> {value, t.(label)} end)

    [
      "<header class=\"page-head\">\n<p class=\"eyebrow\">",
      t.("Aethrion scenario report"),
      "</p>\n<h1>",
      esc(result.scenario.name),
      "</h1>\n<p class=\"lede\">",
      esc(result.scenario.description),
      "</p>\n<dl class=\"stats\">",
      Enum.map(stats, fn {value, label} ->
        ["<div><dt>", esc(label), "</dt><dd>", esc(value), "</dd></div>"]
      end),
      "</dl>\n",
      tuning(result.state, t),
      "</header>\n"
    ]
  end

  defp tuning(%State{tuning: tuning}, _t) when map_size(tuning) == 0, do: ""

  defp tuning(%State{tuning: tuning}, t) do
    items =
      tuning
      |> Enum.sort()
      |> Enum.flat_map(fn {rule, params} ->
        params |> Enum.sort() |> Enum.map(fn {key, value} -> "#{rule}.#{key} = #{value}" end)
      end)
      |> Enum.map(&["<li><code>", esc(&1), "</code></li>"])

    ["<div class=\"tuning\"><span>", t.("Tuned rules"), "</span><ul>", items, "</ul></div>\n"]
  end

  defp cast(result, initial, t) do
    cards =
      result.state
      |> State.sorted_characters()
      |> Enum.map(fn character ->
        before = State.character(initial, character.id)

        why =
          result.steps
          |> Aethrion.Explain.character(character.id, :mood)
          |> Enum.map(&t.({:why, &1, fn id -> narrative_name(result.state, id, t) end}))
          |> Enum.map(&["<li>", esc(&1), "</li>"])

        meters =
          Enum.map(@metrics, fn {field, label, color} ->
            value = Map.fetch!(character.state, field)
            start = if before, do: Map.fetch!(before.state, field), else: value

            [
              "<div class=\"meter\"><span class=\"meter-label\">",
              t.(label),
              "</span><span class=\"meter-track\"><span class=\"meter-fill\" style=\"width:",
              to_string(value),
              "%;background:var(",
              color,
              ")\"></span></span><span class=\"meter-value\">",
              to_string(value),
              delta(value - start),
              "</span></div>"
            ]
          end)

        traits = Enum.map(character.traits, &["<li>", esc(t.({:trait, &1})), "</li>"])

        memory_names = &memory_name(result.state, &1)

        {beliefs, memories} =
          result.state
          |> Aethrion.Memories.important(character.id, length(result.state.memories))
          |> Enum.split_with(&(&1.kind == :impression))

        believes =
          beliefs
          |> Enum.take(3)
          |> Enum.map(fn memory ->
            [
              "<li><span class=\"memory-kind\">",
              t.(if(memory.data["event"] == "reputation", do: "reputation", else: "firsthand")),
              "</span>",
              esc(t.({:memory, memory, memory_names})),
              "</li>"
            ]
          end)

        remembered =
          memories
          |> Enum.take(3)
          |> Enum.map(fn memory ->
            [
              "<li><span class=\"memory-kind\">",
              esc(t.({:kind, memory.kind})),
              "</span>",
              esc(t.({:memory, memory, memory_names})),
              "</li>"
            ]
          end)

        [
          "<article class=\"card\"><div class=\"card-head\"><h3>",
          esc(character.name),
          "</h3><span class=\"chip\">",
          esc(t.({:mood, character.state.mood})),
          "</span></div><p class=\"profile\">",
          esc(character.profile),
          "</p>",
          if(traits == [], do: "", else: ["<ul class=\"traits\">", traits, "</ul>"]),
          meters,
          if(remembered == [],
            do: "",
            else: [
              "<p class=\"remembers\">",
              t.("Remembers most"),
              "</p><ul class=\"memories\">",
              remembered,
              "</ul>"
            ]
          ),
          if(believes == [],
            do: "",
            else: [
              "<p class=\"remembers\">",
              t.("Has come to believe"),
              "</p><ul class=\"memories\">",
              believes,
              "</ul>"
            ]
          ),
          if(why == [],
            do: "",
            else: [
              "<details class=\"why\"><summary>",
              t.("Why this mood"),
              "</summary><ul>",
              why,
              "</ul></details>"
            ]
          ),
          "</article>"
        ]
      end)

    [
      "<section><h2>",
      t.("Cast"),
      "</h2><p class=\"note\">",
      t.("Final state, with change since the start."),
      "</p><div class=\"cards\">",
      cards,
      "</div></section>\n"
    ]
  end

  defp feelings(final, snapshots, t) do
    labels = Enum.map(snapshots, &elem(&1, 0))

    legend =
      Enum.map(@metrics, fn {_field, label, color} ->
        [
          "<li><span class=\"key\" style=\"background:var(",
          color,
          ")\"></span>",
          t.(label),
          "</li>"
        ]
      end)

    charts =
      final
      |> State.sorted_characters()
      |> Enum.map(fn character ->
        series =
          Enum.map(@metrics, fn {field, label, color} ->
            values = Enum.map(snapshots, &metric_value(elem(&1, 1), character.id, field))

            %{name: t.(label), color: color, values: values}
          end)

        [
          "<figure class=\"chart\"><figcaption>",
          esc(character.name),
          "</figcaption>",
          line_chart(labels, series, t.({:feelings, character.name})),
          "</figure>"
        ]
      end)

    table_rows =
      final
      |> State.sorted_characters()
      |> Enum.flat_map(fn character ->
        Enum.map(@metrics, fn {field, label, _color} ->
          values = Enum.map(snapshots, &metric_text(elem(&1, 1), character.id, field))

          [
            "<tr><th scope=\"row\">",
            esc(character.name),
            " · ",
            t.(label),
            "</th>",
            Enum.map(values, &["<td>", &1, "</td>"]),
            "</tr>"
          ]
        end)
      end)

    [
      "<section><h2>",
      t.("How they felt"),
      "</h2><p class=\"note\">",
      t.(
        "Each point is the state after a host event, including everything it cascaded into. Scale 0–100."
      ),
      "</p>",
      "<ul class=\"legend\">",
      legend,
      "</ul><div class=\"charts\">",
      charts,
      "</div><details><summary>",
      t.("Table view"),
      "</summary><div class=\"table-wrap\"><table><thead><tr><th></th>",
      Enum.map(labels, &["<th scope=\"col\">", esc(&1), "</th>"]),
      "</tr></thead><tbody>",
      table_rows,
      "</tbody></table></div></details></section>\n"
    ]
  end

  @width 340
  @height 190
  @pad_left 30
  @pad_right 78
  @pad_top 12
  @pad_bottom 26

  # A character missing from a snapshot (added later) reads as 0 on charts
  # and "–" in tables.
  defp metric_value(state, id, field) do
    case State.character(state, id) do
      nil -> 0
      found -> Map.fetch!(found.state, field)
    end
  end

  defp metric_text(state, id, field) do
    case State.character(state, id) do
      nil -> "–"
      found -> to_string(Map.fetch!(found.state, field))
    end
  end

  defp line_chart(labels, series, label) do
    count = length(labels)
    plot_w = @width - @pad_left - @pad_right
    plot_h = @height - @pad_top - @pad_bottom

    x = fn index ->
      if count <= 1,
        do: @pad_left + plot_w / 2,
        else: @pad_left + index * plot_w / (count - 1)
    end

    y = fn value -> @pad_top + plot_h - value * plot_h / 100 end

    grid =
      Enum.map([0, 50, 100], fn value ->
        [
          "<line class=\"",
          if(value == 0, do: "baseline", else: "grid"),
          "\" x1=\"#{@pad_left}\" x2=\"#{@pad_left + plot_w}\" y1=\"#{fmt(y.(value))}\" y2=\"#{fmt(y.(value))}\"/>",
          "<text class=\"axis\" x=\"#{@pad_left - 6}\" y=\"#{fmt(y.(value) + 3.5)}\" text-anchor=\"end\">#{value}</text>"
        ]
      end)

    ticks =
      labels
      |> Enum.with_index()
      |> Enum.filter(fn {_label, index} -> index == 0 or index == count - 1 or count <= 5 end)
      |> Enum.map(fn {label, index} ->
        anchor =
          cond do
            count <= 1 -> "middle"
            index == 0 -> "start"
            index == count - 1 -> "end"
            true -> "middle"
          end

        [
          "<text class=\"axis\" x=\"#{fmt(x.(index))}\" y=\"#{@height - 8}\" text-anchor=\"#{anchor}\">",
          esc(label),
          "</text>"
        ]
      end)

    lines =
      Enum.map(series, fn %{values: values, color: color} ->
        points =
          values
          |> Enum.with_index()
          |> Enum.map_join(" ", fn {value, index} -> "#{fmt(x.(index))},#{fmt(y.(value))}" end)

        dots =
          values
          |> Enum.with_index()
          |> Enum.map(fn {value, index} ->
            "<circle class=\"dot\" cx=\"#{fmt(x.(index))}\" cy=\"#{fmt(y.(value))}\" r=\"3.5\" style=\"fill:var(#{color})\"/>"
          end)

        [
          "<polyline class=\"line\" points=\"",
          points,
          "\" style=\"stroke:var(",
          color,
          ")\"/>",
          dots
        ]
      end)

    end_labels =
      series
      |> Enum.map(fn %{name: name, values: values} -> {name, List.last(values)} end)
      |> spread_labels(y, 11)
      |> Enum.map(fn {name, value, label_y} ->
        [
          "<text class=\"end-label\" x=\"#{fmt(x.(count - 1) + 8)}\" y=\"#{fmt(label_y + 3.5)}\">",
          esc(name),
          " <tspan class=\"end-value\">#{value}</tspan></text>"
        ]
      end)

    data =
      Jason.encode!(%{
        labels: labels,
        series: Enum.map(series, &Map.take(&1, [:name, :color, :values])),
        x: Enum.map(0..max(count - 1, 0), &Float.round(x.(&1) / 1, 2)),
        top: @pad_top,
        bottom: @pad_top + plot_h
      })

    [
      "<svg viewBox=\"0 0 #{@width} #{@height}\" role=\"img\" aria-label=\"",
      esc(label),
      "\" data-chart=\"",
      esc(data),
      "\">",
      grid,
      ticks,
      lines,
      end_labels,
      "<line class=\"crosshair\" x1=\"0\" x2=\"0\" y1=\"#{@pad_top}\" y2=\"#{@pad_top + plot_h}\" visibility=\"hidden\"/>",
      "<rect class=\"hit\" x=\"0\" y=\"0\" width=\"#{@width}\" height=\"#{@height}\" tabindex=\"0\"/>",
      "</svg>"
    ]
  end

  # Pushes end labels apart so they never overlap, keeping them in value order.
  defp spread_labels(items, y, gap) do
    sorted =
      items
      |> Enum.map(fn {name, value} -> {name, value, y.(value)} end)
      |> Enum.sort_by(fn {_name, _value, label_y} -> label_y end)

    {placed, _last} =
      Enum.map_reduce(sorted, nil, fn {name, value, label_y}, last ->
        label_y = if last && label_y < last + gap, do: last + gap, else: label_y
        {{name, value, label_y}, label_y}
      end)

    overflow = max(elem(List.last(placed) || {nil, nil, 0}, 2) - (@height - @pad_bottom), 0)
    Enum.map(placed, fn {name, value, label_y} -> {name, value, label_y - overflow} end)
  end

  defp relationships(initial, final, outputs, t) do
    ids =
      final.relationships
      |> Map.keys()
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.concat(Map.keys(final.characters))
      |> Enum.uniq()

    others = ids |> Enum.reject(&(&1 == "user")) |> Enum.sort()
    nodes = if "user" in ids, do: ["user" | others], else: others
    count = length(nodes)
    {cx, cy, radius} = {280, 205, 150}

    positions =
      nodes
      |> Enum.with_index()
      |> Map.new(fn {id, index} ->
        angle = -:math.pi() / 2 + index * 2 * :math.pi() / max(count, 1)
        {id, {cx + radius * :math.cos(angle), cy + radius * :math.sin(angle)}}
      end)

    edges =
      final.relationships
      |> Map.values()
      |> Enum.sort_by(&{&1.from, &1.to})
      |> Enum.map(fn relationship -> edge(relationship, positions, final, t) end)

    node_marks =
      Enum.map(nodes, fn id ->
        {x, y} = positions[id]
        name = display(final, id, t)

        [
          "<g class=\"node\"><circle cx=\"#{fmt(x)}\" cy=\"#{fmt(y)}\" r=\"30\"/>",
          "<text x=\"#{fmt(x)}\" y=\"#{fmt(y + 4)}\" text-anchor=\"middle\">",
          esc(name),
          "</text></g>"
        ]
      end)

    rows =
      final.relationships
      |> Map.values()
      |> Enum.sort_by(&{&1.from, &1.to})
      |> Enum.map(fn relationship ->
        start = State.get_relationship(initial, relationship.from, relationship.to)

        [
          "<tr><th scope=\"row\">",
          esc(display(final, relationship.from, t)),
          " → ",
          esc(display(final, relationship.to, t)),
          "</th>",
          Enum.map([:affinity, :trust, :tension], fn field ->
            value = Map.fetch!(relationship, field)
            ["<td>", to_string(value), delta(value - Map.fetch!(start, field)), "</td>"]
          end),
          "<td>",
          bond_change(Bond.derive(start, initial), Bond.derive(relationship, final), t),
          "</td></tr>"
        ]
      end)

    [
      "<section><h2>",
      t.("Relationships"),
      "</h2><p class=\"note\">",
      t.(
        "Directed: an arrow from A to B is how A feels about B. Width grows with |affinity|; blue is warm, red is cold; dashed edges carry tension. Hover an edge for its values."
      ),
      "</p>",
      "<div class=\"graph-wrap\"><svg class=\"graph\" viewBox=\"0 0 560 410\" role=\"img\" aria-label=\"",
      t.("Relationship graph"),
      "\">",
      "<defs>",
      marker("arrow-warm", "--edge-warm"),
      marker("arrow-cold", "--edge-cold"),
      "</defs>",
      edges,
      node_marks,
      "</svg></div>",
      "<details><summary>",
      t.("Table view"),
      "</summary><div class=\"table-wrap\"><table><thead><tr><th></th>",
      Enum.map(
        ["Affinity", "Trust", "Tension", "Bond"],
        &["<th scope=\"col\">", t.(&1), "</th>"]
      ),
      "</tr></thead><tbody>",
      rows,
      "</tbody></table></div></details>",
      bond_history(final, outputs, t),
      "</section>\n"
    ]
  end

  # Every relationship whose bond changed, as one line of steps in order.
  defp bond_history(state, outputs, t) do
    changes = Enum.filter(outputs, &(&1.type == :bond_changed))

    lines =
      changes
      |> Enum.group_by(&{&1.from, &1.to})
      |> Enum.sort_by(fn {pair, list} -> {hd(list).event_id |> event_number(), pair} end)
      |> Enum.take(12)
      |> Enum.map(fn {{from, to}, [first | _] = list} ->
        steps =
          Enum.map(list, fn change ->
            [
              " → <strong>",
              esc(t.({:bond, change.after})),
              "</strong> <span class=\"cause\">",
              esc(change.event_id),
              "</span>"
            ]
          end)

        [
          "<li>",
          esc(display(state, from, t)),
          " → ",
          esc(display(state, to, t)),
          ": ",
          esc(t.({:bond, first.before})),
          steps,
          "</li>"
        ]
      end)

    case lines do
      [] ->
        ""

      lines ->
        [
          "<h3 class=\"sub\">",
          t.("Bond changes"),
          "</h3><ul class=\"bond-history\">",
          lines,
          "</ul>"
        ]
    end
  end

  defp event_number("e" <> n) do
    case Integer.parse(n) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp event_number(_id), do: 0

  defp marker(id, color) do
    "<marker id=\"#{id}\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0,1 L9,5 L0,9 z\" style=\"fill:var(#{color})\"/></marker>"
  end

  defp edge(relationship, positions, state, t) do
    {x1, y1} = positions[relationship.from]
    {x2, y2} = positions[relationship.to]
    {dx, dy} = {x2 - x1, y2 - y1}
    length = max(:math.sqrt(dx * dx + dy * dy), 1.0)
    {ux, uy} = {dx / length, dy / length}

    # Start and end on the node rims; bend to the right so A->B and B->A separate.
    {sx, sy} = {x1 + ux * 32, y1 + uy * 32}
    {ex, ey} = {x2 - ux * 36, y2 - uy * 36}
    {mx, my} = {(sx + ex) / 2 - uy * 22, (sy + ey) / 2 + ux * 22}

    warm? = relationship.affinity >= 0
    width = 1.5 + abs(relationship.affinity) / 20

    title =
      "#{display(state, relationship.from, t)} → #{display(state, relationship.to, t)}: " <>
        "#{t.({:bond, Bond.derive(relationship, state)})}; " <>
        t.({:values, relationship.affinity, relationship.trust, relationship.tension})

    [
      "<path class=\"edge",
      if(relationship.tension > 0, do: " tense", else: ""),
      "\" d=\"M#{fmt(sx)},#{fmt(sy)} Q#{fmt(mx)},#{fmt(my)} #{fmt(ex)},#{fmt(ey)}\" ",
      "style=\"stroke:var(#{if warm?, do: "--edge-warm", else: "--edge-cold"});stroke-width:#{fmt(width)}\" ",
      "marker-end=\"url(##{if warm?, do: "arrow-warm", else: "arrow-cold"})\"><title>",
      esc(title),
      "</title></path>"
    ]
  end

  defp timeline(result, t) do
    title = if result.branches == [], do: "Timeline", else: "Shared timeline"

    [
      "<section><h2>",
      t.(title),
      "</h2><p class=\"note\">",
      t.("Host events, the events they cascaded into, and what characters said."),
      "</p>",
      timeline_list(result.steps, t),
      "</section>\n"
    ]
  end

  defp timeline_list(steps, t) do
    items =
      Enum.map(steps, fn step ->
        names = &narrative_name(step.state, &1, t)

        events =
          Enum.map(step.events, fn event ->
            outputs =
              step.outputs
              |> Enum.filter(&(Output.expressive?(&1) and &1.event_id == event.id))
              |> Enum.map(&bubble(&1, step.state, t))

            bonds =
              step.outputs
              |> Enum.filter(&(&1.type == :bond_changed and &1.event_id == event.id))
              |> Enum.map(fn output ->
                [
                  "<p class=\"bond\">",
                  esc(names.(output.from)),
                  " → ",
                  esc(names.(output.to)),
                  ": ",
                  bond_change(output.before, output.after, t),
                  "</p>"
                ]
              end)

            cause =
              if event[:cause],
                do: ["<span class=\"cause\">", esc(t.({:caused_by, event.cause})), "</span>"],
                else: ""

            [
              "<li class=\"",
              if(event[:cause], do: "event cascade", else: "event host"),
              "\"><div class=\"event-line\"><span class=\"event-id\">",
              esc(event.id),
              "</span>",
              esc(capitalize_first(t.({:event, event, names}))),
              cause,
              "</div>",
              outputs,
              bonds,
              "</li>"
            ]
          end)

        [
          "<li class=\"step\"><ol class=\"events\">",
          events,
          "</ol><details><summary>",
          esc(t.({:rule_log, length(step.log)})),
          "</summary><pre>",
          esc(Enum.join(step.log, "\n")),
          "</pre></details></li>"
        ]
      end)

    ["<ol class=\"timeline\">", items, "</ol>"]
  end

  defp branches(%{branches: []}, _t), do: ""

  defp branches(result, t) do
    columns = result.branches

    header =
      Enum.map(columns, fn branch -> ["<th scope=\"col\">", esc(branch.name), "</th>"] end)

    character_rows =
      result.state
      |> State.sorted_characters()
      |> Enum.flat_map(fn character ->
        [
          branch_row("#{character.name} · #{t.("mood")}", columns, fn branch ->
            mood = branch.state |> State.character(character.id) |> then(& &1.state.mood)
            esc(t.({:mood, mood}))
          end)
        ] ++
          Enum.map(@metrics, fn {field, label, _color} ->
            branch_row("#{character.name} · #{String.downcase(t.(label))}", columns, fn branch ->
              value = Map.fetch!(State.character(branch.state, character.id).state, field)
              base = Map.fetch!(character.state, field)
              [to_string(value), delta(value - base)]
            end)
          end) ++
          [
            branch_row("#{character.name} → #{t.("you")} · #{t.("bond")}", columns, fn branch ->
              bond =
                branch.state
                |> State.get_relationship(character.id, "user")
                |> Bond.derive(branch.state)

              esc(t.({:bond, bond}))
            end)
          ] ++
          Enum.map([:affinity, :trust, :tension], fn field ->
            branch_row(
              "#{character.name} → #{t.("you")} · #{t.(Atom.to_string(field))}",
              columns,
              fn branch ->
                value =
                  branch.state
                  |> State.get_relationship(character.id, "user")
                  |> Map.fetch!(field)

                base =
                  result.state
                  |> State.get_relationship(character.id, "user")
                  |> Map.fetch!(field)

                [to_string(value), delta(value - base)]
              end
            )
          end)
      end)

    activity_rows = [
      branch_row(t.("lines to you"), columns, fn branch ->
        branch.outputs |> Enum.count(&(&1.type in [:proactive_message, :reply])) |> to_string()
      end),
      branch_row(t.("scenes between characters"), columns, fn branch ->
        branch.outputs |> Enum.count(&(&1.type == :character_interaction)) |> to_string()
      end)
    ]

    details =
      Enum.map(columns, fn branch ->
        passed = Enum.count(branch.checks, & &1.passed?)

        [
          "<details class=\"branch\"><summary><strong>",
          esc(branch.name),
          "</strong>",
          if(branch.checks == [],
            do: "",
            else: [
              " · ",
              to_string(passed),
              "/",
              to_string(length(branch.checks)),
              " ",
              t.("expectations met")
            ]
          ),
          "</summary>",
          if(branch.description == "",
            do: "",
            else: ["<p class=\"note\">", esc(branch.description), "</p>"]
          ),
          timeline_list(branch.steps, t),
          "</details>"
        ]
      end)

    {varying, same} = Enum.split_with(character_rows, fn {varies?, _row} -> varies? end)

    table_head = [
      "<div class=\"table-wrap\"><table class=\"compare\"><thead><tr><th></th>",
      header,
      "</tr></thead><tbody>"
    ]

    [
      "<section><h2>",
      t.("Branches"),
      "</h2><p class=\"note\">",
      t.(
        "Every branch starts from the end of the shared timeline. Differences come only from the events each branch adds; changes are relative to that shared starting point."
      ),
      "</p>",
      table_head,
      Enum.map(activity_rows, &elem(&1, 1)),
      Enum.map(varying, &elem(&1, 1)),
      "</tbody></table></div>",
      if(same == [],
        do: "",
        else: [
          "<details><summary>",
          esc(t.({:identical, length(same)})),
          "</summary>",
          table_head,
          Enum.map(same, &elem(&1, 1)),
          "</tbody></table></div></details>"
        ]
      ),
      details,
      "</section>\n"
    ]
  end

  defp branch_row(label, columns, cell) do
    values = Enum.map(columns, cell)
    varies? = values |> Enum.map(&IO.iodata_to_binary/1) |> Enum.uniq() |> length() > 1

    {varies?,
     [
       "<tr",
       if(varies?, do: " class=\"varies\"", else: ""),
       "><th scope=\"row\">",
       esc(label),
       "</th>",
       Enum.map(values, &["<td>", &1, "</td>"]),
       "</tr>"
     ]}
  end

  defp localize(result, :en), do: result

  defp localize(result, :ko) do
    lines = fn outputs ->
      Enum.map(outputs, fn
        %{context: %Aethrion.Expression.Request{} = request} = output ->
          output
          |> Map.put(:text, Aethrion.Expression.Templates.Ko.render(request))
          |> Map.put(:lang, "ko")

        output ->
          output
      end)
    end

    steps = fn steps -> Enum.map(steps, &%{&1 | outputs: lines.(&1.outputs)}) end

    %{
      result
      | steps: steps.(result.steps),
        outputs: lines.(result.outputs),
        branches:
          Enum.map(result.branches, &%{&1 | steps: steps.(&1.steps), outputs: lines.(&1.outputs)})
    }
  end

  defp bond_change(same, same, t), do: esc(t.({:bond, same}))

  defp bond_change(before, after_bond, t),
    do: [esc(t.({:bond, before})), " → <strong>", esc(t.({:bond, after_bond})), "</strong>"]

  defp bubble(output, state, t) do
    {speaker, listener, tag} =
      case output do
        %{type: :character_interaction, kind: kind, character_id: id, to: to} ->
          {id, to, t.({:tag, :scene, kind})}

        %{type: :proactive_message, character_id: id, to: to, reason: reason} ->
          {id, to, t.({:tag, :reaches_out, reason})}

        %{type: :reply, character_id: id, to: to, tone: tone} ->
          {id, to, t.({:tag, :reply, tone})}
      end

    scene? = output.type == :character_interaction

    [
      "<figure class=\"bubble",
      if(scene?, do: " scene", else: ""),
      "\"><figcaption><strong>",
      esc(display(state, speaker, t)),
      "</strong>",
      if(scene?, do: "", else: [" → ", esc(display(state, listener, t))]),
      "<span class=\"tag\">",
      esc(tag),
      "</span></figcaption><blockquote",
      if(output[:lang], do: [" lang=\"", output.lang, "\""], else: ""),
      ">",
      esc(output.text),
      "</blockquote></figure>"
    ]
  end

  defp checks(result, t) do
    case Scenario.all_checks(result) do
      [] -> ""
      checks -> render_checks(checks, t)
    end
  end

  defp render_checks(checks, t) do
    items =
      Enum.map(checks, fn check ->
        [
          "<li class=\"",
          if(check.passed?, do: "pass", else: "fail"),
          "\"><span class=\"status\">",
          t.(if(check.passed?, do: "✓ pass", else: "✕ fail")),
          "</span>",
          if(check.branch,
            do: ["<span class=\"branch-tag\">", esc(check.branch), "</span>"],
            else: ""
          ),
          "<code>",
          esc(check.description),
          "</code>",
          if(check.passed?,
            do: "",
            else: [
              "<span class=\"actual\">",
              t.("actual: "),
              esc(inspect(check.actual)),
              "</span>"
            ]
          ),
          "</li>"
        ]
      end)

    [
      "<section><h2>",
      t.("Expectations"),
      "</h2><ul class=\"checks\">",
      items,
      "</ul></section>\n"
    ]
  end

  ## Language

  @doc false
  def supported_locale!(locale) when locale in [:en, :ko], do: locale

  def supported_locale!(locale),
    do: raise(ArgumentError, "unsupported locale #{inspect(locale)}; use :en or :ko")

  # Everything the report says in its own voice, by locale. Strings are the
  # English text; tuples are phrases with values in them.
  defp translator(:ko), do: &korean/1
  defp translator(_en), do: &english/1

  defp english({:footer, version}),
    do:
      "Generated by Aethrion #{version}. Rules are deterministic: the same scenario always produces this report."

  defp english({:focus, total, shown}),
    do:
      "This world has #{total} characters. The cast, charts, relationships, and branch table show the #{shown} most active; the timeline shows everyone."

  defp english({:feelings, name}), do: "#{name}: feelings over time"
  defp english({:values, a, t, x}), do: "affinity #{a}, trust #{t}, tension #{x}"
  defp english({:caused_by, id}), do: "caused by #{id}"
  defp english({:event, event, names}), do: Event.describe(event, names)
  defp english({:memory, memory, _names}), do: memory.content
  defp english({:short_label, event}), do: short_label(event)
  defp english({:why, change, names}), do: [change] |> Aethrion.Explain.describe(names) |> hd()
  defp english({:rule_log, count}), do: "Rule log (#{count} lines)"
  defp english({:identical, count}), do: "#{count} values identical in every branch"
  defp english({:tag, :scene, kind}), do: "scene · #{kind}"
  defp english({:tag, :reaches_out, reason}), do: "reaches out · #{reason}"
  defp english({:tag, :reply, tone}), do: "reply to #{tone}"
  defp english({_kind, value}), do: to_string(value)
  defp english(text) when is_binary(text), do: text

  @korean %{
    "Aethrion scenario report" => "Aethrion 시나리오 리포트",
    "host events" => "호스트 이벤트",
    "events processed" => "처리된 이벤트",
    "lines & scenes" => "대사와 장면",
    "branches" => "분기",
    "expectations met" => "통과한 검증 항목",
    "Tuned rules" => "조정한 규칙",
    "In short" => "요약",
    "Cast" => "등장인물",
    "Final state, with change since the start." => "최종 상태와 시작 이후의 변화입니다.",
    "Loneliness" => "외로움",
    "Jealousy" => "질투",
    "Joy" => "기쁨",
    "Stress" => "스트레스",
    "Remembers most" => "가장 크게 기억하는 것",
    "Has come to believe" => "굳어진 생각",
    "Why this mood" => "이 기분인 이유",
    "firsthand" => "직접",
    "reputation" => "평판",
    "How they felt" => "감정의 흐름",
    "Each point is the state after a host event, including everything it cascaded into. Scale 0–100." =>
      "각 점은 호스트 이벤트와 그로부터 이어진 모든 일이 끝난 뒤의 상태입니다. 0–100 척도.",
    "Table view" => "표로 보기",
    "Relationships" => "관계",
    "Directed: an arrow from A to B is how A feels about B. Width grows with |affinity|; blue is warm, red is cold; dashed edges carry tension. Hover an edge for its values." =>
      "방향이 있습니다. A에서 B로 향하는 화살표는 A가 B를 어떻게 느끼는지입니다. 호감의 크기만큼 굵어지고, 파랑은 따뜻함, 빨강은 차가움, 점선은 긴장입니다. 선에 마우스를 올리면 값이 보입니다.",
    "Relationship graph" => "관계 그래프",
    "Affinity" => "호감",
    "Trust" => "신뢰",
    "Tension" => "긴장",
    "Bond" => "관계 단계",
    "Bond changes" => "관계 단계 변화",
    "Timeline" => "타임라인",
    "Shared timeline" => "공통 타임라인",
    "Host events, the events they cascaded into, and what characters said." =>
      "호스트 이벤트와 그로부터 이어진 이벤트, 그리고 캐릭터들이 한 말입니다.",
    "Branches" => "분기",
    "Every branch starts from the end of the shared timeline. Differences come only from the events each branch adds; changes are relative to that shared starting point." =>
      "모든 분기는 공통 타임라인이 끝난 지점에서 시작합니다. 차이는 각 분기가 더한 이벤트에서만 생기며, 변화량은 그 공통 시작점을 기준으로 합니다.",
    "mood" => "기분",
    "bond" => "관계 단계",
    "affinity" => "호감",
    "trust" => "신뢰",
    "tension" => "긴장",
    "you" => "너",
    "You" => "너",
    "the user" => "너",
    "lines to you" => "너에게 한 말",
    "scenes between characters" => "캐릭터끼리의 장면",
    "Expectations" => "검증 항목",
    "start" => "시작",
    "✓ pass" => "✓ 통과",
    "✕ fail" => "✕ 실패",
    "actual: " => "실제: "
  }

  @korean_values %{
    mood: %{neutral: "평온", happy: "행복", lonely: "외로움", jealous: "질투", upset: "속상함"},
    bond: %{
      estranged: "틀어진 사이",
      strained: "서먹한 사이",
      neutral: "보통 사이",
      friendly: "편한 사이",
      close: "아주 가까운 사이"
    },
    kind: %{experienced: "직접", observed: "목격", heard: "전해 들음", impression: "인상"},
    scene: %{gossip: "털어놓기", comfort: "위로", together: "함께"},
    reaches_out: %{jealous: "질투", lonely: "외로움", curious: "궁금함", protective: "편들기"},
    reply: %{
      warm: "다정한 말",
      neutral: "평범한 말",
      cold: "차가운 말",
      hostile: "모진 말",
      apology: "사과",
      gift: "선물"
    },
    trait: %{
      sensitive: "예민함",
      calm: "차분함",
      playful: "장난스러움",
      talkative: "수다스러움",
      warm: "다정함",
      romantic: "낭만적",
      observant: "눈썰미",
      curious: "호기심"
    },
    rule: %{mood: "기분"},
    event: %{
      gift_received: "선물",
      message_sent: "메시지",
      apology_offered: "사과",
      gossip_shared: "이야기",
      comfort_offered: "위로",
      time_spent_together: "함께"
    }
  }

  defp korean({:footer, version}),
    do: "Aethrion #{version} 버전으로 생성했습니다. 규칙은 결정론적이라 같은 시나리오는 언제나 이 리포트를 만듭니다."

  defp korean({:short_label, %{type: :time_tick, hours: hours, id: id}}), do: "#{id} +#{hours}시간"
  defp korean({:short_label, %{type: type, id: id}}), do: "#{id} #{korean_value(:event, type)}"

  defp korean({:focus, total, shown}),
    do:
      "이 세계에는 캐릭터가 #{total}명 있습니다. 등장인물, 차트, 관계, 분기 표는 가장 활발한 #{shown}명만 보여 주고, 타임라인은 모두를 보여 줍니다."

  defp korean({:feelings, name}), do: "#{name}: 시간에 따른 감정"
  defp korean({:values, a, t, x}), do: "호감 #{a}, 신뢰 #{t}, 긴장 #{x}"
  defp korean({:caused_by, id}), do: "원인: #{id}"

  defp korean({:memory, memory, names}),
    do: Aethrion.Expression.Templates.Ko.describe_memory(memory, names)

  defp korean({:event, event, names}),
    do: Aethrion.Expression.Templates.Ko.describe_event(event, names)

  defp korean({:rule_log, count}), do: "규칙 로그 (#{count}줄)"

  defp korean({:why, change, names}) do
    chain =
      Enum.map_join(
        change.chain,
        " ← ",
        &Aethrion.Expression.Templates.Ko.describe_event(&1, names)
      )

    "#{korean_value(:mood, change.before)} → #{korean_value(:mood, change.after)} " <>
      "(#{korean_value(:rule, change.rule)} 규칙, #{change.event_id}: #{chain})"
  end

  defp korean({:identical, count}), do: "모든 분기에서 같은 값 #{count}개"
  defp korean({:tag, :scene, kind}), do: "장면 · #{korean_value(:scene, kind)}"
  defp korean({:tag, :reaches_out, reason}), do: "먼저 연락 · #{korean_value(:reaches_out, reason)}"
  defp korean({:tag, :reply, tone}), do: "#{korean_value(:reply, tone)}에 대한 답장"
  defp korean({kind, value}) when is_map_key(@korean_values, kind), do: korean_value(kind, value)
  defp korean({_kind, value}), do: to_string(value)
  defp korean(text) when is_binary(text), do: Map.get(@korean, text, text)

  # Traits read from untrusted data may stay strings, so match by name too.
  defp korean_value(kind, value) do
    values = Map.fetch!(@korean_values, kind)

    Map.get_lazy(values, value, fn ->
      Enum.find_value(values, to_string(value), fn {key, text} ->
        if Atom.to_string(key) == to_string(value), do: text
      end)
    end)
  end

  ## Helpers

  defp short_label(%{type: :time_tick, hours: hours, id: id}), do: "#{id} +#{hours}h"

  defp short_label(%{type: type, id: id}),
    do: "#{id} #{type |> to_string() |> String.split("_") |> hd()}"

  # Names inside sentences ("the user gives Mina a flower").
  # Memory lines in Korean speak to the user, as the character lines do.
  defp memory_name(_state, "user"), do: "너"
  defp memory_name(state, id), do: State.name(state, id)

  defp narrative_name(_state, "user", t), do: t.("the user")
  defp narrative_name(state, id, _t), do: State.name(state, id)

  defp display(_state, "user", t), do: t.("You")
  defp display(state, id, _t), do: State.name(state, id)

  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize_first(text), do: text

  defp delta(0), do: ""
  defp delta(value) when value > 0, do: ["<span class=\"delta\"> +", to_string(value), "</span>"]
  defp delta(value), do: ["<span class=\"delta\"> ", to_string(value), "</span>"]

  defp fmt(number) when is_integer(number), do: Integer.to_string(number)
  defp fmt(number), do: :erlang.float_to_binary(number / 1, decimals: 1)

  defp esc(value) when is_atom(value), do: value |> Atom.to_string() |> esc()
  defp esc(value) when is_integer(value), do: Integer.to_string(value)

  defp esc(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp esc(value), do: value |> inspect() |> esc()

  defp version do
    case :application.get_key(:aethrion, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "dev"
    end
  end

  defp css do
    """
    :root{color-scheme:light}
    .viz-root,body{
      --page:#f9f9f7;--surface-1:#fcfcfb;--text-primary:#0b0b0b;--text-secondary:#52514e;--text-muted:#898781;
      --grid:#e1e0d9;--axis:#c3c2b7;--border:rgba(11,11,11,.10);--chip:#f0efec;
      --series-1:#2a78d6;--series-2:#eb6834;--series-3:#1baf7a;--series-4:#eda100;
      --edge-warm:#2a78d6;--edge-cold:#e34948;--good:#006300;--bad:#d03b3b;
    }
    @media (prefers-color-scheme:dark){
      :root:where(:not([data-theme="light"])){color-scheme:dark}
      :root:where(:not([data-theme="light"])) body,:root:where(:not([data-theme="light"])) .viz-root{
        --page:#0d0d0d;--surface-1:#1a1a19;--text-primary:#ffffff;--text-secondary:#c3c2b7;--text-muted:#898781;
        --grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,.10);--chip:#2c2c2a;
        --series-1:#3987e5;--series-2:#d95926;--series-3:#199e70;--series-4:#c98500;
        --edge-warm:#3987e5;--edge-cold:#e66767;--good:#0ca30c;--bad:#e66767;
      }
    }
    :root[data-theme="dark"]{color-scheme:dark}
    :root[data-theme="dark"] body,:root[data-theme="dark"] .viz-root{
      --page:#0d0d0d;--surface-1:#1a1a19;--text-primary:#ffffff;--text-secondary:#c3c2b7;--text-muted:#898781;
      --grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,.10);--chip:#2c2c2a;
      --series-1:#3987e5;--series-2:#d95926;--series-3:#199e70;--series-4:#c98500;
      --edge-warm:#3987e5;--edge-cold:#e66767;--good:#0ca30c;--bad:#e66767;
    }
    *{box-sizing:border-box}
    body{margin:0;background:var(--page);color:var(--text-primary);font:15px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;font-variant-numeric:tabular-nums}
    main{max-width:1080px;margin:0 auto;padding:40px 16px 64px}
    h1{font-size:34px;line-height:1.15;margin:4px 0 10px;letter-spacing:-.01em}
    h2{font-size:20px;margin:0 0 4px}
    h3{font-size:16px;margin:0}
    section{margin-top:44px}
    .eyebrow{margin:0;color:var(--text-muted);font-size:13px;text-transform:uppercase;letter-spacing:.08em}
    .lede{max-width:72ch;color:var(--text-secondary);margin:0}
    .note{color:var(--text-secondary);margin:0 0 16px;font-size:14px;max-width:80ch}
    .focus-note{margin-top:24px}
    .tuning{margin-top:16px;display:flex;flex-wrap:wrap;gap:8px;align-items:baseline;font-size:13px;color:var(--text-secondary)}
    .tuning ul{display:flex;flex-wrap:wrap;gap:6px;list-style:none;margin:0;padding:0}
    .tuning code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--chip);border-radius:6px;padding:2px 6px}
    .stats{display:flex;flex-wrap:wrap;gap:12px;margin:24px 0 0;padding:0}
    .stats div{background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:12px 16px;min-width:140px}
    .stats dt{color:var(--text-secondary);font-size:13px}
    .stats dd{margin:2px 0 0;font-size:26px;font-weight:650}
    .cards,.charts{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}
    .card,.chart,.graph-wrap,.step{background:var(--surface-1);border:1px solid var(--border);border-radius:14px}
    .card{padding:16px}
    .card-head{display:flex;align-items:center;justify-content:space-between;gap:8px}
    .chip{background:var(--chip);color:var(--text-secondary);border-radius:999px;padding:2px 10px;font-size:13px}
    .profile{color:var(--text-secondary);font-size:14px;margin:8px 0}
    .traits{display:flex;flex-wrap:wrap;gap:6px;list-style:none;padding:0;margin:0 0 12px}
    .traits li{font-size:12px;color:var(--text-muted);border:1px solid var(--border);border-radius:6px;padding:0 6px}
    .meter{display:grid;grid-template-columns:84px 1fr 64px;align-items:center;gap:8px;font-size:13px;margin-top:6px}
    .meter-label{color:var(--text-secondary)}
    .meter-track{height:8px;background:var(--chip);border-radius:4px;overflow:hidden}
    .meter-fill{display:block;height:100%;border-radius:4px}
    .meter-value{text-align:right}
    .why{margin-top:12px;font-size:13px}
    .why ul{margin:6px 0 0;padding-left:18px;color:var(--text-secondary)}
    .why li{margin:3px 0}
    .bond{margin:6px 0 0;font-size:13px;color:var(--text-secondary)}
    .sub{margin:20px 0 6px;font-size:15px}
    .digest{margin:0;padding-left:18px;max-width:80ch}
    .digest li{margin:4px 0}
    .digest li.bond,.digest li.mood{color:var(--text-secondary)}
    .bond-history{margin:0;padding-left:18px;font-size:14px;color:var(--text-secondary)}
    .bond-history li{margin:3px 0}
    .bond-history strong{color:var(--text-primary)}
    .bond strong{color:var(--text-primary)}
    .remembers{margin:14px 0 6px;font-size:12px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.06em}
    .memories{list-style:none;padding:0;margin:0;display:grid;gap:6px;font-size:13px;color:var(--text-secondary)}
    .memory-kind{display:inline-block;min-width:74px;font-size:11px;color:var(--text-muted)}
    .delta{color:var(--text-muted);font-size:12px}
    .legend{display:flex;flex-wrap:wrap;gap:16px;list-style:none;padding:0;margin:0 0 12px;font-size:13px;color:var(--text-secondary)}
    .legend .key{display:inline-block;width:14px;height:2px;border-radius:1px;vertical-align:middle;margin-right:6px}
    .chart{margin:0;padding:12px 12px 4px}
    .chart figcaption{font-weight:600;margin-bottom:4px}
    svg{display:block;width:100%;height:auto;overflow:visible}
    .grid{stroke:var(--grid);stroke-width:1}
    .baseline{stroke:var(--axis);stroke-width:1}
    .axis{fill:var(--text-muted);font-size:10px}
    .line{fill:none;stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
    .dot{stroke:var(--surface-1);stroke-width:2}
    .end-label{fill:var(--text-secondary);font-size:10.5px}
    .end-value{fill:var(--text-primary);font-weight:600}
    .crosshair{stroke:var(--text-muted);stroke-width:1}
    .hit{fill:transparent;cursor:crosshair;outline:none}
    .hit:focus-visible{stroke:var(--text-muted);stroke-dasharray:3 3}
    .graph-wrap{padding:8px}
    .graph{max-width:640px;margin:0 auto}
    .edge{fill:none;opacity:.85}
    .edge:hover{opacity:1}
    .edge.tense{stroke-dasharray:6 4}
    .node circle{fill:var(--surface-1);stroke:var(--axis);stroke-width:2}
    .node text{fill:var(--text-primary);font-size:13px;font-weight:600}
    details{margin-top:12px;font-size:14px}
    summary{cursor:pointer;color:var(--text-secondary)}
    .table-wrap{overflow-x:auto;margin-top:8px}
    table{border-collapse:collapse;font-size:13px;min-width:100%}
    th,td{padding:6px 10px;border-bottom:1px solid var(--grid);text-align:right;white-space:nowrap}
    th[scope=row]{text-align:left;color:var(--text-secondary);font-weight:500}
    thead th{color:var(--text-muted);font-weight:500}
    .timeline{list-style:none;padding:0;margin:0;display:grid;gap:14px}
    .step{padding:14px 16px}
    .events{list-style:none;padding:0;margin:0;display:grid;gap:10px}
    .event.cascade{margin-left:22px;padding-left:14px;border-left:2px solid var(--grid)}
    .event-line{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px}
    .event.host .event-line{font-weight:600}
    .event-id{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text-muted)}
    .cause{font-size:12px;color:var(--text-muted)}
    .bubble{margin:8px 0 0;padding:10px 14px;border-radius:12px;background:var(--chip);max-width:640px}
    .bubble.scene{background:transparent;border:1px dashed var(--axis)}
    .bubble figcaption{font-size:13px;color:var(--text-secondary);display:flex;flex-wrap:wrap;gap:6px;align-items:baseline}
    .bubble strong{color:var(--text-primary)}
    .tag{font-size:12px;color:var(--text-muted)}
    .bubble blockquote{margin:4px 0 0;font-size:15px}
    .bubble.scene blockquote{font-style:italic;color:var(--text-secondary)}
    pre{white-space:pre-wrap;font:12px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text-secondary);background:var(--page);border-radius:8px;padding:10px;margin:8px 0 0}
    .checks{list-style:none;padding:0;margin:0;display:grid;gap:6px}
    .checks li{display:flex;flex-wrap:wrap;gap:10px;align-items:baseline;background:var(--surface-1);border:1px solid var(--border);border-radius:10px;padding:8px 12px}
    .checks .status{font-size:13px;font-weight:600;min-width:56px}
    .checks .pass .status{color:var(--good)}
    .checks .fail .status{color:var(--bad)}
    .checks code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace}
    .actual{color:var(--text-muted);font-size:13px}
    .branch-tag{font-size:12px;color:var(--text-secondary);background:var(--chip);border-radius:6px;padding:1px 6px}
    .compare td,.compare th{text-align:right}
    .compare th[scope=row]{text-align:left}
    .compare thead th{color:var(--text-primary);font-weight:600}
    .compare tr.varies th[scope=row]{color:var(--text-primary);font-weight:600}
    .compare tr:not(.varies) td{color:var(--text-muted)}
    details.branch{background:var(--surface-1);border:1px solid var(--border);border-radius:14px;padding:12px 16px;margin-top:12px}
    details.branch > summary{font-size:15px;color:var(--text-primary)}
    details.branch .timeline{margin-top:12px}
    footer{margin-top:48px;color:var(--text-muted);font-size:13px}
    .tooltip{position:fixed;pointer-events:none;background:var(--surface-1);color:var(--text-primary);border:1px solid var(--border);border-radius:10px;padding:8px 10px;font-size:12px;box-shadow:0 6px 20px rgba(0,0,0,.15);z-index:10;min-width:150px}
    .tooltip .tt-title{color:var(--text-muted);margin-bottom:4px}
    .tooltip .tt-row{display:flex;align-items:center;gap:8px}
    .tooltip .tt-key{width:12px;height:2px;border-radius:1px}
    .tooltip .tt-value{font-weight:650;min-width:24px}
    .tooltip .tt-name{color:var(--text-secondary)}
    @media (max-width:520px){h1{font-size:28px}.stats div{min-width:calc(50% - 6px)}}
    """
  end

  defp script do
    """
    (() => {
      const tip = document.querySelector('.tooltip');
      const show = (svg, index, clientX, clientY) => {
        const data = JSON.parse(svg.dataset.chart);
        const hair = svg.querySelector('.crosshair');
        const x = data.x[index];
        hair.setAttribute('x1', x); hair.setAttribute('x2', x); hair.setAttribute('visibility', 'visible');
        tip.replaceChildren();
        const title = document.createElement('div');
        title.className = 'tt-title';
        title.textContent = svg.closest('figure').querySelector('figcaption').textContent + ' · ' + data.labels[index];
        tip.appendChild(title);
        for (const s of data.series) {
          const row = document.createElement('div'); row.className = 'tt-row';
          const key = document.createElement('span'); key.className = 'tt-key';
          key.style.background = 'var(' + s.color + ')';
          const value = document.createElement('span'); value.className = 'tt-value'; value.textContent = s.values[index];
          const name = document.createElement('span'); name.className = 'tt-name'; name.textContent = s.name;
          row.append(key, value, name); tip.appendChild(row);
        }
        tip.hidden = false;
        const box = tip.getBoundingClientRect();
        const left = Math.min(clientX + 14, window.innerWidth - box.width - 8);
        const top = Math.min(clientY + 14, window.innerHeight - box.height - 8);
        tip.style.left = Math.max(8, left) + 'px'; tip.style.top = Math.max(8, top) + 'px';
      };
      const hide = (svg) => { svg.querySelector('.crosshair').setAttribute('visibility', 'hidden'); tip.hidden = true; };
      for (const svg of document.querySelectorAll('svg[data-chart]')) {
        const hit = svg.querySelector('.hit');
        const data = JSON.parse(svg.dataset.chart);
        let current = data.x.length - 1;
        const nearest = (event) => {
          const point = svg.createSVGPoint(); point.x = event.clientX; point.y = event.clientY;
          const local = point.matrixTransform(svg.getScreenCTM().inverse());
          let best = 0;
          data.x.forEach((x, i) => { if (Math.abs(x - local.x) < Math.abs(data.x[best] - local.x)) best = i; });
          return best;
        };
        hit.addEventListener('pointermove', (e) => { current = nearest(e); show(svg, current, e.clientX, e.clientY); });
        hit.addEventListener('pointerleave', () => hide(svg));
        hit.addEventListener('blur', () => hide(svg));
        hit.addEventListener('keydown', (e) => {
          if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
          e.preventDefault();
          current = Math.max(0, Math.min(data.x.length - 1, current + (e.key === 'ArrowRight' ? 1 : -1)));
          const rect = svg.getBoundingClientRect();
          show(svg, current, rect.left + rect.width * data.x[current] / svg.viewBox.baseVal.width, rect.top + 20);
        });
        hit.addEventListener('focus', () => {
          const rect = svg.getBoundingClientRect();
          show(svg, current, rect.left + rect.width * data.x[current] / svg.viewBox.baseVal.width, rect.top + 20);
        });
      }
    })();
    """
  end
end
