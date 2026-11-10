/*
 * vtpm-hang-minimal.c — minimal C reproducer for
 *   "INFO: task hung in vtpm_proxy_fops_release"
 * (kernels tested: v7.3.0 and v7.4-rc1, unpatched and with the
 *  STATE_OPENED_FLAG patch — the hang reproduces in all of them)
 *
 * Modes:
 *   ./vtpm-hang-minimal N          (auto mode, default)
 *       create N vTPM proxy devices and exit WITHOUT closing the fds;
 *       exit runs __fput() on every fd, so the release path
 *       (vtpm_proxy_fops_release() -> vtpm_proxy_work_stop() ->
 *       flush_work()) runs at process exit.
 *
 *   ./vtpm-hang-minimal N close    (explicit-close mode)
 *       create N devices, then close() each server-side fd explicitly,
 *       printing a timestamped line before and after every close.
 *       close() itself blocks in the same flush_work() — this answers
 *       the question "does explicitly closing the ioctl-returned server
 *       fd still block?" and shows whether the wait eventually ends
 *       (bounded stall) or never does (deadlock).
 *
 * Expected behavior on affected kernels: the chip-register work
 * (vtpm_proxy_work -> tpm_chip_register) keeps talking to the client
 * side (nobody is there) and times out over and over — the serial log
 * repeats "tpm tpmN: Operation Timed out" — and after ~143 s the
 * hung-task monitor reports
 *   INFO: task ... blocked for more than 143 seconds.
 *
 * The guest needs CONFIG_TCG_VTPM_PROXY=y (creates /dev/vtpmx) and the
 * process must run as root. No client side is ever opened; nothing else
 * is needed.
 *
 * Build:   gcc -O2 -static -o vtpm-hang-minimal vtpm-hang-minimal.c
 * Run:     ./vtpm-hang-minimal [N] [close]     (N devices, default 4)
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>

/* self-contained uapi definitions (linux/vtpm_proxy.h may be missing on
 * the build host); values match include/uapi/linux/vtpm_proxy.h */
struct vtpm_proxy_new_dev {
	unsigned int flags;    /* in: 0 = TPM 1.2 protocol */
	unsigned int tpm_num;  /* out: index of the TPM device */
	unsigned int fd;       /* out: fd of the (server side) proxy file */
	unsigned int major;    /* out: char device of the client side */
	unsigned int minor;    /* out: */
};
#define VTPM_PROXY_IOC_NEW_DEV _IOWR(0xa1, 0x00, struct vtpm_proxy_new_dev)

static long now(void) { return time(NULL); }

int main(int argc, char **argv)
{
	int n = (argc > 1) ? atoi(argv[1]) : 4;
	int explicit_close = (argc > 2 && strcmp(argv[2], "close") == 0);
	int ctl, i, created = 0;
	int *fds;
	long t0;

	if (n < 1 || n > 4096) {
		fprintf(stderr, "usage: %s [N] [close]  (N devices, default 4)\n",
			argv[0]);
		return 1;
	}

	ctl = open("/dev/vtpmx", O_RDWR);
	if (ctl < 0) {
		fprintf(stderr, "open(/dev/vtpmx): %s (need CONFIG_TCG_VTPM_PROXY=y, root)\n",
			strerror(errno));
		return 1;
	}

	fds = calloc(n, sizeof(int));
	if (!fds)
		return 1;

	for (i = 0; i < n; i++) {
		struct vtpm_proxy_new_dev req;
		memset(&req, 0, sizeof(req));
		req.flags = 0; /* TPM 1.2: registration runs the long
				* timeout/capabilities probing path */
		if (ioctl(ctl, VTPM_PROXY_IOC_NEW_DEV, &req) < 0) {
			fprintf(stderr, "ioctl NEW_DEV #%d: %s\n", i,
				strerror(errno));
			break;
		}
		fds[i] = req.fd; /* deliberately kept open (auto mode) */
		created++;
		printf("[%ld] created vtpm%d (server fd %d, client %d:%d)\n",
		       now(), req.tpm_num, req.fd, req.major, req.minor);
		fflush(stdout);
	}
	close(ctl);

	if (!explicit_close) {
		printf("[%ld] %d devices created; exiting without closing "
		       "them - the release path will now flush the pending "
		       "chip-register work\n", now(), created);
		fflush(stdout);
		free(fds);
		return 0;
	}

	/* explicit-close mode: answer the question "does closing the
	 * ioctl-returned server fd still block in the same flush_work()?"
	 * and record how long each close() takes (bounded stall vs. deadlock) */
	printf("[%ld] explicitly closing %d server fds (each close() may "
	       "block in flush_work)\n", now(), created);
	fflush(stdout);
	t0 = now();
	for (i = 0; i < created; i++) {
		long c0 = now();
		printf("[%ld] closing server fd %d\n", c0, fds[i]);
		fflush(stdout);
		if (close(fds[i]) < 0)
			fprintf(stderr, "close(%d): %s\n", fds[i],
				strerror(errno));
		printf("[%ld] closed server fd %d (close took %lds)\n",
		       now(), fds[i], now() - c0);
		fflush(stdout);
	}
	printf("[%ld] all %d server fds closed (total %lds)\n",
	       now(), created, now() - t0);
	fflush(stdout);
	free(fds);
	return 0;
}
