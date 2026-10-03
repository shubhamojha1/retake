defmodule Retake.FixturesTest do
  use ExUnit.Case, async: true

  alias Retake.Spec

  @specs_dir Path.expand("../../../fixtures/specs", __DIR__)
  @spec_files Path.wildcard(Path.join(@specs_dir, "*.json"))

  test "there are fixture specs" do
    assert @spec_files != []
  end

  # file:// uris in fixture specs are relative to the repo root (where `just render` runs).
  for path <- @spec_files do
    test "#{Path.basename(path)} is a valid spec" do
      assert {:ok, _spec} = Spec.load(unquote(path))
    end
  end
end
