defmodule Asas.Locale do
  @moduledoc """
  Decides which language a request is answered in, and tells everything that
  cares. A `Plug` for the connection and an `on_mount` hook for LiveView.

  Three things have to be told, and forgetting any one is a bug that looks like
  a half-translated page:

    * **Gettext** — what `gettext/1` reads. Per process.
    * **the CLDR backend** (`ex_cldr` / `ex_money`, if present) — what formats
      dates, numbers and money. Also per process.
    * **the connection or socket** — so the layout can put `lang` and `dir` on
      `<html>`.

  The LiveView hook is not optional politeness: a LiveView runs in a *different
  process* from the request that mounted it and inherits neither of the first
  two. Without it every page renders Arabic on first paint and English on
  every update.

      # router
      plug Asas.Locale, gettext: MyAppWeb.Gettext, locales: ~w(ar en), default: "ar"

      # live_session
      on_mount {Asas.Locale, gettext: MyAppWeb.Gettext}

      # layout
      <html lang={@locale} dir={@dir}>

  ## Where the choice comes from

  In order: an explicit `?locale=` param, the session, the cookie,
  `accept-language`, then the default. The param is first so a shared link can
  carry a language; it is written back to the session so the next request
  without it keeps the choice.
  """

  # ponytail: plug, phoenix_live_view and gettext are optional deps, so a host that
  # has none of them would otherwise eat ten undefined-module warnings — and break
  # outright under --warnings-as-errors. Every Phoenix host has all three; this is
  # for the ones that are not Phoenix hosts.
  @compile {:no_warn_undefined, [Plug.Conn, Phoenix.Component, Gettext]}

  @session_key "locale"
  @rtl ~w(ar he fa ur)

  @doc "The session key the locale is remembered under, so LiveViews read the same one."
  def session_key, do: @session_key

  @doc "`\"rtl\"` or `\"ltr\"` for a locale — for the `dir` attribute."
  @spec dir(binary) :: binary
  def dir(locale) do
    language = locale |> to_string() |> String.split("-") |> hd()
    if language in @rtl, do: "rtl", else: "ltr"
  end

  # --- Plug ---------------------------------------------------------------

  def init(opts), do: opts

  def call(conn, opts) do
    locales = opts[:locales] || ~w(ar en)
    default = opts[:default] || hd(locales)

    conn = Plug.Conn.fetch_cookies(conn)
    locale = choose(candidates(conn), locales, default)
    put_process_locale(locale, opts)

    conn
    |> Plug.Conn.put_session(@session_key, locale)
    |> Plug.Conn.put_resp_cookie(@session_key, locale,
      max_age: 365 * 24 * 60 * 60,
      http_only: false
    )
    |> Plug.Conn.assign(:locale, locale)
    |> Plug.Conn.assign(:dir, dir(locale))
  end

  # --- LiveView -----------------------------------------------------------

  @doc false
  def on_mount(opts, _params, session, socket) do
    locales = opts[:locales] || ~w(ar en)
    default = opts[:default] || hd(locales)
    locale = choose([session[@session_key]], locales, default)
    put_process_locale(locale, opts)

    {:cont,
     socket
     |> Phoenix.Component.assign(:locale, locale)
     |> Phoenix.Component.assign(:dir, dir(locale))}
  end

  # ------------------------------------------------------------------------

  defp candidates(conn) do
    [
      conn.params[@session_key],
      Plug.Conn.get_session(conn, @session_key),
      conn.cookies[@session_key]
    ] ++ accept_language(conn)
  end

  defp accept_language(conn) do
    conn
    |> Plug.Conn.get_req_header("accept-language")
    |> Enum.flat_map(&String.split(&1, ","))
    # "ar-EG;q=0.9" -> "ar". The region is dropped because these apps translate
    # by language, not by locale; keep it and ar-EG silently falls to default.
    |> Enum.map(&(&1 |> String.split(";") |> hd() |> String.trim() |> String.split("-") |> hd()))
  end

  defp choose(candidates, locales, default) do
    Enum.find(candidates, default, &(&1 in locales))
  end

  defp put_process_locale(locale, opts) do
    if backend = opts[:gettext], do: Gettext.put_locale(backend, locale)
    if cldr = opts[:cldr], do: cldr.put_locale(locale)
    :ok
  end
end
