defmodule Hue.Bridge.Body do
  @moduledoc """
  Translates `set` options into a CLIP v2 request body, checking capabilities
  against the cached resource first.

  ## Two kinds of wrongness

  `brightness: "loud"` is a bug in the calling code. There is no runtime
  handling for it — only a source change — so it **raises**, at the call
  site, with a message naming the option. `brightness: 150` is the same kind
  of bug: CLIP v2's `dimming.brightness` is a percentage, `0`-`100` inclusive,
  and a value outside that range was never valid input, on any light,
  regardless of what is plugged into the socket — so it **raises** too,
  rather than being treated as a per-light capability question. This module
  deliberately does **not** validate against a light's `min_dim_level`: that
  is a physical floor that varies by bulb, and clamping a legal percentage up
  to it is the bridge's job, not this library's — see `translate/2`'s
  `:brightness` clause.

  `color: "#ff8800"` sent to a white-only bulb is not a bug. It is a mismatch
  between what the code asked for and what is screwed into a lamp in the
  user's house, which the code could not have known, so it **returns**
  `{:error, %Hue.Error{reason: :not_color_capable}}`.

  ## Every option is validated before any option is translated

  `build/2` runs in two passes rather than one. The first, `validate_option!/1`,
  walks every option and checks its *value* — no resource, no capability, no
  I/O — and raises on the first malformed one it finds. Only once every option
  in the call has passed does the second pass, `translate/2`, touch the
  resource at all.

  The split exists because a single `Enum.reduce_while/3` pass that validated
  and translated together let the *wrong* kind of wrongness win by accident.
  `Body.build([color: "#ff8800", brightness: "loud"], a_colourless_light)`
  under that shape resolved `:color` first, found a genuine capability
  mismatch, and `reduce_while` halted there — so `brightness: "loud"`, a bug
  in the caller's own source, was never reached and never raised. The bug got
  reported as "this light has no colour support," which sends whoever reads
  that message to look at their light fixture instead of their code. Splitting
  validation out means a malformed option raises **regardless of the order
  options were given in and regardless of what any other option's capability
  check would have found** — the property the moduledoc always claimed but
  the single-pass version did not actually have.

  ## Capabilities are checked before the request leaves

  Because `Hue.Bridge` caches every light's capabilities, this check does not
  need the bridge's opinion. That is strictly better than sending the request
  and interpreting the rejection: no round trip, and an error that names the
  light rather than quoting a CLIP description. The reference bridge has two
  lights with no `dimming` key at all, so `:not_dimmable` is a case real
  users hit, not a defensive branch. Option order still decides which
  capability error is reported when two options each fail on a different
  capability — that is a caller with two real problems, and reporting the
  first one honestly is not a bug the way the paragraph above was.

  ## Colour and colour temperature mostly delegate rather than duplicate

  `Hue.Color.payload/2` and `Hue.Color.mirek_for/2` return
  `{:error, %Hue.Error{reason: :not_color_capable, rid: ...}}` for a light
  with no `"color"` or no `"color_temperature"` key — confirmed against
  layer 1 directly before writing this module — so `translate/2`'s `:color`
  and `:kelvin` clauses do not check capability themselves; a second check
  here would be a second place for the two to drift.

  `Hue.Color.to_xy/2` (which `payload/2` calls) validates its input before it
  ever consults the light's gamut, so a value that could never be a colour
  under any of its accepted input shapes (see `t:Hue.Color.input/0`) raises
  there regardless of what is plugged into the socket. `validate_option!/1`
  rejects the same shapes itself, earlier and with a message that names the
  option — a bare number, an atom, a string that is not a hex code, a tuple
  of the wrong arity or element types — before `translate/2` ever runs. What
  it does **not** attempt is hex-digit correctness or an RGB component's
  `0..255` range: those are shapes `validate_option!/1` accepts as
  well-formed (any `"#"`-prefixed string, any integer-tupled `{r, g, b}`),
  and only `Hue.Color.to_xy/2` inspects their content, raising
  (`Color.InvalidHexError`, `Color.InvalidComponentError`) once a colour-
  capable light actually reaches them. Against a colourless light, a value
  well-formed enough to survive both checks — correct hex digits, RGB
  components in range — still reports as `:not_color_capable`, which is the
  one case that genuinely is a capability mismatch rather than a caller bug.
  """

  alias Hue.Color
  alias Hue.Error

  @known_options [:on, :brightness, :color, :kelvin, :transition]

  @doc """
  Builds the request body for `options` against `resource`.

  Returns `{:ok, body}`, or `{:error, %Hue.Error{}}` for a capability the
  resource does not have. Raises `ArgumentError` for an unknown option or a
  malformed value — always, regardless of where in `options` it appears and
  regardless of what any other option's capability check would have found.
  See the moduledoc's "Every option is validated before any option is
  translated".
  """
  @spec build(keyword(), map()) :: {:ok, map()} | {:error, Error.t()}
  def build(options, resource) when is_list(options) and is_map(resource) do
    validate_options!(options)
    Enum.each(options, &validate_option!/1)
    translate(options, resource)
  end

  # Capability-dependent. By the time this runs, validate_option!/1 has
  # already accepted every option's value on its own terms, so the only
  # things left that can go wrong here are facts about `resource` — this
  # returns {:ok, body} or a genuine %Hue.Error{}, never raises.
  defp translate(options, resource) do
    Enum.reduce_while(options, {:ok, %{}}, fn option, {:ok, body} ->
      case fragment(option, resource) do
        {:ok, fragment} -> {:cont, {:ok, Map.merge(body, fragment)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fragment({:on, value}, _resource) do
    {:ok, %{"on" => %{"on" => value}}}
  end

  defp fragment({:brightness, value}, resource) do
    if Map.has_key?(resource, "dimming") do
      {:ok, %{"dimming" => %{"brightness" => value / 1}}}
    else
      {:error, %Error{reason: :not_dimmable, rid: resource["id"]}}
    end
  end

  defp fragment({:transition, value}, _resource) do
    {:ok, %{"dynamics" => %{"duration" => value}}}
  end

  defp fragment({:color, value}, resource) do
    Color.payload(value, resource)
  end

  defp fragment({:kelvin, value}, resource) do
    case Color.mirek_for(value, resource) do
      {:ok, mirek} -> {:ok, %{"color_temperature" => %{"mirek" => mirek}}}
      {:error, _reason} = error -> error
    end
  end

  # Resource-independent. Every clause here either returns :ok or raises —
  # never a %Hue.Error{} — because a malformed value was never valid on any
  # light, not just the one in this call.
  defp validate_option!({:on, value}) when is_boolean(value), do: :ok

  defp validate_option!({:on, value}) do
    raise ArgumentError, "on: expects a boolean, got: #{inspect(value)}"
  end

  defp validate_option!({:brightness, value})
       when is_number(value) and value >= 0 and value <= 100 do
    :ok
  end

  defp validate_option!({:brightness, value}) do
    raise ArgumentError,
          "brightness: expects a number between 0 and 100 (a CLIP v2 percentage), got: #{inspect(value)}"
  end

  defp validate_option!({:transition, value}) when is_integer(value) and value >= 0, do: :ok

  defp validate_option!({:transition, value}) do
    raise ArgumentError,
          "transition: expects a non-negative integer of milliseconds, got: #{inspect(value)}"
  end

  defp validate_option!({:kelvin, value}) when is_integer(value) and value > 0, do: :ok

  defp validate_option!({:kelvin, value}) do
    raise ArgumentError, "kelvin: expects a positive integer, got: #{inspect(value)}"
  end

  # Shape only — matches exactly what Hue.Color.to_xy/2's own clauses accept
  # (t:Hue.Color.input/0). Hex-digit correctness and the 0..255 component
  # range are deliberately left to Hue.Color, which validates and raises for
  # both once a light with colour capability actually reaches them — see the
  # moduledoc's "Colour and colour temperature mostly delegate" section for
  # why this line is drawn where it is rather than duplicating that check.
  defp validate_option!({:color, "#" <> _}), do: :ok

  defp validate_option!({:color, {:xy, x, y}}) when is_number(x) and is_number(y), do: :ok

  defp validate_option!({:color, {r, g, b}})
       when is_integer(r) and is_integer(g) and is_integer(b) do
    :ok
  end

  defp validate_option!({:color, value}) do
    raise ArgumentError,
          "color: expects a hex string like \"#ff8800\", an {r, g, b} tuple, or an " <>
            "{:xy, x, y} tuple, got: #{inspect(value)}"
  end

  # `Enum.uniq/1` before the subtraction is load-bearing, not decoration.
  # `--/2` removes only one matching element per occurrence on its right side,
  # so a duplicated *known* option — `[on: true, on: false]`, a slider firing
  # twice before the caller reads its own accumulator — leaves one copy of
  # `:on` behind after the first is cancelled out, and without the dedupe
  # that survivor is reported as "unknown option(s) [:on]": a real option,
  # called an unknown one. Deduping first means a repeated known option is
  # accepted (later values win, via `Map.merge/3` in `translate/2`, the same
  # last-one-wins rule any keyword-list API applies), and only names genuinely
  # absent from `@known_options` are ever reported.
  defp validate_options!(options) do
    case Enum.uniq(Keyword.keys(options)) -- @known_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) #{inspect(unknown)}; accepted: #{inspect(@known_options)}"
    end
  end
end
