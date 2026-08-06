defmodule Hue.Fixtures do
  @moduledoc """
  Loads bytes recorded from a real BSB002 bridge on 2026-08-06 and sanitised by
  `bin/sanitize-fixtures`. These are real responses, not invented shapes.
  """

  @dir Path.join(__DIR__, "fixtures")

  @doc "Raw fixture contents as a binary."
  def raw(name), do: File.read!(Path.join(@dir, name))

  @doc "A fixture parsed as JSON."
  def json(name), do: name |> raw() |> Jason.decode!()

  @doc "The full-state dump: 178 resources across 22 types."
  def full_state, do: json("full_state.json")

  @doc "Every resource of one type from the full-state dump."
  def resources(type) do
    full_state()["data"] |> Enum.filter(&(&1["type"] == type))
  end

  @doc "The first resource of one type."
  def resource(type), do: type |> resources() |> hd()
end
