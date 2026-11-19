import Foundation

signal(SIGPIPE, SIG_IGN)

coreBasicsTests()
registryTests()
transcriptTests()
hookTests()
permissionServerTests()
activityTests()
rowsTests()
settingsTests()
placementTests()
goalTests()

removeTempDirs()
if failureCount == 0 {
  print("ALL PASS (\(testCount) tests)")
  exit(0)
} else {
  print("\(failureCount) FAILED")
  exit(1)
}
