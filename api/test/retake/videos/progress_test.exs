defmodule Retake.Videos.ProgressTest do
  use ExUnit.Case, async: true

  alias Retake.Videos.Progress

  describe "event_json/1" do
    test "writes the step and status as words and the detail with string keys" do
      event = %{step: :script, scene: nil, status: :done, scenes: 3, title: "Tea"}

      assert Progress.event_json(event) == %{
               "step" => "script",
               "scene" => nil,
               "status" => "done",
               "scenes" => 3,
               "title" => "Tea"
             }
    end

    test "render progress is the status running" do
      event = %{step: :render, scene: nil, status: :progress, done: 5, total: 10}

      assert Progress.event_json(event) == %{
               "step" => "render",
               "scene" => nil,
               "status" => "running",
               "done" => 5,
               "total" => 10
             }
    end

    test "leaves out the render's output path" do
      event = %{step: :render, scene: nil, status: :done, output: "/srv/out/v-1.mp4"}

      assert Progress.event_json(event) == %{"step" => "render", "scene" => nil, "status" => "done"}
    end

    test "a failure's reason becomes a message in words" do
      event = %{step: :stock, scene: 2, status: :failed, reason: {:no_stock_found, ["sea"]}}

      assert %{"status" => "failed", "scene" => 2, "message" => message} =
               Progress.event_json(event)

      assert message == ~s(no stock footage or photo found for: "sea")
    end

    test "atoms and nested values are made safe for JSON" do
      event = %{step: :stock, scene: 1, status: :done, kind: :video, extra: %{tags: [:a, "b"]}}

      json = Progress.event_json(event)

      assert json["kind"] == "video"
      assert json["extra"] == %{"tags" => ["a", "b"]}
      assert Jason.decode!(Jason.encode!(json)) == json
    end
  end

  describe "record/2" do
    test "puts whole-video steps under steps and scene steps under scenes" do
      progress =
        %{}
        |> Progress.record(%{step: :script, scene: nil, status: :started})
        |> Progress.record(%{step: :script, scene: nil, status: :done, scenes: 2, title: "Tea"})
        |> Progress.record(%{step: :stock, scene: 2, status: :started})
        |> Progress.record(%{step: :voice, scene: 2, status: :done, duration_ms: 3_800})

      assert progress == %{
               "current" => %{"step" => "voice", "scene" => 2},
               "steps" => %{"script" => %{"status" => "done", "scenes" => 2, "title" => "Tea"}},
               "scenes" => %{
                 "2" => %{
                   "stock" => %{"status" => "started"},
                   "voice" => %{"status" => "done", "duration_ms" => 3_800}
                 }
               }
             }
    end

    test "a later event for the same step replaces the earlier one" do
      progress =
        %{}
        |> Progress.record(%{step: :render, scene: nil, status: :started})
        |> Progress.record(%{step: :render, scene: nil, status: :progress, done: 1, total: 4})
        |> Progress.record(%{step: :render, scene: nil, status: :progress, done: 3, total: 4})

      assert progress["steps"] == %{
               "render" => %{"status" => "running", "done" => 3, "total" => 4}
             }
    end

    test "keeps scenes apart" do
      progress =
        %{}
        |> Progress.record(%{step: :stock, scene: 1, status: :done})
        |> Progress.record(%{
          step: :stock,
          scene: 2,
          status: :failed,
          reason: {:invalid_input, "no"}
        })

      assert progress["scenes"]["1"]["stock"]["status"] == "done"
      assert progress["scenes"]["2"]["stock"] == %{"status" => "failed", "message" => "no"}
    end

    test "the result survives a round trip through JSON (the database column)" do
      progress =
        %{}
        |> Progress.record(%{step: :script, scene: nil, status: :done, scenes: 1, title: "T"})
        |> Progress.record(%{
          step: :stock,
          scene: 1,
          status: :done,
          kind: "video",
          credit: "By A"
        })

      assert Jason.decode!(Jason.encode!(progress)) == progress
    end
  end
end
