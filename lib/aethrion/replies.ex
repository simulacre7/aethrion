defmodule Aethrion.Replies do
  @moduledoc """
  Reply choices for a messenger-style chat: after a character says
  something, two or three things the person might answer, each with the
  tone it carries (`:warm`, `:neutral`, `:cold`), the way a messenger game
  offers a few replies instead of a keyboard.

  The choices follow what is going on: in a fight, words for the fight;
  otherwise what the character last said: a question gets answers
  ("응, 좋아! 같이 하자." / "일정 보고 알려 줄게." / "그건 좀 어려울 것 같아."),
  a character who is upset or lonely gets comfort or distance, and anything
  else gets a reaction. Unlike in many games the choice matters: sent with
  its tone (`Aethrion.Event.message_sent/4`), it moves the relationship like
  any message. The same conversation always offers the same choices.
  """

  alias Aethrion.{Conversation, State}
  alias Aethrion.Rules.Mood

  @type choice :: %{text: String.t(), tone: :warm | :neutral | :cold}

  @doc "The replies `person` might send `character` now, in `:ko` or `:en`."
  @spec suggest(State.t(), String.t(), String.t(), :ko | :en) :: [choice()]
  def suggest(%State{} = state, character, person \\ "user", locale \\ :ko) do
    turns = Conversation.recent(state, character, person)
    last = turns |> Enum.filter(&(&1.from == character and &1.kind != :deed)) |> List.last()

    situation =
      cond do
        Aethrion.Combat.foe(state) != nil and not Aethrion.Combat.over?(state) -> :fight
        last == nil -> :hello
        String.contains?(last.text, "?") -> :question
        mood(state, character) in [:upset, :lonely, :jealous] -> :troubled
        true -> :reaction
      end

    # Two wordings of each, turning with the conversation, so the same
    # buttons do not repeat every time.
    variant = rem(length(turns), 2)

    for {tone, lines} <- lines(locale, situation),
        do: %{tone: tone, text: Enum.at(lines, variant)}
  end

  defp mood(state, id) do
    case State.character(state, id) do
      nil -> :neutral
      character -> Mood.derive(character.state, state)
    end
  end

  defp lines(:ko, :fight),
    do: [
      warm: ["조심해! 내가 엄호할게.", "같이 버티자. 거의 다 왔어."],
      neutral: ["왼쪽을 맡아 줘.", "상황 보고 움직이자."],
      cold: ["알아서 버텨.", "네 몫은 네가 해."]
    ]

  defp lines(:en, :fight),
    do: [
      warm: ["Careful! I've got your back.", "Hold on, we're almost there."],
      neutral: ["Take the left.", "Watch and move with me."],
      cold: ["Hold your own.", "Pull your weight."]
    ]

  defp lines(:ko, :hello),
    do: [
      warm: ["안녕! 오늘 하루는 어땠어?", "보고 싶었어. 잘 지냈어?"],
      neutral: ["안녕, 뭐 하고 있었어?", "잠깐 얘기할 수 있어?"],
      cold: ["할 얘기가 있어서.", "용건만 말할게."]
    ]

  defp lines(:ko, :question),
    do: [
      warm: ["응, 좋아! 같이 하자.", "물론이지. 언제든 불러."],
      neutral: ["일정 보고 알려 줄게.", "음, 생각해 볼게."],
      cold: ["그건 좀 어려울 것 같아.", "지금은 안 돼."]
    ]

  defp lines(:ko, :troubled),
    do: [
      warm: ["무슨 일 있어? 얘기해 줄래?", "괜찮아, 내가 옆에 있을게."],
      neutral: ["그랬구나.", "그런 일이 있었구나."],
      cold: ["나중에 얘기하자.", "알아서 잘 해결해."]
    ]

  defp lines(:ko, :reaction),
    do: [
      warm: ["고마워, 덕분에 힘이 난다.", "역시 대단하다!"],
      neutral: ["그래, 알았어.", "오, 그렇구나."],
      cold: ["응.", "그래서?"]
    ]

  defp lines(:en, :hello),
    do: [
      warm: ["Hi! How was your day?", "I missed you. How have you been?"],
      neutral: ["Hey, what are you up to?", "Got a minute to talk?"],
      cold: ["I need to tell you something.", "I'll keep this short."]
    ]

  defp lines(:en, :question),
    do: [
      warm: ["Sure, I'd love to!", "Of course. Anytime."],
      neutral: ["Let me check and get back to you.", "Hmm, I'll think about it."],
      cold: ["That won't work for me.", "Not now."]
    ]

  defp lines(:en, :troubled),
    do: [
      warm: ["What happened? Want to talk?", "It's okay, I'm here."],
      neutral: ["I see.", "That happened, huh."],
      cold: ["Let's talk later.", "You'll figure it out."]
    ]

  defp lines(:en, :reaction),
    do: [
      warm: ["Thanks, that made my day.", "That's amazing!"],
      neutral: ["Okay, got it.", "Oh, I see."],
      cold: ["Okay.", "So?"]
    ]
end
