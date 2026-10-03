defmodule Retake.Providers.ProviderTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Provider

  defp provider(attrs \\ []) do
    struct!(
      Provider,
      Keyword.merge(
        [
          name: "groq",
          capability: :llm,
          adapter: "openai_compatible",
          api_key_env: "GROQ_API_KEY"
        ],
        attrs
      )
    )
  end

  describe "api_key/2" do
    test "reads the key from the named environment variable" do
      assert Provider.api_key(provider(), %{"GROQ_API_KEY" => "gsk-1"}) == {:ok, "gsk-1"}
    end

    test "a missing variable is an error that names the variable" do
      assert Provider.api_key(provider(), %{}) == {:error, {:missing_env, "GROQ_API_KEY"}}
    end

    test "a blank variable counts as missing" do
      assert Provider.api_key(provider(), %{"GROQ_API_KEY" => "  "}) ==
               {:error, {:missing_env, "GROQ_API_KEY"}}
    end

    test "a provider without api_key_env needs no key" do
      assert Provider.api_key(provider(api_key_env: nil), %{}) == {:ok, nil}
    end

    test "falls back to the real environment when none is given" do
      System.put_env("RETAKE_TEST_KEY_PRESENT", "from-env")
      on_exit(fn -> System.delete_env("RETAKE_TEST_KEY_PRESENT") end)

      assert Provider.api_key(provider(api_key_env: "RETAKE_TEST_KEY_PRESENT"), nil) ==
               {:ok, "from-env"}
    end
  end

  test "the struct never holds a key, so it cannot leak one when inspected" do
    refute Map.has_key?(Map.from_struct(provider()), :api_key)
  end
end
