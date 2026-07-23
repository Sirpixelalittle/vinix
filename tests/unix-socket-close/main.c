#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#define DEFAULT_ROUNDS 32

static int wait_for(int fd, short events, short required, int round)
{
	struct pollfd poll_fd = {
		.fd = fd,
		.events = events,
	};

	int result;
	do {
		result = poll(&poll_fd, 1, 5000);
	} while (result < 0 && errno == EINTR);

	if (result != 1 || (poll_fd.revents & required) != required) {
		fprintf(stderr,
		        "round %d poll failed: result=%d requested=0x%x required=0x%x returned=0x%x errno=%d\n",
		        round, result, events, required, poll_fd.revents, errno);
		return -1;
	}
	return 0;
}

static int run_round(int round)
{
	int sockets[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) < 0) {
		perror("socketpair");
		return 1;
	}

	pid_t child = fork();
	if (child < 0) {
		perror("fork");
		return 1;
	}
	if (child == 0) {
		close(sockets[0]);
		if (write(sockets[1], "X", 1) != 1)
			_exit(2);
		_exit(0);
	}

	close(sockets[1]);

	if (wait_for(sockets[0], POLLIN, POLLIN, round) < 0)
		return -1;

	char byte = 0;
	if (read(sockets[0], &byte, 1) != 1 || byte != 'X') {
		fprintf(stderr, "round %d did not receive child payload\n", round);
		return -1;
	}

	/*
	 * Ask only for readable data. POSIX still requires poll() to report
	 * POLLHUP, and a stream read after its buffered data is drained must
	 * return EOF.
	 */
	if (wait_for(sockets[0], POLLIN, POLLHUP, round) < 0)
		return -1;
	if (read(sockets[0], &byte, 1) != 0) {
		fprintf(stderr, "round %d read after peer exit did not return EOF\n",
		        round);
		return -1;
	}

	signal(SIGPIPE, SIG_IGN);
	errno = 0;
	if (write(sockets[0], "Y", 1) != -1 || errno != EPIPE) {
		fprintf(stderr,
		        "round %d write after peer exit did not fail with EPIPE: errno=%d\n",
		        round, errno);
		return -1;
	}

	int status = 0;
	if (waitpid(child, &status, 0) != child || !WIFEXITED(status)
	    || WEXITSTATUS(status) != 0) {
		fprintf(stderr, "round %d child exit failed: status=0x%x\n", round,
		        status);
		return -1;
	}

	close(sockets[0]);
	return 0;
}

int main(int argc, char **argv)
{
	int rounds = DEFAULT_ROUNDS;
	if (argc == 2) {
		rounds = atoi(argv[1]);
		if (rounds <= 0)
			return 64;
	}

	for (int round = 1; round <= rounds; ++round) {
		if (run_round(round) < 0)
			return 1;
	}

	printf("unix socket close: PASS (%d rounds)\n", rounds);
	return 0;
}
