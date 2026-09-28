# History URL identity regression runner

Run `Tests/HistoryRegression/run.sh` from any directory. It compiles the app's
real `Address.swift` and `History.swift` with only small app-framework and
storage stubs. The runner creates a fresh temporary store and removes it when
finished; it never reads or writes the browser's normal history file.
