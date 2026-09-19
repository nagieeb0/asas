defmodule Asas.Digits do
  @moduledoc """
  Arabic-Indic digits ⇄ Latin digits. Two directions, two different jobs.

  `latin/1` runs on the way **in** and is a correctness fix. An Arabic Android
  keyboard emits U+0660–U+0669 from its numeric row, and `inputmode="numeric"`
  is a hint to the keyboard, not a coercion of what it produces. Everything
  downstream then fails silently:

      Decimal.parse("٩٩")            #=> :error
      Integer.parse("٩٩")            #=> :error
      Ecto.Type.cast(:decimal, "٩٩") #=> :error
      Money.new(:EGP, "٩٩")          #=> {:error, …}

  So an owner pricing a menu gets a validation error on every row, and a
  customer typing a six-digit OTP is told the code is wrong. Run it on raw
  params before casting — that is the one place it covers all of it.

  `ar/1` runs on the way **out** and is presentation only. Never store its
  output and never send it anywhere: `Q-٢٠٢٦-٠٠٠١` matches `Q-2026-0001` in no
  search box on earth. Identifiers, emails, URLs and phone numbers stay Latin.

      iex> Asas.Digits.latin("٠٥٥١٢٣٤٥٦٧")
      "0551234567"

      iex> Asas.Digits.ar("3,450.00")
      "٣,٤٥٠.٠٠"
  """

  # Arabic-Indic (U+0660–), Extended Arabic-Indic (U+06F0–, what a Persian/Urdu
  # layout emits — common on handsets sold in Egypt), the Arabic decimal and
  # thousands separators, and the bidi marks that ride along when a number is
  # copied out of an RTL page.
  @to_latin %{
    "٠" => "0",
    "١" => "1",
    "٢" => "2",
    "٣" => "3",
    "٤" => "4",
    "٥" => "5",
    "٦" => "6",
    "٧" => "7",
    "٨" => "8",
    "٩" => "9",
    "۰" => "0",
    "۱" => "1",
    "۲" => "2",
    "۳" => "3",
    "۴" => "4",
    "۵" => "5",
    "۶" => "6",
    "۷" => "7",
    "۸" => "8",
    "۹" => "9",
    "\u066B" => ".",
    "\u066C" => ",",
    "\u200E" => "",
    "\u200F" => "",
    "\u061C" => "",
    "\u202A" => "",
    "\u202B" => "",
    "\u202C" => "",
    "\u2066" => "",
    "\u2067" => "",
    "\u2068" => "",
    "\u2069" => ""
  }

  @to_ar %{
    "0" => "٠",
    "1" => "١",
    "2" => "٢",
    "3" => "٣",
    "4" => "٤",
    "5" => "٥",
    "6" => "٦",
    "7" => "٧",
    "8" => "٨",
    "9" => "٩"
  }

  @doc "Folds every Arabic/Persian digit and separator to its ASCII counterpart. Letters untouched."
  @spec latin(binary | number | nil) :: binary
  def latin(nil), do: ""
  def latin(value), do: map_graphemes(value, @to_latin)

  @doc "ASCII digits become Arabic-Indic. Punctuation is left alone — see the moduledoc."
  @spec ar(binary | number | nil) :: binary
  def ar(nil), do: ""
  def ar(value), do: map_graphemes(value, @to_ar)

  @doc """
  `latin/1` applied to every string leaf of a params map, in place.

  This is the call site that matters: one plug or one `handle_event` head
  covers every form in the app, instead of remembering `latin/1` per field.
  """
  @spec normalize_params(term) :: term
  def normalize_params(value) when is_binary(value), do: latin(value)
  def normalize_params(list) when is_list(list), do: Enum.map(list, &normalize_params/1)

  def normalize_params(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, normalize_params(v)} end)
  end

  def normalize_params(other), do: other

  # A table lookup per grapheme, not codepoint arithmetic: the two ranges are not
  # contiguous, and this also has to run client-side under LiveView's Elixir subset.
  defp map_graphemes(value, table) do
    value
    |> to_string()
    |> String.graphemes()
    |> Enum.map_join("", &Map.get(table, &1, &1))
  end
end
