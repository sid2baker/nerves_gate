defmodule WorkbenchWeb.FactoryPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import WorkbenchWeb.PageFixtures

  test "factory provisioning defaults to backup and binds explicit skipping into review" do
    empty =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns()) |> Floki.parse_document!()

    assert Floki.find(empty, "#review-factory select[name=firmware][disabled]") != []
    assert Floki.find(empty, "#confirm-factory") == []
    assert Floki.find(empty, "input[type=password]") == []
    assert Floki.attribute(empty, "#factory-backup option:first-child", "value") == ["true"]
    assert Floki.find(empty, "#factory-backup option[value=false]") != []
    assert Floki.text(empty) =~ "RAM"
    assert Floki.text(empty) =~ "not a verified EC100 serial number"

    review = %{
      kind: :factory,
      token: "factory-token",
      location: "101",
      confirmation: "ERASE EC100 101",
      version: "0.2.0-dev",
      firmware: "/images/ec100.fw",
      backup: "/backups/review",
      capacity: 4_000_000_000,
      required_space: 12_000_000_000,
      available_space: 20_000_000_000,
      sha256: String.duplicate("a", 64)
    }

    job = %{
      job()
      | status: :awaiting_confirmation,
        kind: "factory_review",
        review: review
    }

    document =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns(job: job))
      |> Floki.parse_document!()

    assert Floki.find(
             document,
             "#confirm-factory input[name=identified][type=checkbox][required]"
           ) != []

    assert Floki.find(document, "#confirm-factory input[name=confirmation][required]") != []
    assert Floki.attribute(document, "input[name=review_id]", "value") == ["factory-token"]
    assert Floki.text(document) =~ "ERASE EC100 101"
    assert Floki.text(document) =~ "full eMMC user-area backup"
    assert WorkbenchWeb.Components.job_path(job) == "/provision"

    no_backup =
      Map.merge(review, %{backup_enabled: false, confirmation: "ERASE EC100 101 WITHOUT BACKUP"})

    skipped =
      render_component(
        &WorkbenchWeb.FactoryLive.render/1,
        assigns(job: %{job | review: no_backup})
      )
      |> Floki.parse_document!()

    assert Floki.text(skipped) =~ "SKIPPED"
    assert Floki.text(skipped) =~ "No full backup will be made"
    assert Floki.text(skipped) =~ "ERASE EC100 101 WITHOUT BACKUP"
    assert Floki.text(Floki.find(skipped, "#confirm-factory button")) =~ "WITHOUT BACKUP"
    refute Floki.text(skipped) =~ "will be saved before the first write"
  end

  test "failed factory review highlights its actual error and explains temporary cleanup" do
    job = %{
      job()
      | status: :failed,
        kind: "factory_review",
        output: "Loading the verified review's RAM transport (no eMMC writes)",
        result:
          "The RAM loader opened, but rkdeveloptool could not open or claim the EC100 USB connection."
    }

    document =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns(job: job))
      |> Floki.parse_document!()

    assert Floki.text(Floki.find(document, "[role=alert]")) =~ "could not open or claim"
    assert Floki.text(document) =~ "temporary files have been removed"
    assert Floki.text(document) =~ "do not copy a temporary loader command"
    assert Floki.find(document, "#confirm-factory") == []
    refute Floki.text(Floki.find(document, ".bench-output")) =~ "rkdeveloptool db"
  end

  test "failed factory provisioning retains a visible recovery backup location" do
    job =
      %{
        job()
        | status: :failed,
          kind: "factory_provision",
          result: "Worker exited (epipe). Operation outcome is unknown."
      }
      |> Map.put(:recovery, "/backups/owned-recovery")

    document =
      render_component(&WorkbenchWeb.FactoryLive.render/1, assigns(job: job))
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "Preserve recovery files:"
    assert Floki.text(document) =~ "/backups/owned-recovery"
    assert Floki.text(Floki.find(document, "[role=alert]")) =~ "epipe"
    assert Floki.find(document, "#confirm-factory") == []
  end
end
