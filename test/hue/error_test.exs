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

  describe "message/1" do
    test "reads as a sentence" do
      error = Error.from_response(403, "", "text/html")
      assert Exception.message(error) =~ "unauthorized"
    end
  end
end
