defmodule Asas do
  @moduledoc """
  أساس — the seven pieces every one of these Phoenix/Ash apps wrote from
  scratch, extracted once.

  | module | replaces |
  |---|---|
  | `Asas.Digits` | the Arabic-Indic digit fold, copied into 5 apps |
  | `Asas.Phone` | EG/SA mobile → E.164, copied into 5 apps |
  | `Asas.Akedly` | the Akedly V1.2 OTP client, copied into 5 apps |
  | `Asas.RateLimit` | the ETS fixed-window limiter, copied into 5 apps |
  | `Asas.Storage` | the Local/S3 blob behaviour, copied into 5 apps |
  | `Asas.Release` | `migrate` + seed-once-under-advisory-lock, copied into 9 apps |
  | `Asas.Locale` | the ar/en locale plug and LiveView hook, copied into 6 apps |

  Set the host app once, in `config/config.exs`:

      config :asas, otp_app: :my_app

  Everything else is per-module config under that app's key. What is
  deliberately **not** here: anything `ash_authentication`'s generators
  already write (`token.ex`, `secrets.ex`, `live_user_auth.ex`), anything
  `ash_double_entry` already does (the ledger), and the Mishka components —
  those are generated or vendored, not hand-written, so extracting them buys
  nothing.
  """
end
