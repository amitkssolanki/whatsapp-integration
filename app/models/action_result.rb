# What an operator action did, for the UI to show: `ok?` says whether anything
# changed, `reason` says why not, `count` is how many rows a bulk action moved.
# A refused action is an ordinary outcome (a double click, a stale page), not an
# error, so it is returned rather than raised.
ActionResult = Data.define(:ok, :reason, :count) do
  def self.ok(count: nil) = new(ok: true, reason: nil, count: count)

  def self.refused(reason) = new(ok: false, reason: reason, count: nil)

  def ok? = ok

  def refused? = !ok
end
