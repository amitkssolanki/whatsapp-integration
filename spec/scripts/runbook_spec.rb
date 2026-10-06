require "rails_helper"

# Guards the operational advice in docs/deploy/RUNBOOK.md against regressing
# into the unsafe forms the review found.
RSpec.describe "docs/deploy/RUNBOOK.md" do
  let(:runbook) { Rails.root.join("docs/deploy/RUNBOOK.md").read }

  it "never puts the real verify token (or any secret variable) in a curl URL" do
    curl_lines = runbook.lines.grep(/curl/)

    expect(curl_lines).not_to include(a_string_matching(/verify_token=\$|VERIFY_TOKEN/))
    expect(curl_lines.grep(/hub\.verify_token/)).to all(include("verify_token=wrong"))
    expect(runbook).to include("access logs")
  end

  it "documents restoring into a new database and a manual rename swap, not an in-place restore" do
    expect(runbook).not_to include("--force-live")
    expect(runbook).to include("RENAME TO whatsapp_integration_production", "kamal app stop", "kamal app boot", "pg_stat_activity")
    expect(runbook.index("kamal app stop", runbook.index("Restore over the live database"))).to be < runbook.index("RENAME TO whatsapp_integration_production;")
  end
end
