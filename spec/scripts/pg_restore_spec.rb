require "rails_helper"
require "open3"
require "tmpdir"

# Runs script/backup/pg_restore.sh against a fake `docker` that records every
# invocation, so the safety rules are tested without a database.
RSpec.describe "script/backup/pg_restore.sh" do
  let(:script) { Rails.root.join("script/backup/pg_restore.sh").to_s }
  let(:dir) { Dir.mktmpdir("pg_restore_spec") }
  let(:log_path) { File.join(dir, "docker.log") }
  let(:dump) { File.join(dir, "backup.dump").tap { |path| File.write(path, "PGDMP") } }

  before do
    File.write(File.join(dir, "docker"), <<~'SH')
      #!/usr/bin/env bash
      echo "$*" >> "$FAKE_DOCKER_LOG"
      cat > /dev/null || true
      all="$*"
      case "$all" in
        inspect*) echo true ;;
        *"FROM pg_database WHERE datname = '"*)
          name="${all#*datname = \'}"; name="${name%%\'*}"
          for existing in $FAKE_EXISTING_DATABASES; do [[ "$existing" == "$name" ]] && echo 1; done
          exit 0 ;;
        *pg_restore*) [[ -z "${FAKE_RESTORE_FAILS:-}" ]] || exit 1 ;;
        *"count(*)"*) echo 41 ;;
        *"max(version)"*) echo 20261007000020 ;;
      esac
      exit 0
    SH
    FileUtils.chmod(0o755, File.join(dir, "docker"))
  end

  after { FileUtils.remove_entry(dir) }

  def run_script(*args, existing: "whatsapp_integration_production", fails: false)
    env = { "PATH" => "#{dir}:#{ENV['PATH']}", "FAKE_DOCKER_LOG" => log_path, "FAKE_EXISTING_DATABASES" => existing }
    env["FAKE_RESTORE_FAILS"] = "1" if fails
    out, status = Open3.capture2e(env, "bash", script, *args)
    [ out, status, File.exist?(log_path) ? File.read(log_path) : "" ]
  end

  it "has valid bash syntax" do
    _out, status = Open3.capture2e("bash", "-n", script)

    expect(status).to be_success
  end

  it "restores into a new database inside a single transaction and says the live database was not touched" do
    out, status, calls = run_script(dump, "restored_20261007")

    expect(status).to be_success
    expect(calls).to include('CREATE DATABASE "restored_20261007" OWNER "whatsapp_integration"')
    expect(calls).to match(/pg_restore .*-d restored_20261007 .*--single-transaction .*--no-owner .*--exit-on-error/)
    expect(calls).not_to match(/--clean|DROP DATABASE/)
    expect(out).to include("restored into restored_20261007: 41 public tables, latest migration 20261007000020", "was not touched")
  end

  it "refuses the live database by name, with or without any flag, and touches nothing" do
    [ [], [ "--replace-scratch" ] ].each do |flags|
      out, status, calls = run_script(*flags, dump, "whatsapp_integration_production")

      expect(status).not_to be_success
      expect(out).to include("is the live database", "RUNBOOK")
      expect(calls).not_to match(/CREATE|DROP|pg_restore/)
      File.delete(log_path) if File.exist?(log_path)
    end
  end

  it "honors LIVE_DATABASE from the environment" do
    out, status, = Open3.capture2e({ "PATH" => "#{dir}:#{ENV['PATH']}", "FAKE_DOCKER_LOG" => log_path, "LIVE_DATABASE" => "other_live" }, "bash", script, dump, "other_live")

    expect(status).not_to be_success
    expect(out).to include("is the live database")
  end

  it "has no --force-live any more and says where the swap procedure is" do
    out, status, calls = run_script("--force-live", dump, "whatsapp_integration_production")

    expect(status).not_to be_success
    expect(out).to include("--force-live no longer exists", "RUNBOOK")
    expect(calls).not_to match(/CREATE|DROP|pg_restore/)
  end

  it "refuses to touch an existing database unless --replace-scratch is given" do
    out, status, calls = run_script(dump, "restore_test", existing: "restore_test")

    expect(status).not_to be_success
    expect(out).to include("already exists", "--replace-scratch")
    expect(calls).not_to match(/DROP|CREATE|pg_restore/)
  end

  it "drops and recreates an existing scratch database with --replace-scratch" do
    out, status, calls = run_script("--replace-scratch", dump, "restore_test", existing: "restore_test")

    expect(status).to be_success, out
    expect(calls.lines.grep(/DROP DATABASE|CREATE DATABASE|pg_restore/).map { |l| l[/DROP DATABASE|CREATE DATABASE|pg_restore/] }).to eq([ "DROP DATABASE", "CREATE DATABASE", "pg_restore" ])
  end

  it "refuses system databases and invalid names" do
    %w[postgres template0 template1 bad-name 1abc].each do |name|
      _out, status, calls = run_script(dump, name)

      expect(status).not_to be_success, name
      expect(calls).not_to match(/CREATE|DROP|pg_restore/)
      File.delete(log_path) if File.exist?(log_path)
    end
  end

  it "drops the incomplete database when the restore fails, so no half-restored copy is left" do
    out, status, calls = run_script(dump, "restored_x", fails: true)

    expect(status).not_to be_success
    expect(out).to include("dropping the incomplete database restored_x")
    expect(calls.lines.last).to include('DROP DATABASE IF EXISTS "restored_x"')
  end

  it "refuses a missing or empty dump" do
    File.write(File.join(dir, "empty.dump"), "")

    [ File.join(dir, "missing.dump"), File.join(dir, "empty.dump") ].each do |path|
      out, status, = run_script(path, "restored_y")

      expect(status).not_to be_success
      expect(out).to include("not found or empty")
    end
  end
end
