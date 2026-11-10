/*
 * vtpm-close-minimal.c — the explicit-close CONTROL experiment for
 *   "INFO: task hung in vtpm_proxy_fops_release"
 *
 * Companion to vtpm-hang-minimal.c (which exits WITHOUT closing the fds
 * and reproduces the hang). This program answers the question
 * "are you closing the server-side fd returned by the ioctl? If you
 * close it, it should clear STATE_OPENED_FLAG and wake up any client":
 *
 *   1. open("/dev/vtpmx", O_RDWR)  (needs CONFIG_TCG_VTPM_PROXY=y, root)
 *   2. create N vTPM proxy devices via VTPM_PROXY_IOC_NEW_DEV
 *      (flags = 0, TPM 1.2 mode), keeping every fd the ioctl returns;
 *   3. close() each of those server-side fds EXPLICITLY, printing a
 *      timestamped line before and after every close.
 *
 * Observed results (7.3.0-kernsight-kasan #1, full layout, KVM):
 *   - N=4  and N=32: every close() returned in ~0 s, no hang
 *     (see explicit-close/explicit-close-N4-log.txt and
 *      explicit-close/explicit-close-N32-log.txt).
 *   - i.e. closing the ioctl-returned fds right after creation does
 *     NOT block: the cancel path (req_canceled checks
 *     STATE_OPENED_FLAG, which vtpm_proxy_work_stop()'s undo_open
 *     clears before flush_work()) wins when the release happens here.
 *   - The hang needs the release to overlap the register work while it
 *     is inside the transmit wait — see vtpm-hang-minimal.c (exit-time
 *     close) and minimal-c-repro/README.md.
 *
 * Build:   gcc -O2 -static -o vtpm-close-minimal vtpm-close-minimal.c
 * Run:     ./vtpm-close-minimal [N]      (N devices, default 32, as root)
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
	int n = (argc > 1) ? atoi(argv[1]) : 32;
	int ctl, i, created = 0;
	long t0;
	int *fds;

	if (n < 1 || n > 4096) {
		fprintf(stderr, "usage: %s [N]  (N devices, default 32)\n",
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
		req.flags = 0; /* TPM 1.2 */
		if (ioctl(ctl, VTPM_PROXY_IOC_NEW_DEV, &req) < 0) {
			fprintf(stderr, "ioctl NEW_DEV #%d: %s\n", i,
				strerror(errno));
			break;
		}
		fds[i] = req.fd;
		created++;
		printf("[%ld] created vtpm%d (server fd %d, client %d:%d)\n",
		       now(), req.tpm_num, req.fd, req.major, req.minor);
		fflush(stdout);
	}
	close(ctl);

	t0 = now();
	printf("[%ld] explicitly closing %d server fds (each close() may "
	       "block in flush_work)\n", now(), created);
	fflush(stdout);
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
