module Demo
  # One scenario of a scripted run: what was checked and whether it held.
  Scenario = Struct.new(:key, :title, :checks, keyword_init: true) do
    def passed? = checks.all?(&:last)
  end
end
