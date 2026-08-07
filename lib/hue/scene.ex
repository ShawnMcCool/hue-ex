defmodule Hue.Scene do
  @moduledoc """
  Scenes, addressed by name.

      :ok = Hue.Scene.recall(bridge, "Relax")
      :ok = Hue.Scene.recall(bridge, "Relax", duration: 2_000)

  A scene is not a group and takes none of `Hue.Light`'s options — its whole
  content is the state it puts its lights into. Recall is a write to the scene
  itself, and the only thing you get to say about it is how long the transition
  should take.
  """

  alias Hue.Bridge
  alias Hue.Error

  @doc "Fetches one scene by name or rid."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, target), do: Bridge.resolve(bridge, :scene, target)

  @doc "Every scene the bridge knows about."
  @spec list(atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge), do: Bridge.list(bridge, :scene)

  @doc """
  Activates a scene.

  `:duration` is milliseconds for the transition into the scene.
  """
  @spec recall(atom(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def recall(bridge, target, options \\ []) do
    recall = Enum.reduce(options, %{"action" => "active"}, &recall_option/2)

    with {:ok, scene} <- get(bridge, target) do
      Bridge.write(bridge, :scene, scene["id"], %{"recall" => recall})
    end
  end

  defp recall_option({:duration, value}, recall) when is_integer(value) and value >= 0 do
    Map.put(recall, "duration", value)
  end

  defp recall_option({:duration, value}, _recall) do
    raise ArgumentError,
          "duration: expects a non-negative integer of milliseconds, got: #{inspect(value)}"
  end

  defp recall_option({key, _value}, _recall) do
    raise ArgumentError, "unknown option #{inspect(key)}; recall accepts only :duration"
  end
end
