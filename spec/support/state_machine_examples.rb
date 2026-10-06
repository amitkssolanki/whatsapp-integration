# Exhaustive from x to matrix for any model that includes StatusTransitions.
#
#   it_behaves_like "a state machine", resendable_attrs: {...}
#
# The including spec defines `build_in_status(status)` returning a persisted
# record in that status.
RSpec.shared_examples "a state machine" do
  let(:model) { described_class }

  it "allows exactly the declared transitions across the full from x to matrix" do
    results = model.statuses.keys.product(model.statuses.keys).to_h do |from, to|
      record = build_in_status(from)
      [ [ from, to ], record.transition!(to) ]
    end

    declared = model::ALLOWED_TRANSITIONS.flat_map { |from, tos| tos.map { |to| [ from, to ] } }
    allowed = results.select { |_edge, ok| ok }.keys

    expect(allowed).to match_array(declared)
    expect(results.size).to eq(model.statuses.size**2)
  end

  it "persists the new status and the extra attributes on success" do
    from, to = model::ALLOWED_TRANSITIONS.first.then { |f, tos| [ f, tos.first ] }
    record = build_in_status(from)

    expect(record.transition!(to)).to be(true)
    expect(model.find(record.id).status).to eq(to)
    expect(record.status).to eq(to)
  end

  it "leaves the row untouched when the transition is not allowed" do
    from = model.statuses.keys.find { |s| model::ALLOWED_TRANSITIONS.fetch(s, []).empty? }
    record = build_in_status(from)

    expect(record.transition!(model.statuses.keys.first == from ? model.statuses.keys.last : model.statuses.keys.first)).to be(false)
    expect(model.find(record.id).status).to eq(from)
  end

  it "loses cleanly when another worker already moved the row (stale in-memory state)" do
    from, to = model::ALLOWED_TRANSITIONS.first.then { |f, tos| [ f, tos.first ] }
    stale = build_in_status(from)
    model.where(id: stale.id).update_all(status: model.statuses.fetch(to))

    expect(stale.status).to eq(from)
    expect(stale.transition!(to)).to be(false)
  end

  it "rejects an unknown target status loudly" do
    expect { build_in_status(model.statuses.keys.first).transition!(:bogus) }.to raise_error(ArgumentError, /unknown/)
  end
end
