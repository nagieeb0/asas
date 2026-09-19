defmodule Asas.Phone do
  @moduledoc """
  A typed mobile number to E.164, or `:error`. Egypt and Saudi Arabia.

  ## Why this is strict rather than forgiving

  The phone number is the account's identity: the sign-in credential, the
  customer's key at checkout, the loyalty card's account number. Two spellings
  of one number that both survive normalisation are two accounts for one
  person — his history splits, his subscription is on one and his data on the
  other, and the free allowance he already spent is refilled. So: exactly one
  canonical string per real number, and refuse anything unrecognised. Refusing
  is cheap, he retypes. Accepting a near-miss is permanent.

  The other half of strictness is the OTP. An unrecognised number accepted
  anyway is a code sent into the void — no error, no delivery, and someone
  staring at a code box that can never be satisfied. He cannot tell that apart
  from "the SMS is slow".

  ## Strict about SHAPE, never about the operator

  An earlier version of this checked the operator digit too (`5[0356789]` for
  Saudi, `1[0125]` for Egypt) on the grounds that the rest were unassigned.
  Then a real owner's number — a prefix the regulator had assigned after that
  list was written — was refused, and nobody could be admin. The only symptom
  was one line in a boot log.

  The mistake is the shape of the check. A regulator hands out prefixes on its
  own schedule, so an operator whitelist goes stale silently, and it locks out
  exactly the person who cannot report it because reporting is behind the
  login. The two errors do not cost the same:

    * false reject — a real customer can never sign in, forever, with no
      support channel because support is behind the login.
    * false accept — a code goes to a number that does not exist, he sees
      nothing, he retypes. Thirty seconds, self-correcting.

  So the check is the widest one that still means something: leading digit and
  length. A Riyadh landline (`011…`) and a Cairo landline (`02…`) are still
  rejected, which was the whole job.

  ## Why not `ex_phone_number`

  Local mobile formats in these two countries are unambiguous by length, which
  is what makes this file short:

      05XXXXXXXX    10 digits, leading 05  ->  +9665XXXXXXXX
      01XXXXXXXXX   11 digits, leading 01  ->  +201XXXXXXXXX

  libphonenumber brings metadata for 240 countries to decide between two. When
  a third is sold to, add a clause. If a fourth and fifth follow, that is the
  moment to take the dependency — not now.

      iex> Asas.Phone.e164("٠٥٥١٢٣٤٥٦٧")
      {:ok, "+966551234567"}

      iex> Asas.Phone.e164("+20 100 123 4567")
      {:ok, "+201001234567"}

      iex> Asas.Phone.e164("0223456789")
      :error
  """

  @sa ~r/^5\d{8}$/
  @eg ~r/^1\d{9}$/

  @doc """
  `{:ok, "+9665…"}` / `{:ok, "+201…"}` or `:error`.

  Accepts the local form, the international form with or without `+`, the `00`
  prefix, punctuation, and Arabic-Indic digits.
  """
  @spec e164(binary | nil) :: {:ok, binary} | :error
  def e164(nil), do: :error

  def e164(raw) when is_binary(raw) do
    raw
    |> Asas.Digits.latin()
    |> String.replace(~r/[\s\-().]/u, "")
    |> String.replace_prefix("00", "+")
    |> classify()
  end

  def e164(_other), do: :error

  @doc "`e164/1` as a boolean, for validations that only decide."
  @spec valid?(binary | nil) :: boolean
  def valid?(raw), do: match?({:ok, _}, e164(raw))

  @doc """
  E.164 for display next to Arabic text: `+966 55 123 4567`.

  Wrap the call site in `<bdi dir="ltr">` — a `+` leading a run of digits
  inside RTL text is reordered by the bidi algorithm and lands at the wrong end.
  """
  @spec pretty(binary | nil) :: binary
  def pretty(nil), do: ""

  def pretty("+966" <> r) when byte_size(r) == 9 do
    <<a::binary-2, b::binary-3, c::binary-4>> = r
    "+966 #{a} #{b} #{c}"
  end

  def pretty("+20" <> r) when byte_size(r) == 10 do
    <<a::binary-3, b::binary-3, c::binary-4>> = r
    "+20 #{a} #{b} #{c}"
  end

  def pretty(other), do: to_string(other)

  @doc """
  The `wa.me` form: digits only, no plus — `201012345678`, or `nil`.

  WhatsApp silently opens an empty chat for anything else, which is the worst
  failure mode there is because it looks like it worked.
  """
  @spec whatsapp(binary | nil) :: binary | nil
  def whatsapp(raw) do
    case e164(raw) do
      {:ok, "+" <> digits} -> digits
      :error -> nil
    end
  end

  @doc "Last four digits, to confirm which number a code went to without reprinting it."
  @spec tail(binary | nil) :: binary
  def tail(nil), do: ""
  def tail(e164) when is_binary(e164), do: String.slice(e164, -4, 4)

  # Already international.
  defp classify("+966" <> rest), do: match(rest, @sa, "+966")
  defp classify("+20" <> rest), do: match(rest, @eg, "+20")

  # A bare country code with no plus — what pasting out of a contacts app gives.
  defp classify("966" <> rest), do: match(rest, @sa, "+966")
  defp classify("20" <> rest = all), do: eg_or_local(all, rest)

  # Local, trunk-prefixed. LENGTH disambiguates: 10 digits Saudi, 11 Egyptian.
  # Get this backwards and every Egyptian is silently a Saudi whose OTP is
  # routed to a number that does not exist.
  defp classify("0" <> rest) when byte_size(rest) == 9, do: match(rest, @sa, "+966")
  defp classify("0" <> rest) when byte_size(rest) == 10, do: match(rest, @eg, "+20")

  # No trunk prefix at all — "551234567". Common when a number is dictated.
  defp classify(digits) when byte_size(digits) == 9, do: match(digits, @sa, "+966")

  defp classify(_other), do: :error

  # "20…" is ambiguous in principle — Egypt's country code, or a Saudi number
  # starting 20 — except no Saudi mobile starts with 2, they all start 5.
  # Resolved by trying the Egyptian body first and falling through, not guessed.
  defp eg_or_local(all, rest) do
    case match(rest, @eg, "+20") do
      {:ok, e164} -> {:ok, e164}
      :error -> match(all, @sa, "+966")
    end
  end

  defp match(body, regex, cc) do
    if Regex.match?(regex, body), do: {:ok, cc <> body}, else: :error
  end
end
