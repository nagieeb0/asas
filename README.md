# asas · أساس

The seven things every one of these Phoenix/Ash apps rewrote from scratch.

← الأساس: سبع حاجات اتكتبت من الصفر في كل مشروع

Not a framework. Seven small modules, ~950 lines, one dependency (`req`).

## What it replaces

Counted across `bahz Dactarly ghadwa imdent kipra mawja my_coffee raqeemi sanaa aethel signature_inn taj_signature whatsapy`:

| module | copies | lines out there | files to delete |
|---|---|---|---|
| `Asas.Digits` | 5 | 188 | `my_coffee/digits.ex`, `raqeemi/digits.ex`, the digit table inside `raqeemi/money.ex`, `sanaa/crm/conversion.ex`, `imdent/localize.ex` |
| `Asas.Phone` | 5 | 841 | `raqeemi/phone.ex`, `my_coffee/phone.ex`, `imdent/whatsapp/phone.ex`, `imdent/clinics/phone_number.ex`, `bahz/crm/phone_repair.ex` |
| `Asas.Akedly` | 5 | 954 | `Dactarly/akedly.ex`, `ghadwa/accounts/akedly.ex`, `imdent/otp/akedly.ex`, `my_coffee/akedly.ex`, `raqeemi/otp/akedly.ex` |
| `Asas.RateLimit` | 5 | 348 | `Dactarly/rate_limiter.ex`, `ghadwa/rate_limiter.ex`, `kipra_web/rate_limiter.ex`, `whatsapy/rate_limiter.ex`, `mawja/packages/meta_api/rate_limiter.ex` |
| `Asas.Storage` | 6 | 1707 | `{Dactarly,ghadwa,raqeemi,sanaa,whatsapy}/storage*.ex`, `aethel/health/storage/*` |
| `Asas.Release` | 9 | 961 | `release.ex` in all nine |
| `Asas.Locale` | 6 | 727 | `{ghadwa,mawja,Dactarly,whatsapy}_web/plugs/locale.ex`, `imdent_web/plugs/{set,pin_public}_locale.ex`, `bahz_web/locale.ex`, `ghadwa/i18n.ex` |

**5,726 lines → 958.** Not all 5,726 is pure duplication — some of those files
carry app-specific bits that stay behind. The shared core is what moved.

## Install

```elixir
{:asas, github: "nagieeb0/asas"}
```

The repo is **private**, so the fetch needs credentials somewhere that is not a
laptop. Three places it can come from, cheapest first:

- **Local dev** — nothing to do. `gh auth` or your SSH key already covers it.
- **CranL / Docker builds** — nothing to do either, as long as you keep vendoring
  `deps/` the way you already do for the hex-registry timeout. A committed
  `deps/asas` means the builder never fetches anything.
- **GitHub Actions in a host app** — one step, because the default `GITHUB_TOKEN`
  cannot read a *different* private repo:

  ```yaml
  - run: git config --global url."https://x-access-token:${{ secrets.ASAS_TOKEN }}@github.com/".insteadOf "https://github.com/"
  ```

  where `ASAS_TOKEN` is a fine-grained PAT with read access to `nagieeb0/asas`.

This is the cost of keeping it private, and it is the objection `mihak` wrote
down. It is paid once per host app instead of once per module per app.

```elixir
# config/config.exs — once, per app
config :asas, otp_app: :my_app
```

## The seven

```elixir
# 1. Arabic-Indic digits. Run it on raw params before casting, once, in one plug.
Asas.Digits.latin("٩٩")                 #=> "99"
Asas.Digits.normalize_params(params)    # nested maps and lists
Asas.Digits.ar("3,450.00")              #=> "٣,٤٥٠.٠٠"   (display only, never stored)

# 2. EG + SA mobiles to E.164. Strict about length, never about the operator digit.
Asas.Phone.e164("٠١٠١٢٣٤٥٦٧٨")           #=> {:ok, "+201012345678"}
Asas.Phone.whatsapp("0551234567")       #=> "966551234567"

# 3. Akedly V1.2 OTP. challenge -> send_otp -> verify. Credentials never reach the browser.
{:ok, ch} = Asas.Akedly.challenge()
{:ok, %{"data" => %{"transactionReqID" => id}}} =
  Asas.Akedly.send_otp(phone, pow, turnstile, remote_ip)
{:ok, body} = Asas.Akedly.verify(id, "123456")
Asas.Akedly.verified?(body)             # the number comes from YOUR send step, not from body

# 4. ETS fixed-window limiter. Add {Asas.RateLimit, []} to the supervision tree.
Asas.RateLimit.hit("otp:#{phone}", 5)   #=> {:ok, 4} | {:error, retry_after_seconds}

# 5. Blob storage. Local on a laptop, S3/Tigris/R2 in prod, same three calls.
{:ok, key} = Asas.Storage.build_key("accounts/#{id}", "logo", content_type)
{:ok, ^key} = Asas.Storage.put(key, bytes, content_type)
Asas.Storage.url(key)
Asas.Storage.data_uri(key)              # for headless-Chrome PDFs — read the moduledoc

# 6. Release tasks. migrate on every boot, seed exactly once under an advisory lock.
defmodule MyApp.Release do
  use Asas.Release, otp_app: :my_app, seeded_check: "menu_categories"
end

# 7. Locale. The plug AND the on_mount — a LiveView is a different process.
plug Asas.Locale, gettext: MyAppWeb.Gettext, locales: ~w(ar en), default: "ar"
on_mount {Asas.Locale, gettext: MyAppWeb.Gettext}
```

## What is deliberately NOT here

- **Ash auth boilerplate** (`token.ex`, `secrets.ex`, `live_user_auth.ex`, `auth_overrides.ex`) —
  12 copies, but `mix igniter.install ash_authentication` writes them. Generated
  code is not duplication.
- **The ledger** (7 copies) — that is `ash_double_entry`, already a dependency.
- **Mishka components** (9 copies × 80 files) — vendored by a generator on purpose.
- **`config/runtime.exs`** — 13 copies with ~400 tokens in common each, but every
  one differs where it matters. A shared runtime config is a config file you
  cannot read top to bottom, which is worse than the copy.
- **Multi-gateway payment routing** — `mawja/payments/` already has the behaviour +
  registry + 11 adapters done properly. That stays there until a second app needs
  more than one gateway; today only `mawja` does.

A **single** gateway is a different question, and an earlier draft of this README
got it wrong. `Asas.Moyasar` is the next module to lift, not a deferral: there are
**four** Moyasar clients out there in a strict subset lattice — `aethel` (360) ⊂
`signature_inn` (387) ⊂ `raqeemi` ≡ `khatm` (461, differing only by 50 rename-only
lines). Every divergence between them is *subtraction*, never disagreement, so one
module with tokenisation as an optional group covers all four with no policy
decision to make. The triplicated `raw_body.ex` webhook plug (`aethel` 38,
`raqeemi` 43, `khatm` 33) comes with it.

## Migrating one app

Delete the local module, add the dep, and let the compiler find the call sites —
every one of these is a leaf module with no callers outside its own app.

The one that needs care is `Asas.Phone`: apps differ on which countries they
accept. `raqeemi` is EG+SA (matches this), `my_coffee`/`ghadwa`/`signature_inn`
are EG-only. Egypt-only apps get **wider**, not narrower: a Saudi number now
normalises instead of erroring. If that is wrong for an app, gate it at the
validation, not in this module.
