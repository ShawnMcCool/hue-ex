defmodule Hue.ErrorTest do
  use ExUnit.Case, async: true

  alias Hue.Error

  describe "from_response/3 — CLIP v2" do
    test "403 with an HTML body is unauthorized, not a decode crash" do
      html = Hue.Fixtures.raw("unauthorized_403.html")
      error = Error.from_response(403, html, "text/html")

      assert %Error{reason: :unauthorized, status: 403} = error
    end

    test "404 is not_found" do
      body = ~s({"errors":[{"description":"resource not available"}],"data":[]})
      error = Error.from_response(404, body, "application/json")

      assert %Error{reason: :not_found, description: "resource not available"} = error
    end

    test "429 is rate_limited" do
      assert %Error{reason: :rate_limited} = Error.from_response(429, "", "text/html")
    end

    test "503 is bridge_busy" do
      assert %Error{reason: :bridge_busy} = Error.from_response(503, "", "text/html")
    end
  end

  describe "from_pairing/1 — the v1 envelope at HTTP 200" do
    test "type 101 is link_button_not_pressed" do
      body = Hue.Fixtures.json("pairing_link_button_not_pressed.json")

      assert %Error{
               reason: :link_button_not_pressed,
               type: 101,
               description: "link button not pressed"
             } = Error.from_pairing(body)
    end

    test "an unrecognised type falls back to :unknown but keeps the detail" do
      body = [%{"error" => %{"type" => 7, "description" => "unauthorized user"}}]

      assert %Error{reason: :unknown, type: 7, description: "unauthorized user"} =
               Error.from_pairing(body)
    end
  end

  describe "transport/2" do
    test "carries a reason with no status" do
      assert %Error{reason: :timeout, status: nil} = Error.transport(:timeout)
    end
  end

  describe "from_transport/1" do
    test "an ordinary atom reason passes straight through" do
      assert %Error{reason: :econnrefused} =
               Error.from_transport(%Mint.TransportError{reason: :econnrefused})

      assert %Error{reason: :timeout} =
               Error.from_transport(%Mint.TransportError{reason: :timeout})
    end

    test "the pin firing is reported as :certificate_changed, not as :unknown" do
      alert = client_alert("certificate_changed")

      assert %Error{reason: :certificate_changed, description: description} =
               Error.from_transport(%Mint.TransportError{reason: alert})

      assert description =~ "certificate_changed"
    end

    test "an unrecognised verification event survives to the caller too" do
      alert = client_alert("unexpected_verification_event")

      assert %Error{reason: :unexpected_verification_event} =
               Error.from_transport(%Mint.TransportError{reason: alert})
    end

    # The mistake to avoid is the one the fingerprint-case bug made: telling a
    # user they are being intercepted when they are not.
    test "a handshake failure for an unrelated reason is not reported as interception" do
      for term <- ["hostname_check_failed", "cert_expired", "unknown_ca", "invalid_signature"] do
        assert %Error{reason: :unknown} =
                 Error.from_transport(%Mint.TransportError{reason: client_alert(term)})
      end
    end

    test "an alert the server sent is not reported as interception" do
      for alert <- [
            {:tls_alert,
             {:protocol_version,
              ~c"TLS client: In state wait_sh received SERVER ALERT: Fatal - Protocol Version\n"}},
            {:tls_alert,
             {:insufficient_security,
              ~c"TLS client: In state hello received SERVER ALERT: Fatal - Insufficient Security\n"}}
          ] do
        assert %Error{reason: :unknown} =
                 Error.from_transport(%Mint.TransportError{reason: alert})
      end
    end

    test "a term merely containing the word is not a match" do
      embedded =
        {:tls_alert,
         {:handshake_failure,
          ~c"TLS client: certificate_changed is not what happened\n hostname_check_failed"}}

      assert %Error{reason: :unknown} =
               Error.from_transport(%Mint.TransportError{reason: embedded})
    end

    # ssl_alert.erl carries two adjacent formatters for the same alert:
    # own_alert_format_depth/1 renders " ~s\n ~P" and own_alert_format/1 renders
    # " ~s\n - ~p". Which one produced the text this library is handed is not
    # ours to choose, so both trailing forms must map back.
    test "the sibling alert formatter's dash-and-atom form maps back too" do
      assert %Error{reason: :certificate_changed} =
               Error.from_transport(%Mint.TransportError{
                 reason: sibling_alert("certificate_changed")
               })

      assert %Error{reason: :unexpected_verification_event} =
               Error.from_transport(%Mint.TransportError{
                 reason: sibling_alert("unexpected_verification_event")
               })
    end

    test "a bare inspected atom on the last line maps back too" do
      assert %Error{reason: :certificate_changed} =
               Error.from_transport(%Mint.TransportError{
                 reason: alert_ending_in(~c":certificate_changed")
               })
    end

    test "neither leading form widens the match into a substring search" do
      for trailer <- [~c" - :hostname_check_failed", ~c" :cert_expired"] do
        assert %Error{reason: :unknown} =
                 Error.from_transport(%Mint.TransportError{reason: alert_ending_in(trailer)})
      end
    end

    test "a trailing blank line does not hide the refused term" do
      assert %Error{reason: :certificate_changed} =
               Error.from_transport(%Mint.TransportError{
                 reason: alert_ending_in(~c" - :certificate_changed\n")
               })
    end

    # Not a shape :ssl or Mint has been observed to produce -- both hand back
    # charlists, measured -- but the whole point of this function is that the
    # one failure it must never lose is the one arriving in an unexpected form.
    test "alert text that arrives as a binary is read, not raised on" do
      assert %Error{reason: :certificate_changed, description: description} =
               Error.from_transport(%Mint.TransportError{
                 reason:
                   {:tls_alert,
                    {:handshake_failure,
                     "TLS client: Fatal - Handshake Failure\n - :certificate_changed"}}
               })

      assert description =~ "Handshake Failure"
    end

    test "keeps the alert text as the description, whatever the reason" do
      assert %Error{description: description} =
               Error.from_transport(%Mint.TransportError{reason: client_alert("cert_expired")})

      assert description =~ "Handshake Failure"
    end

    test "an exception with no reason at all still yields an error" do
      assert %Error{reason: :unknown, description: description} =
               Error.from_transport(%RuntimeError{message: "the socket went away"})

      assert description =~ "the socket went away"
    end
  end

  # OTP appends the term a verify_fun returned from {:fail, term} to the alert
  # text, after a newline. This is the exact string observed on OTP 28; only
  # the trailing term varies.
  defp client_alert(term) do
    alert_ending_in(~c" " ++ String.to_charlist(term))
  end

  # The form ssl_alert.erl's own_alert_format/1 produces: " ~s\n - ~p", which
  # inspects the atom and so prints its leading colon. Observed in Logger output
  # on OTP 28 alongside the depth formatter's bare-term form.
  defp sibling_alert(term) do
    alert_ending_in(~c" - :" ++ String.to_charlist(term))
  end

  defp alert_ending_in(trailer) do
    {:tls_alert,
     {:handshake_failure,
      ~c"TLS client: In state wait_cert_cr at ssl_handshake.erl:2200 generated CLIENT ALERT: " ++
        ~c"Fatal - Handshake Failure\n" ++ trailer}}
  end

  describe "message/1" do
    test "reads as a sentence" do
      error = Error.from_response(403, "", "text/html")
      assert Exception.message(error) =~ "unauthorized"
    end
  end
end
