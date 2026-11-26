extends RefCounted
## The lifecycle probe's watchdog. A role whose commands all finish inside the
## frame that accepted them (the idle observer D in the release lifecycle) must
## not be ended by an idle limit that was last refreshed at start-up.

func run(t: Node) -> void:
	var watchdog := CommandWatchdog.new(60000, 300000, 0)
	t.assert_true(not watchdog.observe(299000, false), "a role may wait for its first command")
	var now := 0
	for started in [100000, 200000, 290000, 400000]:
		now = started
		watchdog.command_started(now)
		# The command completed synchronously: no frame ever observes it as busy.
		t.assert_true(not watchdog.observe(now + 16, false), "a command that finished in its own frame leaves the role idle")
	t.assert_true(not watchdog.observe(now + 66000, false),
		"66 s of idle after a quick command is inside the idle limit, however long the run has been")
	t.assert_true(not watchdog.observe(now + 300000, false), "the idle limit is measured from the last command")
	t.assert_true(watchdog.observe(now + 300001, false), "an orphaned role still ends after the idle limit")
	watchdog.command_started(1000000)
	t.assert_true(not watchdog.observe(1060000, true), "a running command has its full limit")
	t.assert_true(watchdog.observe(1060001, true), "a running command is ended after the command limit")
	watchdog.command_started(2000000)
	t.assert_true(not watchdog.observe(2050000, true) and not watchdog.observe(2050016, false)
		and not watchdog.observe(2349000, false), "the idle limit restarts when a long command ends")
