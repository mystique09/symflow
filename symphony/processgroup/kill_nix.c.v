module processgroup

#include <signal.h>
#include <unistd.h>

fn C.getpgrp() int
fn C.kill(pid int, signal int) int

pub fn kill(pid int) {
	if pid <= 1 || pid == C.getpgrp() {
		return
	}
	C.kill(-pid, C.SIGKILL)
}
